#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# build_libmpv_android.sh
#
# Compiles mpv 0.41.0 as a shared library for Android.
#
# === OUTPUT FORMATS AND LOCATIONS ===
# Target Dir:  builds/release/
# Output File: libmpv_android-<abi>.so  (one per ABI; Shared Library)
# 
# === SYSTEM & HARDWARE SPECS ===
# Target OS:   Android (API Level 24 / Android 7.0 Nougat or newer)
# Target Arch: arm64-v8a + x86_64 by default (physical devices + emulators;
#              armeabi-v7a and x86 also supported via ABIS)
# Compiler:    Android NDK (LLVM Clang) statically linking libc++_static.a
#
# Usage (from project root):
#   chmod +x scripts/build_libmpv_android.sh
#   ./scripts/build_libmpv_android.sh
#
# Options (environment variables):
#   ANDROID_NDK_ROOT=/path/to/ndk   (else searched in known SDK locations; NDK r28c auto-downloaded if absent)
#   ANDROID_API=24                   (default: 24 — minSdkVersion)
#   MPV_VERSION=0.41.0              (default: 0.41.0)
#   ABIS="arm64-v8a armeabi-v7a x86_64 x86"  (default: arm64-v8a x86_64)
#   JOBS=N
#   FORCE_DOWNLOAD=1                 (redownload sources even if cached)
#   KEEP_BUILD=1                     (preserve all of BUILD_DIR for inspection)
#   WIPE_ALL=1                       (also delete the src/ download cache + ndk/)
#   SKIP_SIMULATOR=1                 (skips building emulator architectures x86/x86_64)
#   ONLY_SIMULATOR=1                 (builds ONLY emulator architectures)
#   ENABLE_LTO_DEPS=0                (disable ThinLTO on static deps; default on)
#   VIS_HIDDEN=0                     (export every internal symbol; default hides them)
#   SECTION_GC=0                     (disable section-based dead-stripping; default on)
#
# Requirements: cmake, ninja, nasm, python3, git, curl
#            On macOS also: clang (Xcode CLT). libiconv is cross-compiled, not taken from the host.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared across all build_libmpv_<platform>.sh scripts
source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"
source "$SCRIPT_DIR/shared/_audio_only.sh"
source "$SCRIPT_DIR/build_openssl.sh"

ANDROID_API="${ANDROID_API:-24}"
# Guard: this library officially supports Android 7.0+ (API 24+). Building against
# a lower API would produce a .so that contradicts the Gradle minSdk and README.
if ! [[ "$ANDROID_API" =~ ^[0-9]+$ ]] || (( ANDROID_API < 24 )); then
  echo "ERROR: ANDROID_API must be >= 24 (got '$ANDROID_API'). Android 7.0+ is the supported floor." >&2
  exit 1
fi
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"

if [[ "${SKIP_SIMULATOR:-0}" == "1" ]]; then
  ABIS="${ABIS:-arm64-v8a}"
elif [[ "${ONLY_SIMULATOR:-0}" == "1" ]]; then
  ABIS="${ABIS:-x86_64}"
else
  ABIS="${ABIS:-arm64-v8a x86_64}"
fi


# Android-only dependency versions (centralised ones live in _versions.sh)
LIBPLACEBO_VERSION="6.338.2"
LIBSMB2_TAG="v${LIBSMB2_VERSION}"

NDK_VERSION="r28c"
# Maps letter-format → semantic-version. Android Studio installs the NDK as
# 28.2.13676358, while Google's zip is named android-ndk-r28c. Both forms are
# searched among the candidates below.
NDK_SEMVER="28.2.13676358"
BUILD_DIR="${BUILD_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work/Android}"
PREFIX_BASE="$BUILD_DIR/prefix"

# ── Mirror all stdout + stderr to a timestamped log file ─────────────────────
# Every invocation gets its own file so we can diff across runs. Each line
# in the log is prefixed with [YYYY-MM-DD HH:MM:SS] so we can measure how
# long each phase of the build actually took (the terminal stays clean —
# timestamps live only in the file). Old logs (>20) are pruned automatically.
LOG_DIR="$LIBMPV_SCRIPTS_ROOT/builds/logs"
mkdir -p "$LOG_DIR"
ls -t "$LOG_DIR"/build_android_*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
LOG_FILE="$LOG_DIR/build_android_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee >(while IFS= read -r line; do
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
done >> "$LOG_FILE")) 2>&1
echo "════════════════════════════════════════════════════════════"
echo "Build started: $(date)"
echo "Log file:      $LOG_FILE"
echo "FFmpeg:        $FFMPEG_VERSION   mpv: $MPV_VERSION"
echo "════════════════════════════════════════════════════════════"

# Logging helpers (log / ok / warn / err / die / fail) come from _helpers.sh

