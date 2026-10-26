#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Generates the files of the native tests with the ffmpeg command line tool
# (libopus, libmp3lame and libvorbis encoders), one dir per test family.
# A file already there is kept.
#
# prefetch/ (prefetch_*, ao_close_test)
#   a.flac, b.flac 60 s, c.flac 30 s, a2.flac 2 s, each with its own title
#   tag.
# analysis/ (analysis_*)
#   x16.opus  16 channels (mapping family 255), 10 s sine
#   sm.mp3    10 s stereo MP3 then 10 s mono MP3, joined with cat
#   ms.mp3    the same, mono first
#   a.flac    30 s sine at -30 dB, 48 kHz stereo (about -51.8 LUFS)
#   b.flac    30 s pink noise, amplitude 0.5, 48 kHz stereo (about -20.6 LUFS)
#   two.mka   a.flac then b.flac as two audio tracks (Matroska, demux_mkv)
#   two.m4a   the same two tracks in AAC (MP4, demux_lavf)
#   long.flac 15 min sine, 44.1 kHz mono (14 MB)
#   gap.flac  2 s of silence then 8 s of pink noise; gap.ts the same in AAC
#             in MPEG-TS (start time 1.4 s), gaplate.ts with the timestamps
#             3600 s later, gaplate.ogg in Vorbis starting at 100 s
#   over.aac  ADTS AAC, 3 s of silence then pink noise, 40 s, whose
#             estimated duration overshoots
# playback/ (pcm_*, chapter_list_test, af_command_args_test): constant (DC)
# files, so a sample tells which file it came from, 3 s each unless said
#   p_st48.flac   +0.25, stereo, 48 kHz     p_mono48.flac +0.25, mono, 48 kHz
#   n_st48.flac   -0.5,  stereo, 48 kHz     n_mono48.flac -0.5,  mono, 48 kHz
#   n_st44.flac   -0.5,  stereo, 44.1 kHz
#   pn_st48.flac  +0.25 for 2 s then -0.5 for 4 s, stereo, 48 kHz
#   dc20.flac     +0.25, 20 s, stereo, 48 kHz
#   dcm20.flac    -0.25, 20 s, stereo, 48 kHz
#   dc2.mka       dc20.flac then dcm20.flac as two audio tracks
#   sine60.flac   60 s sine, stereo, 48 kHz
# readerror/ (read_error_test), read over HTTP from slow_http.py
#   n.flac      4 s pink noise with a fixed seed, 44.1 kHz stereo (466574
#               bytes, 116 KB a second, so a seek of a second goes past the
#               read buffers); the cut offsets in run.sh are its own
#   n.mp3       n.flac as CBR MP3 at 128 kb/s with an Info header (65220
#               bytes, 16 KB a second), which FFmpeg seeks by offset
#   short.flac  1 s sine, the second entry of the playlist modes
#   vbr.mp3     VBR MP3 without Xing header, 1.5 s of silence then 2.5 s of
#               pink noise: its duration is an estimate, about 6 s for 4
#   hls.m3u8    n.flac in AAC as HLS VOD, seg0.ts to seg3.ts of 1 s and
#               seg4.ts of 23 ms
#
# Usage: bash verify/tests/native/fixtures.sh <dir>

set -euo pipefail

D="${1:?usage: fixtures.sh <dir>}"
ff() { ffmpeg -nostdin -loglevel error -y "$@"; }

d="$D/prefetch"; mkdir -p "$d"
tone() { [[ -f "$d/$1" ]] || ff -f lavfi -i "sine=frequency=$2:sample_rate=44100:duration=$3" -ac 2 -metadata title="$4" "$d/$1"; }
tone a.flac 440 60 "Track A"
tone b.flac 660 60 "Track B"
tone c.flac 880 30 "Track C"
tone a2.flac 550 2 "Track A2"

d="$D/analysis"; mkdir -p "$d"
if [[ ! -f "$d/x16.opus" ]]; then
  pan="16c"; for i in $(seq 0 15); do pan="$pan|c$i=c0"; done
  ff -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=10" -af "pan=$pan" \
     -c:a libopus -mapping_family 255 "$d/x16.opus"
fi
if [[ ! -f "$d/sm.mp3" ]]; then
  ff -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=10" -ac 2 -c:a libmp3lame -b:a 128k "$d/s.mp3"
  ff -f lavfi -i "sine=frequency=660:sample_rate=44100:duration=10" -ac 1 -c:a libmp3lame -b:a 64k "$d/m.mp3"
  cat "$d/s.mp3" "$d/m.mp3" > "$d/sm.mp3"
