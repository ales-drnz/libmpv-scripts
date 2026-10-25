#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# The inputs of the web harnesses: four short fixtures of mpv_audio_kit
# (FLAC, MP3, AAC, Opus), two 60 s files made with the host ffmpeg for the
# decode times (pink noise under a tone, so FLAC cannot compress it to
# nothing) and two steady tones for the audio output.
#
#   make_fixtures.sh <mpv_audio_kit checkout> <out dir>
set -euo pipefail
kit="${1:?mpv_audio_kit checkout}"
out="${2:?out dir}"
mkdir -p "$out"
cp "$kit/test/fixtures/sine_stereo_48k_5s.flac" \
   "$kit/test/fixtures/codec/mp3_44100_stereo.mp3" \
   "$kit/test/fixtures/codec/aac_lc_44100.m4a" \
   "$kit/test/fixtures/codec/opus_48000_stereo.opus" "$out/"
src=(-f lavfi -i "anoisesrc=color=pink:amplitude=0.3:sample_rate=48000:duration=60"
     -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=60"
     -filter_complex "[0][1]amix=inputs=2,aformat=channel_layouts=stereo")
[[ -s "$out/long_60s.flac" ]] || \
  ffmpeg -hide_banner -loglevel error -y "${src[@]}" -sample_fmt s16 "$out/long_60s.flac"
[[ -s "$out/long_60s.mp3" ]] || \
  ffmpeg -hide_banner -loglevel error -y "${src[@]}" -ar 44100 -b:a 192k "$out/long_60s.mp3"
# W2: a steady 1 kHz tone at -12 dBFS (peak 0.25) at two rates, for the gain
# of the output and a format change.
for t in 48:48000 44:44100; do
  f="$out/tone_${t%%:*}k_20s.flac"
  [[ -s "$f" ]] || ffmpeg -hide_banner -loglevel error -y -f lavfi \
    -i "aevalsrc=0.25*sin(2*PI*1000*t)|0.25*sin(2*PI*1000*t):s=${t#*:}:d=20" -sample_fmt s16 "$f"
done
ls -l "$out"
