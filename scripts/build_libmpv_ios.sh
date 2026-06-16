#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# build_libmpv_ios.sh
#
# Compiles mpv 0.41.0 as a DYNAMIC library for iOS.
#
# === OUTPUT FORMATS AND LOCATIONS ===
# Target Dir:  ios/Frameworks/
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
# Target OS:   iOS (Deployment target 15.0+)
# Target Arch: arm64 (Physical Devices); arm64 + x86_64 (iOS Simulator)
# Compiler:    Xcode Toolchain (Apple Clang)
#
# Usage (from project root):
#   chmod +x scripts/build_libmpv_ios.sh
#   ./scripts/build_libmpv_ios.sh
#
# Options (environment variables):
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
source "$SCRIPT_DIR/build_openssl.sh"

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"

# iOS-only dependency versions (centralised ones live in _versions.sh)
LIBPLACEBO_VERSION="6.338.2"
LIBSMB2_TAG="v${LIBSMB2_VERSION}"

# Optional ccache/sccache wrapper (export CC_PREFIX=ccache)
CC_PREFIX="${CC_PREFIX:-}"
CC_BIN="${CC_PREFIX:+${CC_PREFIX} }clang"
CXX_BIN="${CC_PREFIX:+${CC_PREFIX} }clang++"

# LTO defaults to enabled on iOS (same as every other platform). The historic
# `ENABLE_LTO_DEPS=0` reason — bitcode-only .o files rejected by
# `xcodebuild -create-xcframework` when wrapping static archives — no longer
# applies: we now ship a real Mach-O dylib per slice, ThinLTO output is
# linked into a complete dylib before xcframework assembly.

BUILD_DIR="${BUILD_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work/iOS}"
PREFIX_BASE="$BUILD_DIR/prefix"

# Staging dir for the assembled xcframework — in the build tree, never in the
# consumer repo. assemble_xcframework builds libmpv.xcframework here and zips
# it into builds/release/; `./build checksums` installs it into the consumer's
# ios/Frameworks/. The build never writes outside libmpv-scripts.
OUTPUT_DIR="$BUILD_DIR/xcframework-stage"

# ── Mirror all stdout + stderr to a timestamped log file ─────────────────────
# Every invocation gets its own file so we can diff across runs. Each line
# in the log is prefixed with [YYYY-MM-DD HH:MM:SS] so we can measure how
# long each phase of the build actually took (the terminal stays clean —
# timestamps live only in the file). Old logs (>20) are pruned automatically.
LOG_DIR="$LIBMPV_SCRIPTS_ROOT/builds/logs"
mkdir -p "$LOG_DIR"
ls -t "$LOG_DIR"/build_ios_*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
LOG_FILE="$LOG_DIR/build_ios_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee >(while IFS= read -r line; do
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
done >> "$LOG_FILE")) 2>&1
echo "════════════════════════════════════════════════════════════"
echo "Build started: $(date)"
echo "Log file:      $LOG_FILE"
echo "FFmpeg:        $FFMPEG_VERSION   mpv: $MPV_VERSION"
echo "════════════════════════════════════════════════════════════"

# Slices to build:
#   device:    iphoneos arm64
#   simulator: iphonesimulator arm64 (Apple Silicon Macs) + x86_64 (Intel Macs).
# Simulator arm64 + x86_64 are lipo'd into a single fat slice inside the
# xcframework so the same xcframework loads on either dev host. Override the
# simulator arch set with SIM_ARCHS="arm64", SIM_ARCHS="x86_64", or empty.
SIM_ARCHS="${SIM_ARCHS:-arm64 x86_64}"

SLICES=()
if [[ "${ONLY_SIMULATOR:-0}" != "1" ]]; then
  SLICES+=("iphoneos:arm64")
fi
if [[ "${SKIP_SIMULATOR:-0}" != "1" ]]; then
  for sim_arch in $SIM_ARCHS; do
    SLICES+=("iphonesimulator:${sim_arch}")
  done
fi

IOS_MIN="15.0"

# Logging helpers (log / ok / warn / err / die / fail) come from _helpers.sh

# ── Check requirements ────────────────────────────────────────────────────────
check_tools() {
  log "Checking tools..."
  local missing=()
  for t in meson ninja nasm cmake pkg-config python3 autoconf automake libtool git xcodebuild; do
    command -v "$t" &>/dev/null || missing+=("$t")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    command -v brew &>/dev/null || fail "Homebrew required to install: ${missing[*]}"
    brew install "${missing[@]}" 2>/dev/null || true
  fi
  ok "Tools OK"
}

