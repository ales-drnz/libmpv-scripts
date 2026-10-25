#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Runs the webio harness (net_harness.mjs) in Node or in a headless browser,
# against net_server.py.
#
#   run_net.sh <node|firefox|chrome> <module dir> <fixtures dir> [cases] [repeat]
#
# <module dir> holds libmpv.mjs and libmpv.wasm; <fixtures dir> comes from
# make_net_fixtures.sh. The page, the harness, the module and the fixtures
# are staged into a fresh directory next to the fixtures. Prints the lines of
# the harness; the exit status is its. CHROME=<binary> picks the Chrome
# (default: chrome-headless-shell on PATH; a full Chrome runs with
# --headless=new), PORT (default 8130) the page
# port (PORT + 1 is the other origin), TIMEOUT=<s> (default 900).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_name="${1:?node, firefox or chrome}"
module="$(cd "${2:?module dir}" && pwd)"
fixtures="$(cd "${3:?fixtures dir}" && pwd)"
cases="${4:-}"
repeat="${5:-3}"
timeout_s="${TIMEOUT:-900}"
port="${PORT:-8130}"

stage="$(mktemp -d "$fixtures/../net-stage.XXXXXX")"
cp "$HERE/net.html" "$HERE/net_harness.mjs" "$HERE/mpv_net_client.mjs" "$stage/"
ln -s "$module" "$stage/lib"
ln -s "$fixtures" "$stage/fixtures"
result="$stage/result.json"

python3 -I "$HERE/net_server.py" --root "$stage" --media "$fixtures" --port "$port" \
  --result "$result" >"$stage/server.log" 2>&1 &
server=$!
cleanup() {
  [[ -n "${bpid:-}" ]] && kill "$bpid" 2>/dev/null || true
  kill "$server" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$stage"
}
trap cleanup EXIT
sleep 0.5

if [[ "$env_name" == node ]]; then
  set +e
  timeout "$timeout_s" node "$HERE/run_net_node.mjs" "$module/libmpv.mjs" \
    "http://127.0.0.1:$port" "$fixtures" "$cases" "$repeat"
  exit $?
fi

url="http://127.0.0.1:$port/net.html?repeat=$repeat${cases:+&cases=$cases}"
profile="$stage/profile"
mkdir -p "$profile"
case "$env_name" in
  firefox)
    cat > "$profile/user.js" <<'PREFS'
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("app.update.disabledForTesting", true);
user_pref("browser.startup.homepage_override.mstone", "ignore");
PREFS
    firefox --headless --no-remote --profile "$profile" "$url" >"$stage/browser.log" 2>&1 &
    bpid=$!
    ;;
  chrome)
    chrome="${CHROME:-$(command -v chrome-headless-shell || true)}"
    [[ -x "$chrome" ]] || { echo "no Chrome: set CHROME" >&2; exit 2; }
    # chrome-headless-shell is headless by itself; a full Chrome needs the flag.
    flags=()
    [[ "$(basename "$chrome")" == chrome-headless-shell ]] || flags+=(--headless=new)
    "$chrome" --user-data-dir="$profile" --no-first-run --disable-gpu \
      --remote-debugging-port=0 "${flags[@]}" "$url" >"$stage/browser.log" 2>&1 &
    bpid=$!
    ;;
  *) echo "unknown environment: $env_name" >&2; exit 2 ;;
esac

start=$SECONDS
until [[ -s "$result" ]]; do
  if (( SECONDS - start > timeout_s )); then
    echo "run_net: no result after ${timeout_s}s" >&2
    tail -20 "$stage/browser.log" >&2 || true
    exit 3
  fi
  if ! kill -0 "$bpid" 2>/dev/null; then
    echo "run_net: the browser exited" >&2
    tail -20 "$stage/browser.log" >&2 || true
    exit 3
  fi
  sleep 0.5
done
python3 -I - "$result" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"browser: {r.get('userAgent')}")
print(f"crossOriginIsolated: {r.get('crossOriginIsolated')}")
for line in r.get('lines', []):
    print(line)
sys.exit(0 if r.get('code') == 0 else 1)
PY
