# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
# shellcheck shell=bash

# The Tizen pieces of verify_binaries.sh: the llvm tools that read and
# target every arch, the sysroot of Tizen 6.0 packages, and the L13
# dlopen under qemu-user on it. L11, L12 and L16 have their tizen case in
# common.sh and linux.sh. Sourced by verify_binaries.sh. Do not run
# directly.

# An llvm tool (nm, readelf, objdump, clang): llvm-mingw's in the verify
# image, else the one on PATH. They read and target every arch.
_llvm_tool() {
  local d="${LLVM_MINGW_DIR:-/opt/llvm-mingw}/bin"
  case "$1" in
    clang) [[ -x "$d/clang" ]] && { echo "$d/clang"; return; }; echo clang ;;
    *)     [[ -x "$d/llvm-$1" ]] && { echo "$d/llvm-$1"; return; }; echo "llvm-$1" ;;
  esac
}

# The Tizen sysroot of arch (armv7l, x86_64): the build's own when it is there,
# else unpacked once from the pinned packages (scripts/tizen/tizen_sysroot.py).
_tizen_sysroot() {
  local arch="$1"
  local dir="${TIZEN_SYSROOT_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work/Tizen/$arch/sysroot}"
  local lock="$LIBMPV_SCRIPTS_ROOT/scripts/tizen/tizen_sysroot.sha256"
  if ! { [[ -f "$dir/.lock" ]] && cmp -s "$lock" "$dir/.lock"; }; then
    python3 -B "$LIBMPV_SCRIPTS_ROOT/scripts/tizen/tizen_sysroot.py" "$arch" "$dir" >/dev/null || return 1
    cp "$lock" "$dir/.lock"
  fi
  echo "$dir"
}

# Tizen: dlopen_test built with clang against the Tizen sysroot and run with
# qemu-user, whose -L takes the sysroot as the root of the loader: libmpv
# binds against the TVs' glibc 2.30 and libgcc. The real audio APIs need
# the whole Tizen sound stack, so stubs of the same names stand in for them
# (the helper plays nothing: ao=null).
_l13_tizen_dlopen() {
  local arch="$1" artifact="$2" target qemu flags=()
  case "$arch" in
    armv7l) target="armv7l-tizen-linux-gnueabi" qemu="qemu-arm-static"
            flags=(-march=armv7-a -mfpu=neon -mfloat-abi=softfp -mthumb) ;;
    x86_64) target="x86_64-tizen-linux-gnu" qemu="qemu-x86_64-static" ;;
    *) warn "L13: unsupported tizen arch=$arch"; return 0 ;;
  esac
  command -v "$qemu" >/dev/null 2>&1 || { fail "L13: $qemu missing"; return 0; }
  local sysroot
  sysroot="$(_tizen_sysroot "$arch")" || { fail "L13: the Tizen sysroot of $arch could not be unpacked"; return 0; }
  local tmp tizen_cc
  tmp="$(mktemp -d)"
  tizen_cc=("$(_llvm_tool clang)" --target="$target" --sysroot="$sysroot" "${flags[@]}" -fuse-ld=lld)
  cat > "$tmp/capi_stub.c" <<'EOF'
int audio_out_create_new(void) { return -1; }
int audio_out_destroy(void) { return -1; }
int audio_out_set_sound_stream_info(void) { return -1; }
int audio_out_prepare(void) { return -1; }
int audio_out_unprepare(void) { return -1; }
int audio_out_pause(void) { return -1; }
int audio_out_resume(void) { return -1; }
int audio_out_flush(void) { return -1; }
int audio_out_write(void) { return -1; }
int sound_manager_create_stream_information(void) { return -1; }
int sound_manager_destroy_stream_information(void) { return -1; }
EOF
  local lib ok=1
  for lib in libcapi-media-audio-io.so.0 libcapi-media-sound-manager.so.0 libcapi-base-common.so.0; do
    "${tizen_cc[@]}" -shared -fPIC -Wl,-soname,"$lib" "$tmp/capi_stub.c" -o "$tmp/$lib" 2>/dev/null || ok=0
  done
  "${tizen_cc[@]}" -O0 "$LIBMPV_SCRIPTS_ROOT/verify/dlopen_test.c" -ldl -o "$tmp/dlopen_test" 2>/dev/null || ok=0
  if (( ! ok )); then
    fail "L13: dlopen helper or capi stubs failed to build for tizen/$arch"
    rm -rf "$tmp"; return 0
  fi
  local out rc
  # The sysroot has no ld.so.cache, and qemu then hands the loader the
  # host's, whose x86_64 entries the Tizen loader would take: its own
  # directories come first in the search path instead.
  local libs="$tmp:/lib64:/usr/lib64:/lib:/usr/lib"
  out="$(timeout 120 "$qemu" -L "$sysroot" -E LD_LIBRARY_PATH="$libs" "$tmp/dlopen_test" "$artifact" 2>&1)"; rc=$?
  rm -rf "$tmp"
  case "$rc" in
    0)   pass "L13 dlopen(RTLD_NOW) on Tizen's glibc under $qemu: loads + initializes + patched props respond" ;;
    124) fail "L13 dlopen timed out after 120s: $out" ;;
    *)   fail "L13 dlopen failed (exit=$rc): $out" ;;
  esac
  return 0
}
