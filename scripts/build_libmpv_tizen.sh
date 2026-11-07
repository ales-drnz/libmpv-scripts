#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# build_libmpv_tizen.sh
#
# Compiles mpv as libmpv.so for Tizen: armv7l for the TVs (2021 on, Tizen 6.0
# and later, ARM EABI with softfp floats) and x86_64 for the TV emulator.
#
# === OUTPUT ===
# builds/release/libmpv_tizen-<arch>.so
#
# === SYSTEM ===
# Run inside the mpv-build-tizen image (`tizen` stage of docker/Dockerfile):
# clang and lld cross-compile against a sysroot of Tizen 6.0 packages that
# scripts/tizen/tizen_sysroot.py unpacks (glibc 2.30, libgcc of GCC 9.2,
# capi-media-audio-io and capi-media-sound-manager). Small wrappers named
# like a cross toolchain (arm-linux-gnueabi-clang, ...) pass clang the Tizen
# target, the sysroot and the ABI, so every build system takes them as it
# takes gcc. The audio output is ao_tizen (patches/mpv/tizen), the only one;
# ALSA, PulseAudio and PipeWire are not built.
#
# Usage (from project root):
#   ./scripts/build_libmpv_tizen.sh --arch=armv7l
#   ./scripts/build_libmpv_tizen.sh --arch=x86_64
#
# Options (env vars):
#   ARCH=armv7l|x86_64      (default: armv7l; --arch=… overrides)
#   JOBS=N                  (default: nproc)
#   FORCE_DOWNLOAD=1, KEEP_BUILD=1, WIPE_ALL=1, ENABLE_LTO_DEPS=0,
#   VIS_HIDDEN=0, SECTION_GC=0: as in build_libmpv_linux.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"
source "$SCRIPT_DIR/shared/_audio_only.sh"
source "$SCRIPT_DIR/build_openssl.sh"

# ── Parse args ────────────────────────────────────────────────────────────────
ARCH="${ARCH:-armv7l}"
for arg in "$@"; do
  case "$arg" in
    --arch=*)   ARCH="${arg#--arch=}" ;;
    --help|-h)  grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

# Per arch: the triple of the wrappers and of autotools, clang's target (the
# vendor finds the sysroot's GCC 9.2 directory), its ABI flags, and the names
# FFmpeg, meson and OpenSSL know the CPU by.
case "$ARCH" in
  armv7l)
    TRIPLE="arm-linux-gnueabi"
    CLANG_TARGET="armv7l-tizen-linux-gnueabi"
    ABI_FLAGS="-march=armv7-a -mfpu=neon -mfloat-abi=softfp -mthumb"
    MESON_CPU_FAMILY="arm"; MESON_CPU="armv7l"
    OPENSSL_TARGET="linux-armv4"
    OPENSSL_EXTRA=""
    FFMPEG_ARCH_ARGS="--arch=arm --cpu=armv7-a"
    ;;
  x86_64)
    TRIPLE="x86_64-linux-gnu"
    CLANG_TARGET="x86_64-tizen-linux-gnu"
    ABI_FLAGS=""
    MESON_CPU_FAMILY="x86_64"; MESON_CPU="x86_64"
    OPENSSL_TARGET="linux-x86_64"
    OPENSSL_EXTRA=""
    FFMPEG_ARCH_ARGS="--arch=x86_64"
    ;;
  *) die "Unsupported --arch=$ARCH (must be armv7l or x86_64)" ;;
esac

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

LIBPLACEBO_VERSION="7.349.0"
LIBSMB2_TAG="v${LIBSMB2_VERSION}"

BUILD_DIR="${BUILD_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work/Tizen/$ARCH}"
PREFIX="$BUILD_DIR/prefix"
SYSROOT="$BUILD_DIR/sysroot"
TOOLS="$BUILD_DIR/bin"
mkdir -p "$BUILD_DIR" "$PREFIX/include" "$PREFIX/lib" "$TOOLS"

# ── Mirror all stdout + stderr to a timestamped log file ─────────────────────
LOG_DIR="$LIBMPV_SCRIPTS_ROOT/builds/logs"
mkdir -p "$LOG_DIR"
ls -t "$LOG_DIR"/build_tizen-*_*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
LOG_FILE="$LOG_DIR/build_tizen-${ARCH}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee >(while IFS= read -r line; do
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
done >> "$LOG_FILE")) 2>&1
echo "════════════════════════════════════════════════════════════"
echo "Build started: $(date)"
echo "Log file:      $LOG_FILE"
echo "FFmpeg:        $FFMPEG_VERSION   mpv: $MPV_VERSION   target: tizen/$ARCH"
echo "Toolchain:     clang --target=$CLANG_TARGET, sysroot of Tizen 6.0"
echo "════════════════════════════════════════════════════════════"

