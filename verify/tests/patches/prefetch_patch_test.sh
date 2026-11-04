#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patch_prefetch.py on pristine mpv with the property seam
# (patch_property_seam.py, which the build runs first): it applies, it edits
# only the three player files and the two files of the seam it fills, and a
# second run changes nothing. A tree that the prefetch
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
SEAM="$ROOT/patches/mpv/shared/patch_property_seam.py"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

cp -a "$MPV" "$T/seam"
python3 -B "$SEAM" "$T/seam" > "$T/seam.log" 2>&1; check $? "pristine: the seam applies"
cp -a "$T/seam" "$T/ok"
python3 -B "$PATCH" "$T/ok" > "$T/ok.log" 2>&1; check $? "pristine with the seam: the patch applies"
changed="$(LC_ALL=C diff -rq "$T/seam" "$T/ok" | sed "s|^Files .* and $T/ok/||; s| differ$||" | sort | tr '\n' ' ')"
[[ "$changed" == "player/core.h player/loadfile.c player/mak_property_getters.inc player/mak_property_table.inc player/playloop.c " ]]
check $? "pristine with the seam: only the five player files change (${changed% })"
rm -rf "$T/alone"; cp -a "$MPV" "$T/alone"
python3 -B "$PATCH" "$T/alone" > "$T/alone.log" 2>&1; r=$?
[[ $r != 0 ]] && grep -q 'patch_property_seam.py must run first' "$T/alone.log"
check $? "pristine without the seam: the patch refuses the tree (exit $r)"
diff -r "$MPV" "$T/alone" > /dev/null; check $? "pristine without the seam: no file written"
cp -a "$T/ok" "$T/ok.before"
python3 -B "$PATCH" "$T/ok" > "$T/ok2.log" 2>&1; check $? "a second run applies"
diff -r "$T/ok.before" "$T/ok" > /dev/null; check $? "a second run changes nothing"

for m in MAK_PREFETCH_HOOK_PATCH_V2 MAK_PREFETCH_STATE_PATCH_V1; do
  rm -rf "$T/old"; cp -a "$T/seam" "$T/old"
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
