#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# The media of the webio harness: the W1 fixtures (make_fixtures.sh), a
# radio-like MP3 for the live stream, a 300 s WAV for the read speed, and
# 30 s of the 60 s file as HLS (AAC in MPEG-TS, 5 s segments; gap.m3u8 names
# a segment that is not there) and as DASH (AAC in fragmented MP4).
#
#   make_net_fixtures.sh <mpv_audio_kit checkout> <out dir>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kit="${1:?mpv_audio_kit checkout}"
out="${2:?out dir}"
"$HERE/make_fixtures.sh" "$kit" "$out" >/dev/null
ff=(ffmpeg -hide_banner -loglevel error -y)
# A radio-like MP3 for the live stream: no ID3, no Xing header (a looped file
# with one makes the demuxer guess a duration).
[[ -s "$out/live.mp3" ]] || \
  "${ff[@]}" -i "$out/long_60s.mp3" -t 30 -c:a libmp3lame -b:a 128k -id3v2_version 0 \
    -write_xing 0 "$out/live.mp3"
[[ -s "$out/long_300s.wav" ]] || \
  "${ff[@]}" -f lavfi -i "anoisesrc=color=pink:amplitude=0.3:sample_rate=48000:duration=300" \
    -ac 2 -c:a pcm_s16le "$out/long_300s.wav"
if [[ ! -s "$out/hls/index.m3u8" ]]; then
  mkdir -p "$out/hls"
  "${ff[@]}" -i "$out/long_60s.flac" -t 30 -c:a aac -b:a 128k -f hls -hls_time 5 \
    -hls_playlist_type vod -hls_segment_filename "$out/hls/seg%02d.ts" "$out/hls/index.m3u8"
fi
# The same playlist with its third segment missing, for a skipped segment.
sed 's/^seg02\.ts$/missing02.ts/' "$out/hls/index.m3u8" > "$out/hls/gap.m3u8"
if [[ ! -s "$out/dash/manifest.mpd" ]]; then
  mkdir -p "$out/dash"
  "${ff[@]}" -i "$out/long_60s.flac" -t 30 -c:a aac -b:a 128k -f dash -seg_duration 5 \
    -use_template 1 -use_timeline 0 "$out/dash/manifest.mpd"
fi
ls -l "$out" "$out/hls" "$out/dash"
