# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
# shellcheck shell=bash

# The webOS pieces of verify_binaries.sh: the TVs' sysroot out of LG's
# webOS NDK, and the L13 dlopen under qemu-user on it. L11, L12 and L16
# have their webos case in common.sh and linux.sh. Sourced by
# verify_binaries.sh. Do not run directly.

source "$LIBMPV_SCRIPTS_ROOT/scripts/webos/webos_ndk.sh"

# The webOS sysroot: an installed NDK's that has the /lib qemu -L needs,
# else the one taken out of the NDK's installer once (webos_ndk_sysroot).
_webos_sysroot() {
  local ndk="${WEBOS_NDK:-/opt/webos-ndk}/sysroots/$WEBOS_NDK_TARGET"
  if [[ -f "$ndk/usr/lib/libc.so.6" && -e "$ndk/lib/ld-linux.so.3" ]]; then
    echo "$ndk"; return 0
  fi
  webos_ndk_sysroot "${WEBOS_SYSROOT_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work/webOS/ndk}"
}

# webOS: dlopen_test built with clang (_llvm_tool, of tizen.sh, sourced
# first) against the webOS sysroot and run with qemu-user, whose -L takes
# the sysroot as the root of the loader: libmpv binds against the TVs'
# glibc 2.39 and ALSA (the helper plays nothing: ao=null).
_l13_webos_dlopen() {
  local arch="$1" artifact="$2"
  [[ "$arch" == armv7l ]] || { warn "L13: unsupported webos arch=$arch"; return 0; }
  command -v qemu-arm-static >/dev/null 2>&1 || { fail "L13: qemu-arm-static missing"; return 0; }
  local sysroot
  sysroot="$(_webos_sysroot)" || { fail "L13: the webOS sysroot could not be taken out of the NDK"; return 0; }
  sysroot="$(cd "$sysroot" && pwd)"
  # The NDK's GCC files (crtbegin, libgcc) are where Yocto puts them.
  local gcc tmp
  gcc="$(ls -d "$sysroot"/usr/lib/arm-webosmllib32-linux-gnueabi/*/ 2>/dev/null | head -1)"
  tmp="$(mktemp -d)"
  if ! "$(_llvm_tool clang)" --target=arm-linux-gnueabi --sysroot="$sysroot" \
       -march=armv7-a -mfpu=neon -mfloat-abi=softfp -mthumb -fuse-ld=lld \
       -B"$gcc" -L"$gcc" -O0 "$LIBMPV_SCRIPTS_ROOT/verify/dlopen_test.c" -ldl \
       -o "$tmp/dlopen_test" 2>/dev/null; then
    fail "L13: dlopen helper failed to build for webos/$arch"
    rm -rf "$tmp"; return 0
  fi
  local out rc
  # As on Tizen: no ld.so.cache in the sysroot, so its own directories
  # come first in the search path.
  out="$(timeout 120 qemu-arm-static -L "$sysroot" -E LD_LIBRARY_PATH="/usr/lib:/lib" \
    "$tmp/dlopen_test" "$artifact" 2>&1)"; rc=$?
  rm -rf "$tmp"
  case "$rc" in
    0)   pass "L13 dlopen(RTLD_NOW) on webOS's glibc under qemu-arm-static: loads + initializes + patched props respond" ;;
    124) fail "L13 dlopen timed out after 120s: $out" ;;
    *)   fail "L13 dlopen failed (exit=$rc): $out" ;;
  esac
  return 0
}
