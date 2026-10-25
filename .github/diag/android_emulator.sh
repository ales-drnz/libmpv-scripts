#!/bin/bash
# android_emulator.sh <api>: runs test_app's Android integration tests on the
# booted emulator, from kit/test_app: the audiotrack ones (F277, F276,
# F278), the players of an exiting isolate or engine (F170), the media
# session through Media3 (media_session_test) and its service through a
# call (android_focus_foreground_test, F172).
# The F278 test needs audioserver killed from the host while it plays: it
# prints "[f278] playing" when it is ready, this script then kills
# audioserver, writes f278_killed in the app's cache once a new one is up,
# and the test checks that the output comes back. That test
# runs last, so no other test meets an audioserver restarting. adb root
# restarts adbd, which cuts flutter test and logcat off the device, so it
# runs once at the start, before both. Logs go to emu-logs/. The tests get
# MAK_CI and MAK_LIBMPV_RELEASE, the release of the binary under test, so a
# fix up to that release fails instead of skipping (skipBeforeRelease).
set -u
api=$1
defines=(--dart-define=MAK_CI=true "--dart-define=MAK_LIBMPV_RELEASE=${MAK_LIBMPV_RELEASE:?set from the manifest of the run}")
mkdir -p emu-logs
adb root || true
sleep 2
adb wait-for-device
# adbd just restarted: until the device answers its properties, flutter
# sees it as "API null" and finds no device (seen on API 34).
for i in $(seq 1 120); do
  [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = 1 ] &&
    [ -n "$(adb shell getprop ro.build.version.sdk | tr -d '\r')" ] && break
  sleep 1
done
echo "adb as $(adb shell id -un | tr -d '\r'), API $(adb shell getprop ro.build.version.sdk | tr -d '\r')"
# The package verifier of the Google APIs image is a suspect of the adb
# installs that never finish (API 24).
adb shell settings put global verifier_verify_adb_installs 0 || true
adb shell settings put global package_verifier_enable 0 || true
adb logcat -b all -c || true
# events carries the activity relaunches and configuration changes. One -b
# per buffer: API 24 does not take a list.
(adb logcat -b main -b system -b crash -b events -v time > "emu-logs/logcat-$api.txt" 2>&1 &)
app=com.alesdrnz.mpv_audio_kit_test_app
# A file that hangs prints nothing: once seen, the activity recreated under
# a running test (API 34: CONFIG_ASSETS_PATHS, a change of the app's asset
# paths after boot, which no configChanges can keep out) and adb install
# stuck before the app ran (API 24).
# Each file gets 8 minutes; one that times out dumps the device state and
# runs once more. Its outcome is pass, fail or infra. fail: a test failed,
# or the file hung once its tests had started. infra: every try timed out
# before any test started (an install that never ended, an app that never
# attached), which says nothing about the code. Only fail fails the job;
# infra is a warning and a line of the summary, and a release needs zero
# fail and its infra files run again.
dump() {
  local pid; pid=$(adb shell pidof $app | tr -d '\r')
  { echo "== $1 at $(date +%T), pid ${pid:-none}"
    adb shell pm path $app
    adb shell dumpsys activity activities | grep -A4 "$app" | head -40
    [ -n "$pid" ] && adb shell debuggerd -b "$pid"
    adb shell dumpsys media.audio_flinger | head -80
  } > "emu-logs/hang-$1-$api.txt" 2>&1
}
# Whether the flutter test log $1 shows a test that started: a progress
# line past the loading of the file.
started() { grep -E '[0-9]+:[0-9]+ \+[0-9]+[^:]*: ' "$1" | grep -qv ': loading '; }
fails=0
infras=0
summary="emu-logs/summary-$api.txt"
: > "$summary"
outcome() { # file, pass | fail | infra
  echo "$1 $2" | tee -a "$summary"
  case $2 in
    fail) fails=$((fails + 1)); echo "::error::$1 failed on API $api" ;;
    infra)
      infras=$((infras + 1))
      echo "::warning::$1 never started on API $api: infrastructure, not a test result. Run it again before a release."
      ;;
  esac
}
run() {
  local name=$1 try r log result= hung=0
  for try in 1 2; do
    log="emu-logs/$name-$api-$try.log"
    echo "== $name on API $api (try $try)"
    timeout -s INT -k 30 480 flutter test "integration_test/$name" -d emulator-5554 -r expanded "${defines[@]}" 2>&1 | tee "$log"
    r=${PIPESTATUS[0]}
    [ "$r" = 0 ] && { result=pass; break; }
    if [ "$r" != 124 ] && [ "$r" != 137 ]; then result=fail; break; fi
    started "$log" && hung=1
    echo "::warning::$name timed out on API $api (try $try$([ $hung = 1 ] && echo ', tests running'))"
    dump "$name-$try"
  done
  if [ -z "$result" ]; then
    if [ $hung = 1 ]; then result=fail; else result=infra; fi
  fi
  outcome "$name" "$result"
}
run android_audiotrack_test.dart
run android_audiotrack_pause_test.dart
run android_owner_exit_test.dart
run android_engine_exit_test.dart
run media_session_test.dart
run android_focus_foreground_test.dart
# F278: the test waits for the kill. One try: the kill is part of it.
f278=android_audiotrack_dead_object_test.dart
log="emu-logs/dead-object-$api.log"
echo "== $f278 on API $api"
timeout -s INT -k 30 480 flutter test "integration_test/$f278" -d emulator-5554 -r expanded "${defines[@]}" > "$log" 2>&1 &
pid=$!
for i in $(seq 1 600); do
  grep -q '\[f278\] playing' "$log" && break
  kill -0 $pid 2>/dev/null || break
  sleep 0.5
done
if grep -q '\[f278\] playing' "$log"; then
  before=$(adb shell pidof audioserver | tr -d '\r')
  adb shell kill -9 "$before" || adb shell killall audioserver || true
  for i in $(seq 1 20); do
    after=$(adb shell pidof audioserver | tr -d '\r')
    [ -n "$after" ] && [ "$after" != "$before" ] && break
    sleep 0.5
  done
  echo "audioserver pid ${before:-none} then ${after:-none} at $(date +%T)"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$after" != "$before" ]; then
    # The test waits for this file, not for a stop: Android's AudioTrack can
    # restore the track by itself, and then playback never stops.
    adb shell run-as $app touch cache/f278_killed
  else
    echo "::warning::audioserver was not restarted on API $api"
  fi
fi
wait $pid
r=$?
cat "$log"
if [ $r = 0 ]; then
  outcome $f278 pass
elif { [ $r = 124 ] || [ $r = 137 ]; } && ! started "$log"; then
  dump "$f278"
  outcome $f278 infra
else
  outcome $f278 fail
fi
{
  echo "### Android emulator API $api"
  echo
  echo "| file | outcome |"
  echo "|---|---|"
  while read -r file result; do echo "| $file | $result |"; done < "$summary"
  [ $infras -gt 0 ] && echo && echo "$infras file(s) never started: run them again before a release."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
[ $fails = 0 ]
