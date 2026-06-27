#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# build_libmpv_linux.sh
#
# Cross-compiles mpv as libmpv.so for Linux x86_64 / aarch64. Always cross —
# even when the toolchain triple matches the host arch, we go through the
# cross-prefix flow (e.g. x86_64-linux-gnu-gcc), so a single code path covers
# every host/target combination.
#
# === OUTPUT ===
# builds/release/libmpv_linux-<arch>.so
#
# === SYSTEM ===
# Run inside the mpv-build Docker image (docker/Dockerfile). The image
# preinstalls both Linux cross-toolchains (x86_64-linux-gnu, aarch64-linux-gnu)
# plus multiarch :amd64/:arm64 audio dev libs (alsa, pulse, pipewire). X11 /
# VA-API / VDPAU are deliberately disabled — this is an audio-only build.
#
# Usage (from project root):
#   ./scripts/build_libmpv_linux.sh --arch=x86_64
#   ./scripts/build_libmpv_linux.sh --arch=aarch64
#   ARCH=x86_64 ./scripts/build_libmpv_linux.sh   # env-var form also works
#
# Options (env vars):
#   ARCH=x86_64|aarch64     (default: x86_64; --arch=… overrides)
#   MPV_VERSION=0.41.0      (default: 0.41.0)
#   JOBS=N                  (default: nproc)
#   FORCE_DOWNLOAD=1        (redownload sources even if cached)
#   KEEP_BUILD=1            (preserve all of BUILD_DIR for inspection)
#   WIPE_ALL=1              (also delete the src/ download cache at the end)
#   CC_PREFIX=ccache        (prepend a wrapper to the cross-gcc/cross-g++)
#   ENABLE_LTO_DEPS=0       (disable GCC LTO on static deps; default on)
#   VIS_HIDDEN=0            (export every internal symbol; default hides them)
#   SECTION_GC=0            (disable section-based dead-stripping; default on)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"
source "$SCRIPT_DIR/shared/_flavor.sh"
source "$SCRIPT_DIR/shared/_cross.sh"
source "$SCRIPT_DIR/build_openssl.sh"

ROOT="$(resolve_repo_root "$SCRIPT_DIR")" || exit 1

# ── Parse args ────────────────────────────────────────────────────────────────
ARCH="${ARCH:-x86_64}"
for arg in "$@"; do
  case "$arg" in
    --arch=*)   ARCH="${arg#--arch=}" ;;
    --help|-h)  grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done
case "$ARCH" in
  x86_64|aarch64) ;;
  *) die "Unsupported --arch=$ARCH (must be x86_64 or aarch64)" ;;
esac

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# ── Linux-only dependency versions (centralised ones live in _versions.sh) ────
LIBPLACEBO_VERSION="7.349.0"
LIBUNIBREAK_VERSION="6.1"
LIBSMB2_TAG="v${LIBSMB2_VERSION}"

BUILD_DIR="${BUILD_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work$(flavor_build_seg)/Linux/$ARCH}"
PREFIX="$BUILD_DIR/prefix"

# ── Cross-compile setup (toolchain, meson cross-file, cmake toolchain) ────────
export CROSS_BUILD_DIR="$BUILD_DIR"
export CROSS_PREFIX_DIR="$PREFIX"
mkdir -p "$BUILD_DIR" "$PREFIX/include" "$PREFIX/lib"
cross_setup linux "$ARCH"
# Optional ccache wrapper around the cross-gcc/cross-g++.
if [[ -n "${CC_PREFIX:-}" ]]; then
  export CC="${CC_PREFIX} ${CC}"
  export CXX="${CC_PREFIX} ${CXX}"
fi

