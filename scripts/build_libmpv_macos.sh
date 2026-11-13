#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# build_libmpv_macos.sh
#
# Compiles mpv 0.41.0 as a Universal dynamic library for macOS, wrapped in
# a single-slice xcframework so SwiftPM consumers can pick it up via
# `.binaryTarget` (same shape as iOS).
#
# === OUTPUT FORMATS AND LOCATIONS ===
# Final artifact: builds/release/libmpv_macos.xcframework.zip
#                 (contains libmpv.xcframework with one slice
#                  macos-arm64_x86_64/libmpv.framework wrapping a Universal
#                  dylib, install_name = @rpath/libmpv.framework/libmpv).
# Per-arch dylibs are INTERMEDIATE — they stay in the build tree and are
# lipo'd into the xcframework. builds/release/ holds only the xcframework.zip
# (same as the iOS build — no loose per-slice dylibs left behind).
#
# === SYSTEM & HARDWARE SPECS ===
# Target OS:   macOS (Deployment target 12.0+)
# Target Arch: arm64 + x86_64 (Universal). ARCHS="arm64" for arm-only;
#              ARCHS="x86_64" for Intel-only. Default builds both.
# Compiler:    Xcode Toolchain (Apple Clang) — cross-compiles both arches
#              from either host (no Rosetta needed for the toolchain).
#
# Usage:
#   chmod +x scripts/build_libmpv_macos.sh
#   ./scripts/build_libmpv_macos.sh
#
# Options (environment variables):
#   MPV_VERSION=0.41.0            (default: 0.41.0)
#   ARCHS="arm64 x86_64"          (target architectures, space-separated)
#   JOBS=N                        (default: number of cores)
#   FORCE_DOWNLOAD=1              (redownload sources even if cached)
#   KEEP_BUILD=1                  (preserve all of BUILD_DIR for inspection)
#   WIPE_ALL=1                    (also delete the src/ download cache at the end)
#   CC_PREFIX=ccache              (prepend a wrapper to clang/clang++)
#   ENABLE_LTO_DEPS=0             (disable ThinLTO on static deps; default on)
#   VIS_HIDDEN=0                  (export every internal symbol; default hides them)
#
# Requirements (installed by this script if missing via Homebrew):
#   meson, ninja, nasm, cmake, pkg-config, python3, autoconf, automake, libtool, git
# =============================================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared across all build_libmpv_<platform>.sh scripts
source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"
source "$SCRIPT_DIR/shared/_audio_only.sh"
source "$SCRIPT_DIR/shared/_cross.sh"
source "$SCRIPT_DIR/shared/_apple.sh"
source "$SCRIPT_DIR/build_openssl.sh"

# Target architectures. Apple's clang on macOS cross-compiles to either
# arch from either host (no Rosetta required for the toolchain itself).
ARCHS="${ARCHS:-arm64 x86_64}"
for arch in $ARCHS; do
  case "$arch" in
    arm64|x86_64) ;;
    *) fail "Unsupported macOS arch: $arch (allowed: arm64, x86_64)" ;;
  esac
done
# Per-iteration in main()'s loop:
ARCH=""

MACOS_MIN="12.0"

HOST_ARCH="$(uname -m)"

# macOS-only dependency versions (centralised ones live in _versions.sh)
# shellcheck disable=SC2034  # read by the shared builds (_cross.sh, _apple.sh)
LIBPLACEBO_VERSION="7.349.0"
LIBSMB2_TAG="v${LIBSMB2_VERSION}"

# ── Build directory ──────────────────────────────────────────────────────────
# BUILD_ROOT is the shared base; BUILD_DIR is set per-arch inside main()'s
# loop to BUILD_ROOT/<arch>. Giving each arch a fully separate tree (src
# extract + build dirs + prefix) is what keeps a cross-compiled x86_64
# slice from reusing arm64 object files — the dep build dirs and the
# in-source autoconf builds are not arch-tagged individually.
BUILD_ROOT="${BUILD_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work/macOS}"
# BUILD_DIR + PREFIX are set per-arch inside main()'s loop.
BUILD_DIR=""
PREFIX=""