# ── NDK setup ─────────────────────────────────────────────────────────────────
find_or_download_ndk() {
  # 1. Environment variable
  if [[ -n "${ANDROID_NDK_ROOT:-}" && -d "$ANDROID_NDK_ROOT" ]]; then
    ok "NDK found: $ANDROID_NDK_ROOT"
    return
  fi
  local candidates=(
    "$BUILD_DIR/ndk/android-ndk-${NDK_VERSION}"
    "$HOME/Library/Android/sdk/ndk/${NDK_SEMVER}"
    "$HOME/Android/Sdk/ndk/${NDK_SEMVER}"
    "/usr/local/lib/android/sdk/ndk/${NDK_SEMVER}"
    "$HOME/Library/Android/sdk/ndk/${NDK_VERSION}"
    "$HOME/Android/Sdk/ndk/${NDK_VERSION}"
    "/usr/local/lib/android/sdk/ndk/${NDK_VERSION}"
    "$HOME/Library/Android/sdk/ndk-bundle"
    "${TMPDIR:-/tmp}/mpv_android_build/ndk/android-ndk-${NDK_VERSION}"
  )
  for c in "${candidates[@]}"; do
    if [[ -d "$c" ]]; then
      export ANDROID_NDK_ROOT="$c"
      ok "NDK found: $ANDROID_NDK_ROOT"
      return
    fi
  done
  
  # 2.5 Dynamic search in common bases
  for base in "$HOME/Library/Android/sdk/ndk" "$HOME/Android/Sdk/ndk" "/usr/local/lib/android/sdk/ndk"; do
    if [[ -d "$base" ]]; then
      local latest_ndk
      latest_ndk="$(ls -d "$base"/* 2>/dev/null | grep -Ev 'ndk-bundle' | sort -V | tail -1)"
      if [[ -n "$latest_ndk" && -d "$latest_ndk" ]]; then
        export ANDROID_NDK_ROOT="$latest_ndk"
        ok "NDK found: $ANDROID_NDK_ROOT"
        return
      fi
    fi
  done
  # 3. Download NDK
  warn "Android NDK not found. Downloading NDK ${NDK_VERSION}..."
  local ndk_dir="$BUILD_DIR/ndk"
  mkdir -p "$ndk_dir"
  local host_tag
  if [[ "$(uname)" == "Darwin" ]]; then
    host_tag="darwin"
  else
    host_tag="linux"
  fi
  # Note: Google ships a single Darwin zip — the contained toolchain has both
  # arm64 and x86_64 binaries, with arm64 picked automatically on Apple Silicon.
  local url="https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-${host_tag}.zip"
  curl -fsSL --retry 3 -o "$ndk_dir/ndk.zip" "$url" || fail "NDK download failed"
  # Clean any partial/previous extract first, then extract non-interactively
  # (-o). A leftover tree makes plain `unzip` prompt "replace? [y]es,[n]o,…",
  # and with no TTY in the container it reads EOF and aborts mid-extract,
  # leaving a broken NDK.
  rm -rf "$ndk_dir/android-ndk-${NDK_VERSION}"
  unzip -qo "$ndk_dir/ndk.zip" -d "$ndk_dir"
  rm -f "$ndk_dir/ndk.zip"  # ~1 GB archive — not needed once extracted
  export ANDROID_NDK_ROOT="$(ls -d "$ndk_dir/android-ndk-${NDK_VERSION}" 2>/dev/null | head -1)"
  [[ -d "$ANDROID_NDK_ROOT" ]] || fail "NDK not found after extraction"
  ok "NDK installed: $ANDROID_NDK_ROOT"
}

# ── Map ABI → target triple ───────────────────────────────────────────────────
abi_to_triple() {
  case "$1" in
    arm64-v8a)   echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "armv7a-linux-androideabi" ;;
    x86_64)      echo "x86_64-linux-android" ;;
    x86)         echo "i686-linux-android" ;;
    *) fail "Unknown ABI: $1" ;;
  esac
}

abi_to_arch() {
  case "$1" in
    arm64-v8a)   echo "aarch64" ;;
    armeabi-v7a) echo "arm" ;;
    x86_64)      echo "x86_64" ;;
    x86)         echo "x86" ;;
  esac
}

abi_to_cpu_family() {
  case "$1" in
    arm64-v8a)   echo "aarch64" ;;
    armeabi-v7a) echo "arm" ;;
    x86_64)      echo "x86_64" ;;
    x86)         echo "x86" ;;
  esac
}

# ── Toolchain paths ────────────────────────────────────────────────────────────
ndk_toolchain() {
  # The NDK ships a single prebuilt directory per host OS — `darwin-x86_64`
  # for macOS and `linux-x86_64` for Linux — even on Apple Silicon (the
  # toolchain is universal, picks the right slice via Rosetta or natively).
  local host_tag
  if [[ "$(uname)" == "Darwin" ]]; then
    host_tag="darwin-x86_64"
  else
    host_tag="linux-x86_64"
  fi
  echo "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$host_tag"
}

ndk_cc() {
  local abi="$1"
  local triple; triple="$(abi_to_triple "$abi")"
  local tc; tc="$(ndk_toolchain)"
  # armeabi-v7a usa armv7a ma il binario clang ha il prefisso armv7a
  echo "$tc/bin/${triple}${ANDROID_API}-clang"
}

