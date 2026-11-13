#!/usr/bin/env bash
# release_gate.sh <Build run id>: whether the libraries of that Build may be
# published as a libmpv release. They may when a run of Check mpv_audio_kit
# on that same Build was complete and green: the kit's tests on macOS and
# Windows, the app builds, the iOS simulator and the Android emulators, on
# a Build started by a push to release/rN. The Summary job of the check
# writes that verdict in its check-result artifact, which this reads.
#
# libmpv-r24 was published after nine green checks that had run the native
# tests alone: green is not enough, the run has to be complete.
#
# Exit 0 and the run that counts, or exit 1 and what the closest runs
# lacked. It only reads: it publishes nothing.
#
# Reads GH_TOKEN, or the login of gh, and GITHUB_REPOSITORY
# (ales-drnz/libmpv-scripts by default).
#
#   .github/ci/release_gate.sh 42703687387
set -euo pipefail

build="${1:-}"
[[ "$build" =~ ^[0-9]+$ ]] || { echo "usage: $0 <Build run id>" >&2; exit 2; }
repo="${GITHUB_REPOSITORY:-ales-drnz/libmpv-scripts}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The successful checks, newest first. A check of this Build is rarely far
# back: a hundred runs cover the weeks before a release.
runs="$(gh api "repos/$repo/actions/workflows/check-mpv-audio-kit.yml/runs?status=success&per_page=100" \
  --jq '.workflow_runs[].id')"

seen=0
for run in $runs; do
  has="$(gh api "repos/$repo/actions/runs/$run/artifacts?name=check-result" \
    --jq '[.artifacts[] | select(.expired | not)] | length')"
  [[ "$has" == 0 ]] && continue
  rm -rf "$tmp/r"
  gh run download "$run" -R "$repo" -n check-result -D "$tmp/r" > /dev/null
  result="$tmp/r/check-result.json"
  [[ "$(jq -r .build_run "$result")" == "$build" ]] || continue
  seen=$((seen + 1))
  if [[ "$(jq -r .counts_for_release "$result")" == true ]]; then
    echo "Build $build has a complete green check: run $run (kit $(jq -r .kit_ref "$result"), Flutter $(jq -r .flutter "$result"))."
    echo "https://github.com/$repo/actions/runs/$run"
    exit 0
  fi
  echo "Check run $run of Build $build does not count: complete=$(jq -r .complete "$result") green=$(jq -r .green "$result") release_build=$(jq -r .release_build "$result") tags=\"$(jq -r .tags "$result")\"" >&2
done

if [[ $seen == 0 ]]; then
  echo "No successful check of Build $build has a check-result artifact: no complete check was run on it." >&2
fi
echo "Build $build must not be published: run Check mpv_audio_kit on it with [full check] and no other tag, and wait for it green." >&2
exit 1
