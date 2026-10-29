#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Runs the native tests of the mpv patches. It downloads mpv, checks it
# against scripts/shared/_sources.sha256, applies the mpv patches as
# build_libmpv_linux.sh does (apply_mpv_patches_common, then
# patch_optional_audio_libs.py) and builds a debug libmpv with
# AddressSanitizer against the system FFmpeg. Then it runs:
#   - the C tests of this dir, linked with that libmpv, each mode in its own
#     process with the files of fixtures.sh and, for the modes that read
#     over HTTP, slow_http.py at the rate listed in CASES;
#   - the white-box tests, which include one patched source file of the
#     tree (unit) or pristine ao_audiotrack.c with its patch (audiotrack);
#   - the tests of the patch scripts in verify/tests/patches, on pristine
#     mpv and FFmpeg (downloaded and checked the same way).
# A mode passes when its process exits 0: it printed RESULT PASS and
# AddressSanitizer and LeakSanitizer found nothing. Each mode has 120 s.
# The logs stay in <work dir>/runs.
#
# Needs gcc, meson, ninja, pkg-config, python3, curl, the ffmpeg command
# with the libopus, libmp3lame and libvorbis encoders, and the FFmpeg
# development files (mpv 0.41 wants libavcodec 60.31.102 or later).
# audiotrack_test and audiotrack_patch_test run only when
# patches/mpv/android/patch_audiotrack.py exists; audiotrack_test then needs
# jni.h from the NDK in ANDROID_NDK_HOME.
#
# The work dir is wiped first; --reuse keeps its downloads, build and
# fixtures, to rerun after editing a test. Arguments after the work dir pick
# tests, with an optional list of modes: prefetch_state_test:fail,stop.
# Environment: MPV_TARBALL and FFMPEG_TARBALL name local copies of the
# tarballs (checked against the same pins), DISABLED_PATCHES leaves patches
# out as the build does (to see a test fail without its fix), JOBS sets the
# build jobs (default 4), CC the compiler of libmpv and the tests (gcc).
# The tests take about two minutes, most of it waiting on playback.
#
# Usage: bash verify/tests/native/run.sh [--reuse] <work dir> [test[:mode,...] ...]

set -uo pipefail
# AddressSanitizer must come first in the library list.
unset LD_PRELOAD

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
USAGE="usage: run.sh [--reuse] <work dir> [test[:mode,...] ...]"
REUSE=0
if [[ "${1:-}" == "--reuse" ]]; then REUSE=1; shift; fi
WORK="${1:?$USAGE}"; shift
CC="${CC:-gcc}"; export CC
JOBS="${JOBS:-4}"
WANT_DISABLED="${DISABLED_PATCHES:-}"

# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_helpers.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_versions.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_audio_only.sh"
# Only what the caller asked for is left out, not a local Settings override.
DISABLED_PATCHES="$WANT_DISABLED"