ndk_cxx() {
  local abi="$1"; echo "$(ndk_cc "$abi")++"
}

ndk_ar() {
  local tc; tc="$(ndk_toolchain)"
  echo "$tc/bin/llvm-ar"
}

ndk_ranlib() {
  local tc; tc="$(ndk_toolchain)"
  echo "$tc/bin/llvm-ranlib"
}

ndk_strip() {
  local tc; tc="$(ndk_toolchain)"
  echo "$tc/bin/llvm-strip"
}

# Download / git clone / extract helpers come from _helpers.sh

# ── Meson cross-file for Android ──────────────────────────────────────────────
write_android_cross() {
  local abi="$1"
  local prefix="$2"
  local file="$BUILD_DIR/meson_cross_android_${abi}.ini"
  local triple; triple="$(abi_to_triple "$abi")"
  local cpu_family; cpu_family="$(abi_to_cpu_family "$abi")"
  local arch; arch="$(abi_to_arch "$abi")"
  local cc; cc="$(ndk_cc "$abi")"
  local cxx; cxx="$(ndk_cxx "$abi")"
  local ar; ar="$(ndk_ar)"
  local strip; strip="$(ndk_strip)"
  local lto_arg=""
  [[ "${ENABLE_LTO_DEPS:-1}" != "0" ]] && lto_arg=", '-flto=thin'"
  local vis_arg=""
  [[ "${VIS_HIDDEN:-1}" != "0" ]] && vis_arg=", '-fvisibility=hidden', '-fvisibility-inlines-hidden'"
  local sec_arg=""
  [[ "${SECTION_GC:-1}" != "0" ]] && sec_arg=", '-ffunction-sections', '-fdata-sections'"
  cat > "$file" << EOF
[binaries]
c = '$cc'
cpp = '$cxx'
ar = '$ar'
strip = '$strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-I${prefix}/include'${lto_arg}${vis_arg}${sec_arg}]
cpp_args = ['-I${prefix}/include'${lto_arg}${vis_arg}${sec_arg}]
# -static-libstdc++ tells the NDK clang driver to link libc++_static.a +
# libc++abi.a + libunwind.a AT THE END of the link line (correct order for
# static-archive symbol resolution) AND to skip the legacy -lstdc++
# auto-injection. The legacy libstdc++.so shim was removed in API 37, so
# any binary that depends on it crashes on Android 17+.
c_link_args = ['-L${prefix}/lib', '-static-libstdc++'${lto_arg}]
cpp_link_args = ['-L${prefix}/lib', '-static-libstdc++'${lto_arg}]

[host_machine]
system = 'android'
cpu_family = '${cpu_family}'
cpu = '${arch}'
endian = 'little'
EOF
  echo "$file"
}

# ── cmake toolchain file for Android ──────────────────────────────────────────
cmake_android_flags() {
  local abi="$1"
  local prefix="$PREFIX_BASE/$abi"
  echo "-DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake \
    -DANDROID_ABI=$abi \
    -DANDROID_PLATFORM=android-$ANDROID_API \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_DEFAULT_CMP0074=NEW \
    -DCMAKE_FIND_ROOT_PATH=$prefix"
}

