#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks L12 of verify_binaries.sh on webOS: the NDK's sysroot is a
# multilib tree, its usr/lib64 the TVs' 64-bit userland, and an app's
# armv7 libmpv binds the 32-bit glibc of usr/lib only. A small armv7
# library that asks for strtof128, which only the aarch64 glibc has, must
# fail it; one that asks for strtof must pass. Runs in the mpv-build-verify
# image, with the webOS sysroot of _webos_sysroot.
#
# Usage: bash verify/tests/webos_l12_test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export LIBMPV_SCRIPTS_ROOT="$ROOT"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_helpers.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_versions.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_audio_only.sh"
for part in common linux tizen webos; do
  # shellcheck source=/dev/null
  source "$ROOT/scripts/verify/$part.sh"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sysroot="$(cd "$(_webos_sysroot)" && pwd)" || { echo "FAIL no webOS sysroot"; exit 1; }
gcc_dir="$(ls -d "$sysroot"/usr/lib/arm-webosmllib32-linux-gnueabi/*/ | head -1)"

# fixture <name> <function>: an armv7 library whose one undefined symbol is
# <function> of libc.
fixture() {
  printf 'extern int %s(void);\nint f(void) { return %s(); }\n' "$2" "$2" > "$TMP/$1.c"
  "$(_llvm_tool clang)" --target=arm-linux-gnueabi --sysroot="$sysroot" \
    -march=armv7-a -mfpu=neon -mfloat-abi=softfp -mthumb -fuse-ld=lld \
    -B"$gcc_dir" -L"$gcc_dir" -shared -fPIC -nostdlib -fno-builtin -w "$TMP/$1.c" \
    -Wl,--unresolved-symbols=ignore-all -Wl,--no-as-needed -lc -o "$TMP/$1.so"
}

failures=0
expect() { # expect pass|fail <name> <function>
  local want="$1" name="$2"
  fixture "$name" "$3" || { echo "FAIL $name did not build"; failures=$((failures + 1)); return; }
  local before="$FAILED"
  layer12_und_resolvable webos armv7l "$TMP/$name.so" "libc.so.6" > "$TMP/out" 2>&1
  local got=pass
  (( FAILED > before )) && got=fail
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name: L12 $want"
  else
    echo "FAIL $name: L12 should $want, got $got:"; cat "$TMP/out"
    failures=$((failures + 1))
  fi
}

expect fail aarch64_only strtof128
expect pass armv7_too strtof

(( failures == 0 )) && echo "webos_l12_test: all passed" || echo "webos_l12_test: $failures failed"
exit $(( failures > 0 ))
