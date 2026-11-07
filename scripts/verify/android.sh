# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# The Android layer of verify_binaries.sh: L14 stub detection of
# JNI_OnLoad. Sourced by verify_binaries.sh. Do not run directly.

# ─────────────────────────────────────────────────────────────────────────────
# Layer 14 — stub-function detection (defense in depth for Layer 0)
# ─────────────────────────────────────────────────────────────────────────────
# A binary can pass every previous layer (correct format, exports, NEEDED,
# UND resolvability, even a real dlopen) and STILL be functionally broken
# at runtime if a critical internal function was compiled as an
# unconditional-error stub. Concrete case that bit us:
#
#   - ffmpeg's `libavcodec/jni.c` defines `av_jni_set_java_vm` only when
#     CONFIG_JNI=1; otherwise the file falls through to a 2-instruction
#     stub that returns AVERROR(ENOSYS) without storing the VM pointer.
#   - Layer 0 (build-time config audit) catches this PRE-link.
#   - Layer 14 catches it POST-link, as a redundant guard for when
#     binaries are built outside our control (e.g. CI fetches them).
#
# Algorithm (Android only — the only platform with a critical exported
# entry point that delegates to an internal function):
#   1. Find JNI_OnLoad's address (it's exported and in our version script).
#   2. Disassemble JNI_OnLoad's first ~16 instructions.
#   3. Find its `bl <addr>` (aarch64) or `callq <addr>` (x86_64).
#   4. Disassemble the target's first ~32 instructions.
#   5. Count instructions before the first `ret`. Real
#      av_jni_set_java_vm has 30+ (prologue, mutex_lock, globals, mutex_
#      unlock, epilogue); stub has 2 (mov, ret).
#
# < 5 instructions → fail loudly with the diagnostic the maintainer needs
# (almost always: "ffmpeg was built without --enable-jni").
layer14_stub_detection() {
  local platform="$1" arch="$2" artifact="$3"
  phase l14
  case "$platform" in
    android) _l14_jni_onload_real "$arch" "$artifact" ;;
    *)       na "stub detection targets Android's JNI_OnLoad→av_jni_set_java_vm delegate chain, which only exists on Android." ;;
  esac
  return 0
}

_l14_jni_onload_real() {
  local arch="$1" so="$2"
  local nm objdump
  case "$arch" in
    arm64-v8a)   nm="aarch64-linux-gnu-nm";    objdump="aarch64-linux-gnu-objdump"    ;;
    armeabi-v7a) nm="arm-linux-gnueabihf-nm";  objdump="arm-linux-gnueabihf-objdump"  ;;
    x86_64)      nm="x86_64-linux-gnu-nm";     objdump="x86_64-linux-gnu-objdump"     ;;
    *) warn "L14: unknown android arch $arch"; return 0 ;;
  esac

  # JNI_OnLoad must be exported (Layer 2 already validates it; reading it
  # here gives us the address for follow-up disassembly).
  local jni_addr
  jni_addr=$("$nm" -D --defined-only "$so" 2>/dev/null \
    | awk '$3=="JNI_OnLoad" {print "0x"$1; exit}')
  if [[ -z "$jni_addr" ]]; then
    fail "L14: JNI_OnLoad missing — Android JNI bootstrap not wired"
    return 0
  fi

  # Disassemble JNI_OnLoad's first ~16 instructions (64 bytes), look for
  # the bl/callq target. JNI_OnLoad is a 4-instruction wrapper around
  # av_jni_set_java_vm so the call is always within the first 16 bytes.
  # binutils objdump emits `bl 917d0c <symbol+offset>` (no `0x` prefix)
  # whereas llvm-objdump emits `bl 0x917d0c`; awk-extract the address
  # field robustly across both.
  local jni_addr_dec=$((jni_addr))
  local target
  target=$("$objdump" -d \
      --start-address=$jni_addr_dec --stop-address=$((jni_addr_dec + 64)) \
      "$so" 2>/dev/null \
    | awk '
        # aarch64 binutils → "bl 917d0c <sym+off>"
        # x86_64  binutils → "call a01750 <sym+off>"
        # llvm-objdump     → "bl 0x917d0c" / "callq 0xa01750"
        $0 ~ /[[:space:]](bl|call|callq)[[:space:]]/ {
          for (i=1; i<=NF; i++) {
            if ($i == "bl" || $i == "call" || $i == "callq") {
              v = $(i+1)
              sub(/<.*/, "", v)        # strip "<symbol+offset>" suffix
              sub(/^0x/, "", v)        # strip "0x" prefix if present
              if (v ~ /^[0-9a-fA-F]+$/) { print "0x" v; exit }
            }
          }
        }')

  if [[ -z "$target" ]]; then
    fail "L14: JNI_OnLoad has no bl/callq instruction — likely a no-op stub"
    return 0
  fi

  # Disassemble target's first 64 instructions (256 bytes), count
  # instructions before first `ret` / `retq`.
  local target_dec=$((target))
  local n_insns
  n_insns=$("$objdump" -d \
      --start-address=$target_dec --stop-address=$((target_dec + 256)) \
      "$so" 2>/dev/null \
    | awk '
        # Count instructions until the function returns. Return idioms are
        # arch-specific: x86 ret/retq, AArch64 ret, ARM32 bx lr /
        # pop {..,pc} / ldm ..,{..,pc} / mov pc,lr. Without the ARM32 forms
        # the counter never terminates on a 32-bit-ARM .so and a real
        # function reads as a 0-instruction stub.
        /^[[:space:]]*[0-9a-f]+:/ {
          n++
          if ($0 ~ /[[:space:]](ret|retq)([[:space:]]|$)/ ||
              $0 ~ /[[:space:]]bx[[:space:]]+lr([[:space:]]|$)/ ||
              $0 ~ /\{[^}]*pc[[:space:]]*\}/ ||
              $0 ~ /[[:space:]]mov[[:space:]]+pc,[[:space:]]*lr/) { print n; exit }
        }')

  if [[ -z "$n_insns" ]] || (( n_insns < 5 )); then
    fail "L14: JNI_OnLoad → av_jni_set_java_vm at $target is a stub (${n_insns:-0} insns before ret); ffmpeg likely missing --enable-jni"
  else
    pass "L14 stub detection: JNI_OnLoad chain is real ($n_insns insns, target $target)"
  fi
}
