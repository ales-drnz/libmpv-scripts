#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks scripts/shared/_helpers.sh: extract unpacks in a staging directory
# and leaves no half tree, the list of the sources a build checked lives in
# a directory of mktemp that the script removes at exit, the work given to
# on_exit runs with the status of the script unchanged, and the mirror of
# the build log has every line when the script returns.
#
# Usage: bash verify/tests/helpers_test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPERS="$ROOT/scripts/shared/_helpers.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

# ── extract ──────────────────────────────────────────────────────────────────
x="$TMP/extract"; mkdir -p "$x/src/foo-1.0/sub" "$x/src/odd" "$x/dst"
printf 'a\n' > "$x/src/foo-1.0/sub/file"
printf 'h\n' > "$x/src/foo-1.0/.hidden"
printf 'b\n' > "$x/src/odd/file"
tar -czf "$x/foo-1.0.tar.gz" -C "$x/src" foo-1.0
tar -czf "$x/bar-2.0.tar.gz" -C "$x/src" odd
head -c 120 "$x/foo-1.0.tar.gz" > "$x/cut-1.0.tar.gz"
# run <commands>: in a shell of its own that sources the helpers.
run() { TMPDIR="$TMP" bash -c "set -euo pipefail; source '$HELPERS'; $1" 2> "$TMP/err"; }

got="$(run "extract '$x/foo-1.0.tar.gz' '$x/dst'")"
[[ "$got" == "$x/dst/foo-1.0" && -f "$x/dst/foo-1.0/sub/file" && -f "$x/dst/foo-1.0/.hidden" ]]
check $? "extract: the tree is in place, and its path is what it prints"
[[ "$(ls -A "$x/dst")" == "foo-1.0" ]]; check $? "extract: no staging directory is left"

# An existing tree is kept as it is.
printf 'mine\n' > "$x/dst/foo-1.0/sub/file"
run "extract '$x/foo-1.0.tar.gz' '$x/dst'" > /dev/null
[[ "$(cat "$x/dst/foo-1.0/sub/file")" == mine ]]; check $? "extract: an extracted tree is not unpacked again"

# A tar that stops half way leaves no tree to be taken for a whole one,
# and the staging directory of a run that was killed does not get in the way.
mkdir -p "$x/dst/.extract-cut-1.0/cut-1.0/left"
if run "extract '$x/cut-1.0.tar.gz' '$x/dst'" > /dev/null; then false; else true; fi
check $? "extract: a truncated archive stops the build"
[[ ! -e "$x/dst/cut-1.0" && ! -e "$x/dst/.extract-cut-1.0" ]]
check $? "extract: a truncated archive leaves neither a tree nor its staging directory"

if run "extract '$x/bar-2.0.tar.gz' '$x/dst'" > /dev/null; then false; else true; fi
check $? "extract: an archive that does not unpack to its name stops the build"
grep -q 'did not unpack to bar-2.0/' "$TMP/err"; check $? "extract: and says which directory was expected"

# ── SOURCES_FETCHED ──────────────────────────────────────────────────────────
s="$TMP/sources"; mkdir -p "$s"
printf 'x' > "$s/x.tar.gz"
out="$(TMPDIR="$s" STRICT_SOURCES=0 bash -c "
  set -euo pipefail; unset RECORD_SOURCES SOURCES_FETCHED
  source '$HELPERS'
  [[ -d \"\$SOURCES_FETCHED_DIR\" && ! -e \"\$SOURCES_FETCHED\" ]] || exit 3
  [[ \"\$(stat -c %a \"\$SOURCES_FETCHED_DIR\" 2>/dev/null || stat -f %Lp \"\$SOURCES_FETCHED_DIR\")\" == 700 ]] || exit 4
  # Checked in a \$(...), as the builds do: the list is the same file.
  : \"\$(verify_source https://example.invalid/x.tar.gz '$s/x.tar.gz' 2>/dev/null)\"
  grep -c example.invalid \"\$SOURCES_FETCHED\"
  echo \"\$SOURCES_FETCHED_DIR\"
  exit 5" 2>/dev/null)"; status=$?
[[ $status == 5 ]]; check $? "sources: the list is in a private directory of mktemp, made before any source (exit $status)"
[[ "$(sed -n 1p <<<"$out")" == 1 ]]; check $? "sources: a source checked in a subshell is in the list of the build"
dir="$(sed -n 2p <<<"$out")"
[[ -n "$dir" && "$dir" == "$s"/libmpv-sources.* && ! -e "$dir" ]]
check $? "sources: the directory is removed when the script exits, whatever its status"
[[ -z "$(ls -A "$s" | grep -v '^x.tar.gz$')" ]]; check $? "sources: nothing else is left in TMPDIR"

# A script the build runs keeps writing to the list of the build, and does
# not remove it.
out="$(TMPDIR="$s" bash -c "
  set -euo pipefail; unset SOURCES_FETCHED
  source '$HELPERS'
  bash -c 'source \"$HELPERS\"; fetched_source abc child'
  cat \"\$SOURCES_FETCHED\"" 2>/dev/null)"
[[ "$out" == "abc  child" ]]; check $? "sources: a script the build runs appends to the same list and leaves it"

# ── on_exit ──────────────────────────────────────────────────────────────────
out="$(TMPDIR="$TMP" bash -c "
  source '$HELPERS'
  on_exit 'echo first'; on_exit 'false'; on_exit 'echo last'
  exit 7" 2>/dev/null)"; status=$?
[[ $status == 7 && "$out" == $'first\nlast' ]]
check $? "on_exit: the work runs in order, a failing one stops nothing, the status stays (exit $status)"
out="$(TMPDIR="$TMP" bash -c "
  trap 'echo own' EXIT
  source '$HELPERS'
  on_exit 'echo helpers'" 2>/dev/null)"
[[ "$out" == own ]]; check $? "on_exit: a script with its own EXIT trap keeps it"

# ── mirror_build_log ─────────────────────────────────────────────────────────
# 300 lines, one on stderr and a last one without a newline, then a failing
# exit: the file has them all when the script returns, each with its time.
l="$TMP/log"; mkdir -p "$l"
TMPDIR="$TMP" bash -c "
  set -euo pipefail
  source '$HELPERS'
  mirror_build_log '$l/build.log'
  for i in \$(seq 1 300); do echo \"line \$i\"; done
  echo 'on stderr' >&2
  printf 'the error, unterminated'
  exit 9" > "$l/terminal" 2>&1; status=$?
[[ $status == 9 ]]; check $? "log: the status of the script is its own (exit $status)"
[[ "$(wc -l < "$l/build.log")" == 302 ]]; check $? "log: every line is in the file when the script returns ($(wc -l < "$l/build.log") of 302)"
tail -1 "$l/build.log" | grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\] the error, unterminated$'
check $? "log: the last line, with no newline, is there with its time"
grep -q '\] on stderr$' "$l/build.log"; check $? "log: stderr is mirrored too"
[[ "$(grep -c '^line ' "$l/terminal")" == 300 ]] && ! grep -q '^\[' "$l/terminal"
check $? "log: the terminal gets the lines as they are"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "helpers_test: ok"