# =============================================================================
# Build for a single ABI
# =============================================================================
build_abi() {
  local abi="$1"
  local prefix="$PREFIX_BASE/$abi"
  mkdir -p "$prefix/include" "$prefix/lib/pkgconfig"

  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  # Do NOT export PKG_CONFIG_SYSROOT_DIR, it breaks paths prepending the sysroot to local prefixes.

  local cc; cc="$(ndk_cc "$abi")"
  local cxx; cxx="$(ndk_cxx "$abi")"
  export CC="$cc"
  export CXX="$cxx"
  export AR="$(ndk_ar)"
  export RANLIB="$(ndk_ranlib)"
  export STRIP="$(ndk_strip)"
  local lto_extra vis_extra sec_extra
  lto_extra="$(lto_deps_cflags)"
  vis_extra="$(vis_deps_cflags)"
  sec_extra="$(section_gc_cflags)"
  export CFLAGS="-O2 -fPIC $lto_extra $vis_extra $sec_extra"
  export CXXFLAGS="-O2 -fPIC $lto_extra $vis_extra $sec_extra"
  export LDFLAGS="$lto_extra"

  log "═══ ABI: $abi ═══"

  android_zlib       "$abi" "$prefix"
  android_iconv      "$abi" "$prefix"
  android_bzip2      "$abi" "$prefix"
  android_xz         "$abi" "$prefix"
  android_expat      "$abi" "$prefix"
  android_libpng     "$abi" "$prefix"
  android_freetype   "$abi" "$prefix"
  android_fribidi    "$abi" "$prefix"
  android_harfbuzz   "$abi" "$prefix"
  android_freetype2  "$abi" "$prefix"
  android_fontconfig "$abi" "$prefix"
  android_libass     "$abi" "$prefix"
  android_speexdsp   "$abi" "$prefix"
  android_rubberband "$abi" "$prefix"
  # OpenSSL's android-* targets own their toolchain resolution: they
  # locate `clang` / `llvm-ar` on $PATH and match them against
  # $ANDROID_NDK_ROOT (Configurations/15-android.conf) — an explicit
  # $CC is ignored, and a $CC that isn't a bare `clang` makes the
  # config fall through to a `*-gcc` probe that the NDK can't satisfy.
  # So: run in a subshell with the NDK llvm bin on $PATH and CC/AR
  # unset, letting OpenSSL's own logic drive it. `-D__ANDROID_API__`
  # pins the API to ANDROID_API — without it OpenSSL would target the
  # NDK's *max* API, producing libs that fail to load on older devices.
  local openssl_target
  case "$abi" in
    arm64-v8a)    openssl_target="android-arm64"  ;;
    armeabi-v7a)  openssl_target="android-arm"    ;;
    x86_64)       openssl_target="android-x86_64" ;;
    x86)          openssl_target="android-x86"    ;;
    *) die "no OpenSSL target mapping for Android ABI: $abi" ;;
  esac
  (
    export PATH="$(ndk_toolchain)/bin:$PATH"
    unset CC CXX AR RANLIB STRIP
    build_openssl "$prefix" "$BUILD_DIR" "$openssl_target" \
      "-D__ANDROID_API__=${ANDROID_API}"
  )
  android_libsmb2    "$abi" "$prefix"
  android_libxml2    "$abi" "$prefix"
  android_ffmpeg     "$abi" "$prefix"
  android_libplacebo "$abi" "$prefix"
  android_mpv        "$abi" "$prefix"

  # Copy libmpv.so into builds/release
  local release_dir="$LIBMPV_SCRIPTS_ROOT/builds/release"
  mkdir -p "$release_dir"
  local final_name="libmpv_android-${abi}.so"
  cp "$prefix/lib/libmpv.so" "$release_dir/$final_name"

  "$(ndk_strip)" --strip-unneeded "$release_dir/$final_name" 2>/dev/null || true
  ok "Output: $release_dir/$final_name"
}

# ── Android libraries ─────────────────────────────────────────────────────────

android_zlib() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libz.a" ]] && return
  local src="$BUILD_DIR/src/zlib-$ZLIB_VERSION.tar.gz"
  download "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make clean 2>/dev/null || true
  CC="$(ndk_cc "$abi")" \
  CFLAGS="-O2 -fPIC" \
  ./configure --prefix="$prefix" --static
  make -j"$JOBS" AR="$(ndk_ar)" ARFLAGS="rc" RANLIB="$(ndk_ranlib)"; make install
  popd >/dev/null
  ok "zlib ($abi) ✓"
}

android_iconv() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libiconv.a" ]] && return
  local src="$BUILD_DIR/src/libiconv-$LIBICONV_VERSION.tar.gz"
  download "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-$LIBICONV_VERSION.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make distclean 2>/dev/null || true
  ./configure --prefix="$prefix" --host="$(abi_to_triple "$abi")" --enable-static --disable-shared
  make -j"$JOBS"; make install

  mkdir -p "$prefix/lib/pkgconfig"
  printf "prefix=%s\nexec_prefix=\${prefix}\nlibdir=\${exec_prefix}/lib\nincludedir=\${prefix}/include\n\nName: iconv\nDescription: Character set conversion library\nVersion: %s\nLibs: -L\${libdir} -liconv\nCflags: -I\${includedir}\n" "$prefix" "$LIBICONV_VERSION" > "$prefix/lib/pkgconfig/iconv.pc"
  cp "$prefix/lib/pkgconfig/iconv.pc" "$prefix/lib/pkgconfig/libiconv.pc"

  popd >/dev/null
  ok "iconv ($abi) ✓"
}

android_bzip2() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libbz2.a" ]] && return
  local src="$BUILD_DIR/src/bzip2-$BZIP2_VERSION.tar.gz"
  download "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make clean 2>/dev/null || true
  make -j"$JOBS" \
    CC="$(ndk_cc "$abi")" AR="$(ndk_ar)" RANLIB="$(ndk_ranlib)" \
    CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64" libbz2.a
  install -m 644 libbz2.a "$prefix/lib/"
  install -m 644 bzlib.h  "$prefix/include/"
  popd >/dev/null
  ok "bzip2 ($abi) ✓"
}

android_xz() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/liblzma.a" ]] && return
  local src="$BUILD_DIR/src/xz-$XZ_VERSION.tar.gz"
  download "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  CC="$(ndk_cc "$abi")" AR="$(ndk_ar)" RANLIB="$(ndk_ranlib)" \
  CFLAGS="-O2 -fPIC" \
  ./configure --prefix="$prefix" --host="$(abi_to_triple "$abi")" \
    --enable-static --disable-shared \
    --disable-xz --disable-xzdec --disable-lzmadec \
    --disable-lzmainfo --disable-scripts --disable-doc
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "xz ($abi) ✓"
}

