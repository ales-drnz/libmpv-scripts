#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patches/ffmpeg/patch_ffmpeg_filter_bounds.py on the nine pristine
# FFmpeg filter files it edits: it applies, a second run changes nothing, and
# with any one anchor broken it fails and writes no file, the other files
# included (F195, F197). verify/tests/filter_bounds_test.sh checks what the
# patched filters do.
#
# Usage: bash verify/tests/patches/filter_bounds_anchor_test.sh <pristine ffmpeg source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REF="${1:?usage: filter_bounds_anchor_test.sh <pristine ffmpeg source dir> <work dir>}"
T="${2:?usage: filter_bounds_anchor_test.sh <pristine ffmpeg source dir> <work dir>}"
P="$ROOT/patches/ffmpeg/patch_ffmpeg_filter_bounds.py"
FILES="af_compand.c af_aiir.c aeval.c af_chorus.c af_mcompand.c af_anequalizer.c af_adelay.c af_dynaudnorm.c af_adrc.c"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
tree() { mkdir -p "$T/$1/libavfilter"; for f in $FILES; do cp "$REF/libavfilter/$f" "$T/$1/libavfilter/"; done; }

tree ok
python3 -B "$P" "$T/ok" > "$T/ok.log" 2>&1; check $? "pristine: the patch applies"
n=$(grep -l MAK_FILTER_BOUNDS_V1 "$T"/ok/libavfilter/*.c | wc -l)
[[ "$n" == 9 ]]; check $? "pristine: all 9 files carry the marker ($n)"
cp -a "$T/ok" "$T/ok.before"
python3 -B "$P" "$T/ok" > "$T/ok2.log" 2>&1; check $? "pristine: a second run succeeds"
diff -r "$T/ok.before" "$T/ok" > /dev/null; check $? "pristine: a second run changes nothing"
[[ "$(grep -c 'Already patched' "$T/ok2.log")" == 9 ]]; check $? "pristine: a second run skips every file"

# broken <name> <file> <text to change> <replacement>
broken() {
  tree "$1"
  python3 - "$T/$1/libavfilter/$2" "$3" "$4" <<'PY' || { echo "FAIL $1: test anchor not found"; fails=$((fails + 1)); return; }
import sys
p, old, new = sys.argv[1:]
t = open(p).read()
assert t.count(old) == 1
open(p, 'w').write(t.replace(old, new))
PY
  cp -a "$T/$1" "$T/$1.before"
  python3 -B "$P" "$T/$1" > "$T/$1.log" 2>&1; local r=$?
  [[ $r != 0 ]]; check $? "$1: the patch fails (exit $r)"
  diff -r "$T/$1.before" "$T/$1" > /dev/null; check $? "$1: no file written"
}
broken compand af_compand.c 'for (i = nb_decays; i < channels; i++) {' 'for (i = nb_decays; i < channels; ++i) {'
broken aiir af_aiir.c '                    nearest_zero.a = i;' '                    nearest_zero.a = (i);'
broken aeval aeval.c 'FFMIN((int)ch, eval->nb_in_channels-1)' 'FFMIN((int)ch, eval->nb_in_channels - 1)'
broken chorus af_chorus.c '    s->channels = outlink->ch_layout.nb_channels;' '    s->channels = outlink->ch_layout.nb_channels; '
broken mcompand af_mcompand.c 'sscanf(tstr3, "%lf", &s->bands[i].decay_rate[k]);' 'sscanf(tstr3, " %lf", &s->bands[i].decay_rate[k]);'
broken anequalizer af_anequalizer.c '        if (freq < 0 || freq > inlink->sample_rate / 2.0)' '        if (freq < 0 || freq >= inlink->sample_rate / 2.0)'
broken adelay af_adelay.c 'av_fast_realloc(d->samples, &d->samples_size, new_delay * sizeof(type));' 'av_fast_realloc(d->samples, &d->samples_size, sizeof(type) * new_delay);'
broken dynaudnorm af_dynaudnorm.c $'        if (ret < 0)\n            return ret;\n    }\n    return 0;' $'        if (ret < 0)\n            return ret;\n    }\n\n    return 0;'
broken adrc af_adrc.c '    if (ret >= 0 && strcmp(old_expr_str, s->expr_str)) {' '    if (ret >= 0 && strcmp(s->expr_str, old_expr_str)) {'
# A repeated anchor fails too.
broken repeated af_chorus.c '    if (nb_delays != nb_decays && nb_delays != nb_speeds && nb_delays != nb_depths) {' $'    if (nb_delays != nb_decays && nb_delays != nb_speeds && nb_delays != nb_depths) {\n    if (nb_delays != nb_decays && nb_delays != nb_speeds && nb_delays != nb_depths) {'

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