# Download / git clone / extract helpers come from _helpers.sh

# ── SDK helpers ──────────────────────────────────────────────────────────────
sdk_path() { xcrun --sdk "$1" --show-sdk-path; }

cflags_for() {
  local sdk="$1" arch="$2"
  local sysroot; sysroot="$(sdk_path "$sdk")"
  local extra
  extra="$(lto_deps_cflags) $(vis_deps_cflags)"
  if [[ "$sdk" == "iphoneos" ]]; then
    echo "-arch $arch -miphoneos-version-min=$IOS_MIN -isysroot $sysroot $extra"
  else
    echo "-arch $arch -mios-simulator-version-min=$IOS_MIN -isysroot $sysroot $extra"
  fi
}

# ── meson cross-file for iOS ──────────────────────────────────────────────────
write_ios_cross() {
  local sdk="$1" arch="$2"
  local sysroot; sysroot="$(sdk_path "$sdk")"
  local file="$BUILD_DIR/meson_cross_${sdk}_${arch}.ini"
  local min_flag
  if [[ "$sdk" == "iphoneos" ]]; then
    min_flag="-miphoneos-version-min=$IOS_MIN"
  else
    min_flag="-mios-simulator-version-min=$IOS_MIN"
  fi
  local cpu_family="aarch64"
  [[ "$arch" == "x86_64" ]] && cpu_family="x86_64"
  local lto_arg=""
  [[ "${ENABLE_LTO_DEPS:-1}" != "0" ]] && lto_arg=", '-flto=thin'"
  local vis_arg=""
  [[ "${VIS_HIDDEN:-1}" != "0" ]] && vis_arg=", '-fvisibility=hidden', '-fvisibility-inlines-hidden'"
  # mpv C-only eh_frame trim, injected INTO the cross-file c_args (NOT via a
  # command-line -Dc_args, which would OVERRIDE the array and drop -arch/-isysroot
  # — that breaks meson's iOS-SDK symbol checks like kAudioUnitSubType_RemoteIO).
  local ehf_arg="" _f
  for _f in $(eh_frame_cflags); do ehf_arg="$ehf_arg, '$_f'"; done
  # mpv orchestration code favours size: -Oz (placed after meson's own
  # -Os so it wins). DSP stays in ffmpeg/rubberband, untouched by this.
  ehf_arg="$ehf_arg, '-Oz'"
  cat > "$file" << EOF
[binaries]
c = '${CC_BIN}'
cpp = '${CXX_BIN}'
objc = '${CC_BIN}'
objcpp = '${CXX_BIN}'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sysroot'${lto_arg}${vis_arg}${ehf_arg}]
cpp_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sysroot'${lto_arg}${vis_arg}]
objc_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sysroot'${lto_arg}${vis_arg}]
objcpp_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sysroot'${lto_arg}${vis_arg}]
c_link_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sysroot'${lto_arg}]
cpp_link_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sysroot'${lto_arg}]
objc_link_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sysroot'${lto_arg}]
objcpp_link_args = ['-arch', '$arch', '$min_flag', '-isysroot', '$sysroot'${lto_arg}]

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
  cat > "$file" << EOF
[binaries]
c = '${CC_BIN}'
cpp = '${CXX_BIN}'
objc = '${CC_BIN}'
objcpp = '${CXX_BIN}'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
EOF
  echo "$file"
}