android_expat() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libexpat.a" ]] && return
  local src="$BUILD_DIR/src/expat-$LIBEXPAT_VERSION.tar.gz"
  download "https://github.com/libexpat/libexpat/releases/download/R_$(echo "$LIBEXPAT_VERSION" | tr . _)/expat-${LIBEXPAT_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make clean 2>/dev/null || true
  CC="$(ndk_cc "$abi")" AR="$(ndk_ar)" RANLIB="$(ndk_ranlib)" CFLAGS="-O2 -fPIC" \
  ./configure --prefix="$prefix" --host="$(abi_to_triple "$abi")" \
    --enable-static --disable-shared --without-docbook --without-examples --without-tests
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "expat ($abi) ✓"
}

android_libxml2() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libxml2.a" ]] && return
  local src="$BUILD_DIR/src/libxml2-$LIBXML2_VERSION.tar.xz"
  download "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-${LIBXML2_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make clean 2>/dev/null || true
  CC="$(ndk_cc "$abi")" AR="$(ndk_ar)" RANLIB="$(ndk_ranlib)" CFLAGS="-O2 -fPIC" \
  ./configure --prefix="$prefix" --host="$(abi_to_triple "$abi")" \
    --enable-static --disable-shared \
    --without-python --without-readline --without-history \
    --without-http --without-ftp --without-html \
    --without-legacy --without-docbook --without-catalog \
    --without-schematron --without-modules --without-debug \
    --without-iconv --without-lzma --without-zlib
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "libxml2 ($abi) ✓"
}

android_libpng() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libpng.a" ]] && return
  local src="$BUILD_DIR/src/libpng-$LIBPNG_VERSION.tar.gz"
  download "https://downloads.sourceforge.net/project/libpng/libpng16/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make clean 2>/dev/null || true
  CC="$(ndk_cc "$abi")" AR="$(ndk_ar)" RANLIB="$(ndk_ranlib)" \
  CFLAGS="-O2 -fPIC" CPPFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib" \
  ./configure --prefix="$prefix" --host="$(abi_to_triple "$abi")" \
    --enable-static --disable-shared
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "libpng ($abi) ✓"
}

android_freetype() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libfreetype.a" ]] && return
  local src="$BUILD_DIR/src/freetype-$FREETYPE_VERSION.tar.gz"
  download "https://downloads.sourceforge.net/project/freetype/freetype2/${FREETYPE_VERSION}/freetype-${FREETYPE_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/freetype-r1-android-$abi"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" \
    $(cmake_android_flags "$abi") \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=OFF \
    -DFT_DISABLE_HARFBUZZ=ON \
    -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON \
    -DZLIB_INCLUDE_DIR="$prefix/include" -DZLIB_LIBRARY="$prefix/lib/libz.a" \
    -DPNG_PNG_INCLUDE_DIR="$prefix/include" -DPNG_LIBRARY="$prefix/lib/libpng.a" \
    -GNinja
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "freetype r1 ($abi) ✓"
}

android_fribidi() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libfribidi.a" ]] && return
  local src="$BUILD_DIR/src/fribidi-$FRIBIDI_VERSION.tar.gz"
  download "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/fribidi-android-$abi"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" meson setup "$dir" \
    --prefix="$prefix" --buildtype=release --default-library=static \
    -Ddocs=false -Dtests=false --cross-file="$(write_android_cross "$abi" "$prefix")"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "fribidi ($abi) ✓"
}

android_harfbuzz() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libharfbuzz.a" ]] && return
  local src="$BUILD_DIR/src/harfbuzz-$HARFBUZZ_VERSION.tar.gz"
  download "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/harfbuzz-android-$abi"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" meson setup "$dir" \
    --prefix="$prefix" --buildtype=release --default-library=static \
    -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dicu=disabled \
    -Dtests=disabled -Ddocs=disabled --cross-file="$(write_android_cross "$abi" "$prefix")"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "harfbuzz ($abi) ✓"
}

android_freetype2() {
  local abi="$1" prefix="$2"
  local sentinel="$prefix/.ft_r2_$abi"
  [[ -f "$sentinel" ]] && return
  local src="$BUILD_DIR/src/freetype-$FREETYPE_VERSION.tar.gz"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  rm -rf "$BUILD_DIR/build/freetype-r1-android-$abi"
  local bdir="$BUILD_DIR/build/freetype-r2-android-$abi"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" \
    $(cmake_android_flags "$abi") \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=OFF \
    -DFT_DISABLE_HARFBUZZ=OFF -DFT_REQUIRE_HARFBUZZ=ON \
    -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON \
    -DZLIB_INCLUDE_DIR="$prefix/include" -DZLIB_LIBRARY="$prefix/lib/libz.a" \
    -DPNG_PNG_INCLUDE_DIR="$prefix/include" -DPNG_LIBRARY="$prefix/lib/libpng.a" \
    -DHarfBuzz_DIR="$prefix/lib/cmake/harfbuzz" \
    -GNinja
  ninja -j"$JOBS"; ninja install
  touch "$sentinel"
  popd >/dev/null
  ok "freetype r2 ($abi) ✓"
}

