#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks the network side of the FFmpeg patches at runtime: the SMB
# protocol, the embedded CA bundle and the read errors. It downloads FFmpeg
# and libsmb2, checks them against scripts/shared/_sources.sha256, and
# builds with AddressSanitizer libsmb2 (without Kerberos, like the release
# builds) and a minimal FFmpeg: the file, tcp, udp, tls (system OpenSSL),
# http and libsmb2 protocols, the wav, hls, mpegts, dash (libxml2) and mov
# demuxers and the aac decoder, with patch_ffmpeg_libsmb2.py,
# patch_ffmpeg_embed_cacert.py, patch_ffmpeg_http_reconnect.py and
# patch_ffmpeg_segment_skips.py applied.
# Then it runs, each mode in its own process:
#   - smb_url_test: the URL handling of libsmb2.c, password and percent
#     decoding (F85, F86);
#   - tls_roots_test: the embedded roots load only with verification on,
#     against openssl s_server (F90);
#   - smb_client_test: opens, reads and stops against impacket's server
#     (smb_server.py, one per mode, stopped with SIGSTOP), and a TCP connect
#     slowed by slow_connect.py (F83, F84, F85);
#   - read_errors_test: an HTTP body cut short ends with EIO when the
#     reconnect gets an error reply, and the HLS and DASH demuxers count the
#     segments they lose, against native/slow_http.py (one per mode).
# A mode passes when its process exits 0: it printed RESULT PASS and
# AddressSanitizer and LeakSanitizer found nothing. open-hang and pause-read
# wait about 35 s each and run in the background meanwhile. The logs stay
# in <work dir>/runs.
#
# Needs gcc, make, cmake, ninja, pkg-config, git, curl, python3, openssl,
# the OpenSSL and libxml2 development files, and the ffmpeg command with the
# aac encoder and the hls and dash muxers (the fixtures of
# read_errors_test). The smb_client_test modes need impacket for the python
# in SMB_PYTHON (default python3), e.g. a venv with pip install
# impacket==0.13.1.
#
# The work dir is wiped first; --reuse keeps the downloads and builds, and
# applies the patches again and runs make, to rerun after editing a patch
# or a test. Arguments after the work dir pick tests, with an optional list
# of modes: smb_client_test:read-stop,open-stop. Environment: FFMPEG_TARBALL
# names a local copy of the tarball (checked against the same pin), JOBS
# sets the build jobs (default 4), CC and FFMPEG_TOOLCHAIN the compiler
# (default gcc and gcc-asan, or clang and clang-asan), and
# DISABLED_PATCHES=read_error leaves out patch_ffmpeg_http_reconnect.py and
# patch_ffmpeg_segment_skips.py, to see read_errors_test fail without them.
# About two minutes at JOBS=4, half of it building.
#
# Usage: bash verify/tests/network_test.sh [--reuse] <work dir> [test[:mode,...] ...]

set -uo pipefail
# AddressSanitizer must come first in the library list.
unset LD_PRELOAD

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
USAGE="usage: network_test.sh [--reuse] <work dir> [test[:mode,...] ...]"
REUSE=0
if [[ "${1:-}" == "--reuse" ]]; then REUSE=1; shift; fi
WORK="${1:?$USAGE}"; shift
CC="${CC:-gcc}"
TOOLCHAIN="${FFMPEG_TOOLCHAIN:-gcc-asan}"
JOBS="${JOBS:-4}"
SMB_PYTHON="${SMB_PYTHON:-python3}"
WANT_DISABLED="${DISABLED_PATCHES:-}"

# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_helpers.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_versions.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_audio_only.sh"
# Only what the caller asked for is left out, not a local Settings override.
DISABLED_PATCHES="$WANT_DISABLED"

# <test> <modes...>; smb_client_test modes are <mode>[@<timeout in s>].
CASES=(
  "smb_url_test strip decode parse"
  "tls_roots_test verify"
  "smb_client_test open dir sum slow-open read-stop read-stop@60 kill-read@60 open-stop open-stop@60 stress open-hang pause-read"
  "read_errors_test http-refused http-resume hls-ok hls-404 hls-cut dash-ok dash-404 dash-cut"
)
# The modes that mostly wait, started first and in the background.
LONG_MODES=" open-hang pause-read "

declare -A SEL=()
for a in "$@"; do
  m=""; [[ "$a" == *:* ]] && m="${a#*:}"
  SEL["${a%%:*}"]="${m//,/ }"
