#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Runs every check of a web build, one after the other, as the Build's web
# job does:
#
#   run_checks.sh <module dir> <spike dir> <fixtures dir> <work dir>
#
# <module dir>   libmpv.mjs, libmpv.wasm, mak_webaudio_processor.js and
#                build_web.json: libmpv_web.zip unpacked, or RELEASE_DIR
# <spike dir>    spike.mjs and spike.wasm of the same build ($BUILD_DIR/spike)
# <fixtures dir> from make_net_fixtures.sh
# <work dir>     the staging of the browser runs and each check's output,
#                <work dir>/<check>.txt
#
# The checks: the rules of mak_webio.js in plain Node, the webaudio ring
# (needs emcc, or EMSDK), then in Node the C harness (10 cycles and the 60 s
# files), the module driven from the calling thread and http through webio;
# then, in each browser of BROWSERS (default: chrome; also firefox), the C
# harness with the main thread busy, the module from the main thread, the
# webaudio output with the main thread busy, the AudioContext that waits for
# a user gesture, and http. CHROME picks the Chrome binary (run_browser.sh).
# SKIP lists checks left out on purpose, by name. It runs them all and exits
# non-zero when one fails; the last lines name each check and its result.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
module="$(cd "${1:?module dir}" && pwd)"
spike="$(cd "${2:?spike dir}" && pwd)"
fixtures="$(cd "${3:?fixtures dir}" && pwd)"
work="${4:?work dir}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
browsers="${BROWSERS:-chrome}"

# run_browser.sh stages <build dir>/spike and <build dir>/fixtures.
ln -sfn "$spike" "$work/spike"
ln -sfn "$fixtures" "$work/fixtures"

files=sine_stereo_48k_5s.flac,mp3_44100_stereo.mp3,aac_lc_44100.m4a,opus_48000_stereo.opus
longs=long_60s.flac,long_60s.mp3
tones=long_60s.flac,tone_48k_20s.flac,tone_44k_20s.flac,sine_stereo_48k_5s.flac

summary=()
failed=0
# check <name> <command...>: runs it into <work>/<name>.txt and notes the
# result with the harness's last RESULT line.
check() {
  local name="$1"; shift
  if [[ " ${SKIP:-} " == *" $name "* ]]; then
    summary+=("skip $name")
    return
  fi
  echo "── $name"
  local t0=$SECONDS
  "$@" > "$work/$name.txt" 2>&1
  local r=$?
  local result
  result="$(grep -a '^RESULT' "$work/$name.txt" | tail -1)"
  if (( r == 0 )); then
    summary+=("ok   $name ${result:-} ($((SECONDS - t0)) s)")
  else
    summary+=("FAIL $name exit $r ${result:-} ($((SECONDS - t0)) s)")
    failed=$((failed + 1))
    grep -a -E '^(FAIL|page |run_browser|run_net)' "$work/$name.txt" | head -20
    tail -5 "$work/$name.txt"
  fi
}

ring() {
  if ! command -v emcc >/dev/null 2>&1 && [[ -z "${EMSDK:-}" ]]; then
    echo "no emcc: source emsdk_env.sh, set EMSDK or SKIP=ring"
    return 2
  fi
  bash "$HERE/ring_test.sh" "$work/ring"
}

check webio-logic node "$HERE/webio_logic_test.mjs"
check ring ring
check node-spike timeout 900 node "$HERE/run_node.mjs" "$spike/spike.mjs" -n 10 \
  -l "$fixtures/long_60s.flac" -l "$fixtures/long_60s.mp3" \
  "$fixtures/sine_stereo_48k_5s.flac" "$fixtures/mp3_44100_stereo.mp3" \
  "$fixtures/aac_lc_44100.m4a" "$fixtures/opus_48000_stereo.opus"
check node-lib timeout 300 node "$HERE/run_lib_node.mjs" "$module/libmpv.mjs" \
  "$fixtures/sine_stereo_48k_5s.flac" "$fixtures/mp3_44100_stereo.mp3"
check node-net "$HERE/run_net.sh" node "$module" "$fixtures"

for b in $browsers; do
  export LIBDIR="$module"
  check "$b-spike" "$HERE/run_browser.sh" "$b" "$work" \
    "mode=spike&loops=10&busy=1&longs=$longs&files=$files"
  check "$b-lib" "$HERE/run_browser.sh" "$b" "$work" \
    "mode=lib&files=sine_stereo_48k_5s.flac,mp3_44100_stereo.mp3"
  check "$b-audio" env TIMEOUT=150 "$HERE/run_browser.sh" "$b" "$work" \
    "mode=audio&files=$tones&busy=1"
  check "$b-gesture" env AUTOPLAY=0 TIMEOUT=150 "$HERE/run_browser.sh" "$b" "$work" \
    "mode=audio&files=long_60s.flac&gesture=1"
  check "$b-net" "$HERE/run_net.sh" "$b" "$module" "$fixtures"
done

echo "── web checks"
printf '%s\n' "${summary[@]}"
if (( failed > 0 )); then
  echo "$failed check(s) failed (output in $work)"
  exit 1
fi
echo "all web checks passed"
