#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks scripts/webos/webos_ndk.sh: the webos stage of docker/Dockerfile
# installs the NDK of its version and checksum, and webos_ndk_sysroot takes
# only the target's sysroot out of an installer (a fake one here: a script,
# MARKER: and a tar.xz), never runs it, and refuses one of another checksum.
#
# Usage: bash verify/tests/webos_ndk_test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=/dev/null
source "$ROOT/scripts/webos/webos_ndk.sh"

failures=0
check() { # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; failures=$((failures + 1)); fi
}

docker_arg() { sed -n "s/^ARG $1=//p" "$ROOT/docker/Dockerfile"; }
check "the Dockerfile installs NDK $WEBOS_NDK_VERSION" \
  test "$(docker_arg WEBOS_NDK_VERSION)" = "$WEBOS_NDK_VERSION"
check "at the same SHA-256" \
  test "$(docker_arg WEBOS_NDK_SHA256)" = "$WEBOS_NDK_SHA256"

# A fake installer: running it would leave a mark.
mkdir -p "$TMP/payload/sysroots/$WEBOS_NDK_TARGET/usr/lib" "$TMP/payload/sysroots/x86_64-starfishsdk-linux/usr/bin"
echo libc > "$TMP/payload/sysroots/$WEBOS_NDK_TARGET/usr/lib/libc.so.6"
echo gcc > "$TMP/payload/sysroots/x86_64-starfishsdk-linux/usr/bin/gcc"
{
  printf '#!/bin/sh\ntouch "%s/ran"\nexit 0\nMARKER:\n' "$TMP"
  tar -C "$TMP/payload" -cJ ./sysroots
} > "$TMP/fake.sh"
WEBOS_NDK_SHA256="$(sha256sum "$TMP/fake.sh" | cut -d' ' -f1)"
mkdir -p "$TMP/dir"
cp "$TMP/fake.sh" "$TMP/dir/webos-ndk.sh"

out="$(webos_ndk_sysroot "$TMP/dir")"
check "the sysroot is printed" test "$out" = "$TMP/dir/sysroot"
check "the target's sysroot is taken out" test -f "$TMP/dir/sysroot/usr/lib/libc.so.6"
check "the SDK's own tools are not" test ! -e "$TMP/dir/sysroot/usr/bin/gcc"
check "/lib is the merged /usr/lib" test "$(readlink "$TMP/dir/sysroot/lib")" = usr/lib
check "the installer never runs" test ! -e "$TMP/ran"
rm "$TMP/dir/webos-ndk.sh"
check "a sysroot of this checksum is kept" test "$(webos_ndk_sysroot "$TMP/dir")" = "$TMP/dir/sysroot"

# Another checksum: the installer is downloaded again, and one that does
# not match is refused.
WEBOS_NDK_SHA256="$(printf '0%.0s' {1..64})"
cp "$TMP/fake.sh" "$TMP/dir/webos-ndk.sh"
webos_ndk_url() { echo "file://$TMP/fake.sh"; }
if webos_ndk_sysroot "$TMP/dir" > /dev/null 2>&1; then
  echo "FAIL an installer of another checksum is refused"; failures=$((failures + 1))
else
  echo "ok   an installer of another checksum is refused"
fi

(( failures == 0 )) && echo "webos_ndk_test: all passed" || echo "webos_ndk_test: $failures failed"
exit $(( failures > 0 ))
