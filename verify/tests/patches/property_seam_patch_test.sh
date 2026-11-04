#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patch_property_seam.py on pristine mpv: it applies, a second run
# keeps what the property patches added to its files, and a tree extracted
# over a patched one (a pristine command.c beside the files of the earlier
# run, as the Windows build's tar leaves it) starts them again, so a patch
# left out this time leaves nothing behind.
#
# Usage: bash verify/tests/patches/property_seam_patch_test.sh <pristine mpv source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MPV="${1:?usage: property_seam_patch_test.sh <pristine mpv source dir> <work dir>}"
T="${2:?usage: property_seam_patch_test.sh <pristine mpv source dir> <work dir>}"
SEAM="$ROOT/patches/mpv/shared/patch_property_seam.py"
PREFETCH="$ROOT/patches/mpv/shared/patch_prefetch.py"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

cp -a "$MPV" "$T/tree"
python3 -B "$SEAM" "$T/tree" > "$T/seam.log" 2>&1; check $? "pristine: the seam applies"
python3 -B "$PREFETCH" "$T/tree" > "$T/prefetch.log" 2>&1; check $? "pristine with the seam: prefetch applies"
grep -q prefetch-state "$T/tree/player/mak_property_table.inc"
check $? "prefetch's entries are in the table of the seam"
python3 -B "$SEAM" "$T/tree" > "$T/seam2.log" 2>&1; check $? "a second run of the seam applies"
grep -q prefetch-state "$T/tree/player/mak_property_table.inc"
check $? "a second run keeps what prefetch added"

# The Windows build extracts the tarball over the old tree: the files of
# mpv come back pristine, the ones the seam made stay.
cp -a "$MPV/." "$T/tree/"
python3 -B "$SEAM" "$T/tree" > "$T/seam3.log" 2>&1; check $? "over an old tree: the seam applies"
! grep -q prefetch-state "$T/tree/player/mak_property_table.inc"
check $? "over an old tree: the table starts again, without prefetch"
! grep -q mp_property_prefetch "$T/tree/player/mak_property_getters.inc"
check $? "over an old tree: the getters start again, without prefetch"

echo "property_seam_patch_test: $fails failure(s)"
(( fails == 0 ))
