#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patches/ffmpeg/patch_ffmpeg_dash_keepalive.py on pristine FFmpeg: it
# applies, a second run changes nothing, and a keep-alive request refused
# with EINVAL logs at VERBOSE, any other failure at WARNING (F89).
# ff_http_do_new_request2 returns EINVAL for a segment on another host or
# protocol, which every segment redirected to a CDN is: there the new
# connection is the expected path, and a warning every few seconds was noise.
#
# Usage: bash verify/tests/patches/dash_keepalive_patch_test.sh <pristine ffmpeg source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REF="${1:?usage: dash_keepalive_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
T="${2:?usage: dash_keepalive_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
P="$ROOT/patches/ffmpeg/patch_ffmpeg_dash_keepalive.py"
F=libavformat/dashdec.c
rm -rf "$T"; mkdir -p "$T/ok/libavformat"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

# The premise: the host and protocol checks of http.c answer EINVAL.
python3 - "$REF/libavformat/http.c" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
body = t[t.index('int ff_http_do_new_request2('):]
body = body[:body.index('\n}\n')]
for what in ('different protocol', 'different host'):
    i = body.index(f'Cannot reuse HTTP connection for {what}')
    assert 'return AVERROR(EINVAL);' in body[i:i + 300], what
PY
check $? "pristine http.c: another host or protocol is EINVAL"

cp "$REF/$F" "$T/ok/$F"
python3 -B "$P" "$T/ok" > "$T/ok.log" 2>&1; check $? "pristine: the patch applies"
python3 - "$T/ok/$F" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r'av_log\(s,\s*([^"]+?),\s*"DASH keepalive request failed', t)
assert m, 'the keep-alive failure log is not there'
level = ' '.join(m.group(1).split())
assert level == 'ret == AVERROR(EINVAL) ? AV_LOG_VERBOSE : AV_LOG_WARNING', level
PY
check $? "pristine: EINVAL logs at VERBOSE, other failures at WARNING"
cp -a "$T/ok" "$T/ok.before"
python3 -B "$P" "$T/ok" > /dev/null 2>&1; check $? "pristine: a second run applies"
diff -r "$T/ok.before" "$T/ok" > /dev/null; check $? "pristine: a second run changes nothing"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