# Staging dir for the assembled xcframework — in the build tree, never in the
# consumer repo. assemble_xcframework builds libmpv.xcframework here and zips
# it into builds/release/, where the manifest and the release pick it up.
# The build never writes outside libmpv-scripts.
OUTPUT_DIR="$BUILD_ROOT/xcframework-stage"

apple_start_log macos

mkdir -p "$OUTPUT_DIR"

# Logging helpers (log / ok / warn / err / die / fail) come from _helpers.sh

# Source download / git clone / extract helpers come from _helpers.sh

# ── CFLAGS/LDFLAGS base ──────────────────────────────────────────────────────
# Includes the optional ENABLE_LTO_DEPS extra and the (default-on) hidden
# visibility flags, so every per-dep build that overrides CFLAGS via
# `arch_flags` automatically picks both up.
arch_flags() {
  local macos_min="12.0"
  local sdk
  sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo "")"
  local sdk_flags=""
  [[ -n "$sdk" ]] && sdk_flags="-isysroot $sdk"

  echo "-arch $ARCH -mmacosx-version-min=$macos_min $sdk_flags $(lto_deps_cflags) $(vis_deps_cflags)"
}

build_for_arch() {
  mkdir -p "$PREFIX"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig"

  local lto_extra
  lto_extra="$(lto_deps_cflags)"
  # C++-safe .eh_frame trim for the shared dep CFLAGS/CXXFLAGS (like $lto_extra).
  # dep_unwind_cflags() keeps C++ exception unwinding intact, so it is safe in
  # both CFLAGS and CXXFLAGS here. It does NOT leak into the meson objc_args
  # (those come from write_meson_native, where ObjC coreaudio/avfoundation keep
  # their unwind tables), nor into ffmpeg/mpv's own C-only knobs (those use the
  # stronger eh_frame_cflags via --extra-cflags / -Dc_args).
  local unwind_extra
  unwind_extra="$(dep_unwind_cflags)"
  local cflags
  cflags="$(arch_flags) -O2 $lto_extra $unwind_extra"
  local ldflags
  ldflags="$(arch_flags) $lto_extra"

  export CFLAGS="$cflags"
  export CXXFLAGS="$cflags"
  export LDFLAGS="$ldflags"
  export CC="$CC_BIN"
  export CXX="$CXX_BIN"

  # What the shared dep builds (_cross.sh, _apple.sh) take: this arch's tree
  # and prefix, and its autoconf host.
  export CROSS_BUILD_DIR="$BUILD_DIR"
  export CROSS_PREFIX_DIR="$PREFIX"
  CROSS_AUTOTOOLS_HOST="--host=$(apple_host "$ARCH")"
  export CROSS_AUTOTOOLS_HOST
  # shellcheck disable=SC2034  # read by the shared builds
  CROSS_BUILD_SUFFIX="" CROSS_LABEL="$ARCH"

  local af; af="$(arch_flags)"
  CFLAGS="$af -Oz" apple_build_zlib
  AR=ar RANLIB=ranlib CFLAGS="$af -Oz -D_FILE_OFFSET_BITS=64" cross_build_bzip2
  CFLAGS="$af -Oz" cross_build_xz

  # Font stack — built ONLY when libass is kept (strip_libass disabled in
  # Settings ▸ Patches). By default patch_strip_libass.py removes libass from
  # mpv entirely, so the libass/freetype/harfbuzz/fontconfig/fribidi/expat/libpng
  # chain is unreferenced and skipped (libpng + expat are font-only on macOS —
  # only freetype consumes libpng via -DPNG_ROOT; nothing else links expat). When
  # the user restores libass, mpv re-detects it via pkg-config.
  if ! libass_stripped; then
    CFLAGS="$af -O2" cross_build_expat
    build_libpng         "$PREFIX"
    build_freetype       "$PREFIX"
    build_fribidi        "$PREFIX"
    build_harfbuzz       "$PREFIX"
    build_freetype_round2 "$PREFIX"
    build_fontconfig     "$PREFIX"
    build_libass         "$PREFIX"
  fi

  # libplacebo: headers required by mpv csputils.h unconditionally.
  # Built minimal — no vulkan/shaderc/d3d11/opengl.
  apple_build_libplacebo $(write_meson_native "$PREFIX")

  CFLAGS="$af -O2" apple_build_speexdsp
  # librubberband (GPL-2.0+) only in the GPL build (gpl_build in _audio_only.sh).
  if gpl_build; then
    apple_build_rubberband $(write_meson_native "$PREFIX")
  fi
  # OpenSSL Configure honours the exported CFLAGS/LDFLAGS (which carry
  # -arch + -isysroot via arch_flags); the darwin64-<arch>-cc target
  # handles cross-compiling x86_64 on an arm64 host. OpenSSL's canonical
  # targets keep the arch verbatim — darwin64-arm64-cc / darwin64-x86_64-cc.
  local openssl_target="darwin64-${ARCH}-cc"
  build_openssl    "$PREFIX" "$BUILD_DIR" "$openssl_target"
  build_libsmb2    "$PREFIX"
  CFLAGS="$af -Oz" LDFLAGS="$af" cross_build_libxml2

  # libarchive, mujs and luajit are not built — mpv is configured with
  # -Dlibarchive=disabled / -Dlua=disabled / -Djavascript=disabled which
  # gates their use at the preprocessor level (no source-side inclusion).

  build_ffmpeg "$PREFIX"
  build_mpv    "$PREFIX"
}