# ── Mirror all stdout + stderr to a timestamped log file ─────────────────────
LOG_DIR="$LIBMPV_SCRIPTS_ROOT/builds/logs"
mkdir -p "$LOG_DIR"
ls -t "$LOG_DIR"/build_linux-*_*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
LOG_FILE="$LOG_DIR/build_linux-${ARCH}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee >(while IFS= read -r line; do
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
done >> "$LOG_FILE")) 2>&1
echo "════════════════════════════════════════════════════════════"
echo "Build started: $(date)"
echo "Log file:      $LOG_FILE"
echo "FFmpeg:        $FFMPEG_VERSION   mpv: $MPV_VERSION   target: linux/$ARCH"
echo "Toolchain:     $CROSS_TRIPLE ($CROSS_TOOLCHAIN_KIND)"
echo "════════════════════════════════════════════════════════════"

# ── System pkg-config search path (multiarch-scoped) ──────────────────────────
# PKG_CONFIG_LIBDIR (NOT _PATH) so nothing leaks from the host triple's .pc
# files. Include both the flat ($PREFIX/lib) and Debian-multiarch
# ($PREFIX/lib/<triple>) layouts: meson on Ubuntu defaults libdir to the
# multiarch path even when we pass --libdir=lib (some deps ignore it), so
# we keep both paths searchable.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib/${CROSS_TRIPLE}/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/share/pkgconfig:/usr/lib/${CROSS_TRIPLE}/pkgconfig:/usr/share/pkgconfig:/usr/${CROSS_TRIPLE}/lib/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

LTO_EXTRA="$(lto_deps_cflags)"
VIS_EXTRA="$(vis_deps_cflags)"
SEC_EXTRA="$(section_gc_cflags)"
UNWIND_EXTRA="$(dep_unwind_cflags)"   # C++-safe .eh_frame trim, shared by all deps
export CFLAGS="-O2 -fPIC -I$PREFIX/include $LTO_EXTRA $VIS_EXTRA $SEC_EXTRA $UNWIND_EXTRA"
export CXXFLAGS="-O2 -fPIC -I$PREFIX/include $LTO_EXTRA $VIS_EXTRA $SEC_EXTRA $UNWIND_EXTRA"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib/${CROSS_TRIPLE} -L$PREFIX/lib64 -L/usr/lib/${CROSS_TRIPLE} $LTO_EXTRA"

