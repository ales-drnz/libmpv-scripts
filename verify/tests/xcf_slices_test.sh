#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks the slice check of verify_binaries.sh on unzipped xcframeworks
# made here: every slice is of the platform the zip is named for, and
# iOS and tvOS have a device slice. The function is read out of the
# script, as in l13_windows_test.sh.
#
# Usage: bash verify/tests/xcf_slices_test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/verify_binaries.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

body="$(awk '$0 ~ "^_xcf_slices_check\\(\\) \\{" { on = 1 } on { print } on && /^}/ { exit }' "$SCRIPT")"
[[ -n "$body" ]] || { echo "FAIL: _xcf_slices_check not found in $SCRIPT"; exit 1; }
eval "$body"
RESULT=""
pass() { RESULT="pass $*"; }
fail() { RESULT="fail $*"; }

# xcf <name> <slice...>: an unzipped xcframework with those slices.
xcf() {
  local dir="$TMP/$1"; shift
  for s in "$@"; do mkdir -p "$dir/libmpv.xcframework/$s/libmpv.framework"; done
  echo "$dir"
}
check() {
  local want="$1" why="$2" platform="$3" dir="$4"
  RESULT=""
  _xcf_slices_check "$platform" "$dir"
  if [[ "$RESULT" == "$want"* ]]; then echo "ok   $why"; else echo "FAIL $why: $RESULT"; fails=$((fails + 1)); fi
}

check pass "tvOS with its device and simulator slices" tvos \
  "$(xcf tv tvos-arm64 tvos-arm64_x86_64-simulator)"
# codesign --deep writes _CodeSignature/ next to the slices.
check pass "tvOS signed, with _CodeSignature beside the slices" tvos \
  "$(xcf tvsigned tvos-arm64 tvos-arm64_x86_64-simulator _CodeSignature)"
check fail "a tvOS zip with iOS slices refused" tvos \
  "$(xcf tvios ios-arm64 ios-arm64_x86_64-simulator)"
check fail "tvOS with only a simulator slice refused" tvos \
  "$(xcf tvsim tvos-arm64_x86_64-simulator)"
check pass "iOS with its device and simulator slices" ios \
  "$(xcf ios ios-arm64 ios-arm64_x86_64-simulator)"
check pass "macOS with its universal slice" macos "$(xcf mac macos-arm64_x86_64)"
check pass "macOS arm64 only, signed" macos "$(xcf macarm macos-arm64 _CodeSignature)"
check fail "a macOS zip with an iOS slice refused" macos "$(xcf macios ios-arm64)"

echo "xcf_slices_test: $fails failure(s)"
(( fails == 0 ))