android_fontconfig() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libfontconfig.a" ]] && return
  local src="$BUILD_DIR/src/fontconfig-$FONTCONFIG_VERSION.tar.xz"
  download "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FONTCONFIG_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/fontconfig-android-$abi"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" meson setup "$dir" \
    --prefix="$prefix" --buildtype=release --default-library=static \
    -Dtests=disabled -Dtools=disabled -Ddoc=disabled \
    --cross-file="$(write_android_cross "$abi" "$prefix")"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "fontconfig ($abi) ✓"
}

android_libass() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libass.a" ]] && return
  local src="$BUILD_DIR/src/libass-$LIBASS_VERSION.tar.gz"
  download "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make clean 2>/dev/null || true
  CC="$(ndk_cc "$abi")" AR="$(ndk_ar)" RANLIB="$(ndk_ranlib)" \
  CFLAGS="-O2 -fPIC" LDFLAGS="-L$prefix/lib" PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  ./configure --prefix="$prefix" --host="$(abi_to_triple "$abi")" \
    --enable-static --disable-shared \
    --disable-require-system-font-provider --with-pic
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "libass ($abi) ✓"
}

android_speexdsp() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libspeexdsp.a" ]] && return
  # Source tarball from GitHub mirror — downloads.xiph.org is intermittently
  # unreachable. The GitHub archive has no configure shipped (it's the source
  # repo, not a release tarball), so autogen.sh has to run first.
  local src="$BUILD_DIR/src/speexdsp-SpeexDSP-$SPEEXDSP_VERSION.tar.gz"
  download "https://github.com/xiph/speexdsp/archive/refs/tags/SpeexDSP-${SPEEXDSP_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make clean 2>/dev/null || true
  ./autogen.sh
  CC="$(ndk_cc "$abi")" AR="$(ndk_ar)" RANLIB="$(ndk_ranlib)" CFLAGS="-O2 -fPIC" \
  ./configure --prefix="$prefix" --host="$(abi_to_triple "$abi")" --enable-static --disable-shared
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "speexdsp ($abi) ✓"
}

android_rubberband() {
  local abi="$1" prefix="$2"
  if [[ ! -f "$prefix/lib/librubberband.a" ]]; then
    local src="$BUILD_DIR/src/rubberband-$RUBBERBAND_VERSION.tar.bz2"
    download "https://breakfastquay.com/files/releases/rubberband-${RUBBERBAND_VERSION}.tar.bz2" "$src"
    local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
    # rubberband 4.0+ uses unqualified `size_t` in src/common/mathmisc.{h,cpp};
    # modern gcc/clang under -std=c++20 rejects it. Inject <stddef.h>. Idempotent.
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/rubberband/patch_rubberband_size_t.py" "$dir"
    local bdir="$BUILD_DIR/build/rubberband-android-$abi"; mkdir -p "$bdir"
    pushd "$bdir" >/dev/null
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig" meson setup "$dir" \
      --prefix="$prefix" --buildtype=release --default-library=static \
      -Dfft=builtin -Dresampler=speex \
      -Dladspa=disabled -Dvamp=disabled -Djni=disabled \
      --cross-file="$(write_android_cross "$abi" "$prefix")"
    ninja -j"$JOBS"; ninja install
    popd >/dev/null
    ok "rubberband ($abi) ✓"
  fi

  # Post-install patch — applied on every run so a previously-built
  # prefix that pre-dates this fix gets the patch on the next rerun.
  # rubberband's installed `.pc` only declares `-lrubberband`. On
  # Linux/macOS the math symbols (logf, pow, cos, sincosf, …) live in
  # libc, but Android's bionic puts them in libm. Without `-lm` ffmpeg's
  # configure-time link probe fails with "undefined symbol: logf" and
  # rejects librubberband even though pkg-config sees it. Append `-lm`
  # idempotently so subsequent reruns don't double it up.
  local pc="$prefix/lib/pkgconfig/rubberband.pc"
  if [[ -f "$pc" ]] && ! grep -q '\-lm' "$pc"; then
    awk '/^Libs:/ && !/-lm/ { print $0 " -lm"; next } { print }' "$pc" > "$pc.tmp"
    mv "$pc.tmp" "$pc"
  fi
}

android_libsmb2() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libsmb2.a" ]] && return
  log "libsmb2 $LIBSMB2_TAG ($abi)..."
  local dir="$BUILD_DIR/src/libsmb2"
  download_git "https://github.com/sahlberg/libsmb2.git" "$dir" "$LIBSMB2_TAG"

  # Fix: compat.c uses ENXIO under __ANDROID__ without including errno.h.
  # The file already has #include <errno.h> but only inside #if _WINDOWS blocks.
  # We need an unconditional include at the top of the file.
  local compat="$dir/lib/compat.c"
  if [[ -f "$compat" ]] && ! head -3 "$compat" | grep -q 'errno.h'; then
    sed -i.bak '1a\
#include <errno.h>
' "$compat" && rm -f "$compat.bak"
  fi

  local bdir="$BUILD_DIR/build/libsmb2-android-$abi"
  rm -rf "$bdir"
  mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" \
    $(cmake_android_flags "$abi") \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_LIBDIR=lib
  make -j"$JOBS"
  make install
  apply_libsmb2_post_install_fixes "$prefix" "linux"
  popd >/dev/null
  ok "libsmb2 ($abi) ✓"
}

