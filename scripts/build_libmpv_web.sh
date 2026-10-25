#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# build_libmpv_web.sh
#
# Compiles mpv as a WebAssembly module for the browser, with Emscripten and
# pthreads: FFmpeg audio-only and libmpv as static archives, then one module
# (ES6 glue plus .wasm) that exports the mpv_* client API and the mak_pcm_*
# live PCM API, with mpv's webaudio output and its page side.
#
# === OUTPUT ===
# builds/release/libmpv_web/libmpv.mjs, libmpv.wasm   the module (no main),
#                                                     with Module.makWebAudio
# builds/release/libmpv_web/mak_webaudio_processor.js the AudioWorklet module
#                                                     of the webaudio output
# builds/release/libmpv_web/build_web.json            the patch record
# $BUILD_DIR/spike/spike.mjs, spike.wasm              the W1 harness module
#                                                     (verify/web/mak_spike.c)
#
# === SYSTEM ===
# emsdk $EMSDK_VERSION active (emcc on PATH, or EMSDK=<emsdk dir>), meson and
# ninja on PATH, python3, pkg-config. No Docker, no network once the sources
# are in $BUILD_DIR/src: every tarball is checked against _sources.sha256.
#
# What differs from the native builds:
# - no OpenSSL, no libsmb2, no sockets: the browser does TLS and the
#   transport (DISABLED_PATCHES gets libsmb2 and embed_cacert). http, https
#   and makblob (blob: URLs) are the webio protocols, which read through
#   fetch (patches/ffmpeg/patch_ffmpeg_webio.py, scripts/web/mak_webio.js);
# - the audio output is webaudio (patches/mpv/web/patch_ao_webaudio.py): mpv
#   writes rings in wasm memory that an AudioWorklet plays;
# - every shared mpv patch is applied as on the other platforms.
#
# Usage (from project root):
#   ./scripts/build_libmpv_web.sh
#   WEB_LTO=1 WEB_SIMD=1 ./scripts/build_libmpv_web.sh   # measured variants
#
# Options (env vars):
#   EMSDK=<dir>             (emsdk checkout; sourced when emcc is not on PATH)
#   JOBS=N                  (default: min(nproc, 8))
#   WEB_OPT=-Oz             (optimization flag of every C and C++ unit)
#   WEB_LTO=0|1             (LTO across FFmpeg, mpv and the deps; default 0)
#   WEB_SIMD=0|1            (-msimd128; default 0)
#   WEB_POOL=16             (pthread workers made at start; 0 makes each on
#                           demand, which counts the threads mpv needs)
#   WEB_INITIAL_MEMORY=128MB (wasm memory at start; it grows up to 2GB)
#   BUILD_DIR=<dir>         (default: builds/work/Web/<variant>)
#   RELEASE_DIR=<dir>       (default: builds/release/libmpv_web)
#   KEEP_BUILD=0            (wipe build/ and prefix/ at the end; by default
#                           they stay, so STAGE=link can relink)
#   STAGE=all|libs|link     (libs builds the archives only, link relinks)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"
source "$SCRIPT_DIR/shared/_audio_only.sh"

for arg in "$@"; do
  case "$arg" in
    --help|-h) grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# ── Web-only pins (centralised ones live in _versions.sh) ────────────────────
EMSDK_VERSION="${EMSDK_VERSION:-6.0.12}"
# The desktop libplacebo. mpv only keeps its colour helpers after
# strip_mpv_dead, and the 7.x line builds clean under emcc.
LIBPLACEBO_VERSION="7.349.0"

# The browser has no sockets, no TLS store and no SMB: the protocol patches
# that need them stay out (the per-user DISABLED_PATCHES is kept).
export DISABLED_PATCHES="${DISABLED_PATCHES:-} libsmb2 embed_cacert"

_nproc="$(nproc 2>/dev/null || echo 4)"
JOBS="${JOBS:-$(( _nproc < 8 ? _nproc : 8 ))}"
STAGE="${STAGE:-all}"
WEB_OPT="${WEB_OPT:--Oz}"
WEB_LTO="${WEB_LTO:-0}"
WEB_SIMD="${WEB_SIMD:-0}"
WEB_POOL="${WEB_POOL:-16}"
WEB_INITIAL_MEMORY="${WEB_INITIAL_MEMORY:-128MB}"

# The variant names the build dir, so a flag change never reuses archives
# built with other flags.
WEB_VARIANT="${WEB_OPT#-}"
[[ "$WEB_LTO" == "1" ]] && WEB_VARIANT+="-lto"
[[ "$WEB_SIMD" == "1" ]] && WEB_VARIANT+="-simd"
BUILD_DIR="${BUILD_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work/Web/$WEB_VARIANT}"
PREFIX="$BUILD_DIR/prefix"
RELEASE_DIR="${RELEASE_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/release/libmpv_web}"