# =============================================================================
# Single library builds
# =============================================================================

build_libpng() {
  local prefix="$1"
  [[ -f "$prefix/lib/libpng.a" ]] && { ok "libpng already compiled"; return; }
  log "Build libpng $LIBPNG_VERSION..."
  local src="$BUILD_DIR/src/libpng-$LIBPNG_VERSION.tar.gz"
  download "https://downloads.sourceforge.net/project/libpng/libpng16/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  CFLAGS="$(arch_flags) -O2" \
  LDFLAGS="$(arch_flags)" \
  ./configure --prefix="$prefix" --host="$(apple_host "$ARCH")" \
    --enable-static --disable-shared \
    --with-zlib-prefix="$prefix"
  make -j"$JOBS"
  make install
  popd >/dev/null
  ok "libpng ✓"
}

build_freetype() {
  local prefix="$1"
  [[ -f "$prefix/lib/libfreetype.a" ]] && { ok "freetype already compiled"; return; }
  log "Build freetype $FREETYPE_VERSION [round 1 — without harfbuzz]..."
  local src="$BUILD_DIR/src/freetype-$FREETYPE_VERSION.tar.gz"
  download "https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/freetype-r1"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DFT_DISABLE_HARFBUZZ=ON \
    -DFT_DISABLE_BROTLI=ON \
    -DFT_DISABLE_BZIP2=OFF \
    -DFT_REQUIRE_ZLIB=ON \
    -DFT_REQUIRE_PNG=ON \
    -DZLIB_ROOT="$prefix" \
    -DPNG_ROOT="$prefix" \
    -GNinja
  ninja -j"$JOBS"
  ninja install
  popd >/dev/null
  ok "freetype round1 ✓"
}

build_fribidi() {
  local prefix="$1"
  [[ -f "$prefix/lib/libfribidi.a" ]] && { ok "fribidi already compiled"; return; }
  log "Build fribidi $FRIBIDI_VERSION..."
  local src="$BUILD_DIR/src/fribidi-$FRIBIDI_VERSION.tar.gz"
  download "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/fribidi"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  meson setup "$dir" \
    --prefix="$prefix" \
    --buildtype=release \
    --default-library=static \
    -Ddocs=false \
    -Dtests=false \
    $(write_meson_native "$prefix")
  ninja -j"$JOBS"
  ninja install
  popd >/dev/null
  ok "fribidi ✓"
}

build_harfbuzz() {
  local prefix="$1"
  [[ -f "$prefix/lib/libharfbuzz.a" ]] && { ok "harfbuzz already compiled"; return; }
  log "Build harfbuzz $HARFBUZZ_VERSION..."
  local src="$BUILD_DIR/src/harfbuzz-$HARFBUZZ_VERSION.tar.gz"
  download "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/harfbuzz"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  meson setup "$dir" \
    --prefix="$prefix" \
    --buildtype=release \
    --default-library=static \
    -Dfreetype=enabled \
    -Dglib=disabled \
    -Dgobject=disabled \
    -Dicu=disabled \
    -Dtests=disabled \
    -Ddocs=disabled \
    $(write_meson_native "$prefix")
  ninja -j"$JOBS"
  ninja install
  popd >/dev/null
  ok "harfbuzz ✓"
}

