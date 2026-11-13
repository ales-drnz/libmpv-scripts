#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# build_libmpv_ios.sh
#
# Compiles mpv 0.41.0 as a DYNAMIC library for iOS, and for tvOS with
# APPLE_OS=tvos (build_libmpv_tvos.sh).
#
# === OUTPUT FORMATS AND LOCATIONS ===
# Final artifact: builds/release/libmpv_ios.xcframework.zip
#                 (builds/release/libmpv_tvos.xcframework.zip on tvOS)
# Output File: libmpv.xcframework wrapping a dynamic libmpv.framework per slice.
#              Each slice contains:
#                libmpv.framework/libmpv          (Mach-O dylib, install_name
#                                                  @rpath/libmpv.framework/libmpv)
#                libmpv.framework/Headers/*.h
#                libmpv.framework/Info.plist
#                libmpv.framework/PrivacyInfo.xcprivacy
#                libmpv.framework/Modules/module.modulemap
#
# === SYSTEM & HARDWARE SPECS ===
# Target OS:   iOS or tvOS (Deployment target 15.0+)
# Target Arch: arm64 (Physical Devices); arm64 + x86_64 (Simulator)
# Compiler:    Xcode Toolchain (Apple Clang)
#
# Usage (from project root):
#   chmod +x scripts/build_libmpv_ios.sh
#   ./scripts/build_libmpv_ios.sh
#
# Options (environment variables):
#   APPLE_OS=ios|tvos     (default: ios)
#   MPV_VERSION=0.41.0    (default: 0.41.0)
#   JOBS=N                (default: number of cores)
#   FORCE_DOWNLOAD=1      (redownload sources even if cached)
#   KEEP_BUILD=1          (preserve all of BUILD_DIR for inspection)
#   WIPE_ALL=1            (also delete the src/ download cache at the end)
#   SKIP_SIMULATOR=1      (skips the simulator slice)
#   ONLY_SIMULATOR=1      (builds only the simulator slice)
#   SIM_ARCHS="arm64 x86_64"  (simulator architectures to build; default both)
#   CC_PREFIX=ccache      (prepend a wrapper to clang/clang++)
#   ENABLE_LTO_DEPS=0     (disable ThinLTO on static deps; default on)
#   VIS_HIDDEN=0          (export every internal symbol; default hides them)
#
# Note: libmpv ships as a dynamic framework with all its transitive deps
#       (ffmpeg, libplacebo, libass, …) linked statically INTO the dylib.
#       Only the public mpv_* C API is exported (via patch_export_filter).
#       Same dependency versions as build_libmpv_macos.sh, except libplacebo
#       (iOS pins 6.338.2; macOS pins 7.349.0 — see _versions.sh for why).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared across all build_libmpv_<platform>.sh scripts
source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"
source "$SCRIPT_DIR/shared/_audio_only.sh"
source "$SCRIPT_DIR/shared/_cross.sh"
source "$SCRIPT_DIR/shared/_apple.sh"
source "$SCRIPT_DIR/build_openssl.sh"

# tvOS has the audio stack of iOS (AudioUnit, AVFoundation, AVAudioSession),
# so the same build makes it: only the SDKs, the version flags and the
# names change. The libraries keep meson's 'ios' system, which mpv's
# patches already read as Darwin.
APPLE_OS="${APPLE_OS:-ios}"
case "$APPLE_OS" in
  ios)
    DEVICE_SDK="iphoneos";  SIM_SDK="iphonesimulator"
    DEVICE_MIN_FLAG="-miphoneos-version-min"; SIM_MIN_FLAG="-mios-simulator-version-min"
    CMAKE_SYSTEM="iOS";     OS_LABEL="iOS" ;;
  tvos)
    DEVICE_SDK="appletvos"; SIM_SDK="appletvsimulator"
    DEVICE_MIN_FLAG="-mtvos-version-min";     SIM_MIN_FLAG="-mtvos-simulator-version-min"
    CMAKE_SYSTEM="tvOS";    OS_LABEL="tvOS" ;;
  *) die "APPLE_OS is ios or tvos, not $APPLE_OS" ;;
esac