# ── Sysroot ───────────────────────────────────────────────────────────────────
# Unpacked again when the package list or its checksums changed.
setup_sysroot() {
  local lock="$SCRIPT_DIR/tizen/tizen_sysroot.sha256" stamp="$SYSROOT/.lock"
  if [[ -f "$stamp" ]] && cmp -s "$lock" "$stamp"; then
    ok "sysroot already unpacked"
  else
    python3 -B "$SCRIPT_DIR/tizen/tizen_sysroot.py" "$ARCH" "$SYSROOT"
    cp "$lock" "$stamp"
  fi
  # The packages' .pc files say prefix=/usr: copies with the sysroot's path,
  # apart from the prefix's own, so PKG_CONFIG_SYSROOT_DIR is not needed.
  local pcdir="$BUILD_DIR/sysroot-pkgconfig"
  rm -rf "$pcdir"; mkdir -p "$pcdir"
  local pc
  for pc in "$SYSROOT"/usr/lib/pkgconfig/*.pc "$SYSROOT"/usr/lib64/pkgconfig/*.pc; do
    [[ -f "$pc" ]] || continue
    sed -E "s#^(prefix|exec_prefix|libdir|includedir)=/usr#\1=$SYSROOT/usr#" "$pc" > "$pcdir/$(basename "$pc")"
  done
  SYSROOT_PKGCONFIG="$pcdir"
}

# ── Toolchain: clang behind wrappers named like a cross toolchain ─────────────
setup_toolchain() {
  local tool
  for tool in clang clang++; do
    cat > "$TOOLS/$TRIPLE-$tool" <<EOF
#!/usr/bin/env bash
# Generated by build_libmpv_tizen.sh: $tool for Tizen $ARCH.
exec $tool --target=$CLANG_TARGET --sysroot="$SYSROOT" $ABI_FLAGS -fuse-ld=lld -Wno-unused-command-line-argument "\$@"
EOF
    chmod +x "$TOOLS/$TRIPLE-$tool"
  done
  for tool in ar ranlib nm strip readelf objcopy; do
    ln -sf "$(command -v "llvm-$tool")" "$TOOLS/$TRIPLE-$tool"
  done
  ln -sf "$TRIPLE-clang" "$TOOLS/$TRIPLE-gcc"
  ln -sf "$TRIPLE-clang++" "$TOOLS/$TRIPLE-g++"
  export PATH="$TOOLS:$PATH"

  export CC="$TRIPLE-clang" CXX="$TRIPLE-clang++"
  export AR="$TRIPLE-ar" RANLIB="$TRIPLE-ranlib" NM="$TRIPLE-nm"
  export STRIP="$TRIPLE-strip" READELF="$TRIPLE-readelf" OBJCOPY="$TRIPLE-objcopy"

  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$SYSROOT_PKGCONFIG"
  export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
  export PKG_CONFIG="$TOOLS/$TRIPLE-pkg-config"
  cat > "$PKG_CONFIG" <<EOF
#!/usr/bin/env bash
# Generated by build_libmpv_tizen.sh: the prefix's and the sysroot's .pc files only.
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
exec pkg-config "\$@"
EOF
  chmod +x "$PKG_CONFIG"

  CROSS_MESON_FILE="$BUILD_DIR/cross-tizen-$ARCH.meson"
  cat > "$CROSS_MESON_FILE" <<EOF
# Generated by build_libmpv_tizen.sh.
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
ranlib = '$RANLIB'
strip = '$STRIP'
nm = '$NM'
pkgconfig = '$PKG_CONFIG'
cmake = 'cmake'

[host_machine]
system = 'linux'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF

  CROSS_CMAKE_FILE="$BUILD_DIR/cross-tizen-$ARCH.cmake"
  cat > "$CROSS_CMAKE_FILE" <<EOF
# Generated by build_libmpv_tizen.sh.
set(CMAKE_SYSTEM_NAME      Linux)
set(CMAKE_SYSTEM_PROCESSOR $MESON_CPU)
set(CMAKE_C_COMPILER       $CC)
set(CMAKE_CXX_COMPILER     $CXX)
set(CMAKE_AR     $(command -v "llvm-ar") CACHE FILEPATH "Archiver")
set(CMAKE_RANLIB $(command -v "llvm-ranlib") CACHE FILEPATH "Ranlib")
set(CMAKE_FIND_ROOT_PATH              $PREFIX $SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

  CROSS_AUTOTOOLS_HOST="--host=$TRIPLE"
  FFMPEG_CROSS_ARGS="--enable-cross-compile --cross-prefix=$TRIPLE- --cc=$CC --cxx=$CXX --target-os=linux $FFMPEG_ARCH_ARGS --pkg-config=$PKG_CONFIG"

  LTO_EXTRA="$(lto_deps_cflags)"
  VIS_EXTRA="$(vis_deps_cflags)"
  SEC_EXTRA="$(section_gc_cflags)"
  UNWIND_EXTRA="$(dep_unwind_cflags)"
  export CFLAGS="-O2 -fPIC -I$PREFIX/include $LTO_EXTRA $VIS_EXTRA $SEC_EXTRA $UNWIND_EXTRA"
  export CXXFLAGS="$CFLAGS"
  export CPPFLAGS="-I$PREFIX/include"
  export LDFLAGS="-L$PREFIX/lib $LTO_EXTRA"
}

check_toolchain() {
  local missing=() t
  for t in clang clang++ ld.lld llvm-ar llvm-ranlib llvm-nm llvm-strip llvm-readelf \
           llvm-objcopy meson ninja cmake pkg-config python3 git curl; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [[ ${#missing[@]} -gt 0 ]] && die "Missing toolchain binaries: ${missing[*]}"
  ok "Toolchain OK ($(clang --version | head -1))"
}

# =============================================================================
# Library builds, as in build_libmpv_linux.sh (only what the audio-only Tizen
# libmpv links: libass is stripped and the audio client stubs are not built).
# =============================================================================

build_zlib() {
  [[ -f "$PREFIX/lib/libz.a" ]] && return
  local src="$BUILD_DIR/src/zlib-$ZLIB_VERSION.tar.gz"
  download "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  CHOST="$TRIPLE" CFLAGS="$CFLAGS -Os" ./configure --prefix="$PREFIX" --static
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
  CFLAGS="$CFLAGS -Os" \
  ./configure $CROSS_AUTOTOOLS_HOST --prefix="$PREFIX" --enable-static --disable-shared \
    --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
    --disable-scripts --disable-doc \
    SKIP_WERROR_CHECK=yes
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "xz ✓"
}

build_libxml2() {
  [[ -f "$PREFIX/lib/libxml2.a" ]] && return
  local src="$BUILD_DIR/src/libxml2-$LIBXML2_VERSION.tar.xz"
  download "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-${LIBXML2_VERSION}.tar.xz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
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

build_speexdsp() {
  [[ -f "$PREFIX/lib/libspeexdsp.a" ]] && return
  local src="$BUILD_DIR/src/speexdsp-SpeexDSP-$SPEEXDSP_VERSION.tar.gz"
  download "https://github.com/xiph/speexdsp/archive/refs/tags/SpeexDSP-${SPEEXDSP_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  ./autogen.sh
  # speexdsp's NEON code is for aarch64 and armv7 hard float only.
  ./configure $CROSS_AUTOTOOLS_HOST --prefix="$PREFIX" --enable-static --disable-shared --disable-neon
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "speexdsp ✓"
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
    --prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static \
    -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled \
    -Dopengl=disabled -Dd3d11=disabled -Ddemos=false -Dtests=false
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "libplacebo ✓"
}

build_libsmb2() {
  [[ -f "$PREFIX/lib/libsmb2.a" ]] && return
  log "Building libsmb2 $LIBSMB2_TAG..."
  local dir="$BUILD_DIR/src/libsmb2"
  download_git "https://github.com/sahlberg/libsmb2.git" "$dir" "$LIBSMB2_TAG"
  local bdir="$BUILD_DIR/build/libsmb2"
  rm -rf "$bdir"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  cmake "$dir" -DCMAKE_TOOLCHAIN_FILE="$CROSS_CMAKE_FILE" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -GNinja
  ninja -j"$JOBS"; ninja install
  apply_libsmb2_post_install_fixes "$PREFIX" "linux"
  popd >/dev/null
  ok "libsmb2 ✓"
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

  local bdir="$BUILD_DIR/build/ffmpeg"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  # shellcheck disable=SC2046,SC2086
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
  verify_ffmpeg_config "$bdir" "tizen"
  make -j"$JOBS"; make install
  popd >/dev/null
  ok "ffmpeg ✓"
}

build_mpv() {
  [[ -f "$PREFIX/lib/libmpv.so" ]] && return
  log "Building mpv $MPV_VERSION..."
  local src="$BUILD_DIR/src/mpv-$MPV_VERSION.tar.gz"
  download "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz" "$src"
  rm -rf "$BUILD_DIR/src/mpv-$MPV_VERSION"
  local dir; dir="$(extract "$src" "$BUILD_DIR/src")"
  local bdir="$BUILD_DIR/build/mpv"; mkdir -p "$bdir"
  patch_record_start mpv "$PREFIX"
  apply_mpv_patches_common "$dir"
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/tizen/patch_ao_tizen.py" "$dir"
  record_patch ao_tizen

  # As on Linux (see build_libmpv_linux.sh), with libgcc and libstdc++
  # (libplacebo) linked in: the library needs only glibc and the two audio
  # APIs of the system.
  local link_extra=()
  local ld_args
  ld_args="-static-libgcc -static-libstdc++ -Wl,--gc-sections,--exclude-libs=ALL,--no-undefined,--as-needed$(mpv_elf_size_ldflags none)$(mpv_soname_ldflags)"
  [[ "${VIS_HIDDEN:-1}" != "0" ]] && \
    ld_args="$ld_args,--version-script=${SCRIPT_DIR}/shared/mpv.ver"
  local extra_libs="-lssl -lcrypto -lxml2 -lbz2 -llzma"
  link_extra+=("-Dc_link_args=$ld_args $extra_libs")
  link_extra+=("-Dcpp_link_args=$ld_args $extra_libs")

  pushd "$bdir" >/dev/null
  # shellcheck disable=SC2046
  meson setup "$dir" --cross-file "$CROSS_MESON_FILE" \
    --prefix="$PREFIX" \
    --libdir=lib \
    --buildtype=release \
    --default-library=shared \
    $(mpv_common_args) \
    -Dtizen-audio=enabled \
    -Dalsa=disabled \
    -Dpulse=disabled \
    -Dpipewire=disabled \
    -Dc_args="$(eh_frame_cflags)" \
    "${link_extra[@]}"
  verify_mpv_config "$bdir" "tizen"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  ok "mpv ✓"
}

# =============================================================================
# Finalize: stage the .so, strip it, check what it needs at runtime.
# =============================================================================

finalize() {
  local release_dir="$LIBMPV_SCRIPTS_ROOT/builds/release"
  mkdir -p "$release_dir"
  local src
  src="$(ls "$PREFIX"/lib/libmpv.so.* 2>/dev/null | sort -V | tail -1 || true)"
  [[ -n "$src" ]] || src="$PREFIX/lib/libmpv.so"
  [[ -f "$src" ]] || fail "libmpv.so not found in $PREFIX/lib"
  local out="$release_dir/libmpv_tizen-${ARCH}.so"
  cp "$(readlink -f "$src")" "$out"

  log "Stripping symbols..."
  "$STRIP" --strip-unneeded "$out"
  assert_soname "$out" "$READELF"
  assert_no_relr "$out" "$READELF"
  assert_glibc_floor "$out" "$TIZEN_GLIBC_FLOOR" "$READELF"
  # Only glibc and the audio APIs of the system: anything else would be
  # missing on the TV.
  local needed unexpected
  needed="$(LC_ALL=C "$READELF" -d "$out" | awk '/NEEDED/ {gsub(/[\[\]]/,"",$NF); print $NF}')"
  unexpected="$(grep -Ev '^(libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|ld-linux\.so\.[23]|libcapi-media-audio-io\.so\.0|libcapi-media-sound-manager\.so\.0|libcapi-base-common\.so\.0)$' <<< "$needed" || true)"
  [[ -z "$unexpected" ]] || fail "unexpected runtime dependencies of $out: $(tr '\n' ' ' <<< "$unexpected")"
  grep -qx 'libcapi-media-audio-io.so.0' <<< "$needed" || fail "$out does not link capi-media-audio-io"
  ok "NEEDED: $(tr '\n' ' ' <<< "$needed")"

  write_build_record "tizen-$ARCH" "$PREFIX"
  local licenses=(mpv ffmpeg openssl libplacebo libxml2 zlib bzip2 xz speexdsp)
  patch_on libsmb2 && licenses+=(libsmb2)
  gpl_build && licenses+=(rubberband)
  write_licenses "tizen-$ARCH" "$BUILD_DIR/src" "${licenses[@]}"

  local total_syms
  total_syms="$("$READELF" -W --dyn-syms "$out" 2>/dev/null | awk '$5=="GLOBAL" && $4=="FUNC" && $7!="UND" {n++} END{print n+0}')"
  ok "Symbols: $total_syms exported functions"
  ok "Output: $out"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  libass_stripped || die "the Tizen build has no font stack: keep strip_libass and strip_mpv_dead on"
  gpl_build && die "the Tizen build is LGPL only (no librubberband build here)"
  check_toolchain
  setup_sysroot
  setup_toolchain
  mkdir -p "$BUILD_DIR/src" "$BUILD_DIR/build"

  build_zlib
  build_bzip2
  build_xz
  build_speexdsp
  build_libplacebo
  build_openssl "$PREFIX" "$BUILD_DIR" "$OPENSSL_TARGET" "$OPENSSL_EXTRA"
  build_libsmb2
  build_libxml2
  build_ffmpeg
  build_mpv

  finalize
  cleanup_build "$BUILD_DIR"
  ok "Tizen build complete: builds/release/libmpv_tizen-${ARCH}.so"
}

main "$@"
