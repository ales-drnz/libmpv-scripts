# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# The sound device of the headless Firefox of the web checks, sourced by
# run_browser.sh and run_net.sh:
#
#   firefox_sound_env <profile dir>
#
# fills FIREFOX_ENV with the VAR=value words to run Firefox with, and
# FIREFOX_SOUND_NOTE with a line to print when Firefox gets no device.
#
# Firefox tries PulseAudio, then JACK, then ALSA. On a PipeWire desktop JACK
# is pipewire-jack, whose client links itself to the ports of the sound
# cards, so a page that plays would reach the speakers. JACK never connects
# here (PIPEWIRE_REMOTE names no daemon) and ALSA's default is the null
# device, which takes samples with no clock: an AudioContext on it does not
# start. The device is PulseAudio, on the null sink PULSE_SINK names, when
# that sink exists and is not the default output: the AudioContext runs on
# the sink's clock, in real time, and nothing reaches a speaker. The stream
# goes by its own application name, so the desktop's per-application volume
# and target for Firefox stay as they are. Without such a sink Firefox gets
# no sound server and its AudioContext stays suspended.

# Prints why <sink> cannot be the device, and fails; succeeds silently when
# it is a null sink other than the default output.
firefox_null_sink_problem() {
  local sink="$1"
  if [[ -z "$sink" ]]; then
    echo "PULSE_SINK is not set"
    return 0
  fi
  if ! command -v pactl >/dev/null 2>&1; then
    echo "no pactl to find the sink $sink"
    return 0
  fi
  if [[ "$(pactl get-default-sink 2>/dev/null)" == "$sink" ]]; then
    echo "PULSE_SINK $sink is the default output"
    return 0
  fi
  local r=0
  pactl -f json list sinks 2>/dev/null | python3 -I -c '
import json, sys
for s in json.load(sys.stdin):
    if s.get("name") == sys.argv[1]:
        null = (s.get("properties", {}).get("factory.name") == "support.null-audio-sink"
                or s.get("driver", "").startswith("module-null-sink"))
        sys.exit(0 if null else 3)
sys.exit(2)' "$sink" || r=$?
  case "$r" in
    0) return 1 ;;
    2) echo "no sink named $sink" ;;
    3) echo "the sink $sink is not a null sink" ;;
    *) echo "pactl cannot list the sinks" ;;
  esac
  return 0
}

firefox_sound_env() {
  local profile="$1" why
  printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' > "$profile/asound.conf"
  FIREFOX_ENV=(PIPEWIRE_REMOTE=mak-tests-no-pipewire ALSA_CONFIG_PATH="$profile/asound.conf")
  FIREFOX_SOUND_NOTE=""
  if why="$(firefox_null_sink_problem "${PULSE_SINK:-}")"; then
    FIREFOX_ENV+=(PULSE_SERVER=unix:/nonexistent)
    FIREFOX_SOUND_NOTE="Firefox has no sound device ($why): an AudioContext does not start"
  else
    FIREFOX_ENV+=(PULSE_SINK="$PULSE_SINK"
      'PULSE_PROP_OVERRIDE=application.name="mak-tests-firefox" application.id="mak_tests_firefox"')
  fi
}
