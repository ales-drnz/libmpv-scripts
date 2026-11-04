#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Runs the Node checks of a web build made with WEB_SANITIZE=address: the C
# harness (3 cycles and the 60 s files) and the module from the calling
# thread. A check fails when it fails as in run_checks.sh, and also when its
# output holds an AddressSanitizer report: Node does not exit after a report
# in a worker, so each run is watched and stopped at the report, or at its
# timeout.
#
#   run_asan.sh <module dir> <spike dir> <fixtures dir> <work dir>
#
# The dirs are those of run_checks.sh, from the sanitized build.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
module="$(cd "${1:?module dir}" && pwd)"
spike="$(cd "${2:?spike dir}" && pwd)"
fixtures="$(cd "${3:?fixtures dir}" && pwd)"
work="${4:?work dir}"
mkdir -p "$work"
failed=0

# check <name> <seconds> <command...>: the run is watched, and stopped a
# few seconds after the first report (the rest of it is still printing).
check() {
  local name="$1" secs="$2" r=0 pid t=0
  shift 2
  "$@" > "$work/$name.txt" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2> /dev/null; do
    if grep -aq 'ERROR: AddressSanitizer' "$work/$name.txt"; then
      sleep 3
      kill "$pid" 2> /dev/null
      break
    fi
    if (( t >= secs )); then
      kill "$pid" 2> /dev/null
      echo "timed out after $secs s" >> "$work/$name.txt"
      break
    fi
    sleep 1
    t=$((t + 1))
  done
  wait "$pid" || r=$?
  if grep -aq 'ERROR: AddressSanitizer' "$work/$name.txt"; then
    echo "FAIL $name: AddressSanitizer"
    grep -a -A20 'ERROR: AddressSanitizer' "$work/$name.txt" | head -30
    failed=$((failed + 1))
  elif (( r != 0 )); then
    echo "FAIL $name: exit $r"
    tail -10 "$work/$name.txt"
    failed=$((failed + 1))
  else
    echo "ok   $name"
  fi
}

check node-spike 1800 node "$HERE/run_node.mjs" "$spike/spike.mjs" -n 3 \
  -l "$fixtures/long_60s.flac" -l "$fixtures/long_60s.mp3" \
  "$fixtures/sine_stereo_48k_5s.flac" "$fixtures/mp3_44100_stereo.mp3" \
  "$fixtures/aac_lc_44100.m4a" "$fixtures/opus_48000_stereo.opus"
check node-lib 900 node "$HERE/run_lib_node.mjs" "$module/libmpv.mjs" \
  "$fixtures/sine_stereo_48k_5s.flac" "$fixtures/mp3_44100_stereo.mp3"

(( failed == 0 )) || { echo "$failed AddressSanitizer check(s) failed (output in $work)"; exit 1; }
echo "AddressSanitizer checks: ok"
