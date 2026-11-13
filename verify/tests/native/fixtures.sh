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
#   hint.opus Ogg Opus at 128 kb/s, 30 s of pink noise (about 330 KB): read
#             as a chunked stream, mpv knows no length for it
#   est.mp3   VBR MP3 without a Xing header, 3 s of loud white noise then
#             27 s of a quiet sine: lavf estimates 13 s from the bitrate of
#             its first frames
# ebu/ (loudness_ebu_test): 1 kHz sines of a known level, 48 kHz stereo
# 16-bit FLAC unless said, after the synthetic signals of EBU Tech 3341 and
# Tech 3342 (levels in dBFS of the sine's peak, so a stereo file at -23 dBFS
# measures -23.0 LUFS)
#   s23.flac, s33.flac  20 s at -23 and at -33 (3341 cases 1 and 2)
#   g3.flac   10 s at -36, 60 s at -23, 10 s at -36 (case 3)
#   g4.flac   10 s at -72, 10 s at -36, 60 s at -23, 10 s at -36, 10 s at
#             -72 (case 4)
#   g5.flac   20 s at -26, 20.1 s at -20, 20 s at -26 (case 5)
#   c50.wav   5.0(side), 20 s: -28 in L and R, -24 in C, -30 in Ls and Rs
#             (case 6), 24-bit WAV
#   c51.flac  the same in 5.1 with the surrounds as back channels and a
#             60 Hz sine at -6 in the LFE
#   m23.flac  mono at -23; r44.flac and r96.flac stereo at -23, at 44.1 and
#             at 96 kHz
#   tp15.flac to tp19.flac  5 s, a sine at a fraction of the rate and a
#             phase that puts its crest between the samples, faded in and
#             out over half a second (cases 15 to 19): rate/4 at 0 degrees,
#             rate/4 at 45, rate/6 at 60, rate/8 at 67.5, all at 0.5, then
#             rate/4 at 45 degrees at 1.41 (samples at 0.997)
#   l1.flac to l4.flac  20 s a level (3342 cases 1 to 4): -20 then -30,
#             -20 then -15, -40 then -20, and -50, -35, -20, -35, -50
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
#   n.mka       n.flac copied into Matroska (460058 bytes), read by mpv's
#               own Matroska demuxer
#   n.webm      n.flac as Opus at 128 kb/s in WebM (46128 bytes), its Cues
#               after the cluster; nf.webm the same with the Cues before it
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
# A transcode served without a length (mpv_audio_kit #29).
[[ -f "$d/hint.opus" ]] || ff -f lavfi -i "anoisesrc=color=pink:amplitude=0.5:sample_rate=48000:duration=30" \
  -ac 2 -c:a libopus -b:a 128k "$d/hint.opus"
# A transcode whose length lavf estimates short (Subsonic's MP3 with an
# estimated Content-Length).
[[ -f "$d/est.mp3" ]] || ff -f lavfi -i "anoisesrc=color=white:amplitude=0.9:sample_rate=44100:duration=3" \
  -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=27" \
  -filter_complex "[1]volume=0.05[q];[0][q]concat=n=2:v=0:a=1" \
  -ac 2 -c:a libmp3lame -q:a 4 -write_xing 0 "$d/est.mp3"