# ── Toolchain ────────────────────────────────────────────────────────────────
if ! command -v emcc >/dev/null 2>&1 && [[ -n "${EMSDK:-}" ]]; then
  # shellcheck source=/dev/null
  source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
fi

check_toolchain() {
  local missing=() t
  for t in emcc em++ emar emranlib emnm emconfigure emmake meson ninja \
           pkg-config python3; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [[ ${#missing[@]} -gt 0 ]] && die "Missing toolchain binaries: ${missing[*]} (source emsdk_env.sh, or set EMSDK)"
  local got
  got="$(emcc --version | sed -n '1s/.* \([0-9][0-9.]*\) (.*/\1/p')"
  [[ "$got" == "$EMSDK_VERSION" ]] || \
    die "emcc $got found, the web build pins $EMSDK_VERSION (./emsdk activate $EMSDK_VERSION)"
  ok "Toolchain OK (emcc $got)"
}

# ── Flags ────────────────────────────────────────────────────────────────────
# -pthread on every unit and every link: a wasm object without the atomics
# feature cannot join a shared memory module. The LTO and SIMD variants go on
# every unit too, so the final link sees one kind of object.
WEB_CFLAGS="-pthread $WEB_OPT"
[[ "$WEB_LTO" == "1" ]] && WEB_CFLAGS+=" -flto"
[[ "$WEB_SIMD" == "1" ]] && WEB_CFLAGS+=" -msimd128"
WEB_LDFLAGS="-pthread"
[[ "$WEB_LTO" == "1" ]] && WEB_LDFLAGS+=" -flto"

export CFLAGS="$WEB_CFLAGS -I$PREFIX/include"
export CXXFLAGS="$WEB_CFLAGS -I$PREFIX/include"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="$WEB_LDFLAGS -L$PREFIX/lib"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

# The variant flags as a second meson cross file, after scripts/shared/
# emscripten.ini (toolchain and host machine).
write_meson_flags() {
  local f="$BUILD_DIR/emscripten-flags.ini" a quoted=()
  for a in $WEB_CFLAGS; do quoted+=("'$a'"); done
  local cargs; cargs="$(IFS=,; echo "${quoted[*]}")"
  quoted=()
  for a in $WEB_LDFLAGS; do quoted+=("'$a'"); done
  local largs; largs="$(IFS=,; echo "${quoted[*]}")"
  cat > "$f" <<EOF
[built-in options]
c_args = [$cargs]
cpp_args = [$cargs]
c_link_args = [$largs]
cpp_link_args = [$largs]
EOF
  MESON_CROSS=(--cross-file "$SCRIPT_DIR/shared/emscripten.ini" --cross-file "$f")
}

# ── Log ──────────────────────────────────────────────────────────────────────
LOG_DIR="$LIBMPV_SCRIPTS_ROOT/builds/logs"
mkdir -p "$LOG_DIR" "$BUILD_DIR"
ls -t "$LOG_DIR"/build_web-*_*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
LOG_FILE="$LOG_DIR/build_web-${WEB_VARIANT}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee >(while IFS= read -r line; do
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
done >> "$LOG_FILE")) 2>&1
echo "════════════════════════════════════════════════════════════"
echo "Build started: $(date)"
echo "Log file:      $LOG_FILE"
echo "FFmpeg:        $FFMPEG_VERSION   mpv: $MPV_VERSION   target: web ($WEB_VARIANT)"
echo "Build dir:     $BUILD_DIR"
echo "════════════════════════════════════════════════════════════"

# =============================================================================
# Library builds
# =============================================================================

build_zlib() {
  [[ -f "$PREFIX/lib/libz.a" ]] && return
  local src="$BUILD_DIR/src/zlib-$ZLIB_VERSION.tar.gz"
  download "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" "$src"
  rm -rf "$BUILD_DIR/src/zlib-$ZLIB_VERSION"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  emconfigure ./configure --prefix="$PREFIX" --static
  emmake make -j"$JOBS" libz.a
  emmake make install
  popd >/dev/null
  ok "zlib ✓"
}

build_libxml2() {
  [[ -f "$PREFIX/lib/libxml2.a" ]] && return
  local src="$BUILD_DIR/src/libxml2-$LIBXML2_VERSION.tar.xz"
  download "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-${LIBXML2_VERSION}.tar.xz" "$src"
  rm -rf "$BUILD_DIR/src/libxml2-$LIBXML2_VERSION"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/libxml2"; rm -rf "$bdir"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  # The same feature cut as Linux: the DASH demuxer only parses manifests.
  emconfigure "$dir/configure" --host=wasm32-unknown-emscripten \
    --prefix="$PREFIX" --enable-static --disable-shared \
    --without-python --without-readline --without-history \
    --without-http --without-ftp --without-html \
    --without-legacy --without-docbook --without-catalog \
    --without-schematron --without-modules --without-debug \
    --without-iconv --without-lzma --without-zlib
  emmake make -j"$JOBS"
  emmake make install
  popd >/dev/null
  ok "libxml2 ✓"
}

build_rubberband() {
  [[ -f "$PREFIX/lib/librubberband.a" ]] && return
  local src="$BUILD_DIR/src/rubberband-$RUBBERBAND_VERSION.tar.bz2"
  download "https://breakfastquay.com/files/releases/rubberband-${RUBBERBAND_VERSION}.tar.bz2" "$src"
  rm -rf "$BUILD_DIR/src/rubberband-$RUBBERBAND_VERSION"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/rubberband/patch_rubberband_size_t.py" "$dir"
  local bdir="$BUILD_DIR/build/rubberband"; rm -rf "$bdir"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  # resampler=speex is the copy bundled in rubberband, not libspeexdsp.
  meson setup "$dir" "${MESON_CROSS[@]}" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
    -Dfft=builtin -Dresampler=speex -Dladspa=disabled -Dlv2=disabled \
    -Dvamp=disabled -Djni=disabled -Dcmdline=disabled -Dtests=disabled
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "rubberband ✓"
}

build_libplacebo() {
  [[ -f "$PREFIX/lib/libplacebo.a" ]] && return
  local gitdir="$BUILD_DIR/src/libplacebo-git"
  download_git "https://code.videolan.org/videolan/libplacebo.git" "$gitdir" "v$LIBPLACEBO_VERSION"
  git -C "$gitdir" submodule update --init 3rdparty/jinja 3rdparty/markupsafe \
    3rdparty/fast_float 3rdparty/glad 3rdparty/Vulkan-Headers
  apply_libplacebo_patches "$gitdir"
  local bdir="$BUILD_DIR/build/libplacebo"; rm -rf "$bdir"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  meson setup "$gitdir" "${MESON_CROSS[@]}" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
    -Dvulkan=disabled -Dopengl=disabled -Dd3d11=disabled \
    -Dshaderc=disabled -Dglslang=disabled -Dlcms=disabled \
    -Dxxhash=disabled -Dunwind=disabled -Dlibdovi=disabled \
    -Ddemos=false -Dtests=false
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "libplacebo ✓"
}

# The shared FFmpeg flags with the web cuts: no sockets, no TLS, no lzma
# (nothing on the audio path reads it), the protocols that read memory and
# WasmFS, and webio for http, https and blob: URLs. The decoder, filter,
# parser and bsf lists stay the shared ones.
ffmpeg_web_args() {
  ffmpeg_common_args | sed \
    -e 's/^--enable-protocol=.*/--enable-protocol=file,data,crypto,subfile,webio_http,webio_https,webio_makblob/' \
    -e 's/^--enable-network$/--disable-network/' \
    -e 's/^--enable-openssl$/--disable-openssl/' \
    -e 's/^--enable-lzma$/--disable-lzma/' \
    -e '/^--enable-lto/d'
}

build_ffmpeg() {
  [[ -f "$PREFIX/lib/libavcodec.a" ]] && return
  log "Building ffmpeg $FFMPEG_VERSION..."
  local src="$BUILD_DIR/src/ffmpeg-$FFMPEG_VERSION.tar.gz"
  download "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz" "$src"
  rm -rf "$BUILD_DIR/src/ffmpeg-$FFMPEG_VERSION"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  patch_record_start ffmpeg "$PREFIX"
  apply_ffmpeg_patches "$dir"
  # http and https through fetch: the web build's only transport.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_webio.py" "$dir"

  local bdir="$BUILD_DIR/build/ffmpeg"; rm -rf "$bdir"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  # -pthread in the test links too, or configure turns pthreads off
  # (FFmpeg's configure probes pthread_join with the extra flags). The test
  # links go through em++: the rubberband probe links C++ with -lstdc++,
  # which only em++ maps to libc++.
  # shellcheck disable=SC2046
  "$dir/configure" \
    --prefix="$PREFIX" \
    $(ffmpeg_web_args) \
    --target-os=none --arch=wasm32 --enable-cross-compile \
    --cc=emcc --cxx=em++ --objcc=emcc --dep-cc=emcc --ld=em++ \
    --ar=emar --ranlib=emranlib --nm=emnm --pkg-config=pkg-config \
    --disable-asm --disable-inline-asm --disable-stripping \
    --disable-runtime-cpudetect --disable-autodetect \
    --enable-pthreads \
    --extra-cflags="$WEB_CFLAGS -I$PREFIX/include" \
    --extra-cxxflags="$WEB_CFLAGS -I$PREFIX/include" \
    --extra-ldflags="$WEB_LDFLAGS -L$PREFIX/lib"
  verify_ffmpeg_config "$bdir" "web"
  assert_define "$bdir/config.h" "HAVE_PTHREADS" "1"
  emmake make -j"$JOBS"; emmake make install
  popd >/dev/null
  ok "ffmpeg ✓"
}

build_mpv() {
  [[ -f "$PREFIX/lib/libmpv.a" ]] && return
  log "Building mpv $MPV_VERSION..."
  local src="$BUILD_DIR/src/mpv-$MPV_VERSION.tar.gz"
  download "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz" "$src"
  # A pristine tree on every build: the mpv patches assume an unpatched tree.
  rm -rf "$BUILD_DIR/src/mpv-$MPV_VERSION"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  patch_record_start mpv "$PREFIX"
  apply_mpv_patches_common "$dir"
  # The browser's audio output. Not a toggle: without it there is no sound.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/web/patch_ao_webaudio.py" "$dir"

  local bdir="$BUILD_DIR/build/mpv"; rm -rf "$bdir"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  local lto=false
  [[ "$WEB_LTO" == "1" ]] && lto=true
  # shellcheck disable=SC2046
  meson setup "$dir" "${MESON_CROSS[@]}" \
    --prefix="$PREFIX" --libdir=lib \
    --buildtype=release \
    --default-library=static \
    $(mpv_common_args | sed "s/^-Db_lto=.*/-Db_lto=$lto/") \
    -Dwebaudio=enabled
  verify_mpv_config "$bdir" "web"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "mpv ✓"
}

# =============================================================================
# Link: the module and the harness
# =============================================================================

# Archives in dependency order. C++ (rubberband, libplacebo) is why the link
# goes through em++.
WEB_LIBS=(-lmpv -lavfilter -lavformat -lavcodec -lswresample -lavutil
          -lplacebo -lrubberband -lxml2 -lz -lm)

# Settings shared by the module and the harness:
#   PTHREAD_POOL_SIZE=16      workers made at start: core, demux, decoder,
#                             ao, the bulk analysis (coordinator and up to 4
#                             workers) and mpv's thread pool. A thread past
#                             the pool waits until the main thread runs its
#                             event loop.
#   DEFAULT_PTHREAD_STACK_SIZE=2MB   the 64 KB default is too small for
#                             libavcodec decoders (libopus, the FLAC encoder
#                             paths) and mpv's option parser.
#   WASMFS                    the file system lives in wasm memory and every
#                             pthread reads it without a proxy to the main
#                             thread.
#   ALLOW_MEMORY_GROWTH       a 2 GB ceiling for the demuxer cache.
web_link_common() {
  printf '%s\n' \
    -sENVIRONMENT=web,worker,node \
    -sMODULARIZE -sEXPORT_ES6 \
    -sPTHREAD_POOL_SIZE="$WEB_POOL" \
    -sDEFAULT_PTHREAD_STACK_SIZE=2MB -sSTACK_SIZE=1MB \
    -sINITIAL_MEMORY="$WEB_INITIAL_MEMORY" -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=2GB \
    -sWASMFS -sFORCE_FILESYSTEM
}

# The exported C API: every name of shared/mpv.def (the Windows export list,
# the same surface as mpv.ver and mpv.exports) but the render API, which an
# audio-only build has no use for, and the wakeup pipe, which the browser
# replaces with the wakeup callback. Plus the shim and the allocator.
write_web_exports() {
  local f="$BUILD_DIR/web_exports.txt"
  {
    awk '/^EXPORTS/ {on=1; next} on && NF {print $1}' "$SCRIPT_DIR/shared/mpv.def" \
      | grep -Ev '^(mpv_render_|mpv_get_wakeup_pipe$)' | sed 's/^/_/'
    printf '%s\n' _mak_web_wakeup_attach _mak_web_wakeup_detach \
      _mak_web_layout _mak_wa_table_get _malloc _free
    # Streams of the webio protocols not freed yet, for the tests.
    printf '%s\n' _mak_webio_live_streams
  } > "$f"
  WEB_EXPORTS_FILE="$f"
}

link_web() {
  local shim="$LIBMPV_SCRIPTS_ROOT/scripts/web/mak_web.c"
  local obj="$BUILD_DIR/build/mak_web.o"
  mkdir -p "$BUILD_DIR/build" "$RELEASE_DIR" "$BUILD_DIR/spike"
  emcc $WEB_CFLAGS -I"$PREFIX/include" -c "$shim" -o "$obj"
  write_web_exports
  # The JS side of the webio protocols, which libavformat calls.
  local webio_js="$LIBMPV_SCRIPTS_ROOT/scripts/web/mak_webio.js"

  log "Linking libmpv.mjs..."
  # The page side of the webaudio output goes into the glue (post-js:
  # Module.makWebAudio); its AudioWorklet module is a file next to it.
  # shellcheck disable=SC2046
  em++ $WEB_CFLAGS $WEB_LDFLAGS "$obj" -L"$PREFIX/lib" "${WEB_LIBS[@]}" \
    $(web_link_common) \
    --no-entry --js-library "$webio_js" \
    -sEXPORT_NAME=createLibmpv \
    -sEXPORTED_FUNCTIONS=@"$WEB_EXPORTS_FILE" \
    -sEXPORTED_RUNTIME_METHODS=FS,UTF8ToString,stringToNewUTF8,HEAPU8,HEAP32,HEAPF64,wasmMemory \
    --post-js "$LIBMPV_SCRIPTS_ROOT/scripts/web/mak_webaudio.js" \
    -o "$RELEASE_DIR/libmpv.mjs"
  cp "$LIBMPV_SCRIPTS_ROOT/scripts/web/mak_webaudio_processor.js" "$RELEASE_DIR/"
  ok "libmpv.mjs ✓"

  log "Linking the harness (spike.mjs)..."
  # PROXY_TO_PTHREAD: main() runs on a pthread, so the harness may block in
  # mpv_wait_event while the main thread stays free. INVOKE_RUN=0: the runner
  # writes the input files into WasmFS first, then calls callMain.
  # shellcheck disable=SC2046
  emcc $WEB_CFLAGS -I"$PREFIX/include" -c "$LIBMPV_SCRIPTS_ROOT/verify/web/mak_spike.c" \
    -o "$BUILD_DIR/build/mak_spike.o"
  em++ $WEB_CFLAGS $WEB_LDFLAGS "$obj" "$BUILD_DIR/build/mak_spike.o" \
    -L"$PREFIX/lib" "${WEB_LIBS[@]}" \
    $(web_link_common) --js-library "$webio_js" \
    -sEXPORT_NAME=createSpike \
    -sPROXY_TO_PTHREAD -sEXIT_RUNTIME -sINVOKE_RUN=0 \
    -sEXPORTED_RUNTIME_METHODS=FS,callMain \
    -o "$BUILD_DIR/spike/spike.mjs"
  ok "spike.mjs ✓"
}

report_sizes() {
  local f
  for f in "$RELEASE_DIR/libmpv.wasm" "$RELEASE_DIR/libmpv.mjs" \
           "$RELEASE_DIR/mak_webaudio_processor.js" "$BUILD_DIR/spike/spike.wasm"; do
    [[ -f "$f" ]] || continue
    printf '%-60s raw %9d  gzip %9d  brotli %9d\n' "${f#"$LIBMPV_SCRIPTS_ROOT"/}" \
      "$(stat -c %s "$f")" "$(gzip -9c "$f" | wc -c)" \
      "$( (command -v brotli >/dev/null && brotli -9c "$f" | wc -c) || echo 0)"
  done
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  check_toolchain
  mkdir -p "$BUILD_DIR/src" "$BUILD_DIR/build" "$PREFIX/include" "$PREFIX/lib"
  write_meson_flags

  if [[ "$STAGE" != "link" ]]; then
    build_zlib
    build_libxml2
    build_rubberband
    build_libplacebo
    build_ffmpeg
    build_mpv
  fi
  if [[ "$STAGE" != "libs" ]]; then
    link_web
    # The record of the patches and filters the archives were built with,
    # next to the module (write_build_record in shared/_audio_only.sh).
    RELEASE_DIR="$RELEASE_DIR" write_build_record web "$PREFIX"
    report_sizes
  fi
  if [[ "${KEEP_BUILD:-1}" != "1" ]]; then
    cleanup_build "$BUILD_DIR"
  fi
  ok "Web build complete ($WEB_VARIANT)"
}

main "$@"