# ── meson_setup wrapper (unsets SDKROOT so native sanity check passes) ───────
meson_setup() {
  # SDKROOT pointing at the iOS SDK causes meson's build-machine sanity check
  # to fail (dyld thinks the native binary is a simulator program).
  # The cross-file already carries -isysroot, so SDKROOT is not needed here.
  (
    unset SDKROOT
    meson setup "$@"
  )
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

  local sysroot; sysroot="$(sdk_path "$sdk")"
  # Note: Do NOT export SDKROOT here.  The -isysroot flag in CFLAGS / cross-file
  # is sufficient for cross-compilation, and exporting SDKROOT causes dyld to
  # reject native (build-machine) binaries during meson/ninja code-generation.

  log "═══ Slice: $sdk / $arch ═══"

  # Ordine: base → [font] → audio → core
  # Font chain — built ONLY when libass is kept (strip_libass disabled in
  # Settings ▸ Patches). By default libass is stripped from mpv
  # (patch_strip_libass.py), so freetype/harfbuzz/fontconfig/fribidi/libass —
  # plus their font-only deps expat + libpng — are unreferenced and skipped.
  slice_zlib       "$sdk" "$arch" "$prefix" "$cf"
  slice_bzip2      "$sdk" "$arch" "$prefix" "$cf"
  slice_xz         "$sdk" "$arch" "$prefix" "$cf"
  if ! libass_stripped; then
    slice_expat      "$sdk" "$arch" "$prefix" "$cf"
    slice_libpng     "$sdk" "$arch" "$prefix" "$cf"
    slice_freetype   "$sdk" "$arch" "$prefix" "$cf"
    slice_fribidi    "$sdk" "$arch" "$prefix" "$cf"
    slice_harfbuzz   "$sdk" "$arch" "$prefix" "$cf"
    slice_freetype2  "$sdk" "$arch" "$prefix" "$cf"
    slice_fontconfig "$sdk" "$arch" "$prefix" "$cf"
    slice_libass     "$sdk" "$arch" "$prefix" "$cf"
  fi
  slice_speexdsp   "$sdk" "$arch" "$prefix" "$cf"
  slice_rubberband "$sdk" "$arch" "$prefix" "$cf"
  slice_openssl    "$sdk" "$arch" "$prefix" "$cf"
  slice_libsmb2    "$sdk" "$arch" "$prefix" "$cf"
  slice_libxml2    "$sdk" "$arch" "$prefix" "$cf"
  slice_ffmpeg     "$sdk" "$arch" "$prefix" "$cf" "$sysroot"
  slice_libplacebo "$sdk" "$arch" "$prefix" "$cf"
  slice_mpv        "$sdk" "$arch" "$prefix" "$cf"
}

# ── Macro helper: cmake statico ──────────────────────────────────────────────
cmake_static() {
  local sdk="$1" arch="$2" prefix="$3" srcdir="$4"; shift 4
  local bdir="$BUILD_DIR/build/$(basename "$srcdir")-${sdk}-${arch}"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$srcdir" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_SYSROOT="$(sdk_path "$sdk")" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
    -DCMAKE_SYSTEM_NAME="iOS" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    "$@" \
    -GNinja
  ninja -j"$JOBS"
  ninja install
  popd >/dev/null
}

# ── Singole librerie (pattern: check sentinel → build) ───────────────────────

slice_zlib() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libz.a" ]] && return
  log "zlib ($sdk/$arch)..."
  local src="$BUILD_DIR/src/zlib-$ZLIB_VERSION.tar.gz"
  download "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make distclean 2>/dev/null || make clean 2>/dev/null || true
  CFLAGS="$cf -Oz" ./configure --prefix="$prefix" --static
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "zlib ($sdk/$arch) ✓"
}

slice_bzip2() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libbz2.a" ]] && return
  log "bzip2 ($sdk/$arch)..."
  local src="$BUILD_DIR/src/bzip2-$BZIP2_VERSION.tar.gz"
  download "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make clean 2>/dev/null || true
  make -j"$JOBS" CC="clang" CFLAGS="$cf -Oz -D_FILE_OFFSET_BITS=64" AR="ar" RANLIB="ranlib" libbz2.a
  install -m 644 libbz2.a "$prefix/lib/"
  install -m 644 bzlib.h  "$prefix/include/"
  popd >/dev/null
  ok "bzip2 ($sdk/$arch) ✓"
}

slice_xz() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/liblzma.a" ]] && return
  log "xz ($sdk/$arch)..."
  local src="$BUILD_DIR/src/xz-$XZ_VERSION.tar.gz"
  download "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make distclean 2>/dev/null || make clean 2>/dev/null || true
  local host="aarch64-apple-darwin"
  [[ "$arch" == "x86_64" ]] && host="x86_64-apple-darwin"

  CFLAGS="$cf -Oz" ./configure --prefix="$prefix" --host="$host" --enable-static --disable-shared \
    --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "xz ($sdk/$arch) ✓"
}

slice_expat() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libexpat.a" ]] && return
  log "expat ($sdk/$arch)..."
  local src="$BUILD_DIR/src/expat-$LIBEXPAT_VERSION.tar.gz"
  download "https://github.com/libexpat/libexpat/releases/download/R_$(echo "$LIBEXPAT_VERSION" | tr . _)/expat-${LIBEXPAT_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make distclean 2>/dev/null || make clean 2>/dev/null || true
  local host="aarch64-apple-darwin"
  [[ "$arch" == "x86_64" ]] && host="x86_64-apple-darwin"

  CFLAGS="$cf -O2" ./configure --prefix="$prefix" --host="$host" --enable-static --disable-shared --without-docbook --without-examples --without-tests
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "expat ($sdk/$arch) ✓"
}