build_freetype_round2() {
  local prefix="$1"
  local sentinel="$prefix/lib/freetype_harfbuzz_done"
  [[ -f "$sentinel" ]] && { ok "freetype round2 already compiled"; return; }
  log "Build freetype $FREETYPE_VERSION [round 2 — with harfbuzz]..."
  local src="$BUILD_DIR/src/freetype-$FREETYPE_VERSION.tar.gz"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  rm -rf "$BUILD_DIR/build/freetype-r1"
  local bdir="$BUILD_DIR/build/freetype-r2"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DFT_DISABLE_HARFBUZZ=OFF \
    -DFT_DISABLE_BROTLI=ON \
    -DFT_REQUIRE_HARFBUZZ=ON \
    -DFT_REQUIRE_ZLIB=ON \
    -DFT_REQUIRE_PNG=ON \
    -DZLIB_ROOT="$prefix" \
    -DPNG_ROOT="$prefix" \
    -DHarfBuzz_DIR="$prefix/lib/cmake/harfbuzz" \
    -GNinja
  ninja -j"$JOBS"
  ninja install
  touch "$sentinel"
  popd >/dev/null
  ok "freetype round2 ✓"
}

build_fontconfig() {
  local prefix="$1"
  [[ -f "$prefix/lib/libfontconfig.a" ]] && { ok "fontconfig already compiled"; return; }
  log "Build fontconfig $FONTCONFIG_VERSION..."
  local src="$BUILD_DIR/src/fontconfig-$FONTCONFIG_VERSION.tar.xz"
  download "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FONTCONFIG_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/fontconfig"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  meson setup "$dir" \
    --prefix="$prefix" \
    --buildtype=release \
    --default-library=static \
    -Dtests=disabled \
    -Dtools=disabled \
    -Ddoc=disabled \
    $(write_meson_native "$prefix")
  ninja -j"$JOBS"
  ninja install
  popd >/dev/null
  ok "fontconfig ✓"
}

build_libass() {
  local prefix="$1"
  [[ -f "$prefix/lib/libass.a" ]] && { ok "libass already compiled"; return; }
  log "Build libass $LIBASS_VERSION..."
  local src="$BUILD_DIR/src/libass-$LIBASS_VERSION.tar.gz"
  download "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  CFLAGS="$(arch_flags) -O2" \
  LDFLAGS="$(arch_flags) -L$prefix/lib" \
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  ./configure --prefix="$prefix" --host="$(apple_host "$ARCH")" \
    --enable-static --disable-shared \
    --disable-require-system-font-provider \
    --with-pic                            \
    --enable-asm
  make -j"$JOBS"
  make install
  popd >/dev/null
  ok "libass ✓"
}

build_libsmb2() {
  local prefix="$1"
  [[ -f "$prefix/lib/libsmb2.a" ]] && { ok "libsmb2 already built"; return; }
  log "Build libsmb2 $LIBSMB2_TAG..."
  local dir="$BUILD_DIR/src/libsmb2"
  download_git "https://github.com/sahlberg/libsmb2.git" "$dir" "$LIBSMB2_TAG"
  apply_libsmb2_apple_patch "$dir"

  local bdir="$BUILD_DIR/build/libsmb2"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$(arch_flags) -O2" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_LIBDIR=lib
  make -j"$JOBS"
  make install
  apply_libsmb2_post_install_fixes "$prefix" "macos"
  popd >/dev/null
  ok "libsmb2 ✓"
}