android_ffmpeg() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libavcodec.a" ]] && return
  log "ffmpeg ($abi)..."
  local src="$BUILD_DIR/src/ffmpeg-$FFMPEG_VERSION.tar.gz"
  download "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"

  # ── Patch FFmpeg (libsmb2, mov advanced_editlist, DASH keep-alive) ───────
  apply_ffmpeg_patches "$dir"

  local bdir="$BUILD_DIR/build/ffmpeg-android-$abi"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null

  local triple; triple="$(abi_to_triple "$abi")"
  local arch; arch="$(abi_to_arch "$abi")"
  local tc; tc="$(ndk_toolchain)"
  local cc; cc="$(ndk_cc "$abi")"

  # Flags for armeabi-v7a: NEON
  local extra_cflags="-O2 -fPIC"
  local extra_config=""
  [[ "$abi" == "armeabi-v7a" ]] && extra_cflags+=" -mfpu=neon -mfloat-abi=softfp"
  [[ "$abi" == "x86" ]] && extra_config="--disable-asm"

  # ── ffmpeg: smart audio-only build (see scripts/shared/_audio_only.sh) ─────────────
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  "$dir/configure" \
    --prefix="$prefix" \
    $(ffmpeg_common_args) \
    --enable-cross-compile \
    --arch="$arch" \
    --target-os=android \
    --cc="$cc" --cxx="$(ndk_cxx "$abi")" \
    --ar="$(ndk_ar)" --ranlib="$(ndk_ranlib)" \
    --strip="$(ndk_strip)" \
    --extra-cflags="$extra_cflags -I$prefix/include" \
    --extra-ldflags="-L$prefix/lib" \
    $extra_config \
    --enable-jni \
    --disable-mediacodec \
    --disable-v4l2-m2m
  verify_ffmpeg_config "$bdir" "android"
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "ffmpeg ($abi) ✓"
}

android_libplacebo() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libplacebo.a" ]] && return 0
  log "libplacebo ($abi)..."
  local gitdir="$BUILD_DIR/src/libplacebo-git"
  [[ -d "$gitdir/.git" ]] || download_git "https://code.videolan.org/videolan/libplacebo.git" "$gitdir" "v$LIBPLACEBO_VERSION"
  git -C "$gitdir" submodule update --init --recursive
  apply_libplacebo_patches "$gitdir"
  local bdir="$BUILD_DIR/build/libplacebo-android-$abi"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  meson setup "$gitdir" \
    --prefix="$prefix" --buildtype=release --default-library=static \
    -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled -Dopengl=disabled \
    -Dd3d11=disabled -Ddemos=false -Dtests=false \
    --cross-file="$(write_android_cross "$abi" "$prefix")"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "libplacebo ($abi) ✓"
}