fi
[[ -f "$d/ms.mp3" ]] || cat "$d/m.mp3" "$d/s.mp3" > "$d/ms.mp3"
[[ -f "$d/a.flac" ]] || ff -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=30" \
  -af volume=-30dB -ac 2 -c:a flac "$d/a.flac"
[[ -f "$d/b.flac" ]] || ff -f lavfi -i "anoisesrc=color=pink:amplitude=0.5:sample_rate=48000:duration=30" \
  -ac 2 -c:a flac "$d/b.flac"
[[ -f "$d/two.mka" ]] || ff -i "$d/a.flac" -i "$d/b.flac" -map 0 -map 1 -c copy "$d/two.mka"
[[ -f "$d/long.flac" ]] || ff -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=900" \
  -ac 1 -c:a flac "$d/long.flac"
[[ -f "$d/two.m4a" ]] || ff -i "$d/a.flac" -i "$d/b.flac" -map 0 -map 1 -c:a aac -b:a 160k "$d/two.m4a"
# Start time (F64): 2 s of silence, then 8 s of pink noise.
[[ -f "$d/gap.flac" ]] || ff -f lavfi -i "anoisesrc=color=pink:amplitude=0.5:sample_rate=48000:duration=10" \
  -af "volume=enable='lt(t,2)':volume=0" -ac 2 -c:a flac "$d/gap.flac"
[[ -f "$d/gap.ts" ]] || ff -i "$d/gap.flac" -c:a aac -b:a 192k -f mpegts "$d/gap.ts"
[[ -f "$d/gaplate.ts" ]] || ff -i "$d/gap.flac" -c:a aac -b:a 192k -output_ts_offset 3600 -f mpegts "$d/gaplate.ts"
[[ -f "$d/gaplate.ogg" ]] || ff -i "$d/gap.flac" -c:a libvorbis -q:a 5 -output_ts_offset 100 "$d/gaplate.ogg"
# Duration overestimate (F66): ADTS AAC that starts with 3 s of silence, so
# the duration lavf estimates from the bitrate of its first frames is far
# longer than its 40 s.
[[ -f "$d/over.aac" ]] || ff -f lavfi -i "anoisesrc=color=pink:amplitude=0.5:sample_rate=44100:duration=40" \
  -af "volume=enable='lt(t,3)':volume=0" -ac 2 -c:a aac -q:a 2 -f adts "$d/over.aac"

d="$D/playback"; mkdir -p "$d"
dc() { [[ -f "$d/$1" ]] || ff -f lavfi -i "aevalsrc=$2:s=$3:d=$4" -c:a flac "$d/$1"; }
dc p_st48.flac "0.25|0.25" 48000 3
dc p_mono48.flac "0.25" 48000 3
dc n_st48.flac "-0.5|-0.5" 48000 3
dc n_mono48.flac "-0.5" 48000 3
dc n_st44.flac "-0.5|-0.5" 44100 3
dc pn_st48.flac "if(lt(t\,2)\,0.25\,-0.5)|if(lt(t\,2)\,0.25\,-0.5)" 48000 6
dc dc20.flac "0.25|0.25" 48000 20
dc dcm20.flac "-0.25|-0.25" 48000 20
[[ -f "$d/dc2.mka" ]] || ff -i "$d/dc20.flac" -i "$d/dcm20.flac" -map 0 -map 1 -c copy "$d/dc2.mka"
[[ -f "$d/sine60.flac" ]] || ff -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=60" -ac 2 -c:a flac "$d/sine60.flac"

d="$D/readerror"; mkdir -p "$d"
[[ -f "$d/n.flac" ]] || ff -f lavfi -i "anoisesrc=color=pink:amplitude=0.5:sample_rate=44100:duration=4:seed=1" \
  -ac 2 -c:a flac "$d/n.flac"
[[ -f "$d/n.mp3" ]] || ff -i "$d/n.flac" -bitexact -c:a libmp3lame -b:a 128k "$d/n.mp3"
[[ -f "$d/short.flac" ]] || ff -f lavfi -i "sine=frequency=660:sample_rate=44100:duration=1" -ac 2 "$d/short.flac"
[[ -f "$d/vbr.mp3" ]] || ff -f lavfi -i "anoisesrc=color=pink:amplitude=0.5:sample_rate=44100:duration=4:seed=1" \
  -af "volume=enable='lt(t,1.5)':volume=0" -ac 2 -c:a libmp3lame -q:a 6 -write_xing 0 "$d/vbr.mp3"
[[ -f "$d/hls.m3u8" ]] || ff -i "$d/n.flac" -c:a aac -b:a 128k -f hls -hls_time 1 -hls_playlist_type vod \
  -hls_segment_filename "$d/seg%d.ts" "$d/hls.m3u8"