# iOS-only dependency versions (centralised ones live in _versions.sh)
# shellcheck disable=SC2034  # read by the shared builds (_cross.sh, _apple.sh)
LIBPLACEBO_VERSION="6.338.2"
LIBSMB2_TAG="v${LIBSMB2_VERSION}"

# LTO defaults to enabled on iOS (same as every other platform). The historic
# `ENABLE_LTO_DEPS=0` reason — bitcode-only .o files rejected by
# `xcodebuild -create-xcframework` when wrapping static archives — no longer
# applies: we now ship a real Mach-O dylib per slice, ThinLTO output is
# linked into a complete dylib before xcframework assembly.

BUILD_DIR="${BUILD_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work/$OS_LABEL}"
PREFIX_BASE="$BUILD_DIR/prefix"

# Staging dir for the assembled xcframework — in the build tree, never in the
# consumer repo. assemble_xcframework builds libmpv.xcframework here and zips
# it into builds/release/, where the manifest and the release pick it up.
# The build never writes outside libmpv-scripts.
OUTPUT_DIR="$BUILD_DIR/xcframework-stage"

apple_start_log "$APPLE_OS"

# Slices to build (appletvos and appletvsimulator on tvOS):
#   device:    iphoneos arm64
#   simulator: iphonesimulator arm64 (Apple Silicon Macs) + x86_64 (Intel Macs).
# Simulator arm64 + x86_64 are lipo'd into a single fat slice inside the
# xcframework so the same xcframework loads on either dev host. Override the
# simulator arch set with SIM_ARCHS="arm64", SIM_ARCHS="x86_64", or empty.
SIM_ARCHS="${SIM_ARCHS:-arm64 x86_64}"

SLICES=()
if [[ "${ONLY_SIMULATOR:-0}" != "1" ]]; then
  SLICES+=("$DEVICE_SDK:arm64")
fi
if [[ "${SKIP_SIMULATOR:-0}" != "1" ]]; then
  for sim_arch in $SIM_ARCHS; do
    SLICES+=("$SIM_SDK:${sim_arch}")
  done
fi

IOS_MIN="15.0"

# Logging helpers (log / ok / warn / err / die / fail) come from _helpers.sh

# Download / git clone / extract helpers come from _helpers.sh

# ── SDK helpers ──────────────────────────────────────────────────────────────
sdk_path() { xcrun --sdk "$1" --show-sdk-path; }

cflags_for() {
  local sdk="$1" arch="$2"
  local sysroot; sysroot="$(sdk_path "$sdk")"
  local extra
  extra="$(lto_deps_cflags) $(vis_deps_cflags)"
  if [[ "$sdk" == "$DEVICE_SDK" ]]; then
    echo "-arch $arch $DEVICE_MIN_FLAG=$IOS_MIN -isysroot $sysroot $extra"
  else
    echo "-arch $arch $SIM_MIN_FLAG=$IOS_MIN -isysroot $sysroot $extra"
  fi
}