android_mpv() {
  local abi="$1" prefix="$2"
  [[ -f "$prefix/lib/libmpv.so" ]] && return
  log "mpv $MPV_VERSION ($abi) [shared]..."
  local src="$BUILD_DIR/src/mpv-$MPV_VERSION.tar.gz"
  download "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz" "$src"
  # The mpv patches are NOT idempotent and the source tree is shared across the
  # ABIs of one run (extract() reuses an existing dir). Re-extract a pristine
  # tree for each ABI — cheap, from the cached tarball — so the patches apply
  # exactly once. Without this the 2nd ABI re-patches an already-patched tree and
  # the build dies on a duplicate definition (e.g. mp_property_waveform_data).
  rm -rf "$BUILD_DIR/src/mpv-$MPV_VERSION"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/mpv-android-$abi"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  # ── Apply mpv patches (9 shared: 1 required + 8 optional) ────────────────
  apply_mpv_patches_common "$dir"

  # ── JNI bridge (Android-only) ────────────────────────────────────────────
  # Compile a tiny `.o` containing JNI_OnLoad → av_jni_set_java_vm and
  # pass it as a positional input to the mpv link below. Positional `.o`
  # files are always included (no archive symbol-resolution dance) and
  # are immune to `--exclude-libs=ALL` (which only affects archive
  # members), so JNI_OnLoad stays exported via the Android version
  # script. When the consumer's Kotlin plugin does
  # System.loadLibrary("mpv"), the Android loader fires JNI_OnLoad and
  # ffmpeg's JNI globals get the JavaVM* — required for audiotrack and
  # any mediacodec / content:// path.
  local bridge_src="$LIBMPV_SCRIPTS_ROOT/patches/mpv/android/android_jni_bridge.c"
  local bridge_obj="$bdir/android_jni_bridge.o"
  "$(ndk_cc "$abi")" -fPIC -O2 -c "$bridge_src" -o "$bridge_obj"

  # ELF dynsym hygiene + section dead-strip + self-contained C++ runtime:
  #   --gc-sections           drop unreferenced sections (audio-only build)
  #   --exclude-libs=ALL      hide static-archive symbols from .dynsym
  #   --version-script        export only mpv_*
  #   --no-undefined          fail link if any symbol unresolved (catches
  #                           any future libc++ leak instantly)
  #   -Bstatic … -Bdynamic    statically embed libc++_static.a +
  #                           libc++abi.a + libunwind.a into libmpv.so.
  #                           libstdc++.so (the legacy NDK shim providing
  #                           __gxx_personality_v0 + a few C++ ABI symbols)
  #                           was removed in API 37 — a binary that depends
  #                           on it crashes on Android 17+. The clang driver
  #                           flag `-static-libstdc++` is not enough on its
  #                           own when meson + LTO drives the link directly
  #                           (driver-level lib injection gets bypassed),
  #                           so pin the archives explicitly via -Bstatic.
  #                           They sit AT THE END of the link line so static
  #                           refs from libplacebo / librubberband / ffmpeg
  #                           resolve against them.
  #
  # link_extra must be a bash array, not a string: meson's -D options use
  # whitespace as a list separator inside an array option's value, so the
  # whole `-Dc_link_args=…` chunk has to expand as a SINGLE shell token.
  local link_extra=()
  if [[ "${VIS_HIDDEN:-1}" != "0" || "${SECTION_GC:-1}" != "0" ]]; then
    # Android: Android-specific version script keeps `mpv_*` AND
    # `JNI_OnLoad` global. `--exclude-libs=ALL` is fine here because the
    # JNI bridge enters the link as a positional `.o` (NOT an archive
    # member) — `--exclude-libs` only suppresses exports from archives,
    # so JNI_OnLoad survives into .dynsym and the version script keeps
    # it global.
    local ld_args="-Wl,--gc-sections,--exclude-libs=ALL,--no-undefined"
    [[ "${VIS_HIDDEN:-1}" != "0" ]] && \
      ld_args="$ld_args,--version-script=${SCRIPT_DIR}/shared/mpv_android.ver"
    # Pin C++ runtime statically. -l:<filename>.a forces ld to use that
    # exact static archive (resolved via the NDK clang driver's default
    # library search path). -Bstatic / -Bdynamic flips ld between static
    # and dynamic resolution for the immediately-following -l libs.
    # Kept as a SEPARATE -Wl,... chunk (space-separated from $ld_args
    # within the meson option value) — joining with a comma would emit
    # a literal `-Wl` arg to ld between the two groups.
    local cxx_static="-Wl,-Bstatic,-l:libc++_static.a,-l:libc++abi.a,-l:libunwind.a,-Bdynamic"
    # liblog (-llog) provides __android_log_print, referenced by JNI_OnLoad in
    # the bridge object. It MUST follow $bridge_obj in the link order so the
    # symbol resolves — otherwise --no-undefined (above) makes the link fail
    # with "undefined symbol: __android_log_print".
    link_extra+=("-Dc_link_args=$ld_args $cxx_static $bridge_obj -llog")
    link_extra+=("-Dcpp_link_args=$ld_args $cxx_static $bridge_obj -llog")
  fi

  PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
  meson setup "$dir" \
    --prefix="$prefix" \
    --buildtype=release \
    --default-library=shared \
    --cross-file="$(write_android_cross "$abi" "$prefix")" \
    $(mpv_common_args) \
    -Daudiotrack=enabled \
    -Daaudio=enabled \
    -Dopensles=enabled \
    "${link_extra[@]}"
  verify_mpv_config "$bdir" "android"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null

  # Dynsym hygiene check.
  local total_syms mpv_syms
  total_syms="$("$(ndk_strip)" --strip-unneeded "$prefix/lib/libmpv.so" 2>/dev/null; \
    "$(ndk_toolchain)/bin/llvm-nm" -D --defined-only "$prefix/lib/libmpv.so" 2>/dev/null \
    | grep -c ' T ' || echo 0)"
  mpv_syms="$("$(ndk_toolchain)/bin/llvm-nm" -D --defined-only "$prefix/lib/libmpv.so" 2>/dev/null \
    | grep -c ' T mpv_' || echo 0)"
  ok "mpv shared ($abi) ✓ — symbols: $total_syms total, $mpv_syms mpv_*"
  if [[ "${VIS_HIDDEN:-1}" != "0" && "$total_syms" -gt 200 ]]; then
    warn "Expected ~60 symbols with VIS_HIDDEN=1 but got $total_syms"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║   build_libmpv_android.sh — mpv $MPV_VERSION for Android       ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo "  ABI: $ABIS"
  echo "  API: $ANDROID_API"
  echo ""

  for t in cmake ninja nasm python3 git curl; do
    command -v "$t" &>/dev/null || fail "$t not found"
  done

  find_or_download_ndk
  mkdir -p "$BUILD_DIR/src" "$BUILD_DIR/build"

  for abi in $ABIS; do
    build_abi "$abi"
  done

  # Keep ndk/ and src/ between runs (persistent caches), wipe only build byproducts.
  cleanup_build "$BUILD_DIR"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  Android build complete!                                     ║"
  echo "║  Output: builds/release/libmpv_android-{abi}.so             ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
}

main "$@"
