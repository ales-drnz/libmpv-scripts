#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# browser_group.sh against stand-ins of a browser, without a browser:
#
#   browser_group_test.sh <work dir>
#
# - a browser whose helper still writes into the profile for 1 s after the
#   browser process exited: once browser_group_stop returns, the profile
#   can go and stays gone;
# - a browser that ignores TERM: KILL ends it in time, nothing is left;
# - each leads a process group of its own.
# Prints "ok <name>" or "FAIL <name>" per check and exits 1 when one failed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/browser_group.sh"
work="${1:?work dir}"
mkdir -p "$work"
work="$(cd "$work" && pwd)"
fails=0
check() {
  if [[ "$1" == 1 ]]; then echo "ok $2 ${3:-}"; else echo "FAIL $2 ${3:-}"; fails=$((fails + 1)); fi
}
ok_if() { "$@" && echo 1 || echo 0; }
gone() { [[ -z "$(browser_group_left "$1")" ]]; }

# The helper ignores TERM and writes 40 files 25 ms apart; the browser
# process exits on TERM.
profile="$work/profile"
rm -rf "$profile"
mkdir -p "$profile/Default"
set -m
bash -c '
  ( trap "" TERM
    for i in $(seq 1 40); do mkdir -p "$1/Default"; echo x > "$1/Default/f$i"; sleep 0.025; done ) &
  trap "exit 0" TERM
  while :; do sleep 0.05; done' _ "$profile" >"$work/writer.log" 2>&1 &
bpid=$!
set +m
check "$(ok_if browser_group_check "$bpid")" writer.own_group "pid $bpid"
sleep 0.2
t0=$SECONDS
check "$(ok_if browser_group_stop "$bpid")" writer.stopped "after $((SECONDS - t0)) s"
check "$(ok_if rm -rf "$profile")" writer.profile_removed
sleep 1.2
check "$(ok_if test ! -e "$profile")" writer.profile_stays_gone
check "$(ok_if gone "$bpid")" writer.nothing_left

# A browser that ignores TERM.
set -m
bash -c 'trap "" TERM; while :; do sleep 0.05; done' >"$work/stubborn.log" 2>&1 &
bpid=$!
set +m
check "$(ok_if browser_group_check "$bpid")" stubborn.own_group "pid $bpid"
t0=$(date +%s%N)
check "$(BROWSER_STOP_WAIT=1 ok_if browser_group_stop "$bpid")" stubborn.stopped
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
check "$(ok_if gone "$bpid")" stubborn.nothing_left
check "$(( ms < 4000 ))" stubborn.in_time "$ms ms"

echo "RESULT fail=$fails"
(( fails == 0 ))
