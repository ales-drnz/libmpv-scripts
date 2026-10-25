#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks the FFmpeg side of read_error on pristine FFmpeg:
# patch_ffmpeg_http_reconnect.py and patch_ffmpeg_segment_skips.py apply, on
# their own and after patch_ffmpeg_dash_keepalive.py as the build runs them,
# and a second run changes nothing; and the option the HLS and DASH
# demuxers export is the one patch_read_error.py reads, in both demuxers.
# network_test.sh checks what the patched FFmpeg does.
#
# Usage: bash verify/tests/patches/read_error_patch_test.sh <pristine ffmpeg source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REF="${1:?usage: read_error_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
T="${2:?usage: read_error_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
P="$ROOT/patches/ffmpeg"
FILES="http.c hls.c dashdec.c"
rm -rf "$T"; mkdir -p "$T"
export PYTHONDONTWRITEBYTECODE=1
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
tree() { mkdir -p "$T/$1/libavformat"; for f in $FILES; do cp "$REF/libavformat/$f" "$T/$1/libavformat/"; done; }
apply() { python3 "$P/patch_ffmpeg_http_reconnect.py" "$1" && python3 "$P/patch_ffmpeg_segment_skips.py" "$1"; }

for side in alone keepalive; do
  tree "$side"
  if [[ "$side" == keepalive ]]; then
    python3 "$P/patch_ffmpeg_dash_keepalive.py" "$T/$side" > "$T/$side.keepalive.log" 2>&1
    check $? "$side: patch_ffmpeg_dash_keepalive.py applies first"
  fi
  apply "$T/$side" > "$T/$side.log" 2>&1; check $? "$side: the patches apply"
  for f in $FILES; do
    case "$f" in http.c) m=MAK_HTTP_RECONNECT_V1 ;; *) m=MAK_SEGMENT_SKIPS_V1 ;; esac
    grep -q "$m" "$T/$side/libavformat/$f"; check $? "$side: $f carries $m"
  done
  cp -a "$T/$side" "$T/$side.before"
  apply "$T/$side" > "$T/$side.2.log" 2>&1; check $? "$side: a second run applies"
  diff -r "$T/$side.before" "$T/$side" > /dev/null; check $? "$side: a second run changes nothing"
done

# The exported option and the name mpv reads.
python3 - "$T/alone/libavformat" "$ROOT/patches/mpv/shared/patch_read_error.py" <<'PY'
import re, sys
d, mpv = sys.argv[1], open(sys.argv[2]).read()
read = set(re.findall(r'av_opt_get_int\([^"]*"(\w+)"', mpv))
assert read == {'skipped_segments'}, f'patch_read_error.py reads {read}'
for f in ('hls.c', 'dashdec.c'):
    t = open(f'{d}/{f}').read()
    m = re.search(r'\{"(\w+)", "[^"]*",\s*OFFSET\(skipped_segments\), AV_OPT_TYPE_INT64,'
                  r'[^}]*\}[^}]*AV_OPT_FLAG_EXPORT \| AV_OPT_FLAG_READONLY\}', t)
    assert m, f'{f}: no exported read-only option on skipped_segments'
    assert m.group(1) in read, f'{f} exports {m.group(1)}, mpv reads {read}'
PY
check $? "hls.c and dashdec.c export the read-only option patch_read_error.py reads"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