build_ffmpeg() {
  local prefix="$1"
  local sdk
  sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo "")"
  # eh_frame_cflags() is the stronger C-only unwind-table trim — safe for ffmpeg
  # (pure C, no exceptions). Goes via --extra-cflags only, never the shared deps.
  local extra_cflags="-arch $ARCH -mmacosx-version-min=12.0 -I$prefix/include -O2 $(eh_frame_cflags)"
  local extra_ldflags="-arch $ARCH -mmacosx-version-min=12.0 -L$prefix/lib"
  [[ -n "$sdk" ]] && { extra_cflags+=" -isysroot $sdk"; extra_ldflags+=" -isysroot $sdk"; }

  # ── ffmpeg: smart audio-only build ─────────────────────────────────────────
  # See scripts/shared/_audio_only.sh for AUDIO_DECODERS / AUDIO_PARSERS /
  # AUDIO_FILTERS / AUDIO_BSFS.
  # Strategy: keep all demuxers and a protocol whitelist; strip video
  # decoders, encoders, every muxer but spdif, and avdevice. A curated
  # audio-filter whitelist stays enabled (AUDIO_FILTERS, ~86 entries, ~50 KB total)
  # so `setCustomAudioFilters` has full coverage. swscale stays enabled because
  # mpv requires it as a mandatory dependency (cover-art pipeline).
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  cross_build_ffmpeg macos \
    --enable-cross-compile \
    --arch="$ARCH" \
    --target-os=darwin \
    --cc="$CC_BIN" \
    --cxx="$CXX_BIN" \
    --extra-cflags="$extra_cflags" \
    --extra-ldflags="$extra_ldflags" \
    --enable-optimizations \
    --disable-libpulse \
    --disable-videotoolbox \
    --enable-audiotoolbox
}

build_mpv() {
  local prefix="$1"
  local out_dylib="$prefix/lib/libmpv.dylib"
  [[ -f "$out_dylib" ]] && { ok "mpv already compiled"; return; }
  log "Building mpv $MPV_VERSION ($ARCH)..."
  local src="$BUILD_DIR/src/mpv-$MPV_VERSION.tar.gz"
  download "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz" "$src"
  # Per-arch source tree. patch_export_filter writes the arch's prefix path
  # into meson.build; if we shared the source across arches the second
  # build_mpv invocation would be no-op'd by the patch's MARKER guard and
  # link against the previous arch's prefix archives (wrong arch).
  # Re-extracted on every build: src/ survives cleanup_build, and the mpv
  # patches assume an unpatched tree.
  local dir="$BUILD_DIR/src/mpv-$ARCH"
  rm -rf "$dir"; mkdir -p "$dir"
  tar -xzf "$src" --strip-components=1 -C "$dir"
  patch_record_start mpv "$prefix"

  # macOS-only patches: required before the shared ones (touch meson.build).
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/apple/patch_utils_mac.py" "$dir/meson.build"
  apple_mpv_export_filter "$dir" "$prefix"
  apply_mpv_patches_common "$dir"

  local bdir="$BUILD_DIR/build/mpv-$ARCH"
  mkdir -p "$bdir"

  # mpv-only C flags, folded INTO the machine file's c_args (see
  # apple_meson_options): a command-line `-Dc_args` would drop `-arch ${ARCH}`
  # from the compile, breaking the cross-compiled x86_64 slice into a stub.
  local ehf_arg; ehf_arg="$(apple_mpv_c_args)"

  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  meson setup "$dir" \
    --prefix="$prefix" \
    --buildtype=release \
    --default-library=shared \
    $(write_meson_native "$prefix" "$ehf_arg") \
    $(mpv_common_args) \
    -Dswift-build=disabled \
    -Davfoundation=enabled \
    -Dcoreaudio=enabled
  verify_mpv_config "$bdir" "macos"
  ninja -j"$JOBS"
  ninja install
  popd >/dev/null

  ok "mpv ($ARCH) ✓"
}