# ── meson cross-file for iOS ──────────────────────────────────────────────────
write_ios_cross() {
  local sdk="$1" arch="$2"
  local sysroot; sysroot="$(sdk_path "$sdk")"
  local file="$BUILD_DIR/meson_cross_${sdk}_${arch}.ini"
  local min_flag
  if [[ "$sdk" == "$DEVICE_SDK" ]]; then
    min_flag="$DEVICE_MIN_FLAG=$IOS_MIN"
  else
    min_flag="$SIM_MIN_FLAG=$IOS_MIN"
  fi
  local cpu_family="aarch64"
  [[ "$arch" == "x86_64" ]] && cpu_family="x86_64"
  # The mpv C-only flags (eh_frame trim, -Oz) go INTO the cross-file c_args,
  # see apple_meson_options.
  {
    apple_meson_binaries pkg-config
    echo
    apple_meson_options "$arch" "$min_flag" "$sysroot" "$(apple_mpv_c_args)"
    echo
  } > "$file"
  cat >> "$file" << EOF
[host_machine]
system = 'ios'
cpu_family = '${cpu_family/x86_64/x86}'
cpu = '$arch'
endian = 'little'

[build_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
  echo "$file"
}

# ── Native-file meson (build machine compilers) ─────────────────────────────
write_native_file() {
  local file="$BUILD_DIR/meson_native.ini"
  [[ -f "$file" ]] && { echo "$file"; return; }
  apple_meson_binaries pkg-config > "$file"
  echo "$file"
}

# =============================================================================
# Build for a single slice (sdk:arch)
# =============================================================================
build_slice() {
  local sdk="$1" arch="$2"
  local prefix="$PREFIX_BASE/${sdk}_${arch}"
  mkdir -p "$prefix"
  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"

  mkdir -p "$prefix/lib/pkgconfig"
  cat > "$prefix/lib/pkgconfig/iconv.pc" << EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: iconv
Description: Character encoding conversion library
Version: 1.11
Libs: -liconv
Cflags: -I\${includedir}
EOF

  local cf; cf="$(cflags_for "$sdk" "$arch")"
  # $(dep_unwind_cflags): C++-safe .eh_frame trim, shared across all deps
  # (matches $LTO_EXTRA/$VIS_EXTRA wiring in the linux reference). The
  # stronger C-only eh_frame_cflags() goes into ffmpeg --extra-cflags +
  # mpv -Dc_args instead, never here (these compile the C++/ObjC deps).
  export CFLAGS="$cf -O2 $(dep_unwind_cflags)"
  export CXXFLAGS="$cf -O2 $(dep_unwind_cflags)"
  export LDFLAGS="$cf"
  export CC="$CC_BIN"
  export CXX="$CXX_BIN"

  # What the shared dep builds (_cross.sh, _apple.sh) take: one prefix per
  # slice, the src/ trees shared by the slices, build/ dirs named after it.
  export CROSS_BUILD_DIR="$BUILD_DIR"
  export CROSS_PREFIX_DIR="$prefix"
  CROSS_AUTOTOOLS_HOST="--host=$(apple_host "$arch")"
  export CROSS_AUTOTOOLS_HOST
  # shellcheck disable=SC2034  # read by the shared builds
  CROSS_BUILD_SUFFIX="-${sdk}-${arch}" CROSS_LABEL="$sdk/$arch"

  local sysroot; sysroot="$(sdk_path "$sdk")"
  # Note: Do NOT export SDKROOT here.  The -isysroot flag in CFLAGS / cross-file
  # is sufficient for cross-compilation, and exporting SDKROOT causes dyld to
  # reject native (build-machine) binaries during meson/ninja code-generation.

  log "═══ Slice: $sdk / $arch ═══"

  # Order: base → [font] → audio → core
  # Font chain — built ONLY when libass is kept (strip_libass disabled in
  # Settings ▸ Patches). By default libass is stripped from mpv
  # (patch_strip_libass.py), so freetype/harfbuzz/fontconfig/fribidi/libass —
  # plus their font-only deps expat + libpng — are unreferenced and skipped.
  local machine=(--cross-file="$(write_ios_cross "$sdk" "$arch")" --native-file="$(write_native_file)")
  CFLAGS="$cf -Oz" apple_build_zlib
  AR=ar RANLIB=ranlib CFLAGS="$cf -Oz -D_FILE_OFFSET_BITS=64" cross_build_bzip2
  CFLAGS="$cf -Oz" cross_build_xz
  if ! libass_stripped; then
    CFLAGS="$cf -O2" cross_build_expat
    slice_libpng     "$sdk" "$arch" "$prefix" "$cf"
    slice_freetype   "$sdk" "$arch" "$prefix" "$cf"
    slice_fribidi    "$sdk" "$arch" "$prefix" "$cf"
    slice_harfbuzz   "$sdk" "$arch" "$prefix" "$cf"
    slice_freetype2  "$sdk" "$arch" "$prefix" "$cf"
    slice_fontconfig "$sdk" "$arch" "$prefix" "$cf"
    slice_libass     "$sdk" "$arch" "$prefix" "$cf"
  fi
  CFLAGS="$cf -O2" apple_build_speexdsp
  # librubberband (GPL-2.0+) only in the GPL build (gpl_build in _audio_only.sh).
  if gpl_build; then
    apple_build_rubberband "${machine[@]}"
  fi
  slice_openssl    "$sdk" "$arch" "$prefix" "$cf"
  slice_libsmb2    "$sdk" "$arch" "$prefix" "$cf"
  CFLAGS="$cf -Oz" LDFLAGS="$cf" cross_build_libxml2
  slice_ffmpeg     "$sdk" "$arch" "$prefix" "$cf" "$sysroot"
  apple_build_libplacebo "${machine[@]}"
  slice_mpv        "$sdk" "$arch" "$prefix" "$cf"
}

# ── Helper: static cmake build ──────────────────────────────────────────────
cmake_static() {
  local sdk="$1" arch="$2" prefix="$3" srcdir="$4"; shift 4
  local bdir="$BUILD_DIR/build/$(basename "$srcdir")-${sdk}-${arch}"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$srcdir" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_SYSROOT="$(sdk_path "$sdk")" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    "$@" \
    -GNinja
  ninja -j"$JOBS"
  ninja install
  popd >/dev/null
}

# ── Libraries (pattern: check sentinel → build) ───────────────────────

slice_libpng() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libpng.a" ]] && return
  log "libpng ($sdk/$arch)..."
  local src="$BUILD_DIR/src/libpng-$LIBPNG_VERSION.tar.gz"
  download "https://downloads.sourceforge.net/project/libpng/libpng16/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make distclean 2>/dev/null || make clean 2>/dev/null || true
  local host="aarch64-apple-darwin"
  [[ "$arch" == "x86_64" ]] && host="x86_64-apple-darwin"

  CFLAGS="$cf -O2" LDFLAGS="$cf" ./configure --prefix="$prefix" --host="$host" --enable-static --disable-shared
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "libpng ($sdk/$arch) ✓"
}

