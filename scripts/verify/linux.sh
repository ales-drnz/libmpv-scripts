# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
# shellcheck shell=bash

# The ELF layers of verify_binaries.sh: L12 UND resolvability (Linux and
# Android), the L13 dlopen of Linux and L16 ELF invariants (Linux and
# Android). Sourced by verify_binaries.sh. Do not run directly.

# ─────────────────────────────────────────────────────────────────────────────
# Layer 12 — UND symbol resolvability
# ─────────────────────────────────────────────────────────────────────────────
# The dynamic linker, at runtime, resolves every UND (st_shndx=SHN_UNDEF)
# symbol against the union of exports from all NEEDED libraries. If a UND
# symbol has no provider, the load fails. Layer 12 simulates that lookup
# offline by:
#   1. Resolving each NEEDED library to a real .so on the container's
#      filesystem (Linux: /lib/<triple>/, Android: NDK sysroot stubs at
#      /ndk-sysroot/<arch>/, mounted from the host by the build orchestrator).
#   2. Building a sorted union of exported symbol names across all those
#      .so files using `readelf -W --dyn-syms`.
#   3. Diff'ing the binary's UND set against that union via comm -23.
#   4. Filtering the diff against a whitelist of well-known weak symbols
#      and loader stubs that don't need a NEEDED provider (gmon, ITM,
#      __cxa_finalize fallback, etc.).
# Anything left is a runtime-load failure waiting to happen.
#
# Args: $1 = platform, $2 = arch (x86_64|aarch64|arm64-v8a|x86),
#       $3 = artifact path, $4 = newline-separated NEEDED list
layer12_und_resolvable() {
  local platform="$1" arch="$2" artifact="$3" deps="$4"
  phase l12
  local triple="" sysroot=""

  # Map (platform, arch) → multiarch sysroot path within the container.
  case "$platform/$arch" in
    linux/x86_64)         triple="x86_64-linux-gnu" ;;
    linux/aarch64)        triple="aarch64-linux-gnu" ;;
    android/arm64-v8a)    triple="aarch64-linux-android" ;;
    android/armeabi-v7a)  triple="arm-linux-androideabi" ;;
    android/x86_64)       triple="x86_64-linux-android" ;;
    tizen/armv7l|tizen/x86_64)
      sysroot="$(_tizen_sysroot "$arch")" || {
        fail "L12: the Tizen sysroot of $arch could not be unpacked"
        return 0
      }
      ;;
    webos/armv7l)
      sysroot="$(_webos_sysroot)" || {
        fail "L12: the webOS sysroot could not be taken out of the NDK"
        return 0
      }
      ;;
    windows/*)
      na "UND resolvability is nm/ELF-based; a PE's imports are bound by the Windows loader at runtime — covered by the L13 LoadLibrary load test instead."
      return 0
      ;;
    macos/*|ios/*|tvos/*)
      na "UND resolvability is nm/ELF-based; a Mach-O dylib's binds are resolved by Apple's dyld (validated at consumer link/load), not introspectable with nm here."
      return 0
      ;;
    *)
      warn "L12: no triple mapping for $platform/$arch"
      return 0
      ;;
  esac

  # Locate exports by walking NEEDED → real .so. Linux: /lib/<triple>/.
  # Android: /ndk-sysroot/<arch>/, expected mounted by the build orchestrator.
  local search_dirs=()
  case "$platform" in
    linux)
      search_dirs=("/lib/$triple" "/usr/lib/$triple" "/lib" "/usr/lib")
      ;;
    android)
      # NDK ships per-API-level stub .so files. We use API 24 stubs (the
      # minimum mpv_audio_kit officially supports).
      search_dirs=(
        "/ndk-sysroot/$triple/24"
        "/ndk-sysroot/$triple"
      )
      if [[ ! -d "/ndk-sysroot/$triple" && ! -d "/ndk-sysroot/$triple/24" ]]; then
        warn "L12: NDK sysroot not mounted at /ndk-sysroot — Android UND check skipped (mount the NDK in './build verify' to enable)"
        return 0
      fi
      ;;
    tizen|webos)
      search_dirs=("$sysroot/lib64" "$sysroot/usr/lib64" "$sysroot/lib" "$sysroot/usr/lib")
      ;;
  esac
  # The host's nm reads only its own arch: llvm-nm reads the Tizen ones.
  local nm=nm
  [[ "$platform" == tizen || "$platform" == webos ]] && nm="$(_llvm_tool nm)"

  # Build exports union. Each NEEDED entry is resolved to its first match
  # under search_dirs. Missing system libs → warning (means our allowlist
  # is right but the container doesn't ship the .so to introspect).
  #
  # We use `nm -D --defined-only --extern-only` (not readelf-awk) for two
  # reasons: (a) nm output is column-stable across binutils versions, and
  # (b) by default it includes every dynamic symbol the dynamic linker
  # would consider during resolution — both GLOBAL and WEAK bindings
  # (huge for C++ stdlib, where most template instantiations are WEAK).
  # The earlier readelf approach with `$5=="GLOBAL"` silently dropped
  # ~4000 weak C++ symbols out of libstdc++.so.6.
  local exports_db="$(mktemp)"
  local missing=()
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    local found=""
    for d in "${search_dirs[@]}"; do
      [[ -f "$d/$dep" ]] && { found="$d/$dep"; break; }
    done
    if [[ -z "$found" ]]; then
      missing+=("$dep")
      continue
    fi
    # nm -D output is "<addr> <type> <name>". Type single letter:
    # T/t=text, D/d=data, B/b=bss, R/r=rodata, W/w=weak, V/v=weak object,
    # i=indirect, U=undefined. We want everything DEFINED — i.e. anything
    # that is NOT 'U'. The dynamic linker resolves UND of one .so against
    # any of these in another .so.
    "$nm" -D --defined-only --extern-only "$found" 2>/dev/null \
      | awk '$2 != "U" && $NF != "" {sub(/@.*/,"",$NF); print $NF}' \
      >> "$exports_db" || true
  done <<<"$deps"

  if (( ${#missing[@]} > 0 )); then
    warn "L12: NEEDED .so missing in container (cannot introspect): ${missing[*]}"
  fi

  # Linux only: also fold in the dynamic linker's exports. ld-linux-*.so
  # provides __libc_start_main, __cxa_finalize, dl_iterate_phdr, etc.,
  # which are referenced by binaries but rarely appear in NEEDED.
  if [[ "$platform" == "linux" || "$platform" == "tizen" || "$platform" == "webos" ]]; then
    # shellcheck disable=SC2206  # the globs expand here, on purpose
    local lds=(/lib/ld-linux-${arch//-/_}.so.* /lib/ld-linux*.so.* /lib64/ld-linux*.so.*)
    [[ "$platform" == tizen || "$platform" == webos ]] && lds=("$sysroot"/lib/ld-linux*.so.* "$sysroot"/lib64/ld-linux*.so.*)
    for ld in "${lds[@]}"; do
      [[ -f "$ld" ]] || continue
      "$nm" -D --defined-only --extern-only "$ld" 2>/dev/null \
        | awk '$2 != "U" && $NF != "" {sub(/@.*/,"",$NF); print $NF}' \
        >> "$exports_db" || true
    done
  fi

  sort -u "$exports_db" -o "$exports_db"

  # Get UND symbols of the binary, strip version tag, sort/uniq. Only STRONG
  # undefined (nm type 'U') must resolve against a NEEDED lib. WEAK undefined
  # ('w'/'v') is loader-legal: it resolves to 0 when absent and the caller
  # guards the call — e.g. OpenSSL references getentropy() weakly when built
  # with __ANDROID_API__ < 28 (added to bionic in 28), with a /dev/urandom
  # fallback, so the .so stays correct on the API-24 floor.
  local und_db="$(mktemp)"
  if ! "$nm" -D --undefined-only "$artifact" 2>/dev/null \
    | awk '$1 == "U" && $NF != "" {sub(/@.*/,"",$NF); print $NF}' \
    | sort -u > "$und_db"; then
    fail "L12 UND resolvability: nm failed on $(basename "$artifact")"
    rm -f "$exports_db" "$und_db"
    return 0
  fi

  # Whitelist of symbols that legitimately stay UND in a .so:
  #   __gmon_start__, _ITM_*  → gprof / Intel TM stubs (always weak).
  #   _Jv_RegisterClasses     → GCJ stub (weak, deprecated).
  #   _DYNAMIC, _GLOBAL_OFFSET_TABLE_ → loader-internal sections, not real syms.
  #   __cxa_finalize          → glibc 2.2+ exits handler, weak by definition.
  #   __register_atfork       → glibc 2.27+, weak.
  #   _Unwind_*               → libgcc_s, but some distros mark as weak.
  local weak_re='^(__gmon_start__|_ITM_(deregisterTMCloneTable|registerTMCloneTable)|_Jv_RegisterClasses|_DYNAMIC|_GLOBAL_OFFSET_TABLE_|__cxa_finalize|__register_atfork|_edata|_end|__bss_start)$'
  local unresolved="$(mktemp)"
  comm -23 "$und_db" "$exports_db" 2>/dev/null \
    | grep -vE "$weak_re" > "$unresolved" || true

  local und_count exports_count unresolved_count
  und_count=$(wc -l <"$und_db" | tr -d ' ')
  exports_count=$(wc -l <"$exports_db" | tr -d ' ')
  unresolved_count=$(wc -l <"$unresolved" | tr -d ' ')

  if (( und_count == 0 || exports_count == 0 )); then
    fail "L12 UND resolvability: empty symbol set ($und_count UND, $exports_count NEEDED exports), nothing was checked"
  elif (( unresolved_count == 0 )); then
    pass "L12 UND resolvability: all $und_count UND symbols resolve against $exports_count NEEDED exports"
  else
    fail "L12 UND resolvability: $unresolved_count/$und_count UND symbol(s) NOT resolved by any NEEDED lib"
    head -10 "$unresolved" | sed 's/^/       · /'
    if (( unresolved_count > 10 )); then
      printf "       (+%d more)\n" $((unresolved_count - 10))
    fi
  fi

  rm -f "$exports_db" "$und_db" "$unresolved"
  # Explicit return so the function never propagates a non-zero exit from
  # an optional sub-command — set -e in the caller would otherwise abort
  # the per-binary loop after a mid-flight transient (e.g. a closed pipe
  # in `head | sed`, an arithmetic comparison's status, etc.).
  return 0
}

_l13_linux_dlopen() {
  local arch="$1" artifact="$2"
  local cc="" qemu=""
  case "$arch" in
    x86_64)  cc="x86_64-linux-gnu-gcc"  qemu="qemu-x86_64-static"  ;;
    aarch64) cc="aarch64-linux-gnu-gcc" qemu="qemu-aarch64-static" ;;
    *) warn "L13: unsupported linux arch=$arch"; return 0 ;;
  esac

  local helper_src="$LIBMPV_SCRIPTS_ROOT/verify/dlopen_test.c"
  if [[ ! -f "$helper_src" ]]; then
    warn "L13: dlopen helper missing: $helper_src"
    return 0
  fi

  local helper_bin
  helper_bin="$(mktemp)"
  if ! "$cc" -O0 -o "$helper_bin" "$helper_src" -ldl 2>/dev/null; then
    fail "L13: dlopen helper failed to cross-compile for $arch"
    rm -f "$helper_bin"
    return 0
  fi

  # Decide native vs qemu based on host arch (image arch). qemu-user-static
  # is invoked only when foreign — qemu adds ~50ms overhead but is otherwise
  # transparent.
  local host_arch; host_arch="$(uname -m)"
  local runner=()
  case "$host_arch/$arch" in
    x86_64/x86_64|aarch64/aarch64) ;;
    *)
      if ! command -v "$qemu" >/dev/null 2>&1; then
        warn "L13: qemu-user-static missing for $arch on $host_arch host — load test skipped"
        rm -f "$helper_bin"
        return 0
      fi
      runner=("$qemu")
      ;;
  esac

  # Stage the binary + helper next to each other so dlopen() finds it via
  # rpath-less name. We pass the absolute path anyway, so this is just for
  # tidiness.
  # 60s timeout guards against any future regression where dlopen hangs on
  # a misbehaving constructor or fork+exec inside a static dep.
  local out rc
  out="$(timeout 60 "${runner[@]}" "$helper_bin" "$artifact" 2>&1)"
  rc=$?
  rm -f "$helper_bin"
  case "$rc" in
    0)   pass "L13 dlopen(RTLD_NOW): loads + initializes + patched props respond at runtime" ;;
    124) fail "L13 dlopen timed out after 60s: $out" ;;
    *)   fail "L13 dlopen failed (exit=$rc): $out" ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 16 — ELF loader invariants (Linux + Android)