# Toolchain sanity: refuse to start unless every triple-prefixed binary is
# present in the running container/host.
check_toolchain() {
  local missing=()
  for t in "$CC" "$CXX" "$AR" "$RANLIB" "$NM" "$STRIP" \
           meson ninja nasm cmake pkg-config python3 git curl patchelf; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [[ ${#missing[@]} -gt 0 ]] && die "Missing toolchain binaries: ${missing[*]}"
  ok "Toolchain OK"
}

# =============================================================================
# Library builds — every dep takes the cross toolchain via env vars, plus a
# build-system-specific cross argument:
#   autotools → $CROSS_AUTOTOOLS_HOST (--host=…)
#   cmake     → -DCMAKE_TOOLCHAIN_FILE=$CROSS_CMAKE_FILE
#   meson     → --cross-file=$CROSS_MESON_FILE
# =============================================================================

build_zlib() {
  [[ -f "$PREFIX/lib/libz.a" ]] && return
  local src="$BUILD_DIR/src/zlib-$ZLIB_VERSION.tar.gz"
  download "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  # Append -Os so it wins over the global -O2 export (last -O flag wins),
  # while keeping the LTO/visibility/security flags it carries — matches the
  # bzip2 -Os below and the other platforms' size pass for the compression
  # deps. DSP/crypto deps (openssl, rubberband) keep -O2 via the unchanged
  # global export.
  CHOST="$CROSS_TRIPLE" CFLAGS="$CFLAGS -Os" ./configure --prefix="$PREFIX" --static
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "zlib ✓"
}

build_bzip2() {
  [[ -f "$PREFIX/lib/libbz2.a" ]] && return
  local src="$BUILD_DIR/src/bzip2-$BZIP2_VERSION.tar.gz"
  download "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make CC="$CC" AR="$AR" RANLIB="$RANLIB" \
       -j"$JOBS" CFLAGS="-Os -fPIC -D_FILE_OFFSET_BITS=64" libbz2.a
  install -m 644 libbz2.a "$PREFIX/lib/"
  install -m 644 bzlib.h  "$PREFIX/include/"
  popd >/dev/null
  ok "bzip2 ✓"
}

build_xz() {
  [[ -f "$PREFIX/lib/liblzma.a" ]] && return
  local src="$BUILD_DIR/src/xz-$XZ_VERSION.tar.gz"
  download "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  # xz 5.8.x's configure aborts if its `-Werror`-usability probe trips on
  # the build's non-default CFLAGS (LTO etc.). SKIP_WERROR_CHECK=yes is
  # the upstream-sanctioned escape hatch — it only affects xz's own
  # configure-time feature detection, not the built liblzma.
  # -Os appended so it wins over the global -O2 export (see build_zlib).
  CFLAGS="$CFLAGS -Os" \
  ./configure $CROSS_AUTOTOOLS_HOST --prefix="$PREFIX" --enable-static --disable-shared \
    --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
    --disable-scripts --disable-doc \
    SKIP_WERROR_CHECK=yes
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "xz ✓"
}

build_expat() {
  [[ -f "$PREFIX/lib/libexpat.a" ]] && return
  local src="$BUILD_DIR/src/expat-$LIBEXPAT_VERSION.tar.gz"
  download "https://github.com/libexpat/libexpat/releases/download/R_$(echo "$LIBEXPAT_VERSION" | tr . _)/expat-${LIBEXPAT_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  ./configure $CROSS_AUTOTOOLS_HOST --prefix="$PREFIX" --enable-static --disable-shared \
    --without-docbook --without-examples --without-tests
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "expat ✓"
}

build_libxml2() {
  [[ -f "$PREFIX/lib/libxml2.a" ]] && return
  local src="$BUILD_DIR/src/libxml2-$LIBXML2_VERSION.tar.xz"
  download "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-${LIBXML2_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  # -Os appended so it wins over the global -O2 export (see build_zlib).
  CFLAGS="$CFLAGS -Os" \
  ./configure $CROSS_AUTOTOOLS_HOST --prefix="$PREFIX" --enable-static --disable-shared \
    --without-python --without-readline --without-history \
    --without-http --without-ftp --without-html \
    --without-legacy --without-docbook --without-catalog \
    --without-schematron --without-modules --without-debug \
    --without-iconv --without-lzma --without-zlib
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "libxml2 ✓"
}

build_libpng() {
  [[ -f "$PREFIX/lib/libpng.a" ]] && return
  local src="$BUILD_DIR/src/libpng-$LIBPNG_VERSION.tar.gz"
  download "https://downloads.sourceforge.net/project/libpng/libpng16/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  ./configure $CROSS_AUTOTOOLS_HOST --prefix="$PREFIX" --enable-static --disable-shared
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "libpng ✓"
}

build_freetype() {
  [[ -f "$PREFIX/lib/libfreetype.a" && ! -f "$PREFIX/.ft_round2" ]] && return
  local src="$BUILD_DIR/src/freetype-$FREETYPE_VERSION.tar.gz"
  download "https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"

  # Round 1: without HarfBuzz
  if [[ ! -f "$PREFIX/lib/libfreetype.a" ]]; then
    local bdir="$BUILD_DIR/build/freetype-r1"; mkdir -p "$bdir"
    pushd "$bdir" >/dev/null
    cmake "$dir" -DCMAKE_TOOLCHAIN_FILE="$CROSS_CMAKE_FILE" \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_SHARED_LIBS=OFF -DFT_DISABLE_HARFBUZZ=ON \
      -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON \
      -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON \
      -DZLIB_INCLUDE_DIR="$PREFIX/include" -DZLIB_LIBRARY="$PREFIX/lib/libz.a" \
      -DPNG_PNG_INCLUDE_DIR="$PREFIX/include" -DPNG_LIBRARY="$PREFIX/lib/libpng.a" -GNinja
    ninja -j"$JOBS"; ninja install
    popd >/dev/null
    ok "freetype r1 ✓"
  fi
}

build_fribidi() {
  [[ -f "$PREFIX/lib/libfribidi.a" ]] && return
  local src="$BUILD_DIR/src/fribidi-$FRIBIDI_VERSION.tar.gz"
  download "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/fribidi"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  meson setup "$dir" --cross-file "$CROSS_MESON_FILE" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
    -Ddocs=false -Dtests=false
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "fribidi ✓"
}

build_harfbuzz() {
  [[ -f "$PREFIX/lib/libharfbuzz.a" ]] && return
  local src="$BUILD_DIR/src/harfbuzz-$HARFBUZZ_VERSION.tar.gz"
  download "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/harfbuzz"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  meson setup "$dir" --cross-file "$CROSS_MESON_FILE" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dicu=disabled \
    -Dtests=disabled -Ddocs=disabled
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "harfbuzz ✓"
}

build_freetype_round2() {
  [[ -f "$PREFIX/.ft_round2" ]] && return
  local src="$BUILD_DIR/src/freetype-$FREETYPE_VERSION.tar.gz"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/freetype-r2"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" -DCMAKE_TOOLCHAIN_FILE="$CROSS_CMAKE_FILE" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DFT_DISABLE_HARFBUZZ=OFF -DFT_REQUIRE_HARFBUZZ=ON \
    -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON \
    -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON \
    -DZLIB_INCLUDE_DIR="$PREFIX/include" -DZLIB_LIBRARY="$PREFIX/lib/libz.a" \
    -DPNG_PNG_INCLUDE_DIR="$PREFIX/include" -DPNG_LIBRARY="$PREFIX/lib/libpng.a" \
    -DHarfBuzz_DIR="$PREFIX/lib/cmake/harfbuzz" -GNinja
  ninja -j"$JOBS"; ninja install
  touch "$PREFIX/.ft_round2"
  popd >/dev/null
  ok "freetype r2 ✓"
}

build_fontconfig() {
  [[ -f "$PREFIX/lib/libfontconfig.a" ]] && return
  local src="$BUILD_DIR/src/fontconfig-$FONTCONFIG_VERSION.tar.xz"
  download "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FONTCONFIG_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/fontconfig"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  meson setup "$dir" --cross-file "$CROSS_MESON_FILE" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
    -Dtests=disabled -Dtools=disabled -Ddoc=disabled -Dcache-build=disabled
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "fontconfig ✓"
}

build_libass() {
  [[ -f "$PREFIX/lib/libass.a" ]] && return
  local src="$BUILD_DIR/src/libass-$LIBASS_VERSION.tar.gz"
  download "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  ./configure $CROSS_AUTOTOOLS_HOST --prefix="$PREFIX" --enable-static --disable-shared \
    --disable-require-system-font-provider --with-pic --enable-asm \
    --enable-unibreak
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "libass ✓"
}

build_speexdsp() {
  [[ -f "$PREFIX/lib/libspeexdsp.a" ]] && return
  # Source tarball from GitHub mirror — downloads.xiph.org is intermittently
  # unreachable. The GitHub archive has no configure shipped (it's the source
  # repo, not a release tarball), so autogen.sh has to run first.
  local src="$BUILD_DIR/src/speexdsp-SpeexDSP-$SPEEXDSP_VERSION.tar.gz"
  download "https://github.com/xiph/speexdsp/archive/refs/tags/SpeexDSP-${SPEEXDSP_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  ./autogen.sh
  ./configure $CROSS_AUTOTOOLS_HOST --prefix="$PREFIX" --enable-static --disable-shared
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "speexdsp ✓"
}

build_libunibreak() {
  [[ -f "$PREFIX/lib/libunibreak.a" ]] && return
  local src="$BUILD_DIR/src/libunibreak-$LIBUNIBREAK_VERSION.tar.gz"
  download "https://github.com/adah1972/libunibreak/releases/download/libunibreak_$(echo "$LIBUNIBREAK_VERSION" | tr . _)/libunibreak-${LIBUNIBREAK_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" > /dev/null
  ./configure $CROSS_AUTOTOOLS_HOST --prefix="$PREFIX" --enable-static --disable-shared
  make -j"$JOBS"; make install
  popd > /dev/null
  ok "libunibreak ✓"
}

build_rubberband() {
  [[ -f "$PREFIX/lib/librubberband.a" ]] && return
  local src="$BUILD_DIR/src/rubberband-$RUBBERBAND_VERSION.tar.bz2"
  download "https://breakfastquay.com/files/releases/rubberband-${RUBBERBAND_VERSION}.tar.bz2" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  # rubberband 4.0+ uses unqualified `size_t` in src/common/mathmisc.{h,cpp};
  # modern gcc/clang under -std=c++20 rejects it. Inject <stddef.h>. Idempotent.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/rubberband/patch_rubberband_size_t.py" "$dir"
  local bdir="$BUILD_DIR/build/rubberband"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  meson setup "$dir" --cross-file "$CROSS_MESON_FILE" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
    -Dfft=builtin -Dresampler=speex -Dladspa=disabled -Dvamp=disabled -Djni=disabled
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "rubberband ✓"
}

build_libplacebo() {
  [[ -f "$PREFIX/lib/libplacebo.a" ]] && return
  local gitdir="$BUILD_DIR/src/libplacebo-git"
  download_git "https://code.videolan.org/videolan/libplacebo.git" "$gitdir" "v$LIBPLACEBO_VERSION"
  git -C "$gitdir" submodule update --init --recursive
  apply_libplacebo_patches "$gitdir"
  local bdir="$BUILD_DIR/build/libplacebo"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  meson setup "$gitdir" --cross-file "$CROSS_MESON_FILE" \
    --prefix="$PREFIX" --buildtype=release --default-library=static \
    -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled \
    -Dopengl=disabled -Dd3d11=disabled -Ddemos=false -Dtests=false
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "libplacebo ✓"
}

# OpenSSL Configure honours the exported CC/AR/RANLIB (cross-toolchain
# set by cross_setup) + CFLAGS/LDFLAGS. It needs an explicit Configure
# target string per arch.
build_openssl_linux() {
  local openssl_target
  case "$ARCH" in
    aarch64) openssl_target="linux-aarch64" ;;
    x86_64)  openssl_target="linux-x86_64"  ;;
    *) die "no OpenSSL target mapping for linux arch: $ARCH" ;;
  esac
  build_openssl "$PREFIX" "$BUILD_DIR" "$openssl_target"
}

