#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# The media of the webio harness: the W1 fixtures (make_fixtures.sh), a
# 300 s WAV for the read speed, and 30 s of the 60 s file as HLS (AAC in
# MPEG-TS, 5 s segments) and as DASH (AAC in fragmented MP4).
#
#   make_net_fixtures.sh <mpv_audio_kit checkout> <out dir>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kit="${1:?mpv_audio_kit checkout}"
out="${2:?out dir}"
"$HERE/make_fixtures.sh" "$kit" "$out" >/dev/null
ff=(ffmpeg -hide_banner -loglevel error -y)
[[ -s "$out/long_300s.wav" ]] || \
  "${ff[@]}" -f lavfi -i "anoisesrc=color=pink:amplitude=0.3:sample_rate=48000:duration=300" \
    -ac 2 -c:a pcm_s16le "$out/long_300s.wav"
if [[ ! -s "$out/hls/index.m3u8" ]]; then
  mkdir -p "$out/hls"
  "${ff[@]}" -i "$out/long_60s.flac" -t 30 -c:a aac -b:a 128k -f hls -hls_time 5 \
    -hls_playlist_type vod -hls_segment_filename "$out/hls/seg%02d.ts" "$out/hls/index.m3u8"
fi
if [[ ! -s "$out/dash/manifest.mpd" ]]; then
  mkdir -p "$out/dash"
  "${ff[@]}" -i "$out/long_60s.flac" -t 30 -c:a aac -b:a 128k -f dash -seg_duration 5 \
    -use_template 1 -use_timeline 0 "$out/dash/manifest.mpd"
fi
ls -l "$out" "$out/hls" "$out/dash"
