#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patches/mpv/android/patch_audiotrack.py on pristine mpv (F277, F278,
# F276, the passthrough rate): it applies, each fix leaves its marker, a second run changes
# nothing, and an anchor of a fix that is not found once stops it with no
# file written. With the NDK (ANDROID_NDK_HOME) the patched driver must
# compile for API 24 on arm64, armv7 and x86_64 with no warning the
# pristine driver lacks; the headers come from a patched mpv tree and its
# meson build dir (config.h). verify/tests/native/audiotrack_test.c checks
# what the patched driver does.
#
# Usage: bash verify/tests/patches/audiotrack_patch_test.sh <pristine mpv source dir> <patched mpv source dir> <mpv build dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
USAGE="usage: audiotrack_patch_test.sh <pristine mpv source dir> <patched mpv source dir> <mpv build dir> <work dir>"
MPV="${1:?$USAGE}"; SRC="${2:?$USAGE}"; BLD="${3:?$USAGE}"; T="${4:?$USAGE}"
P="$ROOT/patches/mpv/android/patch_audiotrack.py"
F=audio/out/ao_audiotrack.c
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
B=audio/out/buffer.c
tree() { mkdir -p "$T/$1/audio/out"; cp "$MPV/$F" "$T/$1/$F"; cp "$MPV/$B" "$T/$1/$B"; }
# The fixes, the file of each and one anchor line: marker|file|line to break.
FIXES=(
  "MAK_AUDIOTRACK_IDLE_PATCH_V1|$F|            int samples = ao_read_data(ao, &p->chunk, read_samples, ts, NULL, false, false);"
  "MAK_AUDIOTRACK_DEAD_OBJECT_PATCH_V1|$F|    return AudioTrack_New(ao);"
  "MAK_AUDIOTRACK_PAUSE_PATCH_V1|$F|    .start     = start,"
  "MAK_AUDIOTRACK_SPDIF_RATE_PATCH_V1|$F|    if (AudioTrack.getNativeOutputSampleRate) {"
)

# control: pristine tree.
tree ok
python3 -B "$P" "$T/ok" > "$T/ok.log" 2>&1; check $? "pristine: the patch applies"
for fx in "${FIXES[@]}"; do
  m=${fx%%|*} rest=${fx#*|}; f=${rest%%|*}
  [[ "$(grep -c "$m" "$T/ok/$f")" -ge 1 ]]; check $? "pristine: $m is in"
done
cp -a "$T/ok" "$T/ok.before"
python3 -B "$P" "$T/ok" > /dev/null 2>&1; check $? "pristine: a second run applies"
diff -r "$T/ok.before" "$T/ok" > /dev/null; check $? "pristine: a second run changes nothing"

# each fix: one of its anchors broken.
n=0
for fx in "${FIXES[@]}"; do
  m=${fx%%|*} rest=${fx#*|}; f=${rest%%|*} line=${rest#*|}; n=$((n + 1))
  tree "bad$n"
  python3 - "$T/bad$n/$f" "$line" <<'PY'
import sys
p, line = sys.argv[1:]
t = open(p).read()
assert t.count(line + '\n') == 1, line
open(p, 'w').write(t.replace(line + '\n', line + ' /* moved */\n'))
PY
  cp -a "$T/bad$n" "$T/bad$n.before"
  python3 -B "$P" "$T/bad$n" > "$T/bad$n.log" 2>&1; r=$?
  [[ $r != 0 ]]; check $? "$m anchor broken: the patch fails (exit $r)"
  diff -r "$T/bad$n.before" "$T/bad$n" > /dev/null; check $? "$m anchor broken: no file written"
done

# NDK compile, pristine as the control: no new warning.
if [[ -n "$NDK" && -d "$NDK" ]]; then
  CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
  SR="$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
  # buffer.c includes FFmpeg, which the sysroot lacks: the host's FFmpeg
  # headers, and only those, come after it, for a syntax check only.
  FF="$T/ffmpeg-include"; mkdir -p "$FF"
  inc="$(pkg-config --variable=includedir libavutil 2>/dev/null)"
  for l in "${inc:-/usr/include}"/lib{avutil,avcodec,avformat,avfilter,swresample,swscale}; do
    [[ -d "$l" ]] && ln -sfn "$l" "$FF/"
  done
  for t in aarch64-linux-android24 armv7a-linux-androideabi24 x86_64-linux-android24; do
    for v in pristine ok; do
      d="$T/cc-$v"; mkdir -p "$d/audio/out"; cp "$SRC"/audio/out/*.h "$d/audio/out/"
      rc=0; : > "$T/cc-$t-$v.log"
      for f in "$F" "$B"; do
        if [[ $v == pristine ]]; then cp "$MPV/$f" "$d/$f"; else cp "$T/ok/$f" "$d/$f"; fi
        "$CC" --target=$t --sysroot="$SR" -std=gnu11 -fsyntax-only -Wall -Wextra -Wno-unused-parameter \
          -Wno-sign-compare -Wno-missing-field-initializers -I"$d" -I"$SRC" -I"$SRC/include" -I"$BLD" \
          -idirafter "$FF" "$d/$f" >> "$T/cc-$t-$v.log" 2>&1 || rc=1
      done
      echo $rc > "$T/cc-$t-$v.rc"
    done
    [[ "$(cat "$T/cc-$t-ok.rc")" == 0 ]]; check $? "$t: the patched driver and buffer.c compile"
    grep -o 'warning: .*' "$T/cc-$t-pristine.log" | sort -u > "$T/w-p"; grep -o 'warning: .*' "$T/cc-$t-ok.log" | sort -u > "$T/w-o"
    new=$(comm -13 "$T/w-p" "$T/w-o")
    [[ -z "$new" ]]; check $? "$t: no new warning${new:+: $new}"
  done
else
  echo "skip the NDK compile: ANDROID_NDK_HOME not set"
fi

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