build_libsmb2() {
  [[ -f "$PREFIX/lib/libsmb2.a" ]] && return
  log "Building libsmb2 $LIBSMB2_TAG..."
  local dir="$BUILD_DIR/src/libsmb2"
  download_git "https://github.com/sahlberg/libsmb2.git" "$dir" "$LIBSMB2_TAG"

  local bdir="$BUILD_DIR/build/libsmb2"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" -DCMAKE_TOOLCHAIN_FILE="$CROSS_CMAKE_FILE" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -GNinja
  ninja -j"$JOBS"
  ninja install
  apply_libsmb2_post_install_fixes "$PREFIX" "linux"
  popd >/dev/null
  ok "libsmb2 ✓"
}

build_ffmpeg() {
  [[ -f "$PREFIX/lib/libavcodec.a" ]] && return
  log "Building ffmpeg $FFMPEG_VERSION..."
  local src="$BUILD_DIR/src/ffmpeg-$FFMPEG_VERSION.tar.gz"
  download "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  apply_ffmpeg_patches "$dir"

  local bdir="$BUILD_DIR/build/ffmpeg"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  "$dir/configure" \
    --prefix="$PREFIX" \
    $(ffmpeg_common_args) \
    $FFMPEG_CROSS_ARGS \
    --disable-libxcb \
    --disable-libxcb-shm \
    --disable-libxcb-xfixes \
    --disable-libxcb-shape \
    --extra-cflags="$(eh_frame_cflags)" \
    --extra-libs="-lm -lpthread -ldl"
  verify_ffmpeg_config "$bdir" "linux"
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "ffmpeg ✓"
}

