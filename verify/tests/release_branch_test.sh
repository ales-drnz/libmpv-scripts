#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks verify/release_branch.sh on a copy of the scripts whose
# LIBMPV_RELEASE is set by hand.
#
# Usage: bash verify/tests/release_branch_test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/verify" "$TMP/scripts/shared"
cp "$ROOT/verify/release_branch.sh" "$TMP/verify/"
printf 'export LIBMPV_RELEASE="${LIBMPV_RELEASE:-r21}"\n' > "$TMP/scripts/shared/_versions.sh"

failures=0
expect() { # expect <status> <branch> [env]
  local want="$1" branch="$2" got=0
  shift 2
  env "$@" bash "$TMP/verify/release_branch.sh" "$branch" > "$TMP/out" 2>&1 || got=$?
  if [[ "$want" == pass && $got -ne 0 ]] || [[ "$want" == fail && $got -eq 0 ]]; then
    echo "FAIL: $branch $* should $want, got exit $got:"; cat "$TMP/out"
    failures=$((failures + 1))
  fi
}

expect pass release/r21
expect fail release/r22
expect fail release/r2
expect fail release/next
expect pass main
expect pass wip/r22-anything
# A LIBMPV_RELEASE from outside does not hide the one the scripts carry.
expect fail release/r22 LIBMPV_RELEASE=r22

[[ $failures -eq 0 ]] && echo "release_branch_test: ok"
exit $(( failures > 0 ))