# ── Helper: generate the meson machine file for the current target arch ─────
# Reused for every meson-based dep + mpv. When ARCH matches the build host a
# native-file is enough; when it differs (x86_64 slice on an Apple-Silicon
# host) meson needs a cross-file with a [host_machine] section, otherwise it
# selects the build machine's arch for asm + config. `needs_exe_wrapper =
# false` lets meson run host-arch test binaries directly (Rosetta covers
# x86_64-on-arm64).
write_meson_native() {
  local prefix="$1"
  # Optional meson-array fragment of EXTRA C-only compile flags (e.g. the mpv
  # eh_frame trim), folded straight into the cross-file `c_args` array. It must
  # go here, NOT via a command-line `-Dc_args=…`, because meson REPLACES the
  # cross-file `c_args` with a command-line `-Dc_args` (it does not append) —
  # which silently drops `-arch ${ARCH}` from the COMPILE step while the link
  # keeps it (c_link_args), so a cross-compiled x86_64 slice gets arm64 objects
  # the x86_64 link then ignores, producing a ~40 KB stub dylib. Empty for deps.
  local extra_c_args="${2:-}"
  local file="$BUILD_DIR/meson_machine_${ARCH}.ini"
  local sdk pkgcfg
  sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo "")"
  pkgcfg="$(command -v pkg-config)"

  {
    apple_meson_binaries "$pkgcfg"
    echo
    apple_meson_options "$ARCH" "-mmacosx-version-min=${MACOS_MIN}" "$sdk" "$extra_c_args"
    echo
    echo "[properties]"
    echo "pkg_config_libdir = ['${prefix}/lib/pkgconfig', '${prefix}/lib64/pkgconfig']"
  } > "$file"

  if [[ "$ARCH" == "$HOST_ARCH" ]]; then
    echo "--native-file=${file}"
  else
    local cpu_family="aarch64"
    [[ "$ARCH" == "x86_64" ]] && cpu_family="x86_64"
    cat >> "$file" << EOF
needs_exe_wrapper = false

[host_machine]
system = 'darwin'
cpu_family = '${cpu_family}'
cpu = '${ARCH}'
endian = 'little'
EOF
    echo "--cross-file=${file}"
  fi
}

# ── Per-arch finalization: copy + install_name (intermediate output) ────────
# Lands in the build tree, NOT builds/release/ — assemble_xcframework lipos
# the per-arch dylibs into the Universal binary and only the xcframework.zip
# is a release artifact (mirrors the iOS build).
finalize_arch() {
  local src="$PREFIX/lib/libmpv.dylib"
  mkdir -p "$BUILD_ROOT"
  local out="$BUILD_ROOT/libmpv_macos-$ARCH.dylib"
  [[ ! -f "$src" ]] && fail "libmpv.dylib not found: $src"
  rm -f "$out"
  # `cp -L` follows the libmpv.dylib -> libmpv.<soversion>.dylib symlink
  # produced by meson so we get a real file we can rewrite in place.
  cp -L "$src" "$out"
  chmod +w "$out"
  install_name_tool -id "@rpath/libmpv.framework/libmpv" "$out" 2>/dev/null
  apple_sign "$out"
  # Stub-slice guard: a cross-compile that lost its `-arch` flag compiles the
  # wrong architecture's objects, which ld64 then silently ignores, yielding a
  # tiny dylib with no mpv_* exports. Fail HERE, per-arch, rather than lipo a
  # stub into the Universal binary and ship a broken slice (a 40 KB x86_64 stub
  # shipped once because every downstream check inspected the fat binary in
  # aggregate and never saw a single broken slice).
  local _sz _mpvn
  _sz=$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out" 2>/dev/null || echo 0)
  _mpvn=$(nm -gU "$out" 2>/dev/null | grep -c ' T _mpv_' || true)
  if (( _sz < 1000000 || _mpvn < 50 )); then
    fail "Per-arch dylib looks like a STUB: $out ($_sz bytes, $_mpvn mpv_* exports)." \
         "A real libmpv is ~8 MB with 54 mpv_* exports — this almost always means" \
         "the $ARCH compile lost its -arch flag and ld ignored the wrong-arch objects."
  fi
  ok "Per-arch dylib: $out"
}