build_mpv() {
  [[ -f "$PREFIX/lib/libmpv.so" ]] && return
  log "Building mpv $MPV_VERSION..."
  local src="$BUILD_DIR/src/mpv-$MPV_VERSION.tar.gz"
  download "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/mpv"; mkdir -p "$bdir"
  apply_mpv_patches_common "$dir"

  # ELF dynsym hygiene + section dead-strip + transitive-static linkage:
  #   --gc-sections           drop unreferenced sections (audio-only build)
  #   --exclude-libs=ALL      hide static-archive symbols from .dynsym
  #   --version-script        export only mpv_*
  #   --no-undefined          fail link if any symbol unresolved (catches
  #                           any future transitive-dep leak instantly)
  #   -lssl/-lcrypto, -lxml2, -lbz2, -llzma —
  #     ffmpeg's libavformat.a / libavcodec.a contain references to these
  #     (TLS via openssl, DASH/IMF demuxer via libxml2, matroska/avi
  #     compression via bz2 + lzma). They live in libavformat.pc's
  #     Libs.private, but meson's `dependency()` calls pkg-config WITHOUT
  #     --static by default, so Libs.private is never emitted. Without
  #     these explicit -l flags the symbols become UND in libmpv.so and
  #     fail at runtime on systems without those .so installed (e.g. WSL).
  local link_extra=()
  if [[ "${VIS_HIDDEN:-1}" != "0" || "${SECTION_GC:-1}" != "0" ]]; then
    # Shared ELF size flags (-Bsymbolic + RELR relative-reloc packing) come from
    # mpv_elf_size_ldflags() in _flavor.sh so linux + android stay in sync.
    # NOTE: x86_64 BFD ld packs RELR; the aarch64 BFD/gold in binutils 2.42 do
    # NOT (they accept -z pack-relative-relocs but emit no .relr.dyn), so
    # linux-aarch64 keeps ~0.95M of unpacked .rela.dyn. Fixable with mold once
    # the Docker image's foreign-arch multiarch apt step is repaired (mold links
    # gcc-LTO + packs aarch64 RELR); deferred to avoid an image-rebuild regression.
    local ld_args="-Wl,--gc-sections,--exclude-libs=ALL,--no-undefined$(mpv_elf_size_ldflags)"
    [[ "${VIS_HIDDEN:-1}" != "0" ]] && \
      ld_args="$ld_args,--version-script=${SCRIPT_DIR}/shared/mpv.ver"
    local extra_libs="-lssl -lcrypto -lxml2 -lbz2 -llzma"
    link_extra+=("-Dc_link_args=$ld_args $extra_libs")
    link_extra+=("-Dcpp_link_args=$ld_args $extra_libs")
  fi

  pushd "$bdir" >/dev/null
  meson setup "$dir" --cross-file "$CROSS_MESON_FILE" \
    --prefix="$PREFIX" \
    --buildtype=release \
    --default-library=shared \
    $(mpv_common_args) \
    -Dalsa=enabled \
    -Dpulse=enabled \
    -Dpipewire=enabled \
    -Dc_args="$(eh_frame_cflags)" \
    "${link_extra[@]}"
  verify_mpv_config "$bdir" "linux"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "mpv ✓"
}