# ─────────────────────────────────────────────────────────────────────────────
# The same facts the build scripts assert (assert_soname, assert_no_relr,
# assert_load_align, assert_glibc_floor in _audio_only.sh), checked again on
# the shipped file:
#   SONAME     libmpv_audio_kit.so, so the kit never collides with another
#              plugin's libmpv in one process or one bundle.
#   DT_RELR    absent (tag 0x24, or Android's OS-private 0x6fffe000): glibc
#              below 2.36 refuses it, bionic below API 30 skips it silently.
#   alignment  every LOAD segment aligned to >= 0x4000 on arm64-v8a and
#              x86_64, which Android 15+ devices with 16 KB pages require.
#   glibc      no GLIBC_x.y symbol version above LINUX_GLIBC_FLOOR.
# Args: $1 = platform, $2 = arch, $3 = artifact path, $4 = readelf
layer16_elf_invariants() {
  local platform="$1" arch="$2" artifact="$3" readelf="${4:-readelf}"
  phase l16
  case "$platform" in
    linux|android|tizen|webos) ;;
    *) na "ELF loader invariants; $platform binaries are not ELF."; return 0 ;;
  esac
  local floor="$LINUX_GLIBC_FLOOR"
  [[ "$platform" == tizen ]] && floor="$TIZEN_GLIBC_FLOOR"
  [[ "$platform" == webos ]] && floor="$WEBOS_GLIBC_FLOOR"

  local dyn
  dyn="$(LC_ALL=C "$readelf" -dW "$artifact" 2>/dev/null)"
  if [[ -z "$dyn" ]]; then
    fail "L16: readelf -d produced no output (tool failure)"
    return 0
  fi

  local soname
  soname="$(sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p' <<<"$dyn")"
  if [[ "$soname" == "$MPV_SONAME" ]]; then
    pass "L16 SONAME $soname"
  else
    fail "L16 SONAME is '${soname:-none}', expected $MPV_SONAME"
  fi

  if grep -qE '^ *0x0*(24|6fffe000) ' <<<"$dyn"; then
    fail "L16 DT_RELR present (glibc < 2.36 refuses it, Android < 11 skips it)"
  else
    pass "L16 no DT_RELR"
  fi

  if [[ "$platform" == android ]]; then
    case "$arch" in
      arm64-v8a|x86_64)
        local aligns a low=""
        aligns="$(LC_ALL=C "$readelf" -lW "$artifact" 2>/dev/null | awk '$1 == "LOAD" {print $NF}')"
        if [[ -z "$aligns" ]]; then
          fail "L16: no LOAD segments read (tool failure)"
        else
          for a in $aligns; do
            (( a >= 0x4000 )) || low+="$a "
          done
          if [[ -z "$low" ]]; then
            pass "L16 LOAD alignment >= 0x4000 (16 KB pages)"
          else
            fail "L16 LOAD segment(s) aligned below 0x4000: $low"
          fi
        fi
        ;;
      *) info "L16 16 KB alignment: not required on $arch (32-bit)" ;;
    esac
  else
    local newest
    newest="$(LC_ALL=C "$readelf" -W -V "$artifact" 2>/dev/null \
      | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/GLIBC_//' | sort -Vu | tail -1)"
    if [[ -z "$newest" ]]; then
      fail "L16 glibc floor: no GLIBC symbol versions read (tool failure)"
    elif [[ "$(printf '%s\n%s\n' "$newest" "$floor" | sort -V | tail -1)" == "$floor" ]]; then
      pass "L16 glibc floor: needs $newest (max $floor)"
    else
      fail "L16 glibc floor: needs $newest, above $floor"
    fi
  fi
  return 0
}