# <kind> <test> <fixtures> <HTTP bytes per second[:cut[:option,...]]> <modes...>
#   lib: linked with libmpv; unit: includes a patched source file;
#   audiotrack: includes pristine ao_audiotrack.c with its patch.
#   fixtures: a dir of fixtures.sh, "-" for none; HTTP "-": no server.
#   The cut and the options go to slow_http.py, which lists them.
CASES=(
  "lib prefetch_hook_test prefetch - stall transition rewrite props clear stop destroy noclient repeat"
  "lib prefetch_guard_test prefetch - two"
  "lib prefetch_params_test prefetch - differ only-b same none hint hintdiffer"
  "lib prefetch_state_test prefetch - fail stop failstop hookfail"
  "lib prefetch_state_test prefetch 2000 httpstop"
  "lib analysis_channels_test analysis - opus16 opus16wave opus16loud sm smloud ms"
  "lib analysis_channels_test analysis 4000000 opus16http opus16httpwave"
  "lib analysis_track_test analysis - mka1 mka2 m4a2 ext"
  "lib analysis_track_test analysis 1000000 http2 httpseek"
  "lib analysis_fd_test analysis - fd fdclose reuse pipe"
  "lib analysis_close_test analysis 600000 stop feedstop readystop loudoff loudkeep probe"
  "lib analysis_worker_test analysis - fail"
  "lib analysis_oom_test analysis - start"
  "lib analysis_start_test analysis - ts late ogg"
  "lib analysis_start_test analysis 2000000 http"
  "lib analysis_tail_test analysis 2000000 over"
  "lib analysis_tail_test analysis 2000000:400000 overcut"
  "lib analysis_feed_test analysis 600000 grow"
  "lib analysis_hint_test analysis 60000::chunked exact short long none full nocache"
  "lib analysis_hint_test analysis 600000 range"
  "unit loudness_lock_test - - run"
  "lib ao_close_test prefetch - play pause eof direct silence stop nogapless"
  "audiotrack audiotrack_test - - underrun silence dead pause seek"
  "lib pcm_tap_test playback - ch up rate idle"
  "unit pcm_tap_idle_test - - idle slow pause quiet"
  "lib pcm_loop_test playback - file late ab next abnext off"
  "lib chapter_list_test playback - meta index observe kit same"
  "lib af_command_args_test playback - prop seek track extern reload next keep rollback order fail labels bridge"
  "lib read_error_test readerror 2000000:233000:drop cutlist"
  "lib read_error_test readerror 2000000:233000:down cutpark"
  "lib read_error_test readerror 2000000:233000:norange norange"
  "lib read_error_test readerror 2000000 whole vbr"
  "lib read_error_test readerror 2000000:233000:resume resume"
  "lib read_error_test readerror 2000000:311000:drop seekback"
  "lib read_error_test readerror 2000000:311000:outage retry retryback retrynocache retrybacknocache"
  "lib read_error_test readerror 2000000:43500:outage retrymp3"
  "lib read_error_test readerror 2000000::missing=seg2.ts hls"
)
# <test> <arguments>: {mpv} pristine mpv, {ffmpeg} pristine FFmpeg, {src}
# and {build} the patched tree and its build. The work dir comes last.
PATCH_TESTS=(
  "prefetch_patch_test {mpv}"
  "ios_audio_stubs_patch_test {mpv}"
  "audiotrack_patch_test {mpv} {src} {build}"
  "apply_order_test {mpv}"
  "libsmb2_patch_test {ffmpeg}"
  "embed_cacert_patch_test {ffmpeg}"
  "filter_bounds_anchor_test {ffmpeg}"
  "winsock_poll_patch_test {ffmpeg}"
  "dash_keepalive_patch_test {ffmpeg}"
  "read_error_patch_test {ffmpeg}"
  "anchor_corrupt_test {mpv} {ffmpeg}"
)
AUDIOTRACK_PATCH="$ROOT/patches/mpv/android/patch_audiotrack.py"

# Test selection: test name -> its modes ("" for all).
declare -A SEL=()
for a in "$@"; do
  m=""; [[ "$a" == *:* ]] && m="${a#*:}"
  SEL["${a%%:*}"]="${m//,/ }"