# Sanity-check a single dylib: external deps, symbol hygiene, size.
verify_dylib() {
  local out="$1"
  log "Verifying $(basename "$out")..."
  local external
  external="$(otool -L "$out" | grep '/opt/homebrew\|/usr/local' || true)"
  if [[ -n "$external" ]]; then
    warn "Warning: found Homebrew dependencies in the final binary:"
    echo "$external"
  else
    ok "No Homebrew dependencies — the dylib is fully self-sufficient"
  fi

  # Dynsym hygiene: the exports list is `_mpv_*`, so with VIS_HIDDEN applied we
  # expect ~60 exported symbols — essentially just the public mpv_* C API.
  # Without it, expect ~8000.
  local total_syms mpv_syms
  total_syms="$(nm -gU "$out" 2>/dev/null | grep -c ' T ' || echo 0)"
  mpv_syms="$(nm -gU "$out" 2>/dev/null | grep -c ' T _mpv_' || echo 0)"
  ok "Symbols: $total_syms total, $mpv_syms mpv_*"
  if [[ "${VIS_HIDDEN:-1}" != "0" && "$total_syms" -gt 200 ]]; then
    die "Export-filter regression: expected ~60 exported symbols with" \
        "VIS_HIDDEN=1 but got $total_syms. The dylib is leaking internal /" \
        "ffmpeg / libass symbols that clash with other Flutter plugins —" \
        "verify patch_export_filter.py applied and the exports list bound" \
        "into the final ld64 link."
  fi
  ok "Size: $(du -sh "$out" | cut -f1)  →  $out"
}