slice_libxml2() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libxml2.a" ]] && return
  log "libxml2 ($sdk/$arch)..."
  local src="$BUILD_DIR/src/libxml2-$LIBXML2_VERSION.tar.xz"
  download "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-${LIBXML2_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make distclean 2>/dev/null || make clean 2>/dev/null || true
  local host="aarch64-apple-darwin"
  [[ "$arch" == "x86_64" ]] && host="x86_64-apple-darwin"
  CFLAGS="$cf -Oz" LDFLAGS="$cf" ./configure --prefix="$prefix" --host="$host" \
    --enable-static --disable-shared \
    --without-python --without-readline --without-history \
    --without-http --without-ftp --without-html \
    --without-legacy --without-docbook --without-catalog \
    --without-schematron --without-modules --without-debug \
    --without-iconv --without-lzma --without-zlib
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "libxml2 ($sdk/$arch) ✓"
}

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
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" meson_setup "$dir" \
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
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" meson_setup "$dir" \
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
    -DCMAKE_SYSTEM_NAME="iOS" \
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
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" meson_setup "$dir" \
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

slice_speexdsp() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libspeexdsp.a" ]] && return
  log "speexdsp ($sdk/$arch)..."
  local src="$BUILD_DIR/src/speexdsp-$SPEEXDSP_VERSION.tar.gz"
  download "https://downloads.xiph.org/releases/speex/speexdsp-${SPEEXDSP_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make distclean 2>/dev/null || make clean 2>/dev/null || true
  local host="aarch64-apple-darwin"
  [[ "$arch" == "x86_64" ]] && host="x86_64-apple-darwin"

  CFLAGS="$cf -O2" ./configure --prefix="$prefix" --host="$host" --enable-static --disable-shared
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "speexdsp ($sdk/$arch) ✓"
}

slice_rubberband() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/librubberband.a" ]] && return
  log "rubberband ($sdk/$arch)..."
  local src="$BUILD_DIR/src/rubberband-$RUBBERBAND_VERSION.tar.bz2"
  download "https://breakfastquay.com/files/releases/rubberband-${RUBBERBAND_VERSION}.tar.bz2" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  # rubberband 4.0+ uses unqualified `size_t` in src/common/mathmisc.{h,cpp};
  # modern gcc/clang under -std=c++20 rejects it. Inject <stddef.h>. Idempotent.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/rubberband/patch_rubberband_size_t.py" "$dir"
  local bdir="$BUILD_DIR/build/rubberband-${sdk}-${arch}"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" meson_setup "$dir" \
    --prefix="$prefix" --buildtype=release --default-library=static \
    -Dfft=builtin -Dresampler=speex \
    -Dladspa=disabled -Dvamp=disabled -Djni=disabled \
    --cross-file="$(write_ios_cross "$sdk" "$arch")" \
    --native-file="$(write_native_file)"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "rubberband ($sdk/$arch) ✓"
}

slice_openssl() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  # OpenSSL Configure honours the exported CC/CFLAGS/LDFLAGS set in
  # build_slice (cf carries -arch + -isysroot). The Configure target
  # depends on the SDK, not the arch — the simulator target is xcrun-
  # driven and covers both arm64 and x86_64.
  local openssl_target
  case "$sdk" in
    iphoneos)         openssl_target="ios64-cross"        ;;
    iphonesimulator)  openssl_target="iossimulator-xcrun" ;;
    *) die "no OpenSSL target mapping for iOS sdk: $sdk" ;;
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
    -DCMAKE_SYSTEM_NAME="iOS" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_LIBDIR=lib
  make -j"$JOBS"
  make install
  apply_libsmb2_post_install_fixes "$prefix" "ios"
  popd >/dev/null
  ok "libsmb2 ($sdk/$arch) ✓"
}

slice_libplacebo() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4"
  [[ -f "$prefix/lib/libplacebo.a" ]] && return 0
  log "libplacebo ($sdk/$arch)..."
  local gitdir="$BUILD_DIR/src/libplacebo-git"
  [[ -d "$gitdir/.git" ]] || download_git "https://code.videolan.org/videolan/libplacebo.git" "$gitdir" "v$LIBPLACEBO_VERSION"
  git -C "$gitdir" submodule update --init --recursive
  apply_libplacebo_patches "$gitdir"
  local bdir="$BUILD_DIR/build/libplacebo-${sdk}-${arch}"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  meson_setup "$gitdir" \
    --prefix="$prefix" --buildtype=release --default-library=static \
    -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled -Dopengl=disabled \
    -Dd3d11=disabled -Ddemos=false -Dtests=false \
    --cross-file="$(write_ios_cross "$sdk" "$arch")" \
    --native-file="$(write_native_file)"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "libplacebo ($sdk/$arch) ✓"
}