slice_freetype() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libfreetype.a" ]] && return 0
  log "freetype r1 ($sdk/$arch)..."
  local src="$BUILD_DIR/src/freetype-$FREETYPE_VERSION.tar.gz"
  download "https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  cmake_static "$sdk" "$arch" "$prefix" "$dir" \
    -DFT_DISABLE_HARFBUZZ=ON \
    -DFT_REQUIRE_ZLIB=ON \
    -DFT_REQUIRE_PNG=ON \
    -DZLIB_LIBRARY="$prefix/lib/libz.a" \
    -DZLIB_INCLUDE_DIR="$prefix/include" \
    -DPNG_LIBRARY="$prefix/lib/libpng.a" \
    -DPNG_PNG_INCLUDE_DIR="$prefix/include" \
    -DCMAKE_POLICY_DEFAULT_CMP0074=NEW
  ok "freetype r1 ($sdk/$arch) ✓"
}

slice_fribidi() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libfribidi.a" ]] && return
  log "fribidi ($sdk/$arch)..."
  local src="$BUILD_DIR/src/fribidi-$FRIBIDI_VERSION.tar.gz"
  download "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/fribidi-${sdk}-${arch}"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" apple_meson_setup "$dir" \
    --prefix="$prefix" --buildtype=release --default-library=static \
    -Ddocs=false -Dtests=false \
    --cross-file="$(write_ios_cross "$sdk" "$arch")" \
    --native-file="$(write_native_file)"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "fribidi ($sdk/$arch) ✓"
}

slice_harfbuzz() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libharfbuzz.a" ]] && return
  log "harfbuzz ($sdk/$arch)..."
  local src="$BUILD_DIR/src/harfbuzz-$HARFBUZZ_VERSION.tar.gz"
  download "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/harfbuzz-${sdk}-${arch}"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" apple_meson_setup "$dir" \
    --prefix="$prefix" --buildtype=release --default-library=static \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dicu=disabled \
    -Dtests=disabled -Ddocs=disabled \
    --cross-file="$(write_ios_cross "$sdk" "$arch")" \
    --native-file="$(write_native_file)"
  ninja -j"$JOBS"; ninja install
  mkdir -p "$prefix/lib/cmake/harfbuzz"
  cat > "$prefix/lib/cmake/harfbuzz/harfbuzz-config-version.cmake" << EOF
