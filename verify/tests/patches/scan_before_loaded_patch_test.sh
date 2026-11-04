#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks the order patch_bulk_analysis.py gives player/loadfile.c: the scan
# starts, and so duplicates an fd://N source, before mpv tells the client
# MPV_EVENT_FILE_LOADED. A client may reuse N as soon as it hears the
# event (analysis_fd_test reuse does), and a scan that duplicates N after
# it reads whatever N names then. With patch_embedded_cover_art.py, which
# anchors on the same line, in both orders.
#
# Usage: bash verify/tests/patches/scan_before_loaded_patch_test.sh <pristine mpv source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MPV="${1:?usage: scan_before_loaded_patch_test.sh <pristine mpv source dir> <work dir>}"
T="${2:?usage: scan_before_loaded_patch_test.sh <pristine mpv source dir> <work dir>}"
P="$ROOT/patches/mpv/shared"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

# order <name> <patch>...: applies the seam and the patches in that order
# and checks that mak_scan_start comes before the FILE_LOADED notify.
order() {
  local name="$1" d="$T/$1" p
  shift
  cp -a "$MPV" "$d"
  python3 -B "$P/patch_property_seam.py" "$d" > "$d.log" 2>&1
  for p in "$@"; do python3 -B "$P/$p" "$d" >> "$d.log" 2>&1 || { check 1 "$name: $p applies"; return; }; done
  local scan loaded
  scan="$(grep -n 'mak_scan_start(mpctx' "$d/player/loadfile.c" | head -1 | cut -d: -f1)"
  loaded="$(grep -n 'mp_notify(mpctx, MPV_EVENT_FILE_LOADED, NULL);' "$d/player/loadfile.c" | cut -d: -f1)"
  [[ -n "$scan" && -n "$loaded" && $(grep -c 'MPV_EVENT_FILE_LOADED, NULL);' "$d/player/loadfile.c") == 1 ]]
  check $? "$name: one scan start and one FILE_LOADED notify"
  [[ -n "$scan" && -n "$loaded" ]] && (( scan < loaded ))
  check $? "$name: the scan starts (line $scan) before FILE_LOADED (line $loaded)"
}

order bulk patch_bulk_analysis.py
order bulk-then-cover patch_bulk_analysis.py patch_embedded_cover_art.py
order cover-then-bulk patch_embedded_cover_art.py patch_bulk_analysis.py

echo "scan_before_loaded_patch_test: $fails failure(s)"
(( fails == 0 ))