slice_ffmpeg() {
  local sdk="$1" arch="$2" prefix="$3" cf="$4" sysroot="$5"
  [[ -f "$prefix/lib/libavcodec.a" ]] && return
  log "ffmpeg ($sdk/$arch)..."
  local src="$BUILD_DIR/src/ffmpeg-$FFMPEG_VERSION.tar.gz"
  download "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"

  # ── Patch FFmpeg (libsmb2, mov advanced_editlist, DASH keep-alive) ───────
  apply_ffmpeg_patches "$dir"

  local bdir="$BUILD_DIR/build/ffmpeg-${sdk}-${arch}"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null

  local min_flag target_os
  if [[ "$sdk" == "iphoneos" ]]; then
    min_flag="-miphoneos-version-min=$IOS_MIN"
    target_os="ios"
  else
    min_flag="-mios-simulator-version-min=$IOS_MIN"
    target_os="ios_simulator"
  fi

  # ── ffmpeg: smart audio-only build (see scripts/shared/_audio_only.sh) ─────────────
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  "$dir/configure" \
    --prefix="$prefix" \
    $(ffmpeg_common_args) \
    --enable-cross-compile \
    --arch="$arch" \
    --target-os=darwin \
    --cc="$CC_BIN" --cxx="$CXX_BIN" \
    --extra-cflags="-arch $arch $min_flag -isysroot $sysroot -I$prefix/include -O2 $(eh_frame_cflags)" \
    --extra-ldflags="-arch $arch $min_flag -isysroot $sysroot -L$prefix/lib" \
    --disable-videotoolbox \
    --enable-audiotoolbox
  verify_ffmpeg_config "$bdir" "ios"
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "ffmpeg ($sdk/$arch) ✓"
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
  local dir="$BUILD_DIR/src/mpv-${sdk}_${arch}"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    tar -xzf "$src" --strip-components=1 -C "$dir"
  fi

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
  # Inject the export filter into mpv's libmpv `library()` call so ld64
  # only exposes mpv_* in the final dylib's symbol table.
  if [[ "${VIS_HIDDEN:-1}" != "0" ]]; then
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/apple/patch_export_filter.py" \
      "$dir" "$SCRIPT_DIR/shared/mpv.exports" "$prefix"
  fi
  # 9 patches shared across every platform (1 required + 8 optional) —
  # see scripts/shared/_audio_only.sh.
  apply_mpv_patches_common "$dir"

  local bdir="$BUILD_DIR/build/mpv-${sdk}-${arch}"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  meson_setup "$dir" \
    --prefix="$prefix" \
    --buildtype=release \
    --default-library=shared \
    --cross-file="$(write_ios_cross "$sdk" "$arch")" \
    --native-file="$(write_native_file)" \
    $(mpv_common_args) \
    -Dswift-build=disabled \
    -Davfoundation=enabled \
    -Daudiounit=enabled
  verify_mpv_config "$bdir" "ios"
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
    # Re-sign the Mach-O AFTER the last edit (bitcode_strip / install_name_tool /
    # strip -x all rewrite the binary and invalidate the linker's adhoc signature).
    # A broken-signature dylib SIGKILLs on dlopen on Apple Silicon (iOS Simulator
    # host loads, direct loads); a consumer app re-signs on embed, but the later
    # `codesign --deep` on the xcframework does NOT reliably re-sign this inner
    # Mach-O, so sign it explicitly here. Matches the macOS build.
    # --identifier is MANDATORY: the Info.plist below sets CFBundleIdentifier to
    # com.ales-drnz.libmpv, and iOS installd rejects a device install when a
    # framework's code-signing identifier != its CFBundleIdentifier
    # (MismatchedBundleIDSigningIdentifier). Signing a bare Mach-O with no
    # --identifier defaults to `libmpv-<hash>` → broken installs. Xcode preserves
    # this identifier when it re-signs on embed, so it MUST be correct here.
    codesign -s - --force --identifier com.ales-drnz.libmpv "$fw/libmpv" 2>/dev/null || true

    # Export-filter hygiene (mirrors the macOS sanity check): the exports list
    # is `_mpv_*`, so with it applied we expect ~60 exported (T) symbols —
    # essentially just the public mpv_* C API. A blown-up count means the filter
    # was dropped and this slice is leaking ffmpeg/libass internals that
    # clash with other Flutter plugins linking the same symbols.
    if [[ "${VIS_HIDDEN:-1}" != "0" ]]; then
      local _total_syms
      _total_syms="$(nm -gU "$fw/libmpv" 2>/dev/null | grep -c ' T ' || echo 0)"
      ok "iOS slice symbols: $_total_syms total ($(basename "$fw"))"
      if [[ "$_total_syms" -gt 200 ]]; then
        die "Export-filter regression: expected ~60 exported symbols but" \
            "got $_total_syms in this iOS slice — verify patch_export_filter.py" \
            "bound the exported-symbols list into the final link."
      fi
    fi

    cp -r "$headers_src"/* "$fw/Headers/" 2>/dev/null || true
    cat > "$fw/Modules/module.modulemap" <<'EOF'
framework module mpv {
  umbrella header "client.h"
  export *
  module * { export * }
}
EOF
    # Required Info.plist. CFBundleExecutable must match the binary filename
    # (here `libmpv`, no extension) — Apple validation tools reject mismatches.
    cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>libmpv</string>
<key>CFBundleIdentifier</key><string>com.ales-drnz.libmpv</string>
<key>CFBundleName</key><string>libmpv</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>${MPV_VERSION}</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>${IOS_MIN}</string>
</dict></plist>
EOF
    # Privacy manifest declaring the required-reason APIs libmpv uses
    # internally (file timestamps via fstat for cache files; monotonic clock
    # via clock_gettime for playback timing). Mandatory since May 2024 for
    # any third-party SDK that touches these APIs.
    cat > "$fw/PrivacyInfo.xcprivacy" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSPrivacyTracking</key>
  <false/>
  <key>NSPrivacyCollectedDataTypes</key>
  <array/>
  <key>NSPrivacyAccessedAPITypes</key>
  <array>
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array><string>3B52.1</string></array>
    </dict>
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSPrivacyAccessedAPICategorySystemBootTime</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array><string>35F9.1</string></array>
    </dict>
  </array>
</dict>
</plist>
EOF
  }

  local release_dir="$LIBMPV_SCRIPTS_ROOT/builds/release"
  mkdir -p "$release_dir"

  local xcodebuild_args=("-create-xcframework")

  # Device slice (iphoneos arm64).
  if [[ "${ONLY_SIMULATOR:-0}" != "1" ]]; then
    local device_fw="$BUILD_DIR/libmpv.framework_device/libmpv.framework"
    # `cp -L` follows the libmpv.dylib -> libmpv.<soversion>.dylib symlink
    # produced by meson, giving us a real file we can rename to plain
    # `libmpv` inside the framework.
    local device_dylib="$BUILD_DIR/libmpv_device.dylib"
    cp -L "$PREFIX_BASE/iphoneos_arm64/lib/libmpv.dylib" "$device_dylib"
    build_dynamic_framework \
      "$device_dylib" \
      "$PREFIX_BASE/iphoneos_arm64/include/mpv" \
      "$device_fw"
    xcodebuild_args+=("-framework" "$device_fw")
  fi

  # Simulator slice (iphonesimulator arm64 + x86_64 lipo'd into a fat dylib).
  if [[ "${SKIP_SIMULATOR:-0}" != "1" ]]; then
    local sim_fw="$BUILD_DIR/libmpv.framework_sim/libmpv.framework"
    local sim_dylib="$BUILD_DIR/libmpv_sim.dylib"
    local lipo_args=()
    for sim_arch in $SIM_ARCHS; do
      lipo_args+=("$PREFIX_BASE/iphonesimulator_${sim_arch}/lib/libmpv.dylib")
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
      "$PREFIX_BASE/iphonesimulator_${first_sim_arch}/include/mpv" \
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
  local out_zip="$release_dir/libmpv_ios.xcframework.zip"
  rm -f "$out_zip"
  pushd "$OUTPUT_DIR" >/dev/null
  zip -r "$out_zip" "libmpv.xcframework" >/dev/null
  popd >/dev/null
  ok "Output: $out_zip"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║   build_libmpv_ios.sh — mpv $MPV_VERSION (dynamic xcframework) ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  check_tools
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
  echo "║  iOS build complete!                                         ║"
  echo "║  Output: builds/release/libmpv_ios.xcframework.zip           ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
}

main "$@"