done
picked() { (( ${#SEL[@]} == 0 )) || [[ -v "SEL[$1]" ]]; }
# picked_modes <test> <modes...>: the listed modes the selection keeps;
# read-stop picks read-stop@60 too.
picked_modes() {
  local t="$1"; shift
  if (( ${#SEL[@]} == 0 )) || [[ -z "${SEL[$t]}" ]]; then echo "$*"; return; fi
  local m out=()
  for m in "$@"; do
    [[ " ${SEL[$t]} " == *" $m "* || " ${SEL[$t]} " == *" ${m%@*} "* ]] && out+=("$m")
  done
  echo "${out[*]}"
}

(( REUSE )) || rm -rf "$WORK"
mkdir -p "$WORK/logs"
WORK="$(cd "$WORK" && pwd)"
RUNS="$WORK/runs" BIN="$WORK/bin" PREFIX="$WORK/prefix" FFPREFIX="$WORK/ffprefix"
SRC="$WORK/src/ffmpeg-$FFMPEG_VERSION" BLD="$WORK/build/ffmpeg" SHARE="$WORK/share"
rm -rf "$RUNS"; mkdir -p "$RUNS" "$BIN" "$WORK/src"
ASAN=(-fsanitize=address -fno-omit-frame-pointer)

# ── Sources ──────────────────────────────────────────────────────────────────
TARBALL="$WORK/src/ffmpeg-$FFMPEG_VERSION.tar.gz"
[[ -s "$TARBALL" || -z "${FFMPEG_TARBALL:-}" ]] || cp "$FFMPEG_TARBALL" "$TARBALL"
download "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz" "$TARBALL" || exit 1
download_git "https://github.com/sahlberg/libsmb2.git" "$WORK/src/libsmb2" "v$LIBSMB2_VERSION" || exit 1

echo "FFmpeg $FFMPEG_VERSION, libsmb2 $LIBSMB2_VERSION, $("$CC" --version | head -1)," \
  "$(openssl version 2>/dev/null || echo 'no openssl command')"

# ── Builds ───────────────────────────────────────────────────────────────────
if [[ ! -f "$PREFIX/lib/libsmb2.a" ]]; then
  log "Building libsmb2 $LIBSMB2_VERSION with AddressSanitizer"
  rm -rf "$WORK/build/libsmb2"
  cmake -S "$WORK/src/libsmb2" -B "$WORK/build/libsmb2" -GNinja -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Debug -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_DISABLE_FIND_PACKAGE_LibKrb5=ON -DHAVE_LIBKRB5=0 \
    -DHAVE_GSSAPI_GSSAPI_H=0 -DCMAKE_C_FLAGS="${ASAN[*]} -O1 -g" \
    > "$WORK/logs/libsmb2.log" 2>&1 &&
    ninja -C "$WORK/build/libsmb2" -j"$JOBS" install >> "$WORK/logs/libsmb2.log" 2>&1 || {
    tail -30 "$WORK/logs/libsmb2.log"; die "the libsmb2 build failed"; }
  apply_libsmb2_post_install_fixes "$PREFIX" linux
fi
export PKG_CONFIG_PATH="$FFPREFIX/lib/pkgconfig:$PREFIX/lib/pkgconfig"

if [[ ! -f "$BLD/config.h" ]]; then
  log "Configuring FFmpeg $FFMPEG_VERSION with AddressSanitizer"
  rm -rf "$SRC" "$BLD" "$FFPREFIX" "$WORK/pristine"
  tar -xzf "$TARBALL" -C "$WORK/src" || die "cannot extract $TARBALL"
  mkdir -p "$WORK/pristine" "$BLD"
  for f in tls_openssl.c http.c hls.c dashdec.c; do cp "$SRC/libavformat/$f" "$WORK/pristine/"; done
  python3 -B "$ROOT/patches/ffmpeg/patch_ffmpeg_libsmb2.py" "$SRC" "$ROOT/patches/ffmpeg/libsmb2.c" \
    > "$WORK/logs/patch.log" 2>&1 || { cat "$WORK/logs/patch.log"; die "patch_ffmpeg_libsmb2.py failed"; }
  ( cd "$BLD" && "$SRC/configure" --prefix="$FFPREFIX" --cc="$CC" --toolchain="$TOOLCHAIN" \
      --disable-everything --disable-autodetect --disable-programs --disable-doc \
      --disable-avdevice --disable-avfilter --disable-swscale --disable-x86asm \
      --disable-stripping --optflags=-O1 --enable-network --enable-openssl --enable-libsmb2 \
      --enable-libxml2 --enable-protocol=file,tcp,udp,tls,http,libsmb2 \
      --enable-demuxer=wav,hls,mpegts,dash,mov --enable-decoder=pcm_s16le,aac --enable-parser=aac
  ) > "$WORK/logs/configure.log" 2>&1 || { tail -30 "$WORK/logs/configure.log"; die "FFmpeg configure failed"; }
fi
# The patches of the tree under test, every run: libsmb2.c is copied again,
# and the other files are patched again from their pristine copies (cp
# keeps them newer than their objects, so make rebuilds them).
{ python3 -B "$ROOT/patches/ffmpeg/patch_ffmpeg_libsmb2.py" "$SRC" "$ROOT/patches/ffmpeg/libsmb2.c" &&
  touch "$SRC/libavformat/libsmb2.c" &&
  for f in tls_openssl.c http.c hls.c dashdec.c; do cp "$WORK/pristine/$f" "$SRC/libavformat/$f"; done &&
  python3 -B "$ROOT/patches/ffmpeg/patch_ffmpeg_embed_cacert.py" "$SRC" &&
  if patch_on read_error; then
    python3 -B "$ROOT/patches/ffmpeg/patch_ffmpeg_http_reconnect.py" "$SRC" &&
      python3 -B "$ROOT/patches/ffmpeg/patch_ffmpeg_segment_skips.py" "$SRC"
  fi
} > "$WORK/logs/patch.log" 2>&1 || { cat "$WORK/logs/patch.log"; die "the FFmpeg patches failed"; }
[[ -n "$DISABLED_PATCHES" ]] && echo "disabled patches: $DISABLED_PATCHES"
log "Building FFmpeg"
make -C "$BLD" -j"$JOBS" install > "$WORK/logs/make.log" 2>&1 || {
  grep -B2 -A8 'error' "$WORK/logs/make.log" | head -60; die "the FFmpeg build failed"; }
for c in LIBSMB2_PROTOCOL TLS_PROTOCOL HTTP_PROTOCOL HLS_DEMUXER DASH_DEMUXER; do
  grep -q "CONFIG_$c 1" "$BLD/config_components.h" || die "FFmpeg was built without CONFIG_$c"
done
ok "built $FFPREFIX"

# ── Tests ────────────────────────────────────────────────────────────────────
PASSED=0
FAILED=()
# report <label> <exit code> <log>
report() {
  local res
  res="$(grep -m1 -E '^RESULT' "$3" || echo 'no RESULT')"
  if (( $2 == 0 )); then
    echo "ok   $1: $res"
    PASSED=$((PASSED + 1))
    return
  fi
  (( $2 == 124 )) && res="timed out, $res"
  echo "FAIL $1: exit $2, $res"
  grep -E '^FAIL|ERROR: (Address|Leak)Sanitizer|^SUMMARY|runtime error' "$3" | head -8 | sed 's/^/     /'
  FAILED+=("$1")
}

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
# wait_line <log> <text>: up to 20 s for a server to print it.
wait_line() {
  local i
  for i in $(seq 200); do
    grep -q "$2" "$1" 2> /dev/null && return 0
    sleep 0.1
  done
  return 1
}
wait_port() {
  local i
  for i in $(seq 200); do
    (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null && return 0
    sleep 0.1
  done
  return 1
}
# Every server and proxy, stopped or not, goes at exit.
PIDS="$RUNS/pids"
: > "$PIDS"
cleanup() {
  local p
  while read -r p; do kill -CONT "$p" 2> /dev/null; kill "$p" 2> /dev/null; done < "$PIDS"
  wait 2> /dev/null
}
trap cleanup EXIT

compile() { # compile <test> [flags...]: builds $BIN/<test>, 0 on success
  local t="$1"; shift
  # shellcheck disable=SC2046
  "$CC" -g -O1 "${ASAN[@]}" "$@" "$HERE/$t.c" -o "$BIN/$t" \
    $(pkg-config --static --cflags --libs libavformat libsmb2) -lpthread > "$RUNS/$t.cc.log" 2>&1 && return
  echo "FAIL $t: does not compile"; sed 's/^/     /' "$RUNS/$t.cc.log" | head -20
  FAILED+=("$t (compile)")
  return 1
}

run_url() {
  local smb2="$ROOT/patches/ffmpeg/libsmb2.c" defs=() m r
  # The r17 signatures, to see the cases fail on the old file.
  grep -q '^static char \*strip_password_from_url' "$smb2" && defs+=(-DOLD_STRIP)
  grep -q '^static void percent_decode' "$smb2" && defs+=(-DOLD_DECODE)
  compile smb_url_test -std=c17 -D_GNU_SOURCE -DLIBSMB2_C="\"$smb2\"" "${defs[@]}" \
    -Wno-unused-function -I"$BLD" -I"$SRC" -I"$SRC/libavformat" || return
  for m in "$@"; do
    timeout 120 "$BIN/smb_url_test" "$m" > "$RUNS/smb_url_test-$m.log" 2>&1; r=$?
    report "smb_url_test $m" "$r" "$RUNS/smb_url_test-$m.log"
  done
}

run_tls() {
  local t="$RUNS/tls" port srv r
  compile tls_roots_test -Wl,--wrap=PEM_read_bio_X509 -Wl,--wrap=SSL_CTX_set_default_verify_paths || return
  mkdir -p "$t"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj /CN=network-test -keyout "$t/key.pem" -out "$t/cert.pem" > "$t/req.log" 2>&1 || {
    echo "FAIL tls_roots_test: no test certificate"; FAILED+=("tls_roots_test"); return; }
  port="$(free_port)"
  openssl s_server -accept "127.0.0.1:$port" -cert "$t/cert.pem" -key "$t/key.pem" -quiet \
    > "$t/server.log" 2>&1 &
  srv=$!; echo "$srv" >> "$PIDS"
  wait_port "$port" || echo "openssl s_server did not start on port $port" >> "$t/server.log"
  timeout 120 "$BIN/tls_roots_test" "$port" "$t/cert.pem" > "$RUNS/tls_roots_test-verify.log" 2>&1; r=$?
  kill "$srv" 2> /dev/null; wait "$srv" 2> /dev/null
  report "tls_roots_test verify" "$r" "$RUNS/tls_roots_test-verify.log"
}

# smb_mode <mode>[@<timeout in s>]: one mode against its own server; the
# exit code goes to <log>.rc.
smb_mode() {
  local mode="${1%@*}" tmo="-" log="$RUNS/smb_client_test-$1.log" port srv proxy url file="" r
  [[ "$1" == *@* ]] && tmo="${1#*@}000000"
  "$SMB_PYTHON" -I "$HERE/smb_server.py" "$SHARE" > "$log.server" 2>&1 &
  srv=$!; echo "$srv" >> "$PIDS"
  if ! wait_line "$log.server" '^ready'; then
    echo "RESULT FAIL: smb_server.py did not start" > "$log"; echo 1 > "$log.rc"; return
  fi
  port="$(awk '$1 == "ready" { print $2; exit }' "$log.server")"
  url="smb2://u:p@127.0.0.1:$port/SHARE/long.wav"
  case "$mode" in
    open) url="smb2://127.0.0.1:$port/SHARE/a@b.wav" ;;
    dir) url="smb2://u:p@127.0.0.1:$port/SHARE/" ;;
    sum) file="$SHARE/long.wav" ;;
    slow-open)
      python3 -I "$HERE/slow_connect.py" "$port" 2.5 > "$log.proxy" 2>&1 &
      proxy=$!; echo "$proxy" >> "$PIDS"
      wait_line "$log.proxy" '^ready' || echo "slow_connect.py did not start" >> "$log.proxy"
      url="smb2://u:p@127.0.0.1:$(awk '$1 == "ready" { print $2; exit }' "$log.proxy")/SHARE/long.wav" ;;
  esac
  SMB_SERVER_PID="$srv" timeout 120 "$BIN/smb_client_test" "$mode" "$url" "$tmo" ${file:+"$file"} > "$log" 2>&1
  r=$?
  kill -CONT "$srv" 2> /dev/null; kill "$srv" ${proxy:-} 2> /dev/null; wait "$srv" ${proxy:-} 2> /dev/null
  echo "$r" > "$log.rc"
}

run_smb() {
  local m bg=() fg=()
  if ! "$SMB_PYTHON" -I -c 'import impacket' 2> /dev/null; then
    echo "FAIL smb_client_test: no impacket for $SMB_PYTHON (set SMB_PYTHON to a python with impacket)"
    FAILED+=("smb_client_test (impacket)")
    return
  fi
  compile smb_client_test || return
  mkdir -p "$SHARE"
  python3 - "$SHARE/long.wav" <<'PY' || { echo "FAIL smb_client_test: no fixture"; FAILED+=("smb_client_test"); return; }
import random, sys, wave
# 60 s of stereo 16 bit noise at 48 kHz, the same bytes on every run.
w = wave.open(sys.argv[1], 'wb')
w.setnchannels(2)
w.setsampwidth(2)
w.setframerate(48000)
w.writeframes(random.Random(1).randbytes(60 * 48000 * 4))
w.close()
PY
  cp "$SHARE/long.wav" "$SHARE/a@b.wav"
  for m in "$@"; do
    if [[ "$LONG_MODES" == *" ${m%@*} "* ]]; then bg+=("$m"); smb_mode "$m" & else fg+=("$m"); fi
  done
  for m in "${fg[@]}"; do smb_mode "$m"; smb_report "$m"; done
  wait
  for m in "${bg[@]}"; do smb_report "$m"; done
}

# read_errors_mode <mode>: one mode against its own slow_http.py.
read_errors_mode() {
  local m="$1" log="$RUNS/read_errors_test-$1.log" port srv r opts=()
  case "$m" in
    http-refused) opts=(233287) ;;
    http-resume) opts=(233287 resume) ;;
    hls-404) opts=(missing=seg2.ts) ;;
    hls-cut) opts=(cutfile=seg2.ts) ;;
    dash-404) opts=(missing=chunk3.m4s) ;;
    dash-cut) opts=(cutfile=chunk3.m4s) ;;
  esac
  port="$(free_port)"
  python3 -I "$ROOT/verify/tests/native/slow_http.py" "$WORK/errors" "$port" 10000000 "${opts[@]}" \
    2> "$log.http" &
  srv=$!; echo "$srv" >> "$PIDS"
  wait_port "$port" || echo "slow_http.py did not start on port $port" >> "$log.http"
  timeout 120 "$BIN/read_errors_test" "$m" "$port" > "$log" 2>&1; r=$?
  kill "$srv" 2> /dev/null; wait "$srv" 2> /dev/null
  report "read_errors_test $m" "$r" "$log"
}