set(PACKAGE_VERSION "${HARFBUZZ_VERSION}")
if (PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else ()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if (PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif ()
endif ()
EOF
  popd >/dev/null
  ok "harfbuzz ($sdk/$arch) ✓"
}

slice_freetype2() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  local sentinel="$prefix/.ft_round2_${sdk}_${arch}"
  [[ -f "$sentinel" ]] && return 0

  # Ensure harfbuzz-config-version.cmake exists
  mkdir -p "$prefix/lib/cmake/harfbuzz"
  if [[ ! -f "$prefix/lib/cmake/harfbuzz/harfbuzz-config-version.cmake" ]]; then
    cat > "$prefix/lib/cmake/harfbuzz/harfbuzz-config-version.cmake" << EOF
set(PACKAGE_VERSION "${HARFBUZZ_VERSION}")
if (PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION)
  set(PACKAGE_VERSION_COMPATIBLE FALSE)
else ()
  set(PACKAGE_VERSION_COMPATIBLE TRUE)
  if (PACKAGE_VERSION VERSION_EQUAL PACKAGE_FIND_VERSION)
    set(PACKAGE_VERSION_EXACT TRUE)
  endif ()
endif ()
EOF
  fi

  log "freetype r2 ($sdk/$arch)..."
  local src="$BUILD_DIR/src/freetype-$FREETYPE_VERSION.tar.gz"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  rm -rf "$BUILD_DIR/build/freetype-${sdk}-${arch}"
  local bdir="$BUILD_DIR/build/freetype-r2-${sdk}-${arch}"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_SYSROOT="$(sdk_path "$sdk")" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DFT_DISABLE_HARFBUZZ=OFF -DFT_REQUIRE_HARFBUZZ=ON \
    -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON \
    -DZLIB_LIBRARY="$prefix/lib/libz.a" -DZLIB_INCLUDE_DIR="$prefix/include" \
    -DPNG_LIBRARY="$prefix/lib/libpng.a" -DPNG_PNG_INCLUDE_DIR="$prefix/include" \
    -DHarfBuzz_INCLUDE_DIR="$prefix/include/harfbuzz" \
    -DHarfBuzz_LIBRARY="$prefix/lib/libharfbuzz.a" \
    -DHarfBuzz_FOUND=ON \
    -DHarfBuzz_VERSION="${HARFBUZZ_VERSION}" \
    -DPC_HarfBuzz_VERSION="${HARFBUZZ_VERSION}" \
    -DPC_HarfBuzz_FOUND=1 \
    -DCMAKE_PREFIX_PATH="$prefix" -DCMAKE_POLICY_DEFAULT_CMP0074=NEW \
    -GNinja
  ninja -j"$JOBS"; ninja install
  touch "$sentinel"
  popd >/dev/null
  ok "freetype r2 ($sdk/$arch) ✓"
}

slice_fontconfig() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libfontconfig.a" ]] && return
  log "fontconfig ($sdk/$arch)..."
  local src="$BUILD_DIR/src/fontconfig-$FONTCONFIG_VERSION.tar.xz"
  download "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FONTCONFIG_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/fontconfig-${sdk}-${arch}"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" apple_meson_setup "$dir" \
    --prefix="$prefix" --buildtype=release --default-library=static \
    -Dtests=disabled -Dtools=disabled -Ddoc=disabled \
    --cross-file="$(write_ios_cross "$sdk" "$arch")" \
    --native-file="$(write_native_file)"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "fontconfig ($sdk/$arch) ✓"
}

slice_libass() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libass.a" ]] && return
  log "libass ($sdk/$arch)..."
  local src="$BUILD_DIR/src/libass-$LIBASS_VERSION.tar.gz"
  download "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make distclean 2>/dev/null || make clean 2>/dev/null || true
  local host="aarch64-apple-darwin"
  [[ "$arch" == "x86_64" ]] && host="x86_64-apple-darwin"

  CFLAGS="$cf -O2" LDFLAGS="$cf -L$prefix/lib" PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  ./configure --prefix="$prefix" --host="$host" --enable-static --disable-shared \
    --disable-require-system-font-provider --with-pic --enable-asm
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "libass ($sdk/$arch) ✓"
}

