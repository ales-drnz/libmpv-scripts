#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Runs the Windows tests of this dir against a built libmpv DLL under Wine,
# on an x86_64 host: each .c file is built with mingw into a dir of its own
# and run from there with the DLL by its full path, as the L13 load test of
# scripts/verify/windows.sh does, and with a files/ dir to write into. A
# test passes when it exits 0 and printed RESULT PASS; any other exit code
# is a failure, a crash of the DLL included (an abort exits 3 under Wine).
#
# Needs wine and x86_64-w64-mingw32-gcc: the verify image has both. run.sh
# cannot do this, its tests run a Linux libmpv built on the spot, and the
# code under test here is compiled on Windows only.
#
# Usage: bash verify/tests/native/win/run_wine.sh <libmpv_windows-x86_64.dll> <work dir> [test ...]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DLL="${1:?usage: run_wine.sh <libmpv_windows-x86_64.dll> <work dir> [test ...]}"
WORK="${2:?usage: run_wine.sh <libmpv_windows-x86_64.dll> <work dir> [test ...]}"
shift 2
[[ -f "$DLL" ]] || { echo "no such DLL: $DLL"; exit 2; }
DLL="$(cd "$(dirname "$DLL")" && pwd)/$(basename "$DLL")"
CC="${MINGW_CC:-x86_64-w64-mingw32-gcc}"
command -v "$CC" > /dev/null || { echo "no $CC on this host"; exit 2; }
WINE="$(command -v wine64 2> /dev/null || command -v wine 2> /dev/null)"
[[ -n "$WINE" ]] || { echo "no wine on this host"; exit 2; }

rm -rf "$WORK"; mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
# Wine wants a home and a runtime dir of its own user.
export HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK/xdg"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;mshtml="
timeout 180 "$WINE" wineboot --init > "$WORK/wineboot.log" 2>&1 || true

TESTS=("$@")
if (( ${#TESTS[@]} == 0 )); then
  for f in "$HERE"/*_test.c; do TESTS+=("$(basename "$f" .c)"); done
fi
passed=0 failed=0
for t in "${TESTS[@]}"; do
  d="$WORK/$t"; mkdir -p "$d/files"
  if ! "$CC" -O1 -Wall -o "$d/$t.exe" "$HERE/$t.c" -static > "$d/cc.log" 2>&1; then
    echo "FAIL $t: does not compile"; sed 's/^/     /' "$d/cc.log" | head -20
    failed=$((failed + 1)); continue
  fi
  ( cd "$d" && timeout 300 "$WINE" "$t.exe" "$DLL" files ) > "$d/run.log" 2>&1
  r=$?
  res="$(grep -a -m1 -E '^RESULT' "$d/run.log" || echo 'no RESULT')"
  if (( r == 0 )) && [[ "$res" == "RESULT PASS"* ]]; then
    echo "ok   $t: ${res%$'\r'}"; passed=$((passed + 1))
  else
    (( r == 124 )) && res="timed out, $res"
    echo "FAIL $t: exit $r, ${res%$'\r'}"
    grep -a -E '^FAIL|Assertion|exception|Unhandled' "$d/run.log" | head -8 | sed 's/^/     /'
    failed=$((failed + 1))
  fi
done
echo "$passed passed, $failed failed"
exit $(( failed > 0 ))
