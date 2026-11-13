#!/usr/bin/env bash
# resolve_build_run.sh [run id]: the Build run whose libmpv-release artifact
# Check mpv_audio_kit tests, checked before any job downloads it.
#
# With a run id, that run. Without one, the latest successful Build
# (build.yml) started by a push to release/rN, where rN is LIBMPV_RELEASE of
# scripts/shared/_versions.sh at this commit: the binaries this branch is
# about to ship. No Build of that branch is an error, never an older
# release: the workflow once had a run id as its default, which pointed at
# the Build of four releases before and whose artifact would have expired.
#
# Either way the run must be one of build.yml and still hold a
# libmpv-release artifact (GitHub keeps it 90 days).
#
# Prints key=value lines for GITHUB_OUTPUT (run, branch, sha, event,
# release_build) and everything else on stderr. release_build is true for a
# Build started by a push to a release/rN branch, the only kind a libmpv
# release is published from.
#
# Reads GH_TOKEN (Actions read access) and GITHUB_REPOSITORY.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
run="${1:-}"

fail() {
  echo "::error title=Build run::$*" >&2
  exit 1
}

if [[ -n "$run" ]]; then
  [[ "$run" =~ ^[0-9]+$ ]] || fail "\"$run\" is not a run id."
  echo "Build run $run, given by hand." >&2
else
  release="$(env -u LIBMPV_RELEASE bash -c "source '$root/scripts/shared/_versions.sh'; echo \"\$LIBMPV_RELEASE\"")"
  [[ "$release" =~ ^r[0-9]+$ ]] || fail "LIBMPV_RELEASE is \"$release\", not of the form rN."
  branch="release/$release"
  # The filter checks branch and event again in case the query ignored them.
  run="$(gh api "repos/$repo/actions/workflows/build.yml/runs?branch=$branch&event=push&status=success&per_page=5" \
    --jq "[.workflow_runs[] | select(.head_branch == \"$branch\" and .event == \"push\")][0].id // empty")" ||
    fail "Could not list the Builds of $branch on $repo."
  [[ -n "$run" ]] || fail "No run was given, and $repo has no successful Build of $branch started by a push. Push $branch, or name a run: the libs_run input, or [libs_run <id>] in the commit message of a ci/ branch."
  echo "Build run $run: the latest successful Build of $branch started by a push." >&2
fi

info="$(gh api "repos/$repo/actions/runs/$run" \
  --jq '[.path, .head_branch, .head_sha, .event, .status, (.conclusion // "none")] | @tsv')" ||
  fail "Run $run was not found on $repo."
IFS=$'\t' read -r path branch sha event status conclusion <<<"$info"
[[ "$path" == .github/workflows/build.yml* ]] ||
  fail "Run $run is a run of $path, not of build.yml: it has no libraries to check."

artifact="$(gh api "repos/$repo/actions/runs/$run/artifacts?name=libmpv-release" \
  --jq '.artifacts[0] | if . == null then "missing" elif .expired then "expired \(.expires_at)" else "ok \(.expires_at)" end')" ||
  fail "Could not list the artifacts of run $run."
case "$artifact" in
  missing)
    fail "Build run $run ($branch, $status, $conclusion) has no libmpv-release artifact: only a Build whose release job ran has one."
    ;;
  expired*)
    fail "The libmpv-release artifact of Build run $run ($branch) expired on ${artifact#expired }. Check a newer Build."
    ;;
esac

release_build=false
[[ "$event" == push && "$branch" =~ ^release/r[0-9]+$ ]] && release_build=true
echo "Build run $run: $branch at $sha, started by $event, $conclusion; its artifact is kept until ${artifact#ok }." >&2
printf 'run=%s\nbranch=%s\nsha=%s\nevent=%s\nrelease_build=%s\n' \
  "$run" "$branch" "$sha" "$event" "$release_build"
