#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Runs harness.html in a headless browser, cross-origin isolated.
#
#   run_browser.sh <firefox|chrome> <build_dir> '<query>' [result.json]
#
# Stages the page, lib_harness.mjs, the modules (<build_dir>/spike and
# builds/release/libmpv_web) and <build_dir>/fixtures (make_fixtures.sh) into
# <build_dir>/browser, serves it with serve_coi.py and opens it with a fresh
# profile. Prints the page's lines; the exit status is the harness's.
# CHROME=<binary> picks the Chrome (default: chrome-headless-shell of Chrome
# for Testing on PATH). TIMEOUT=<s> (default 300).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
browser="${1:?firefox or chrome}"
build="${2:?build dir}"
query="${3:-mode=spike}"
result="${4:-$build/browser-result.json}"
timeout_s="${TIMEOUT:-300}"
port="${PORT:-8123}"

stage="$build/browser"
rm -rf "$stage"
mkdir -p "$stage"
cp "$HERE/harness.html" "$HERE/lib_harness.mjs" "$stage/"
ln -s "$build/spike" "$stage/spike"
ln -s "$ROOT/builds/release/libmpv_web" "$stage/lib"
ln -s "$build/fixtures" "$stage/fixtures"
rm -f "$result"

python3 -I "$HERE/serve_coi.py" --root "$stage" --port "$port" --result "$result" &
server=$!
profile="$(mktemp -d "$build/profile.XXXXXX")"
cleanup() {
  [[ -n "${bpid:-}" ]] && kill "$bpid" 2>/dev/null || true
  kill "$server" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$profile"
}
trap cleanup EXIT
sleep 0.5

url="http://127.0.0.1:$port/harness.html?$query"
case "$browser" in
  firefox)
    cat > "$profile/user.js" <<'EOF'
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("app.update.disabledForTesting", true);
user_pref("browser.startup.homepage_override.mstone", "ignore");
EOF
    firefox --headless --no-remote --profile "$profile" "$url" >"$build/browser.log" 2>&1 &
    bpid=$!
    ;;
  chrome)
    chrome="${CHROME:-$(command -v chrome-headless-shell || true)}"
    [[ -x "$chrome" ]] || { echo "no Chrome: set CHROME" >&2; exit 2; }
    "$chrome" --user-data-dir="$profile" --no-first-run --disable-gpu \
      --remote-debugging-port=0 "$url" >"$build/browser.log" 2>&1 &
    bpid=$!
    ;;
  *) echo "unknown browser: $browser" >&2; exit 2 ;;
esac

start=$SECONDS
until [[ -s "$result" ]]; do
  if (( SECONDS - start > timeout_s )); then
    echo "run_browser: no result after ${timeout_s}s" >&2
    tail -20 "$build/browser.log" >&2 || true
    exit 3
  fi
  if ! kill -0 "$bpid" 2>/dev/null; then
    echo "run_browser: the browser exited" >&2
    tail -20 "$build/browser.log" >&2 || true
    exit 3
  fi
  sleep 0.5
done
python3 -I - "$result" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"browser: {r.get('userAgent')}")
print(f"crossOriginIsolated: {r.get('crossOriginIsolated')}, busyTicks: {r.get('busyTicks')}")
for line in r.get('lines', []):
    print(line)
sys.exit(0 if r.get('code') == 0 else 1)
EOF