# ── Assemble the macOS xcframework ───────────────────────────────────────────
# Lipo per-arch dylibs into a single Universal binary, wrap it in a
# libmpv.framework with the macOS versioned-bundle layout (Versions/A/ + a
# Current symlink — NOT the iOS shallow layout), then assemble an xcframework
# via `xcodebuild -create-xcframework`. Output:
#   builds/release/libmpv_macos.xcframework.zip
# The zip holds a single xcframework at its root, the layout a SwiftPM
# .binaryTarget(url:checksum:) expects.
assemble_xcframework() {
  log "Assembling macOS xcframework..."
  local release_dir="$LIBMPV_SCRIPTS_ROOT/builds/release"
  mkdir -p "$release_dir"
  local xcfw="$OUTPUT_DIR/libmpv.xcframework"
  rm -rf "$xcfw"
  mkdir -p "$OUTPUT_DIR"

  # 1. Combine per-arch dylibs into a Universal binary.
  local universal_dylib="$BUILD_ROOT/libmpv_universal.dylib"
  local lipo_args=()
  for arch in $ARCHS; do
    lipo_args+=("$BUILD_ROOT/libmpv_macos-$arch.dylib")
  done
  if [[ ${#lipo_args[@]} -eq 1 ]]; then
    cp "${lipo_args[0]}" "$universal_dylib"
  else
    lipo -create "${lipo_args[@]}" -output "$universal_dylib"
  fi
  # Strip local symbols + debug from the shipped dylib (~1.2M). -x removes only
  # local symbols; the exported mpv_* API and the @rpath install_name survive.
  # (meson does not strip the dylib; Linux/Android already strip their output.)
  strip -x "$universal_dylib"

  # 2. Build libmpv.framework wrapper — macOS versioned-bundle layout.
  # macOS frameworks are NOT shallow bundles (iOS is): the payload lives under
  # Versions/A/, with a `Current` symlink and top-level symlinks pointing into
  # it. xcodebuild -create-xcframework and Xcode's framework-embed step both
  # reject a flat macOS framework ("expected Versions/Current/Resources/...").
  local fw="$BUILD_ROOT/libmpv.framework_macos/libmpv.framework"
  rm -rf "$fw"
  local ver="$fw/Versions/A"
  mkdir -p "$ver/Headers" "$ver/Modules" "$ver/Resources"
  cp "$universal_dylib" "$ver/libmpv"
  chmod +w "$ver/libmpv"
  install_name_tool -id "@rpath/libmpv.framework/libmpv" "$ver/libmpv"
  # Re-sign after the last edit (strip -x + install_name_tool), see apple_sign.
  apple_sign "$ver/libmpv" || warn "codesign (adhoc) of $ver/libmpv failed — host dlopen may SIGKILL on Apple Silicon"
  # Headers: pick from any arch's prefix — identical across arches.
  local first_arch="${ARCHS%% *}"
  cp -r "$BUILD_ROOT/$first_arch/prefix/include/mpv"/* "$ver/Headers/" 2>/dev/null || true
  apple_write_modulemap "$ver/Modules/module.modulemap"
  apple_write_info_plist "$ver/Resources/Info.plist" LSMinimumSystemVersion "$MACOS_MIN"
  apple_write_privacy_manifest "$ver/Resources/PrivacyInfo.xcprivacy"

  # Versioned-bundle symlinks: Current → A, then the top-level entries that
  # consumers (and `@rpath/libmpv.framework/libmpv`) resolve through.
  ln -s A                        "$fw/Versions/Current"
  ln -s Versions/Current/libmpv    "$fw/libmpv"
  ln -s Versions/Current/Headers   "$fw/Headers"
  ln -s Versions/Current/Modules   "$fw/Modules"
  ln -s Versions/Current/Resources "$fw/Resources"

  # 3. Assemble xcframework.
  xcodebuild -create-xcframework -framework "$fw" -output "$xcfw"
  codesign -s - --force --deep "$xcfw" 2>/dev/null || true
  ok "xcframework: $xcfw"

  # 4. Zip for release. `-y` stores symlinks AS symlinks — the macOS
  # versioned framework relies on them (Current → A, top-level → Current/*);
  # without `-y` zip follows them and the unzipped framework is a broken,
  # symlink-less triplicate that Xcode rejects.
  local out_zip="$release_dir/libmpv_macos.xcframework.zip"
  rm -f "$out_zip"
  pushd "$OUTPUT_DIR" >/dev/null
  zip -y -r "$out_zip" "libmpv.xcframework" >/dev/null
  popd >/dev/null
  ok "Output: $out_zip"
  local prefixes=()
  for arch in $ARCHS; do
    prefixes+=("$BUILD_ROOT/$arch/prefix")
  done
  write_build_record macos "${prefixes[@]}"
  # The texts of the first arch, whose mpv tree is mpv-<arch> (build_mpv).
  apple_write_licenses macos "$BUILD_ROOT/${ARCHS%% *}/src" "mpv-${ARCHS%% *}"

  # 5. Verify the universal dylib inside the framework.
  verify_dylib "$fw/libmpv"
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║   build_libmpv_macos.sh — dynamic mpv $MPV_VERSION (xcframework) ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo "  ARCHS : $ARCHS"
  echo "  JOBS  : $JOBS"
  echo "  OUTPUT: $OUTPUT_DIR"
  echo "  BUILD : $BUILD_DIR"
  [[ -n "$CC_PREFIX" ]] && echo "  CCACHE: $CC_PREFIX"
  if [[ "${ENABLE_LTO_DEPS:-1}" != "0" ]]; then
    echo "  LTO   : deps + ffmpeg + mpv (ThinLTO)"
  else
    echo "  LTO   : ffmpeg + mpv only (deps disabled via ENABLE_LTO_DEPS=0)"
  fi
  if [[ "${VIS_HIDDEN:-1}" != "0" ]]; then
    echo "  VIS   : hidden (dynsym limited to mpv_*)"
  else
    echo "  VIS   : default (all internals exported via VIS_HIDDEN=0)"
  fi
  echo ""

  apple_check_tools meson ninja nasm cmake pkg-config python3 autoconf automake libtool git
  apple_toolchain_notes macosx

  # Build each requested arch into its own fully separate tree
  # (BUILD_ROOT/<arch>: src extract + build dirs + prefix) so a
  # cross-compiled slice can't reuse another arch's object files.
  for arch in $ARCHS; do
    ARCH="$arch"
    BUILD_DIR="$BUILD_ROOT/$ARCH"
    PREFIX="$BUILD_DIR/prefix"
    mkdir -p "$BUILD_DIR/src"
    log "═══ macOS slice: $ARCH ═══"
    build_for_arch
    finalize_arch
  done

  # Lipo per-arch dylibs + wrap in libmpv.framework + assemble xcframework.
  assemble_xcframework

  for arch in $ARCHS; do
    cleanup_build "$BUILD_ROOT/$arch"
  done

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  Build completed successfully!                               ║"
  echo "║                                                              ║"
  echo "║  Next steps:                                                 ║"
  echo "║  1. builds/release/libmpv_macos.xcframework.zip (final)      ║"
  echo "║  2. Upload xcframework.zip to GitHub releases                ║"
  echo "║  3. Run mpv_audio_kit's scripts/update_libmpv.sh             ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
}

main "$@"