slice_openssl() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  # OpenSSL Configure honours the exported CC/CFLAGS/LDFLAGS set in
  # build_slice (cf carries -arch + -isysroot). The Configure target
  # depends on the SDK, not the arch — the simulator target is xcrun-
  # driven and covers both arm64 and x86_64. OpenSSL has no tvOS target:
  # the iOS ones add only -arch, -isysroot and CC, which the exported flags
  # replace with the tvOS SDK and version.
  local openssl_target
  case "$sdk" in
    iphoneos|appletvos)               openssl_target="ios64-cross"        ;;
    iphonesimulator|appletvsimulator) openssl_target="iossimulator-xcrun" ;;
    *) die "no OpenSSL target mapping for sdk: $sdk" ;;
  esac
  build_openssl "$prefix" "$BUILD_DIR" "$openssl_target"
}

slice_libsmb2() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libsmb2.a" ]] && return
  log "libsmb2 $LIBSMB2_TAG ($sdk/$arch)..."
  local dir="$BUILD_DIR/src/libsmb2"
  download_git "https://github.com/sahlberg/libsmb2.git" "$dir" "$LIBSMB2_TAG"
  apply_libsmb2_apple_patch "$dir"

  local sysroot; sysroot="$(sdk_path "$sdk")"
  local bdir="$BUILD_DIR/build/libsmb2-${sdk}-${arch}"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_SYSTEM_NAME="$CMAKE_SYSTEM" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_LIBDIR=lib
  make -j"$JOBS"
  make install
  apply_libsmb2_post_install_fixes "$prefix" "$APPLE_OS"
  popd >/dev/null
  ok "libsmb2 ($sdk/$arch) ✓"
}

slice_ffmpeg() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4" sysroot="$5"
  local min_flag
  if [[ "$sdk" == "$DEVICE_SDK" ]]; then
    min_flag="$DEVICE_MIN_FLAG=$IOS_MIN"
  else
    min_flag="$SIM_MIN_FLAG=$IOS_MIN"
  fi

  # ── ffmpeg: smart audio-only build (see scripts/shared/_audio_only.sh) ─────────────
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  cross_build_ffmpeg "$APPLE_OS" \
    --enable-cross-compile \
    --arch="$arch" \
    --target-os=darwin \
    --cc="$CC_BIN" --cxx="$CXX_BIN" \
    --extra-cflags="-arch $arch $min_flag -isysroot $sysroot -I$prefix/include -O2 $(eh_frame_cflags)" \
    --extra-ldflags="-arch $arch $min_flag -isysroot $sysroot -L$prefix/lib" \
    --disable-videotoolbox \
    --enable-audiotoolbox
}

slice_mpv() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libmpv.dylib" ]] && return
  log "mpv $MPV_VERSION ($sdk/$arch) [shared]..."
  local src="$BUILD_DIR/src/mpv-$MPV_VERSION.tar.gz"
  download "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz" "$src"
  # Per-slice mpv source tree. patch_export_filter writes the slice's
  # absolute prefix path into meson.build; if we shared the source across
  # slices the second slice_mpv invocation would be no-op'd by the patch's
  # MARKER guard and link against the previous slice's prefix archives
  # (wrong arch). Cost: ~50 MB × N slices.
  # Re-extracted on every build: src/ survives cleanup_build, and the mpv
  # patches assume an unpatched tree.
  local dir="$BUILD_DIR/src/mpv-${sdk}_${arch}"
  rm -rf "$dir"; mkdir -p "$dir"
  tar -xzf "$src" --strip-components=1 -C "$dir"
  patch_record_start mpv "$prefix"

  # ── Apply mpv patches ──────────────────────────────────────────────────────
  # iOS-only patches (must run before the shared ones — they touch
  # meson.build files the shared `patch_optional_deps` then patches further).
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/ios/patch_ios_platform.py"     "$dir" "$sdk"
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/ios/patch_ios_audio_stubs.py"  "$dir"
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/apple/patch_utils_mac.py"      "$dir/meson.build"
  # Gate the kAudioObjectPropertyElementMain compat shim on TARGET_OS_OSX
  # so iOS 15+ uses the native symbol (the upstream shim references the
  # iOS-26-removed kAudioObjectPropertyElementMaster).
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/ios/patch_compat_apple.py"     "$dir"
  apple_mpv_export_filter "$dir" "$prefix"
  # The mpv patches shared across every platform, see
  # scripts/shared/_audio_only.sh.
  apply_mpv_patches_common "$dir"

  local bdir="$BUILD_DIR/build/mpv-${sdk}-${arch}"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  apple_meson_setup "$dir" \
    --prefix="$prefix" \
    --buildtype=release \
    --default-library=shared \
    --cross-file="$(write_ios_cross "$sdk" "$arch")" \
    --native-file="$(write_native_file)" \
    $(mpv_common_args) \
    -Dswift-build=disabled \
    -Davfoundation=enabled \
    -Daudiounit=enabled
  verify_mpv_config "$bdir" "$APPLE_OS"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "mpv shared ($sdk/$arch) ✓"
}

