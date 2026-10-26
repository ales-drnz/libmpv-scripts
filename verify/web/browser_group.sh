# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# The browser of a run in a process group of its own, so the cleanup can
# wait for every process of it before the profile goes. The browser process
# can exit before its helpers, which still write into the profile: an rm -rf
# right after it failed with "Directory not empty" (Build 40303575127,
# google-chrome). Sourced by run_browser.sh and run_net.sh, tested by
# browser_group_test.sh.
#
# The runner starts the browser in the background between set -m and set +m
# (job control: the job leads a new process group), then:
#   browser_group_check <pid>  fails unless <pid> leads its own group
#   browser_group_stop <pid>   TERM to every process of the group, KILL after
#                              BROWSER_STOP_WAIT seconds (default 10);
#                              returns once none is left, 1 when some stay

browser_group_check() {
  local pg
  pg="$(ps -o pgid= -p "$1" | tr -d ' ')" || pg=
  # An empty answer: the browser already exited, the loop of the runner
  # says so.
  if [[ -n "$pg" && "$pg" != "$1" ]]; then
    echo "browser_group: the browser $1 is in process group $pg, not its own" >&2
    return 1
  fi
}

# Processes of group $1 that still run (zombies write nothing).
browser_group_left() {
  ps -e -o pid=,pgid=,stat= | awk -v g="$1" '$2 == g && $3 !~ /^Z/ { print $1 }'
}

browser_group_stop() {
  [[ -n "${1:-}" ]] || return 0
  local pg="$1" limit="${BROWSER_STOP_WAIT:-10}" sig t left
  for sig in TERM KILL; do
    left="$(browser_group_left "$pg")"
    [[ -z "$left" ]] && break
    # kill fails on a process that ended since the list: the wait below
    # is the check.
    kill -s "$sig" $left 2>/dev/null || :
    for (( t = 0; t < limit * 20; t++ )); do
      [[ -z "$(browser_group_left "$pg")" ]] && break
      sleep 0.05
    done
    limit=5
  done
  # The browser is the runner's child: reap it.
  wait "$pg" 2>/dev/null || :
  left="$(browser_group_left "$pg")"
  if [[ -n "$left" ]]; then
    echo "browser_group: processes of the browser still running after KILL: $left" >&2
    return 1
  fi
}