run_read_errors() {
  local d="$WORK/errors" m
  compile read_errors_test || return
  if [[ ! -f "$d/d.mpd" ]]; then
    rm -rf "$d"; mkdir -p "$d"
    {
      python3 -c 'import random, sys; open(sys.argv[1], "wb").write(random.Random(1).randbytes(466574))' \
        "$d/data.bin" &&
      ffmpeg -nostdin -loglevel error -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=4" \
        -ac 2 -c:a aac -b:a 128k -f hls -hls_time 1 -hls_playlist_type vod \
        -hls_segment_filename "$d/seg%d.ts" "$d/hls.m3u8" &&
      ffmpeg -nostdin -loglevel error -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=4" \
        -ac 2 -c:a aac -b:a 128k -f dash -seg_duration 1 -use_template 1 -use_timeline 0 \
        -init_seg_name init.m4s -media_seg_name 'chunk$Number$.m4s' "$d/d.mpd"
    } > "$WORK/logs/errors_fixtures.log" 2>&1 || {
      tail -5 "$WORK/logs/errors_fixtures.log"; echo "FAIL read_errors_test: no fixtures"
      FAILED+=("read_errors_test (fixtures)"); return; }
  fi
  for m in "$@"; do read_errors_mode "$m"; done
}

smb_report() {
  local m="$1" label="smb_client_test ${1%@*}" log="$RUNS/smb_client_test-$1.log"
  [[ "$m" == *@* ]] && label+=" (timeout ${m#*@} s)"
  report "$label" "$(cat "$log.rc" 2> /dev/null || echo 1)" "$log"
}

for c in "${CASES[@]}"; do
  read -r t listed <<< "$c"
  picked "$t" || continue
  # shellcheck disable=SC2086
  read -r -a modes <<< "$(picked_modes "$t" $listed)"
  (( ${#modes[@]} )) || continue
  case "$t" in
    smb_url_test) run_url "${modes[@]}" ;;
    tls_roots_test) run_tls ;;
    smb_client_test) run_smb "${modes[@]}" ;;
    read_errors_test) run_read_errors "${modes[@]}" ;;
  esac
done

echo "$PASSED passed, ${#FAILED[@]} failed"
if (( ${#FAILED[@]} )); then
  printf 'failed: %s\n' "${FAILED[@]}"
  exit 1
fi
(( PASSED > 0 )) || { echo "no test picked"; exit 1; }