done
picked() { (( ${#SEL[@]} == 0 )) || [[ -v "SEL[$1]" ]]; }
# picked_modes <test> <modes...>: the listed modes the selection keeps.
picked_modes() {
  local t="$1"; shift
  if (( ${#SEL[@]} == 0 )) || [[ -z "${SEL[$t]}" ]]; then echo "$*"; return; fi
  local m out=()
  for m in "$@"; do [[ " ${SEL[$t]} " == *" $m "* ]] && out+=("$m"); done
  echo "${out[*]}"
}

NEED_BUILD=0 NEED_FX=0 NEED_FFMPEG=0
for c in "${CASES[@]}"; do
  read -r kind t fx _ <<< "$c"
  picked "$t" || continue
  NEED_BUILD=1
  [[ "$fx" != "-" ]] && NEED_FX=1
done
for p in "${PATCH_TESTS[@]}"; do
  picked "${p%% *}" || continue
  [[ "$p" == *"{build}"* ]] && NEED_BUILD=1
  [[ "$p" == *"{ffmpeg}"* ]] && NEED_FFMPEG=1
done

(( REUSE )) || rm -rf "$WORK"
mkdir -p "$WORK/logs"
WORK="$(cd "$WORK" && pwd)"
RUNS="$WORK/runs" BIN="$WORK/bin" FX="$WORK/fixtures"
SRC="$WORK/src" BLD="$WORK/build"
rm -rf "$RUNS"; mkdir -p "$RUNS" "$BIN"

# fetch <url> <local copy or ""> <dest dir> [path...]: the tarball, checked
# against its pin, extracted to <dest dir> (only the given paths of its top
# dir when there are some).
fetch() {
  local url="$1" copy="$2" dest="$3"; shift 3
  local tarball top p members=()
  tarball="$dest.tar.gz"
  [[ -s "$tarball" || -z "$copy" ]] || cp "$copy" "$tarball"
  download "$url" "$tarball" || exit 1
  [[ -d "$dest" ]] && return
  top="$(tar -tzf "$tarball" | head -1)"; top="${top%%/*}"
  for p in "$@"; do members+=("$top/$p"); done
  rm -rf "$dest.tmp"; mkdir -p "$dest.tmp"
  tar -xzf "$tarball" --strip-components=1 -C "$dest.tmp" "${members[@]}" || die "cannot extract $tarball"
  mv "$dest.tmp" "$dest"
}

fetch "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz" \
  "${MPV_TARBALL:-}" "$WORK/mpv"
if (( NEED_FFMPEG )); then
  fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz" "${FFMPEG_TARBALL:-}" \
    "$WORK/ffmpeg" configure libavcodec libavformat libavfilter
fi

echo "mpv $MPV_VERSION, libavcodec $(pkg-config --modversion libavcodec 2>/dev/null || echo '?')," \
  "$("$CC" --version | head -1), meson $(meson --version 2>/dev/null || echo '?')"
[[ -n "$DISABLED_PATCHES" ]] && echo "disabled patches: $DISABLED_PATCHES"

if (( NEED_BUILD )) && [[ ! -f "$BLD/libmpv.so" || $REUSE == 0 ]]; then
  log "Patching and building mpv $MPV_VERSION with AddressSanitizer"
  rm -rf "$SRC" "$BLD"
  cp -a "$WORK/mpv" "$SRC"
  # Not on the left of ||: bash ignores set -e there, also inside the
  # subshell, and a failed patch would let the build go on without it.
  ( set -e
    apply_mpv_patches_common "$SRC"
    python3 "$ROOT/patches/mpv/linux/patch_optional_audio_libs.py" "$SRC"
  ) > "$WORK/logs/apply.log" 2>&1
  (( $? == 0 )) || { tail -20 "$WORK/logs/apply.log"; die "the mpv patches failed"; }
  ( cd "$SRC" && meson setup "$BLD" -Dbuildtype=debug -Doptimization=1 -Dauto_features=disabled \
      -Dgpl=true -Dlibmpv=true -Dcplayer=false -Dbuild-date=false -Dtests=false -Dgl=disabled \
      -Dplain-gl=disabled -Drubberband=disabled -Dzlib=enabled -Db_sanitize=address -Db_lundef=false
  ) > "$WORK/logs/setup.log" 2>&1 || { tail -30 "$WORK/logs/setup.log"; die "meson setup failed"; }
  ninja -C "$BLD" -j"$JOBS" > "$WORK/logs/ninja.log" 2>&1 || {
    grep -B2 -A8 'error' "$WORK/logs/ninja.log" | head -60; die "the mpv build failed"; }
  ok "built $BLD/libmpv.so"
fi
if (( NEED_FX )); then
  bash "$HERE/fixtures.sh" "$FX" > "$WORK/logs/fixtures.log" 2>&1 || {
    tail -20 "$WORK/logs/fixtures.log"; die "the fixtures failed"; }
fi

PASSED=0 SKIPPED=0
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
  grep -E '^FAIL|ERROR: (Address|Leak)Sanitizer|^SUMMARY|Assertion|runtime error' "$3" | head -8 | sed 's/^/     /'
  FAILED+=("$1")
}
skip() { echo "skip $1"; SKIPPED=$((SKIPPED + 1)); }

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
wait_port() {
  local i
  for i in $(seq 50); do
    (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null && return 0
    sleep 0.1
  done
  return 1
}

TA=()
compile() { # compile <kind> <test>: builds $BIN/<test>, 0 on success
  local kind="$1" t="$2" log="$RUNS/$2.cc.log"
  case "$kind" in
    lib)
      # The FFmpeg headers for read_error_test, which stands in for an
      # libavutil function.
      # shellcheck disable=SC2046
      "$CC" -g -O1 -fsanitize=address -I"$SRC/include" $(pkg-config --cflags libavutil) \
        "$HERE/$t.c" -o "$BIN/$t" -L"$BLD" -lmpv -Wl,-rpath,"$BLD" -ldl -lpthread -lm > "$log" 2>&1 ;;
    unit)
      # shellcheck disable=SC2046
      "$CC" -g -O1 -std=gnu11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -fsanitize=address \
        -I"$SRC" -I"$SRC/include" -I"$BLD" $(pkg-config --cflags libavcodec libswresample libavutil) \
        "$HERE/$t.c" "${TA[@]}" -o "$BIN/$t" \
        $(pkg-config --libs libavcodec libswresample libavutil) -lpthread -lm > "$log" 2>&1 ;;
    audiotrack)
      local o="$WORK/audiotrack" ndk="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
      local jni="$ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/jni.h"
      [[ -n "$ndk" && -f "$jni" ]] || { echo "no jni.h: set ANDROID_NDK_HOME to an NDK" > "$log"; return 1; }
      rm -rf "$o"; mkdir -p "$o/audio/out" "$o/jni"
      ln -s "$jni" "$o/jni/jni.h"
      cp "$SRC"/audio/out/*.h "$o/audio/out/"
      # The patch also edits buffer.c (the paused delay); the test builds the
      # driver only, but the patch wants both files to apply.
      cp "$WORK/mpv/audio/out/ao_audiotrack.c" "$WORK/mpv/audio/out/buffer.c" "$o/audio/out/"
      python3 -B "$AUDIOTRACK_PATCH" "$o" > "$log" 2>&1 || return 1
      "$CC" -g -O1 -std=gnu11 -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -fsanitize=address \
        -Wall -Wno-unused-function -I"$o" -I"$SRC" -I"$SRC/include" -I"$BLD" -idirafter "$o/jni" \
        "$HERE/$t.c" "${TA[@]}" -o "$BIN/$t" -lpthread -lm >> "$log" 2>&1 ;;
  esac
}

# run_mode <test> <mode> <fixtures> <HTTP rate[:cut]>
run_mode() {
  local t="$1" m="$2" fx="$3" http="$4" tmp="$RUNS/$1-$2" srv="" port="" r
  rm -rf "$tmp"; mkdir -p "$tmp"
  if [[ "$http" != "-" ]]; then
    port="$(free_port)"
    local rate="${http%%:*}" cut="" opts=""
    [[ "$http" == *:* ]] && cut="${http#*:}"
    if [[ "$cut" == *:* ]]; then opts="${cut#*:}"; cut="${cut%%:*}"; fi
    # shellcheck disable=SC2086
    python3 -B "$HERE/slow_http.py" "$FX/$fx" "$port" "$rate" $cut ${opts//,/ } 2> "$tmp.http.log" &
    srv=$!
    wait_port "$port" || echo "slow_http.py did not start on port $port" >> "$tmp.log"
  fi
  if [[ "$fx" == "-" ]]; then
    timeout 120 "$BIN/$t" "$m" > "$tmp.log" 2>&1; r=$?
  else
    env ${port:+HTTP_PORT=$port} timeout 120 "$BIN/$t" "$m" "$FX/$fx" "$tmp" > "$tmp.log" 2>&1; r=$?
  fi
  if [[ -n "$srv" ]]; then kill "$srv" 2> /dev/null; wait "$srv" 2> /dev/null; fi
  report "$t $m" "$r" "$tmp.log"
}

if (( NEED_BUILD )); then
  TA=("$BLD"/libmpv.so.*.p/ta_ta*.c.o)
fi
declare -A BUILT=()
for c in "${CASES[@]}"; do
  read -r kind t fx http listed <<< "$c"
  picked "$t" || continue
  # shellcheck disable=SC2086
  read -r -a modes <<< "$(picked_modes "$t" $listed)"
  (( ${#modes[@]} )) || continue
  if [[ "$kind" == audiotrack && ! -f "$AUDIOTRACK_PATCH" ]]; then
    skip "$t: no patches/mpv/android/patch_audiotrack.py"
    continue
  fi
  if [[ -z "${BUILT[$t]:-}" ]]; then
    if compile "$kind" "$t"; then
      BUILT[$t]=1
    else
      echo "FAIL $t: does not compile"; sed 's/^/     /' "$RUNS/$t.cc.log" | head -20
      FAILED+=("$t (compile)")
      BUILT[$t]=0
    fi
  fi
  [[ "${BUILT[$t]}" == 1 ]] || continue
  for m in "${modes[@]}"; do run_mode "$t" "$m" "$fx" "$http"; done
done

for p in "${PATCH_TESTS[@]}"; do
  read -r t args <<< "$p"
  picked "$t" || continue
  if [[ "$t" == audiotrack_patch_test && ! -f "$AUDIOTRACK_PATCH" ]]; then
    skip "$t: no patches/mpv/android/patch_audiotrack.py"
    continue
  fi
  args="${args//\{mpv\}/$WORK/mpv}"; args="${args//\{ffmpeg\}/$WORK/ffmpeg}"
  args="${args//\{src\}/$SRC}"; args="${args//\{build\}/$BLD}"
  # shellcheck disable=SC2086
  timeout 600 bash "$ROOT/verify/tests/patches/$t.sh" $args "$RUNS/$t" > "$RUNS/$t.log" 2>&1
  r=$?
  if (( r == 0 )); then
    echo "ok   $t: $(tail -1 "$RUNS/$t.log")"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL $t: exit $r, $(tail -1 "$RUNS/$t.log")"
    grep -E '^FAIL' "$RUNS/$t.log" | head -8 | sed 's/^/     /'
    FAILED+=("$t")
  fi
done

echo "$PASSED passed, ${#FAILED[@]} failed, $SKIPPED skipped"
if (( ${#FAILED[@]} )); then
  printf 'failed: %s\n' "${FAILED[@]}"
  exit 1
fi
(( PASSED + SKIPPED > 0 )) || { echo "no test picked"; exit 1; }