d="$D/ebu"; mkdir -p "$d"
# amp <dBFS>: the linear amplitude, as an expression of aevalsrc.
amp() { echo "pow(10\\,$1/20)"; }
# steps <dBFS> <seconds> ... <dBFS>: the amplitude over time, each level
# held for the seconds after it and the last one to the end.
steps() {
  local out="" close="" at=0
  while (( $# > 1 )); do
    at="$(awk "BEGIN { print $at + $2 }")"
    out+="if(lt(t\\,$at)\\,$(amp "$1")\\,"; close+=")"
    shift 2
  done
  echo "$out$(amp "$1")$close"
}
# ebu <file> <rate> <seconds> <layout> <expression per channel> [codec options]
ebu() {
  local f="$1" rate="$2" secs="$3" layout="$4" expr="$5"; shift 5
  [[ -f "$d/$f" ]] && return
  (( $# )) || set -- -c:a flac -sample_fmt s16
  ff -f lavfi -i "aevalsrc=$expr:s=$rate:d=$secs:c=$layout" "$@" "$d/$f"
}
SIN="sin(2*PI*1000*t)"
both() { echo "$1*$SIN|$1*$SIN"; }
ebu s23.flac 48000 20 stereo "$(both "$(amp -23)")"
ebu s33.flac 48000 20 stereo "$(both "$(amp -33)")"
ebu g3.flac 48000 80 stereo "$(both "$(steps -36 10 -23 60 -36)")"
ebu g4.flac 48000 100 stereo "$(both "$(steps -72 10 -36 10 -23 60 -36 10 -72)")"
ebu g5.flac 48000 60.1 stereo "$(both "$(steps -26 20 -20 20.1 -26)")"
ebu c50.wav 48000 20 "5.0(side)" \
  "$(amp -28)*$SIN|$(amp -28)*$SIN|$(amp -24)*$SIN|$(amp -30)*$SIN|$(amp -30)*$SIN" -c:a pcm_s24le
ebu c51.flac 48000 20 "5.1" \
  "$(amp -28)*$SIN|$(amp -28)*$SIN|$(amp -24)*$SIN|$(amp -6)*sin(2*PI*60*t)|$(amp -30)*$SIN|$(amp -30)*$SIN"
ebu m23.flac 48000 20 mono "$(amp -23)*$SIN"
ebu r44.flac 44100 20 stereo "$(both "$(amp -23)")"
ebu r96.flac 96000 20 stereo "$(both "$(amp -23)")"
# peak <file> <rate divisor> <phase in degrees> <amplitude>
peak() {
  local e="$4*min(1\\,min(t\\,5-t)*2)*sin(2*PI*48000/$2*t+$3*PI/180)"
  ebu "$1" 48000 5 stereo "$e|$e"
}
peak tp15.flac 4 0 0.5
peak tp16.flac 4 45 0.5
peak tp17.flac 6 60 0.5
peak tp18.flac 8 67.5 0.5
peak tp19.flac 4 45 1.41
ebu l1.flac 48000 40 stereo "$(both "$(steps -20 20 -30)")"
ebu l2.flac 48000 40 stereo "$(both "$(steps -20 20 -15)")"
ebu l3.flac 48000 40 stereo "$(both "$(steps -40 20 -20)")"
ebu l4.flac 48000 100 stereo "$(both "$(steps -50 20 -35 20 -20 20 -35 20 -50)")"

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
[[ -f "$d/n.mka" ]] || ff -i "$d/n.flac" -c:a copy "$d/n.mka"
[[ -f "$d/n.webm" ]] || ff -i "$d/n.flac" -c:a libopus -b:a 128k "$d/n.webm"
[[ -f "$d/nf.webm" ]] || ff -i "$d/n.flac" -c:a libopus -b:a 128k -cues_to_front 1 "$d/nf.webm"
[[ -f "$d/short.flac" ]] || ff -f lavfi -i "sine=frequency=660:sample_rate=44100:duration=1" -ac 2 "$d/short.flac"
[[ -f "$d/vbr.mp3" ]] || ff -f lavfi -i "anoisesrc=color=pink:amplitude=0.5:sample_rate=44100:duration=4:seed=1" \
  -af "volume=enable='lt(t,1.5)':volume=0" -ac 2 -c:a libmp3lame -q:a 6 -write_xing 0 "$d/vbr.mp3"
[[ -f "$d/hls.m3u8" ]] || ff -i "$d/n.flac" -c:a aac -b:a 128k -f hls -hls_time 1 -hls_playlist_type vod \
  -hls_segment_filename "$d/seg%d.ts" "$d/hls.m3u8"
