#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patches/ffmpeg/patch_ffmpeg_advanced_editlist.py on pristine FFmpeg
# (F87): it applies, alone and before patch_ffmpeg_dash_keepalive.py and
# patch_ffmpeg_segment_skips.py as the build runs them, and a second run
# changes nothing. The upstream autodisable of advanced_editlist stays,
# skipped only with the private option mak_frag_editlist (default 0), which
# only the DASH demuxer sets, in reopen_demux_for_component, the function
# that opens the mov demuxer again at every segment. network_test.sh
# (editlist_test) checks what the patched FFmpeg decodes.
#
# Usage: bash verify/tests/patches/advanced_editlist_patch_test.sh <pristine ffmpeg source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REF="${1:?usage: advanced_editlist_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
T="${2:?usage: advanced_editlist_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
P="$ROOT/patches/ffmpeg"
FILES="isom.h mov.c dashdec.c http.c hls.c"
rm -rf "$T"; mkdir -p "$T"
export PYTHONDONTWRITEBYTECODE=1
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
tree() { mkdir -p "$T/$1/libavformat"; for f in $FILES; do cp "$REF/libavformat/$f" "$T/$1/libavformat/"; done; }

for side in alone build; do
  tree "$side"
  python3 "$P/patch_ffmpeg_advanced_editlist.py" "$T/$side" > "$T/$side.log" 2>&1
  check $? "$side: the patch applies"
  if [[ "$side" == build ]]; then
    { python3 "$P/patch_ffmpeg_dash_keepalive.py" "$T/$side" &&
      python3 "$P/patch_ffmpeg_http_read_errors.py" "$T/$side" &&
      python3 "$P/patch_ffmpeg_segment_skips.py" "$T/$side"; } >> "$T/$side.log" 2>&1
    check $? "$side: dash_keepalive and read_error apply after it"
  fi
  python3 - "$T/$side/libavformat" <<'PY'
import re, sys
d = sys.argv[1]
isom, mov, dash = (open(f'{d}/{f}').read() for f in ('isom.h', 'mov.c', 'dashdec.c'))
ctx = isom[isom.index('typedef struct MOVContext'):]
ctx = ctx[:ctx.index('} MOVContext;')]
assert re.search(r'\bint mak_frag_editlist;', ctx), 'MOVContext has no mak_frag_editlist'
# The upstream block, with the option as the only change.
m = re.search(r'if \(!sc->stts_count && c->advanced_editlist && !c->mak_frag_editlist\) \{\s*'
              r'av_log\(c->fc, AV_LOG_VERBOSE, "advanced_editlist does not work with fragmented "\s*'
              r'"MP4\. disabling\.\\n"\);\s*'
              r'c->advanced_editlist = 0;\s*c->advanced_editlist_autodisabled = 1;\s*\}', mov)
assert m, 'the autodisable is not the upstream one under !c->mak_frag_editlist'
opt = re.search(r'\{"mak_frag_editlist",\s*"[^"]*",\s*OFFSET\(mak_frag_editlist\),\s*'
                r'AV_OPT_TYPE_BOOL,\s*\{\.i64 = 0\},\s*0, 1, FLAGS\}', mov)
assert opt, 'no mak_frag_editlist option of default 0 in mov_options'
assert mov.count('mak_frag_editlist') == 4, mov.count('mak_frag_editlist')
# Set by the DASH demuxer on the options of the demuxer it opens per segment.
fn = dash[dash.index('static int reopen_demux_for_component('):]
fn = fn[:fn.index('\n}\n')]
s = fn.index('av_dict_set(&in_fmt_opts, "mak_frag_editlist", "1", 0);')
assert s < fn.index('avformat_open_input(&pls->ctx'), 'set after the open'
assert dash.count('mak_frag_editlist') == 1, dash.count('mak_frag_editlist')
PY
  check $? "$side: autodisable kept unless mak_frag_editlist (default 0), set by reopen_demux_for_component"
  cp -a "$T/$side" "$T/$side.before"
  python3 "$P/patch_ffmpeg_advanced_editlist.py" "$T/$side" > /dev/null 2>&1
  check $? "$side: a second run applies"
  diff -r "$T/$side.before" "$T/$side" > /dev/null; check $? "$side: a second run changes nothing"
done

# verify_binaries.sh looks for the option name, which pristine FFmpeg has not
# (advanced_editlist, the old marker, is upstream's own option).
grep -q '"mak_frag_editlist|' "$ROOT/scripts/verify/common.sh"; check $? "verify_binaries.sh has the marker mak_frag_editlist"
! grep -rq mak_frag_editlist "$REF/libavformat"; check $? "pristine FFmpeg has no mak_frag_editlist"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