# =============================================================================
# Finalize: stage the .so, strip it, audit external NEEDED entries.
# =============================================================================

finalize() {
  local release_dir="$LIBMPV_SCRIPTS_ROOT/builds/release$(flavor_build_seg)"
  mkdir -p "$release_dir"

  log "Locating libmpv.so..."
  local lib_paths=("$PREFIX/lib" "$PREFIX/lib64" "$PREFIX/lib/$CROSS_TRIPLE")
  local src=""
  for lp in "${lib_paths[@]}"; do
    [[ -d "$lp" ]] || continue
    local found
    found="$(ls "$lp"/libmpv.so.* 2>/dev/null | sort -V | tail -1 || true)"
    [[ -z "$found" ]] && found="$(ls "$lp"/libmpv.so 2>/dev/null || true)"
    if [[ -n "$found" && -f "$found" ]]; then
      src="$found"; break
    fi
  done
  [[ -z "$src" ]] && fail "libmpv.so not found in any expected prefix/lib path."

  log "Found libmpv: $src"
  local out="$release_dir/libmpv_linux-${ARCH}.so"
  if [[ -L "$src" ]]; then
    cp "$(readlink -f "$src")" "$out"
  else
    cp "$src" "$out"
  fi

  log "Stripping symbols..."
  "$STRIP" --strip-unneeded "$out"

  # Dynsym hygiene check. readelf -W --dyn-syms columns:
  #   Num Value Size Type Bind Vis Ndx Name
  # ($1) ($2)  ($3)  ($4)  ($5) ($6)($7)($8)
  # Defined global functions = Bind=GLOBAL, Type=FUNC, Ndx!=UND.
  local total_syms mpv_syms
  total_syms="$("$READELF" -W --dyn-syms "$out" 2>/dev/null | awk '$5=="GLOBAL" && $4=="FUNC" && $7!="UND" {n++} END{print n+0}')"
  mpv_syms="$("$READELF"   -W --dyn-syms "$out" 2>/dev/null | awk '$5=="GLOBAL" && $4=="FUNC" && $7!="UND" && $8 ~ /^mpv_/ {n++} END{print n+0}')"
  ok "Symbols: $total_syms total, $mpv_syms mpv_*"
  if [[ "${VIS_HIDDEN:-1}" != "0" && "$total_syms" -gt 200 ]]; then
    warn "Expected ~60 symbols with VIS_HIDDEN=1 but got $total_syms"
  fi

  ok "Output: $out"

  log "Checking external NEEDED entries..."
  local external
  external="$("$READELF" -d "$out" 2>/dev/null \
    | awk '/NEEDED/ {gsub(/[\[\]]/,"",$NF); print $NF}' \
    | grep -Ev '^(libc|libm|libdl|libpthread|librt|libresolv|libgcc_s|ld-linux)' \
    || true)"
  if [[ -n "$external" ]]; then
    warn "External runtime dependencies (expected on Linux):"
    echo "$external"
  else
    ok "Minimal dependencies (glibc only)"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  build_libmpv_linux.sh — mpv $MPV_VERSION for linux/$ARCH        ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo ""

  check_toolchain
  mkdir -p "$BUILD_DIR/src" "$BUILD_DIR/build" "$PREFIX/include" "$PREFIX/lib"

  build_zlib
  build_bzip2
  build_xz

  # Font stack — built ONLY when libass is kept (strip_libass disabled in
  # Settings ▸ Patches). By default libass is stripped from mpv, so the whole
  # chain (expat, libpng, freetype ×2, fribidi, harfbuzz, fontconfig, unibreak,
  # libass) is dead weight and skipped. mpv re-detects libass via pkg-config
  # when these are present; see swscale_stripped()/patch_on in _flavor.sh.
  if ! libass_stripped; then
    build_expat
    build_libpng
    build_freetype
    build_fribidi
    build_harfbuzz
    build_freetype_round2
    build_fontconfig
    build_libunibreak
    build_libass
  fi

  build_speexdsp
  build_rubberband

  build_libplacebo

  build_openssl_linux
  build_libsmb2
  build_libxml2
  build_ffmpeg

  build_mpv

  finalize
  cleanup_build "$BUILD_DIR"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  ✓ Linux build complete!                                         ║"
  echo "║  Output: builds/release/libmpv_linux-${ARCH}.so                  ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
}

main "$@"
