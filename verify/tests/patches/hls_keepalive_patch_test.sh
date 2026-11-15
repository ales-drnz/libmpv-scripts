#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patches/ffmpeg/patch_ffmpeg_hls_keepalive.py on pristine FFmpeg 9.0:
# it applies, on its own and after patch_ffmpeg_segment_skips.py as the
# build runs it, a second run changes nothing, hls.c no longer turns
# http_persistent off on an s->pb without a URLContext, and
# open_url_keepalive() closes an AVIOContext without one instead of
# asserting. network_test.sh (hls_keepalive_test) checks what it does.
#
# Usage: bash verify/tests/patches/hls_keepalive_patch_test.sh <pristine ffmpeg source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REF="${1:?usage: hls_keepalive_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
T="${2:?usage: hls_keepalive_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
P="$ROOT/patches/ffmpeg"
F=libavformat/hls.c
rm -rf "$T"; mkdir -p "$T"
export PYTHONDONTWRITEBYTECODE=1
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

for side in alone skips; do
  mkdir -p "$T/$side/libavformat"; cp "$REF/$F" "$REF/libavformat/dashdec.c" "$T/$side/libavformat/"
  if [[ "$side" == skips ]]; then
    python3 "$P/patch_ffmpeg_segment_skips.py" "$T/$side" > "$T/$side.skips.log" 2>&1
    check $? "$side: patch_ffmpeg_segment_skips.py applies first"
  fi
  python3 "$P/patch_ffmpeg_hls_keepalive.py" "$T/$side" > "$T/$side.log" 2>&1
  check $? "$side: the patch applies"
  cp -a "$T/$side" "$T/$side.before"
  python3 "$P/patch_ffmpeg_hls_keepalive.py" "$T/$side" > "$T/$side.2.log" 2>&1
  check $? "$side: a second run applies"
  diff -r "$T/$side.before" "$T/$side" > /dev/null; check $? "$side: a second run changes nothing"
done

python3 - "$T/alone/$F" <<'PY'
import sys
t = open(sys.argv[1]).read()
assert 'MAK_HLS_KEEPALIVE_V1' in t
assert 'Disabling http_persistent' not in t, 'the s->pb test is still there'
assert 'ffio_geturlcontext(s->pb)' not in t, 'the s->pb test is still there'
body = t[t.index('static int open_url_keepalive('):]
body = body[:body.index('\n}\n')]
assert 'av_assert0(uc)' not in body, 'open_url_keepalive still asserts'
i = body.index('if (!uc) {')
assert 'ff_format_io_close(s, pb);' in body[i:i + 120] and 'return AVERROR_EOF;' in body[i:i + 160]
# Both callers open a new connection on any failure but AVERROR_EXIT.
assert t.count('open_url_keepalive(c->ctx,') == 2
PY
check $? "the s->pb test is gone, and open_url_keepalive closes and answers AVERROR_EOF"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