# =============================================================================
# Assemble xcframework from slices.
#
# Each slice ships as a dynamic framework wrapper (`libmpv.framework/`) whose
# binary is a Mach-O dylib with `install_name = @rpath/libmpv.framework/libmpv`.
# The Dart side loads it via `DynamicLibrary.open('libmpv.framework/libmpv')`;
# Xcode embeds & code-signs the framework into the consumer app's
# `App.app/Frameworks/` at build time.
#
# Simulator slices arm64 + x86_64 are lipo'd into a single fat dylib before
# wrapping so one xcframework runs on Apple-Silicon AND Intel dev hosts.
# =============================================================================
assemble_xcframework() {
  log "Assembling xcframework..."
  local xcfw="$OUTPUT_DIR/libmpv.xcframework"
  rm -rf "$xcfw"
  mkdir -p "$OUTPUT_DIR"

  # Helper: wrap a (possibly lipo'd) Mach-O dylib into a `libmpv.framework/`
  # bundle. Rewrites install_name to @rpath/libmpv.framework/libmpv, strips
  # any leftover bitcode segments (defensive — modern Xcode shouldn't emit
  # them anyway), copies headers + Info.plist + PrivacyInfo + module.modulemap.
  # $1 = dylib path  $2 = headers source dir  $3 = framework dir to create
  build_dynamic_framework() {
    local dylib="$1" headers_src="$2" fw="$3"
    rm -rf "$fw"
    mkdir -p "$fw/Headers" "$fw/Modules"
    cp "$dylib" "$fw/libmpv"
    chmod +w "$fw/libmpv"
    install_name_tool -id "@rpath/libmpv.framework/libmpv" "$fw/libmpv"
    # Defensive — Xcode 14+ no longer accepts bitcode segments on upload.
    xcrun bitcode_strip -r "$fw/libmpv" -o "$fw/libmpv" 2>/dev/null || true
    # Strip local symbols + debug (~1.3M; meson does not strip). -x keeps the
    # exported mpv_* API + @rpath install_name. Done before the hygiene count.
    strip -x "$fw/libmpv" 2>/dev/null || true
    # Re-sign after the last edit (bitcode_strip, install_name_tool, strip -x),
    # see apple_sign.
    apple_sign "$fw/libmpv" || true

    # Export-filter hygiene (mirrors the macOS sanity check): the exports list
    # is `_mpv_*`, so with it applied we expect ~60 exported (T) symbols —
    # essentially just the public mpv_* C API. A blown-up count means the filter
    # was dropped and this slice is leaking ffmpeg/libass internals that
    # clash with other Flutter plugins linking the same symbols.
    if [[ "${VIS_HIDDEN:-1}" != "0" ]]; then
      local _total_syms
      _total_syms="$(nm -gU "$fw/libmpv" 2>/dev/null | grep -c ' T ' || echo 0)"
      ok "$OS_LABEL slice symbols: $_total_syms total ($(basename "$fw"))"
      if [[ "$_total_syms" -gt 200 ]]; then
        die "Export-filter regression: expected ~60 exported symbols but" \
            "got $_total_syms in this $OS_LABEL slice — verify patch_export_filter.py" \
            "bound the exported-symbols list into the final link."
      fi
    fi

    cp -r "$headers_src"/* "$fw/Headers/" 2>/dev/null || true
    apple_write_modulemap "$fw/Modules/module.modulemap"
    apple_write_info_plist "$fw/Info.plist" MinimumOSVersion "$IOS_MIN"
    apple_write_privacy_manifest "$fw/PrivacyInfo.xcprivacy"
  }

  local release_dir="$LIBMPV_SCRIPTS_ROOT/builds/release"
  mkdir -p "$release_dir"

  local xcodebuild_args=("-create-xcframework")

  # Device slice (iphoneos or appletvos arm64).
  if [[ "${ONLY_SIMULATOR:-0}" != "1" ]]; then
    local device_fw="$BUILD_DIR/libmpv.framework_device/libmpv.framework"
    # `cp -L` follows the libmpv.dylib -> libmpv.<soversion>.dylib symlink
    # produced by meson, giving us a real file we can rename to plain
    # `libmpv` inside the framework.
    local device_dylib="$BUILD_DIR/libmpv_device.dylib"
    cp -L "$PREFIX_BASE/${DEVICE_SDK}_arm64/lib/libmpv.dylib" "$device_dylib"
    build_dynamic_framework \
      "$device_dylib" \
      "$PREFIX_BASE/${DEVICE_SDK}_arm64/include/mpv" \
      "$device_fw"
    xcodebuild_args+=("-framework" "$device_fw")
  fi

  # Simulator slice (arm64 + x86_64 lipo'd into a fat dylib).
  if [[ "${SKIP_SIMULATOR:-0}" != "1" ]]; then
    local sim_fw="$BUILD_DIR/libmpv.framework_sim/libmpv.framework"
    local sim_dylib="$BUILD_DIR/libmpv_sim.dylib"
    local lipo_args=()
    for sim_arch in $SIM_ARCHS; do
      lipo_args+=("$PREFIX_BASE/${SIM_SDK}_${sim_arch}/lib/libmpv.dylib")
    done
    if [[ ${#lipo_args[@]} -eq 1 ]]; then
      cp -L "${lipo_args[0]}" "$sim_dylib"
    else
      lipo -create "${lipo_args[@]}" -output "$sim_dylib"
    fi
    # Pick any sim arch's headers — they're identical across arches.
    local first_sim_arch="${SIM_ARCHS%% *}"
    build_dynamic_framework \
      "$sim_dylib" \
      "$PREFIX_BASE/${SIM_SDK}_${first_sim_arch}/include/mpv" \
      "$sim_fw"
    xcodebuild_args+=("-framework" "$sim_fw")
  fi

  xcodebuild_args+=("-output" "$xcfw")
  xcodebuild "${xcodebuild_args[@]}"

  codesign -s - --force --deep "$xcfw" 2>/dev/null || true
  ok "xcframework: $xcfw"

  log "Zipping xcframework..."
  # Remove the previous archive first — `zip -r` UPDATES (appends) the
  # archive if it exists, leaving stale slices from earlier runs around.
  local out_zip="$release_dir/libmpv_${APPLE_OS}.xcframework.zip"
  rm -f "$out_zip"
  pushd "$OUTPUT_DIR" >/dev/null
  zip -r "$out_zip" "libmpv.xcframework" >/dev/null
  popd >/dev/null
  ok "Output: $out_zip"
  local prefixes=() slice
  for slice in "${SLICES[@]}"; do
    prefixes+=("$PREFIX_BASE/${slice%%:*}_${slice##*:}")
  done
  write_build_record "$APPLE_OS" "${prefixes[@]}"
  # The mpv tree of a slice is mpv-<sdk>_<arch> (slice_mpv): the first one.
  local first="${SLICES[0]}"
  apple_write_licenses "$APPLE_OS" "$BUILD_DIR/src" "mpv-${first%%:*}_${first##*:}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║   build_libmpv_ios.sh — mpv $MPV_VERSION (dynamic xcframework) ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  apple_check_tools meson ninja nasm cmake pkg-config python3 autoconf automake libtool git xcodebuild
  apple_toolchain_notes "$DEVICE_SDK" "$SIM_SDK"
  mkdir -p "$BUILD_DIR/src" "$BUILD_DIR/build"

  for slice in "${SLICES[@]}"; do
    local sdk="${slice%%:*}"
    local arch="${slice##*:}"
    build_slice "$sdk" "$arch"
  done

  assemble_xcframework

  cleanup_build "$BUILD_DIR"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  printf '║  %-60s║\n' "$OS_LABEL build complete!"
  printf '║  %-60s║\n' "Output: builds/release/libmpv_${APPLE_OS}.xcframework.zip"
  echo "╚══════════════════════════════════════════════════════════════╝"
}

main "$@"
