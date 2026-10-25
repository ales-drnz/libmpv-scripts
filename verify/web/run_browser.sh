#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Runs harness.html in a headless browser, cross-origin isolated.
#
#   run_browser.sh <firefox|chrome> <build_dir> '<query>' [result.json]
#
# Stages the page, the harnesses, the modules (<build_dir>/spike and
# builds/release/libmpv_web, or LIBDIR) and <build_dir>/fixtures
# (make_fixtures.sh) into <build_dir>/browser, serves it with serve_coi.py
# and opens it with a fresh profile. Prints the page's lines; the exit
# status is the harness's.
#
# No browser reaches the machine's sound card: Chrome renders into its fake
# output (--disable-audio-output, a 44.1 kHz clock), Firefox gets no
# PulseAudio and ALSA's null device (48 kHz). Autoplay is allowed unless
# AUTOPLAY=0, which leaves an AudioContext suspended until a gesture.
#
# The page's signals (serve_coi.py): click makes a user gesture through the
# browser's remote protocol (gesture.mjs), cpu-start and cpu-end sample the
# CPU time of the browser's processes (proc_cpu.py).
#
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
libdir="${LIBDIR:-$ROOT/builds/release/libmpv_web}"
autoplay="${AUTOPLAY:-1}"

stage="$build/browser"
rm -rf "$stage"
mkdir -p "$stage"
cp "$HERE/harness.html" "$HERE/lib_harness.mjs" "$HERE/audio_harness.mjs" \
   "$HERE/mpv_client.mjs" "$stage/"
ln -s "$build/spike" "$stage/spike"
ln -s "$libdir" "$stage/lib"
ln -s "$build/fixtures" "$stage/fixtures"
rm -f "$result" "$result".*

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
bidi_port=$((port + 1000))
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
    if [[ "$autoplay" == 1 ]]; then
      printf '%s\n' 'user_pref("media.autoplay.default", 0);' \
        'user_pref("media.autoplay.block-webaudio", false);' >> "$profile/user.js"
    fi
    printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > "$profile/asound.conf"
    PULSE_SERVER=unix:/nonexistent ALSA_CONFIG_PATH="$profile/asound.conf" \
      firefox --headless --no-remote --profile "$profile" \
      --remote-debugging-port "$bidi_port" "$url" >"$build/browser.log" 2>&1 &
    bpid=$!
    ;;
  chrome)
    chrome="${CHROME:-$(command -v chrome-headless-shell || true)}"
    [[ -x "$chrome" ]] || { echo "no Chrome: set CHROME" >&2; exit 2; }
    flags=(--disable-audio-output)
    [[ "$autoplay" == 1 ]] && flags+=(--autoplay-policy=no-user-gesture-required)
    "$chrome" --user-data-dir="$profile" --no-first-run --disable-gpu \
      --remote-debugging-port=0 "${flags[@]}" "$url" >"$build/browser.log" 2>&1 &
    bpid=$!
    ;;
  *) echo "unknown browser: $browser" >&2; exit 2 ;;
esac

start=$SECONDS
cpu_note=""
signals() {
  if [[ -f "$result.click" ]]; then
    rm -f "$result.click"
    if [[ "$browser" == chrome ]]; then
      node "$HERE/gesture.mjs" chrome "$profile" || echo "run_browser: gesture failed" >&2
    else
      node "$HERE/gesture.mjs" firefox "$bidi_port" || echo "run_browser: gesture failed" >&2
    fi
  fi
  if [[ -f "$result.cpu-start" ]]; then
    rm -f "$result.cpu-start"
    cpu0="$(python3 -I "$HERE/proc_cpu.py" "$bpid")"; wall0="$(date +%s.%N)"
  fi
  if [[ -f "$result.cpu-end" && -n "${cpu0:-}" ]]; then
    rm -f "$result.cpu-end"
    cpu1="$(python3 -I "$HERE/proc_cpu.py" "$bpid")"; wall1="$(date +%s.%N)"
    cpu_note="$(python3 -I -c 'import sys; c0, c1, w0, w1 = map(float, sys.argv[1:]); print(f"measure browser_cpu_percent {100 * (c1 - c0) / (w1 - w0):.1f} (every process of the browser, {c1 - c0:.2f} s of CPU in {w1 - w0:.2f} s)")' "$cpu0" "$cpu1" "$wall0" "$wall1")"
  fi
}
until [[ -s "$result" ]]; do
  signals
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
  sleep 0.1
done
signals
python3 -I - "$result" "$cpu_note" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
print(f"browser: {r.get('userAgent')}")
print(f"crossOriginIsolated: {r.get('crossOriginIsolated')}, busyTicks: {r.get('busyTicks')}")
for line in r.get('lines', []):
    print(line)
if sys.argv[2]:
    print(sys.argv[2])
sys.exit(0 if r.get('code') == 0 else 1)
EOF
