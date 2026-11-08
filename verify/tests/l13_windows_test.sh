#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks how L13 of verify_binaries.sh turns the exit code of the Windows load
# helper into pass, fail, warn or a skip, with no Wine and no DLL. The L13
# functions are read out of the script, and fake uname, wine and mingw
# commands stand in for the real ones: the fake wine exits with FAKE_RC.
#
# Usage: bash verify/tests/l13_windows_test.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/verify/windows.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/xdg" "$TMP/release"
cat > "$TMP/bin/uname" <<'SH'
#!/usr/bin/env bash
# L13 only asks for the machine name.
echo "$FAKE_HOST"
SH
cat > "$TMP/bin/wine" <<'SH'
#!/usr/bin/env bash
# The prefix init of _wine_prepare succeeds; the load test exits FAKE_RC.
[[ "${1:-}" == "wineboot" ]] && exit 0
echo "fake wine $*: exit $FAKE_RC"
exit "$FAKE_RC"
SH
cat > "$TMP/bin/x86_64-w64-mingw32-gcc" <<'SH'
#!/usr/bin/env bash
# Writes an empty helper where -o points.
while (($#)); do
  [[ "$1" == "-o" ]] && { : > "$2"; exit 0; }
  shift
done
exit 1
SH
chmod +x "$TMP/bin/"*
ln -s wine "$TMP/bin/wine64"
export PATH="$TMP/bin:$PATH" HOME="$TMP/home" XDG_RUNTIME_DIR="$TMP/xdg" TMPDIR="$TMP"
export LIBMPV_SCRIPTS_ROOT="$ROOT"
DLL="$TMP/release/libmpv_windows-x86_64.dll"
: > "$DLL"

# The script runs its checks when sourced, so only its L13 Windows functions
# are loaded. The result helpers below record the last verdict instead.
for fn in _wine_prepare _l13_windows_loadlibrary _l13_windows_verdict; do
  body="$(awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) \\{" { on = 1 } on { print } on && /^}/ { exit }' "$SCRIPT")"
  [[ -n "$body" ]] || { echo "FAIL: $fn not found in $SCRIPT"; exit 1; }
  eval "$body"
done
RESULT=""
pass() { RESULT="pass $*"; }
fail() { RESULT="fail $*"; }
warn() { RESULT="warn $*"; }
info() { RESULT="info $*"; }
log()  { :; }

FAILS=0
# expect <case> <verdict> [text the message must not contain]
expect() {
  local name="$1" want="$2" banned="${3:-}"
  if [[ "${RESULT%% *}" != "$want" ]]; then
    echo "FAIL $name: want $want, got: ${RESULT:-nothing}"
    FAILS=$((FAILS + 1))
  elif [[ -n "$banned" && "$RESULT" == *"$banned"* ]]; then
    echo "FAIL $name: the message names $banned: $RESULT"
    FAILS=$((FAILS + 1))
  else
    echo "ok   $name: $RESULT"
  fi
}

# load <host arch> <PE arch> <fake wine exit code>: the whole L13 Windows path.
# `|| true` drops errexit inside it, as the `|| fail` of the script does.
load() {
  RESULT=""; WINE_PREFIX_READY=0
  export FAKE_HOST="$1" FAKE_RC="$3"
  _l13_windows_loadlibrary "$2" "$DLL" || true
}

# verdict <via> <exit code>: only the classification, for the Hangover/FEX
# path that needs its FEX DLL on an arm64 host.
verdict() {
  RESULT=""
  _l13_windows_verdict "$1" "$2" "fake output" || true
}

load x86_64 x86_64 0;   expect "x86_64 DLL on x86_64, helper passes" pass
load x86_64 x86_64 1;   expect "x86_64 DLL on x86_64, helper reports a defect" fail
load x86_64 aarch64 0;  expect "aarch64 DLL on x86_64 is skipped" info
# Native Wine runs the DLL with no emulator in between, so a stall or a crash
# is the DLL's own (0xC0000005 leaves Wine with exit code 5).
load x86_64 x86_64 124; expect "x86_64 DLL on x86_64, stall" fail "Box64/FEX"
load x86_64 x86_64 5;   expect "x86_64 DLL on x86_64, access violation" fail "Box64/FEX"
load x86_64 x86_64 29;  expect "x86_64 DLL on x86_64, other abnormal exit" fail "Box64/FEX"
verdict "Hangover/FEX" 124; expect "Hangover/FEX timeout" warn
verdict "Hangover/FEX" 29;  expect "Hangover/FEX abnormal exit" warn

if (( FAILS > 0 )); then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all cases passed"
