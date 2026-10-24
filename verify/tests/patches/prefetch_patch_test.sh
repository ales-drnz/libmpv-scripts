#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patch_prefetch.py on pristine mpv: it applies, it edits only the four
# player files, and a second run changes nothing. A tree that the prefetch
# patches of an older release patched (patch_prefetch_hook.py and
# patch_prefetch_state.py, whose edits this one replaces) is refused, with
# no file written.
#
# Usage: bash verify/tests/patches/prefetch_patch_test.sh <pristine mpv source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MPV="${1:?usage: prefetch_patch_test.sh <pristine mpv source dir> <work dir>}"
T="${2:?usage: prefetch_patch_test.sh <pristine mpv source dir> <work dir>}"
PATCH="$ROOT/patches/mpv/shared/patch_prefetch.py"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

cp -a "$MPV" "$T/ok"
python3 -B "$PATCH" "$T/ok" > "$T/ok.log" 2>&1; check $? "pristine: the patch applies"
changed="$(LC_ALL=C diff -rq "$MPV" "$T/ok" | sed "s|^Files .* and $T/ok/||; s| differ$||" | sort | tr '\n' ' ')"
[[ "$changed" == "player/command.c player/core.h player/loadfile.c player/playloop.c " ]]
check $? "pristine: only the four player files change (${changed% })"
cp -a "$T/ok" "$T/ok.before"
python3 -B "$PATCH" "$T/ok" > "$T/ok2.log" 2>&1; check $? "a second run applies"
diff -r "$T/ok.before" "$T/ok" > /dev/null; check $? "a second run changes nothing"

for m in MAK_PREFETCH_HOOK_PATCH_V2 MAK_PREFETCH_STATE_PATCH_V1; do
  rm -rf "$T/old"; cp -a "$MPV" "$T/old"
  printf '/* %s */\n' "$m" >> "$T/old/player/loadfile.c"
  cp -a "$T/old" "$T/old.before"
  python3 -B "$PATCH" "$T/old" > "$T/old-$m.log" 2>&1; r=$?
  [[ $r != 0 ]] && grep -q 'older release' "$T/old-$m.log"
  check $? "$m in loadfile.c: the patch refuses the tree (exit $r)"
  diff -r "$T/old.before" "$T/old" > /dev/null; check $? "$m in loadfile.c: no file written"
  rm -rf "$T/old.before"
done

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
