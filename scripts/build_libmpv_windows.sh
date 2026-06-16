#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# build_libmpv_windows.sh
#
# Cross-compiles mpv as libmpv.dll for Windows x86_64 / aarch64.
#
# === TOOLCHAINS ===
#   x86_64  — GNU MinGW-w64 (gcc-mingw-w64-x86-64 from Ubuntu apt)
#   aarch64 — llvm-mingw     (clang+lld+ucrt; tarball preinstalled in Docker
#                            image at /opt/llvm-mingw)
#
# === OUTPUT ===
# builds/release/libmpv_windows-<arch>.dll
#   - <arch> is 'x86_64' or 'arm64' (Windows-canonical naming, NOT 'aarch64')
#
# Usage (from project root):
#   ./scripts/build_libmpv_windows.sh --arch=x86_64
#   ./scripts/build_libmpv_windows.sh --arch=aarch64    # internal name
#   ARCH=x86_64 ./scripts/build_libmpv_windows.sh
#
# Options (env vars):
#   ARCH=x86_64|aarch64     (default: x86_64; --arch=… overrides)
#   MPV_VERSION=0.41.0      (default: 0.41.0)
#   JOBS=N                  (default: nproc)
#   FORCE_DOWNLOAD=1        (redownload sources even if cached)
#   KEEP_BUILD=1            (preserve all of BUILD_DIR for inspection)
#   WIPE_ALL=1              (also delete the src/ download cache at the end)
#   ENABLE_LTO_DEPS=0       (disable GCC LTO on static deps; default on)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"
source "$SCRIPT_DIR/shared/_audio_only.sh"
source "$SCRIPT_DIR/shared/_cross.sh"
source "$SCRIPT_DIR/build_openssl.sh"

ROOT="$(resolve_repo_root "$SCRIPT_DIR")" || exit 1

# ── Parse args ────────────────────────────────────────────────────────────────
ARCH="${ARCH:-x86_64}"
for arg in "$@"; do
  case "$arg" in
    --arch=*)  ARCH="${arg#--arch=}" ;;
    --help|-h) grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done
case "$ARCH" in
  x86_64|aarch64) ;;
  *) die "Unsupported --arch=$ARCH (must be x86_64 or aarch64)" ;;
esac

# ── Windows-only dependency versions (centralised ones live in _versions.sh) ──
EXPAT_VERSION="${EXPAT_VERSION:-${LIBEXPAT_VERSION}}"
LIBPLACEBO_VERSION="${LIBPLACEBO_VERSION:-v6.338.2}"
LIBSMB2_TAG="${LIBSMB2_TAG:-v${LIBSMB2_VERSION}}"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
KEEP_BUILD="${KEEP_BUILD:-0}"

BUILD_DIR="${BUILD_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work/Windows/$ARCH}"
DIST="$BUILD_DIR/dist"
SRC="$BUILD_DIR/src"

# ── Cross-compile setup ───────────────────────────────────────────────────────
export CROSS_BUILD_DIR="$BUILD_DIR"
export CROSS_PREFIX_DIR="$DIST"
mkdir -p "$BUILD_DIR" "$DIST/include" "$DIST/lib" "$DIST/lib/pkgconfig" "$SRC"

# llvm-mingw lives outside PATH by default to avoid shadowing the GNU
# MinGW-w64 toolchain (which we use for Windows x86_64). Prepend it here
# only when building aarch64 — the one target where llvm-mingw is the
# only available toolchain.
if [[ "$ARCH" == "aarch64" ]]; then
  export PATH="${LLVM_MINGW_DIR:-/opt/llvm-mingw}/bin:$PATH"
fi

cross_setup windows "$ARCH"
TRIPLE="$CROSS_TRIPLE"

# Sysroot lib path for the link stage. Differs between GNU MinGW (Ubuntu apt
# layout) and llvm-mingw (relocatable tarball).
case "$CROSS_TOOLCHAIN_KIND" in
  gnu)  WIN_SYSROOT_LIB="/usr/${TRIPLE}/lib" ;;
  llvm) WIN_SYSROOT_LIB="${LLVM_MINGW_DIR:-/opt/llvm-mingw}/${TRIPLE}/lib" ;;
esac

# ── Mirror all stdout + stderr to a timestamped log file ─────────────────────
LOG_DIR="$LIBMPV_SCRIPTS_ROOT/builds/logs"
mkdir -p "$LOG_DIR"
ls -t "$LOG_DIR"/build_windows-*_*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
LOG_FILE="$LOG_DIR/build_windows-${ARCH}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee >(while IFS= read -r line; do
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
done >> "$LOG_FILE")) 2>&1
echo "════════════════════════════════════════════════════════════"
echo "Build started: $(date)"
echo "Log file:      $LOG_FILE"
echo "FFmpeg:        $FFMPEG_VERSION   mpv: $MPV_VERSION   target: windows/$ARCH"
echo "Toolchain:     $TRIPLE ($CROSS_TOOLCHAIN_KIND)"
echo "════════════════════════════════════════════════════════════"

# ── Clock skew fix for Docker on Windows hosts ────────────────────────────────
# When Docker mounts a Windows (NTFS) volume into a Linux container, mtime
# can drift hundreds of ms ahead of the container clock. Meson and ninja then
# abort with "clock skew detected". Touch any "future" file mtimes to now.
if [[ -d "$BUILD_DIR" ]]; then
  find "$BUILD_DIR" -newer /proc/1 -exec touch -m {} + 2>/dev/null || true
fi

# ── Toolchain sanity ──────────────────────────────────────────────────────────
MISSING=()
for tool in "$CC" "$CXX" "$AR" "$RANLIB" "$STRIP" "$WINDRES" "$DLLTOOL" \
            nasm ninja meson cmake python3 autoreconf curl git gperf; do
  command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
[[ ${#MISSING[@]} -gt 0 ]] && fail "Missing toolchain: ${MISSING[*]}"

# ── Common build flags ────────────────────────────────────────────────────────
WIN_FLAGS="-D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00"
LTO_EXTRA="$(lto_deps_cflags)"
VIS_EXTRA="$(vis_deps_cflags)"
SEC_EXTRA="$(section_gc_cflags)"
UNWIND_EXTRA="$(dep_unwind_cflags)"   # C++-safe .eh_frame trim, shared by all deps
CFLAGS_COMMON="-O2 -pipe $WIN_FLAGS -I$DIST/include $LTO_EXTRA $VIS_EXTRA $SEC_EXTRA $UNWIND_EXTRA"
CXXFLAGS_COMMON="-O2 -pipe $WIN_FLAGS -I$DIST/include $LTO_EXTRA $VIS_EXTRA $SEC_EXTRA $UNWIND_EXTRA"
CPPFLAGS_COMMON="-I$DIST/include"
# Static-runtime flags differ between GCC and clang. GCC: -static-libgcc /
# -static-libstdc++ embed libgcc & libstdc++. clang/llvm-mingw: rely on
# --rtlib=compiler-rt and statically link via -static.
case "$CROSS_TOOLCHAIN_KIND" in
  gnu)  STATIC_RUNTIME_LDFLAGS="-static-libgcc"; STATIC_RUNTIME_LDFLAGS_CXX="-static-libgcc -static-libstdc++" ;;
  llvm) STATIC_RUNTIME_LDFLAGS="";               STATIC_RUNTIME_LDFLAGS_CXX="" ;;
esac
LDFLAGS_COMMON="-L$DIST/lib $STATIC_RUNTIME_LDFLAGS $LTO_EXTRA"

AUTOCONF_COMMON=(
  $CROSS_AUTOTOOLS_HOST
  --prefix="$DIST"
  --enable-static
  --disable-shared
)

# ── pkg-config wrapper override ───────────────────────────────────────────────
# cross_setup() already created one, but the Windows builds want $DIST scope
# only (no host's /usr/lib/.../pkgconfig leaking). Re-pin LIBDIR explicitly.
export PKG_CONFIG_LIBDIR="$DIST/lib/pkgconfig:$DIST/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"

# Convenience helpers ─────────────────────────────────────────────────────────
fetch() {
  local name="$1" url="$2"
  local archive="$SRC/$(basename "$url")"
  if [[ ! -f "$archive" ]]; then
    log "→ Downloading $name..."
    local success=0
    for i in {1..3}; do
      if curl -fsSL "$url" -o "$archive"; then success=1; break; fi
      warn "Retrying $name download ($i/3)..."
      rm -f "$archive"; sleep 5
    done
    [[ $success -eq 1 ]] || die "Failed to download $name after 3 attempts"
  fi
  echo "$archive"
}

cmake_win() {
  cmake -S "$1" -B "$2" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$CROSS_CMAKE_FILE" \
    -DCMAKE_INSTALL_PREFIX="$DIST" \
    -DCMAKE_BUILD_TYPE=Release \
    "${@:3}"
}

# ════════════════════════════════════════════════════════════════════════════════
# Dependencies
# ════════════════════════════════════════════════════════════════════════════════

# ── zlib ──────────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libz.a" ]]; then
  log "Building zlib $ZLIB_VERSION..."
  Z=$(fetch zlib "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz")
  tar -xf "$Z" -C "$SRC"
  pushd "$SRC/zlib-$ZLIB_VERSION"
    CHOST="$TRIPLE" ./configure --prefix="$DIST" --static
    make -j"$JOBS" install
  popd
  ok "zlib ✓"
fi

# ── bzip2 ─────────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libbz2.a" ]]; then
  log "Building bzip2 $BZIP2_VERSION..."
  BZ=$(fetch bzip2 "https://sourceware.org/pub/bzip2/bzip2-${BZIP2_VERSION}.tar.gz")
  tar -xf "$BZ" -C "$SRC"
  pushd "$SRC/bzip2-$BZIP2_VERSION"
    make CC="$CC" AR="$AR" RANLIB="$RANLIB" \
         CFLAGS="$CFLAGS_COMMON" -j"$JOBS" libbz2.a
    install -m644 libbz2.a "$DIST/lib/"
    install -m644 bzlib.h  "$DIST/include/"
    cat > "$DIST/lib/pkgconfig/bzip2.pc" <<PCF
prefix=${DIST}
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: bzip2
Version: ${BZIP2_VERSION}
Libs: -L\${libdir} -lbz2
Cflags: -I\${includedir}
PCF
  popd
  ok "bzip2 ✓"
fi

# ── xz (liblzma) ──────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/liblzma.a" ]]; then
  log "Building xz $XZ_VERSION..."
  XZ=$(fetch xz "https://tukaani.org/xz/xz-${XZ_VERSION}.tar.gz")
  tar -xf "$XZ" -C "$SRC"
  pushd "$SRC/xz-$XZ_VERSION"
    # xz 5.8.x's configure aborts if its `-Werror`-usability probe trips
    # on the build's non-default CFLAGS. SKIP_WERROR_CHECK=yes is the
    # upstream escape hatch — configure-time only, no effect on liblzma.
    CFLAGS="$CFLAGS_COMMON" ./configure "${AUTOCONF_COMMON[@]}" \
      --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
      --disable-scripts --disable-doc \
      SKIP_WERROR_CHECK=yes
    make -j"$JOBS" install
  popd
  ok "xz ✓"
fi

# ── libiconv ──────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libiconv.a" ]]; then
  log "Building libiconv $LIBICONV_VERSION..."
  IC=$(fetch libiconv "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${LIBICONV_VERSION}.tar.gz")
  tar -xf "$IC" -C "$SRC"
  pushd "$SRC/libiconv-$LIBICONV_VERSION"
    CFLAGS="$CFLAGS_COMMON" ./configure "${AUTOCONF_COMMON[@]}" \
      --enable-extra-encodings --disable-nls
    make -j"$JOBS" install
  popd
  ok "libiconv ✓"
fi

# ── font stack — built ONLY when libass is kept ──────────────────────────────
# By default libass is stripped from mpv (patch_strip_libass.py), so the entire
# font chain it pulls in — expat, libpng, freetype (both passes), fribidi,
# harfbuzz, fontconfig, libass — is unreferenced and skipped, and the font -l
# flags are dropped from WIN_USR_LIBS below (a leftover -lass with no libass.a
# would break the final link). Disabling strip_libass in Settings ▸ Patches
# rebuilds this chain and re-adds the link flags. Gated as one block so the
# inner `if [[ ! -f ]]` rebuild-skip guards are preserved.
if ! libass_stripped; then
# ── expat ─────────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libexpat.a" ]]; then
  log "Building expat $EXPAT_VERSION..."
  EV="${EXPAT_VERSION//./_}"
  EX=$(fetch expat "https://github.com/libexpat/libexpat/releases/download/R_${EV}/expat-${EXPAT_VERSION}.tar.bz2")
  tar -xf "$EX" -C "$SRC"
  pushd "$SRC/expat-$EXPAT_VERSION"
    CFLAGS="$CFLAGS_COMMON" ./configure "${AUTOCONF_COMMON[@]}" --without-xmlwf
    make -j"$JOBS" install
  popd
  ok "expat ✓"
fi

# ── libpng ────────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libpng.a" ]]; then
  log "Building libpng $LIBPNG_VERSION..."
  PN=$(fetch libpng "https://downloads.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.xz")
  tar -xf "$PN" -C "$SRC"
  pushd "$SRC/libpng-$LIBPNG_VERSION"
    CFLAGS="$CFLAGS_COMMON" CPPFLAGS="$CPPFLAGS_COMMON" LDFLAGS="$LDFLAGS_COMMON" \
      ./configure "${AUTOCONF_COMMON[@]}"
    make -j"$JOBS" install
  popd
  ok "libpng ✓"
fi

# ── freetype (first pass — without harfbuzz) ─────────────────────────────────
if [[ ! -f "$DIST/lib/libfreetype.a" ]]; then
  log "Building freetype $FREETYPE_VERSION (first pass)..."
  FT=$(fetch freetype "https://downloads.sourceforge.net/freetype/freetype-${FREETYPE_VERSION}.tar.xz")
  tar -xf "$FT" -C "$SRC"
  pushd "$SRC/freetype-$FREETYPE_VERSION"
    CFLAGS="$CFLAGS_COMMON" CPPFLAGS="$CPPFLAGS_COMMON" LDFLAGS="$LDFLAGS_COMMON" \
      PKG_CONFIG_PATH="$PKG_CONFIG_PATH" \
      ./configure "${AUTOCONF_COMMON[@]}" \
        --with-zlib=yes --with-png=yes --with-harfbuzz=no --with-brotli=no
    make -j"$JOBS" install
  popd
  ok "freetype r1 ✓"
fi

# ── fribidi ───────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libfribidi.a" ]]; then
  log "Building fribidi $FRIBIDI_VERSION..."
  FB=$(fetch fribidi "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz")
  tar -xf "$FB" -C "$SRC"
  pushd "$SRC/fribidi-$FRIBIDI_VERSION"
    CFLAGS="$CFLAGS_COMMON" ./configure "${AUTOCONF_COMMON[@]}" \
      --disable-debug --disable-deprecated
    make -j"$JOBS" install
  popd
  ok "fribidi ✓"
fi

# ── harfbuzz ──────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libharfbuzz.a" ]]; then
  log "Building harfbuzz $HARFBUZZ_VERSION..."
  HB=$(fetch harfbuzz "https://github.com/harfbuzz/harfbuzz/archive/refs/tags/${HARFBUZZ_VERSION}.tar.gz")
  tar -xf "$HB" -C "$SRC"
  pushd "$SRC/harfbuzz-$HARFBUZZ_VERSION"
    rm -rf build
    meson setup build \
      --cross-file "$CROSS_MESON_FILE" \
      --prefix="$DIST" --libdir=lib \
      --buildtype=release --default-library=static \
      -Dtests=disabled -Ddocs=disabled -Dglib=disabled \
      -Dc_args="$CFLAGS_COMMON" -Dcpp_args="$CXXFLAGS_COMMON"
    ninja -C build install
  popd
  ok "harfbuzz ✓"
fi

# ── freetype (second pass — with harfbuzz) ──────────────────────────────────
log "Building freetype $FREETYPE_VERSION (second pass)..."
pushd "$SRC/freetype-$FREETYPE_VERSION"
  make clean || true
  CFLAGS="$CFLAGS_COMMON" CPPFLAGS="$CPPFLAGS_COMMON" LDFLAGS="$LDFLAGS_COMMON" \
    PKG_CONFIG_PATH="$PKG_CONFIG_PATH" \
    ./configure "${AUTOCONF_COMMON[@]}" \
      --with-zlib=yes --with-png=yes --with-harfbuzz=yes --with-brotli=no
  make -j"$JOBS" install
popd
ok "freetype r2 ✓"

# ── fontconfig ────────────────────────────────────────────────────────────────
# Built via meson (NOT autotools). Reason: with `--default-library=static`
# autotools still links fc-cache.exe / fc-list.exe / etc. binaries which pull
# in freetype's harfbuzz dependency through LTO, and the link fails without
# explicit `-lharfbuzz`. Meson exposes `-Dtools=disabled` + `-Dcache-build=disabled`
# to skip those binaries entirely — we only need libfontconfig.a for the
# final mpv link. Matches the Linux script's approach.
if [[ ! -f "$DIST/lib/libfontconfig.a" ]]; then
  log "Building fontconfig $FONTCONFIG_VERSION..."
  FC=$(fetch fontconfig "https://www.freedesktop.org/software/fontconfig/release/fontconfig-${FONTCONFIG_VERSION}.tar.xz")
  tar -xf "$FC" -C "$SRC"
  pushd "$SRC/fontconfig-$FONTCONFIG_VERSION"
    rm -rf build
    meson setup build \
      --cross-file "$CROSS_MESON_FILE" \
      --prefix="$DIST" --libdir=lib \
      --buildtype=release --default-library=static \
      -Dtests=disabled -Dtools=disabled -Ddoc=disabled -Dcache-build=disabled \
      -Dnls=disabled -Diconv=enabled \
      -Dc_args="$CFLAGS_COMMON" -Dcpp_args="$CXXFLAGS_COMMON"
    ninja -C build install
  popd
  ok "fontconfig ✓"
fi
fi  # ! libass_stripped

# ── speexdsp ──────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libspeexdsp.a" ]]; then
  log "Building speexdsp $SPEEXDSP_VERSION..."
  SP=$(fetch speexdsp "https://github.com/xiph/speexdsp/archive/refs/tags/SpeexDSP-${SPEEXDSP_VERSION}.tar.gz")
  tar -xf "$SP" -C "$SRC"
  pushd "$SRC/speexdsp-SpeexDSP-$SPEEXDSP_VERSION"
    # Patch (canonical MSYS2 fix): resample_neon.h uses int32_t / uint32_t
    # without including <stdint.h>. Compiles on Linux because stdint
    # leaks transitively, but on MinGW aarch64 (clang/llvm-mingw) the
    # types are undeclared and the build fails with "unknown type name
    # 'int32_t'". Insert before the first `#ifdef FIXED_POINT` (stable
    # anchor across speexdsp versions). Idempotent.
    if ! grep -q '#include <stdint.h>' libspeexdsp/resample_neon.h; then
      sed -i '/^#ifdef FIXED_POINT/i\
#include <stdint.h>\

' libspeexdsp/resample_neon.h
    fi
    ./autogen.sh
    CFLAGS="$CFLAGS_COMMON" ./configure "${AUTOCONF_COMMON[@]}"
    make -j"$JOBS" install
  popd
  ok "speexdsp ✓"
fi

# ── rubberband ────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/librubberband.a" ]]; then
  log "Building rubberband $RUBBERBAND_VERSION..."
  RB=$(fetch rubberband "https://breakfastquay.com/files/releases/rubberband-${RUBBERBAND_VERSION}.tar.bz2")
  tar -xf "$RB" -C "$SRC"
  pushd "$SRC/rubberband-$RUBBERBAND_VERSION"
    # rubberband's system_memorybarrier() MinGW branch uses x86 inline asm
    # (`xchgl %%eax,%0`) that fails to assemble on aarch64 clang; the patch
    # swaps it for a portable atomic fence. rubberband 4.0+ removed the
    # function entirely, so the patch is a no-op there. Idempotent.
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/rubberband/patch_rubberband_winarm64.py" \
      "$SRC/rubberband-$RUBBERBAND_VERSION"
    # rubberband 4.0+ uses unqualified `size_t` in src/common/mathmisc.{h,cpp};
    # modern gcc/clang under -std=c++20 rejects it. Inject <stddef.h>. Idempotent.
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/rubberband/patch_rubberband_size_t.py" \
      "$SRC/rubberband-$RUBBERBAND_VERSION"
    rm -rf build
    meson setup build \
      --cross-file "$CROSS_MESON_FILE" \
      --prefix="$DIST" --libdir=lib \
      --buildtype=release --default-library=static \
      -Dfft=builtin -Dresampler=builtin
    ninja -C build install
  popd
  ok "rubberband ✓"
fi

# ── libplacebo ────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libplacebo.a" ]]; then
  log "Building libplacebo $LIBPLACEBO_VERSION..."
  LP_DIR="$SRC/libplacebo-git"
  download_git "https://code.videolan.org/videolan/libplacebo.git" "$LP_DIR" "$LIBPLACEBO_VERSION"
  git -C "$LP_DIR" submodule update --init --recursive
  apply_libplacebo_patches "$LP_DIR"
  pushd "$LP_DIR"
    rm -rf build
    # `-DPL_STATIC` mutes the `PL_API` macro so it doesn't expand to
    # `__declspec(dllexport)`. Without it, every `pl_*` function lands
    # in the .o's `.drectve` COFF section as `-export:pl_*`, which the
    # linker honors regardless of `--exclude-all-symbols` at the final
    # libmpv-2.dll link — leaking 300+ libplacebo symbols into the
    # public export table.
    meson setup build \
      --cross-file "$CROSS_MESON_FILE" \
      --prefix="$DIST" --libdir=lib \
      --buildtype=release --default-library=static \
      -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled -Dopengl=disabled \
      -Dd3d11=disabled -Ddemos=false -Dtests=false \
      -Dc_args="$CFLAGS_COMMON -DPL_STATIC" -Dcpp_args="$CXXFLAGS_COMMON -DPL_STATIC"
    ninja -C build install
  popd
  ok "libplacebo ✓"
fi

# ── libass — built ONLY when libass is kept (see font-stack block above) ──────
if ! libass_stripped; then
if [[ ! -f "$DIST/lib/libass.a" ]]; then
  log "Building libass $LIBASS_VERSION..."
  LA=$(fetch libass "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.gz")
  tar -xf "$LA" -C "$SRC"
  pushd "$SRC/libass-$LIBASS_VERSION"
    CFLAGS="$CFLAGS_COMMON" ./configure "${AUTOCONF_COMMON[@]}" \
      --disable-require-system-font-provider
    make -j"$JOBS" install
  popd
  ok "libass ✓"
fi
fi  # ! libass_stripped

# ── openssl ───────────────────────────────────────────────────────────────────
# Both arches use OpenSSL's "mingw64" Configure target — for aarch64 the
# llvm-mingw clang set as $CC by cross_setup drives the codegen.
# build_openssl honours CC/AR/RANLIB (exported by cross_setup) + CFLAGS/
# LDFLAGS, which the Windows build keeps as CFLAGS_COMMON/LDFLAGS_COMMON
# rather than exported env, so pass them inline for this call.
#
# OpenSSL ships no ARM64-mingw target. For aarch64 build "mingw64" with
# `no-asm`: its asm modules are x86_64-only and won't assemble for AArch64;
# the pure-C crypto is fine for TLS. The target's `-m64` cflag is silently
# accepted by clang on aarch64.
OPENSSL_EXTRA=""
[[ "$ARCH" == "aarch64" ]] && OPENSSL_EXTRA="no-asm"
CFLAGS="$CFLAGS_COMMON" LDFLAGS="$LDFLAGS_COMMON" \
  build_openssl "$DIST" "$BUILD_DIR" "mingw64" "$OPENSSL_EXTRA"

# OpenSSL's libcrypto.pc keeps the Win32 syslibs (ws2_32/crypt32/gdi32) under
# Libs.private. ffmpeg's openssl probe links the test against the non-static
# `pkg-config --libs` set, drops those syslibs, fails to link, and then wrongly
# aborts ("OpenSSL <3.0.0 is incompatible with the gpl"). Promote the private
# syslibs onto the public Libs line so the probe links.
crypto_pc="$DIST/lib/pkgconfig/libcrypto.pc"
if [[ -f "$crypto_pc" ]] && ! grep -qE '^Libs:.*-lws2_32' "$crypto_pc"; then
  priv="$(sed -n 's/^Libs\.private:[[:space:]]*//p' "$crypto_pc")"
  [[ -n "$priv" ]] && sed -i "s|^\(Libs:.*\)|\1 $priv|" "$crypto_pc"
fi

# ── libsmb2 ──────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libsmb2.a" ]]; then
  log "Building libsmb2 $LIBSMB2_TAG..."
  SMB2_DIR="$SRC/libsmb2"
  download_git "https://github.com/sahlberg/libsmb2.git" "$SMB2_DIR" "$LIBSMB2_TAG"

  # ── Patch libsmb2 for MinGW cross-compilation ──────────────────────────────
  # Applies cleanly to both GNU MinGW and llvm-mingw (llvm-mingw also defines
  # __MINGW32__ / _WIN32, which is what these gates check).
  sed -i 's/^typedef int t_socket;/#if !defined(_WIN32)\ntypedef int t_socket;\n#endif/' \
      "$SMB2_DIR/include/smb2/libsmb2.h"
  sed -i 's/^int random(void);/long random(void);/' "$SMB2_DIR/lib/compat.h"
  # libsmb2 6.x redeclares gethostname() with a size_t length on __MINGW32__;
  # winsock2.h already declares it with int — drop the conflicting prototype.
  sed -i '/^int gethostname(char\* name, size_t len);/d' "$SMB2_DIR/lib/compat.h"
  # Inject `<stdlib.h>` UNCONDITIONALLY at line 1 so rand()/srand()
  # (substitutions below) are visible regardless of #ifdef platform branch.
  # GCC tolerates implicit declarations as warnings; clang on llvm-mingw
  # aarch64 errors out (`-Wimplicit-function-declaration`). The file already
  # has many `#include <stdlib.h>` but each is inside a different platform
  # #ifdef and none are active on MinGW. Idempotency: check line 1 exactly.
  if [[ "$(head -1 "$SMB2_DIR/lib/compat.c")" != "#include <stdlib.h>" ]]; then
    sed -i '1i #include <stdlib.h>' "$SMB2_DIR/lib/compat.c"
  fi
  sed -i 's/return smb2_random();/return rand();/'           "$SMB2_DIR/lib/compat.c"
  sed -i 's/smb2_srandom(seed);/srand(seed);/'              "$SMB2_DIR/lib/compat.c"
  sed -i 's/return getpid_num();/return (int)GetCurrentProcessId();/' "$SMB2_DIR/lib/compat.c"
  sed -i 's/return login_num;/buf[0] = 0; return 0;/'       "$SMB2_DIR/lib/compat.c"
  sed -i 's/^int random(void)/long random(void)/' "$SMB2_DIR/lib/compat.c"
  sed -i '1i #ifndef __MINGW32__' "$SMB2_DIR/include/asprintf.h"
  echo '#endif /* !__MINGW32__ */' >> "$SMB2_DIR/include/asprintf.h"
  sed -i 's/#ifndef _MSC_VER/#if !defined(_MSC_VER) \&\& !defined(_WIN32)/' \
      "$SMB2_DIR/lib/socket.c"

  mkdir -p "$SRC/libsmb2-build"
  cmake_win "$SMB2_DIR" "$SRC/libsmb2-build" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="$CFLAGS_COMMON"
  cmake --build "$SRC/libsmb2-build" -j"$JOBS" --target install

  if [[ -f "$DIST/include/smb2/libsmb2.h" ]] && ! grep -q 'stddef.h' "$DIST/include/smb2/libsmb2.h"; then
    sed -i '1i\
#include <time.h>\
#include <stdint.h>\
#include <stddef.h>\
#include "smb2.h"\
#if defined(_WIN32) && !defined(_WINDOWS)\
#include <winsock2.h>\
typedef SOCKET t_socket;\
#define SMB2_INVALID_SOCKET INVALID_SOCKET\
#endif
' "$DIST/include/smb2/libsmb2.h"
  fi

  if [[ ! -f "$DIST/lib/libsmb2.a" ]]; then
    FOUND_A=$(find "$DIST" -name "libsmb2.a" 2>/dev/null | head -1)
    if [[ -n "$FOUND_A" ]]; then
      mkdir -p "$DIST/lib"; mv "$FOUND_A" "$DIST/lib/libsmb2.a"
    else
      FOUND_A=$(find "$SRC/libsmb2-build" -name "libsmb2.a" 2>/dev/null | head -1)
      if [[ -n "$FOUND_A" ]]; then
        mkdir -p "$DIST/lib"; cp "$FOUND_A" "$DIST/lib/libsmb2.a"
      fi
    fi
  fi
  if [[ ! -d "$DIST/include/smb2" ]]; then
    mkdir -p "$DIST/include/smb2"
    cp "$SMB2_DIR"/include/smb2/*.h "$DIST/include/smb2/"
    cp "$SMB2_DIR"/include/*.h "$DIST/include/" 2>/dev/null || true
  fi

  # cmake-generated .pc lacks -lws2_32 + smb2/ subdir; rewrite.
  cat > "$DIST/lib/pkgconfig/libsmb2.pc" <<PCEOF
prefix=$DIST
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libsmb2
Description: SMB2/3 client library
Version: ${LIBSMB2_VERSION}
Libs: -L\${libdir} -lsmb2 -lws2_32
Cflags: -I\${includedir} -I\${includedir}/smb2
PCEOF
  ok "libsmb2 ✓"
fi

# ── libxml2 (needed by FFmpeg DASH demuxer) ───────────────────────────────────
if [[ ! -f "$DIST/lib/libxml2.a" ]]; then
  log "Building libxml2 $LIBXML2_VERSION..."
  XML2=$(fetch libxml2 "https://download.gnome.org/sources/libxml2/${LIBXML2_VERSION%.*}/libxml2-${LIBXML2_VERSION}.tar.xz")
  tar -xf "$XML2" -C "$SRC"
  pushd "$SRC/libxml2-$LIBXML2_VERSION"
    CFLAGS="$CFLAGS_COMMON" ./configure "${AUTOCONF_COMMON[@]}" \
      --without-python --without-readline --without-history \
      --without-http --without-ftp --without-html \
      --without-legacy --without-docbook --without-catalog \
      --without-schematron --without-modules --without-debug \
      --without-iconv --without-lzma --without-zlib
    make -j"$JOBS" install
  popd
  ok "libxml2 ✓"
fi

# ── FFmpeg ────────────────────────────────────────────────────────────────────
if [[ ! -f "$DIST/lib/libavcodec.a" ]]; then
  log "Building FFmpeg $FFMPEG_VERSION..."
  FF=$(fetch ffmpeg "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz")
  tar -xf "$FF" -C "$SRC"
  apply_ffmpeg_patches "$SRC/ffmpeg-$FFMPEG_VERSION"
  pushd "$SRC/ffmpeg-$FFMPEG_VERSION"
    ./configure \
      --prefix="$DIST" \
      $(ffmpeg_common_args) \
      $FFMPEG_CROSS_ARGS \
      --disable-d3d11va --disable-dxva2 --disable-cuda-llvm \
      --extra-cflags="-I$DIST/include $WIN_FLAGS $(eh_frame_cflags)" \
      --extra-cxxflags="-I$DIST/include $WIN_FLAGS" \
      --extra-ldflags="-L$DIST/lib $STATIC_RUNTIME_LDFLAGS"
    verify_ffmpeg_config "." "windows"
    make -j"$JOBS" install
  popd
  ok "ffmpeg ✓"
fi

# ── mpv ───────────────────────────────────────────────────────────────────────
log "Building mpv $MPV_VERSION..."
MPV_ARCHIVE=$(fetch mpv "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz")
tar -xf "$MPV_ARCHIVE" -C "$SRC"

pushd "$SRC/mpv-$MPV_VERSION"
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/windows/patch_windows_deps.py" "$SRC/mpv-$MPV_VERSION/meson.build"
  # timer_resolution (toggleable): stop mpv pinning the system-wide timer
  # resolution to 1 ms at init (it fights DWM frame-pacing → host-app UI
  # micro-stutter). Windows-only (edits the win32-only timer-win32.c), so it
  # is applied here rather than from apply_mpv_patches_common — but still
  # gated on the same `patch_on` mechanism as the shared toggleable patches.
  if patch_on timer_resolution; then
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/windows/patch_timer_resolution.py" "$SRC/mpv-$MPV_VERSION"
  else
    warn "Skipping disabled patch: timer_resolution"
  fi
  apply_mpv_patches_common "$SRC/mpv-$MPV_VERSION"

  rm -rf build
  # Export hygiene: PE/COFF doesn't honor `-fvisibility=hidden`, so by default
  # MinGW's auto-export dumps every global symbol from every static archive
  # into the DLL's export table (~500 entries, +3-5 MB).
  #
  # `--exclude-all-symbols` alone should restrict exports to symbols marked
  # with `__declspec(dllexport)` (which mpv's MPV_EXPORT macro applies to
  # every public API function), but in practice with `-flto` the dllexport
  # attribute can be lost when LTO bitcode is unpacked at the final link.
  # The robust fix is a DEF file: when a DEF is supplied to MinGW ld, the
  # auto-export table is replaced wholesale by the DEF's EXPORTS list,
  # which is independent of LTO state.
  #
  # mpv.def lists exactly the public mpv_* C API — same surface as
  # mpv.ver (Linux ELF version-script) and mpv.exports (macOS Mach-O).
  # `--gc-sections` drops unreferenced code from the static archives
  # (mirrors the Linux build's same flag).
  # `--exclude-libs=ALL` is a GNU ld extension; lld (llvm-mingw, aarch64)
  # rejects it. `--exclude-all-symbols` plus the DEF file is sufficient on
  # both linkers — the DEF entry list is what gets exported, period.
  EXTRA_EXCLUDE_LIBS=""
  [[ "$CROSS_TOOLCHAIN_KIND" == "gnu" ]] && EXTRA_EXCLUDE_LIBS="-Wl,--exclude-libs=ALL"
  EXPORT_HYGIENE_LDFLAGS="-Wl,--exclude-all-symbols $EXTRA_EXCLUDE_LIBS -Wl,--gc-sections ${SCRIPT_DIR}/shared/mpv.def"

  # Explicit static-deps list. meson's pkg-config dependency resolver doesn't
  # always pull `Requires.private` transitively in cross builds with
  # `auto_features=disabled`, so we list every static archive mpv ultimately
  # depends on. `--start-group` lets ld revisit archives for circular refs.
  #
  # Layered order (left → right means consumer → provider):
  #   font stack: libass → fontconfig → harfbuzz → freetype → fribidi (kept only
  #               when strip_libass is disabled; private deps libpng + expat)
  #   media:      libplacebo, librubberband, libsmb2, libxml2, libspeexdsp
  #   compression: zlib, bz2, lzma, iconv
  #   tls:        openssl (ssl + crypto)
  #   threading + winsock: winpthread, ws2_32 (libsmb2)
  #   Windows system libs: avrt, dwmapi, gdi32, …
  # The font -l flags are added ONLY when libass is kept (strip_libass disabled);
  # a leftover -lass with no libass.a would break the link. libswscale needs no
  # entry here — when kept it comes in via mpv's own dependency('libswscale')
  # pkg-config, like the other libav* archives. -Wl,--start-group lets ld revisit
  # archives for circular refs, so the exact intra-group order is not critical.
  _font_libs=""
  if ! libass_stripped; then
    _font_libs="-lass -lfontconfig -lharfbuzz -lfribidi -lfreetype -lpng16 -lexpat "
  fi
  WIN_USR_LIBS="-Wl,--start-group \
    ${_font_libs}-lplacebo -lrubberband -lsmb2 -lxml2 -lspeexdsp \
    -lz -lbz2 -llzma -liconv \
    -lssl -lcrypto \
    -Wl,--end-group"
  # -luxtheme: w32_common.c calls SetWindowTheme. GNU ld GCs the dead win32-VO
  # path in the audio-only build before it needs the import; lld keeps the
  # reference, so the import lib must be listed explicitly.
  # -luuid: the win32-desktop block lists cc.find_library('uuid') (COM/CLSID
  # GUID symbols). We make all those find_library calls optional, so provide
  # it explicitly as cheap insurance — it links today only because the
  # audio-only build GCs the COM-consuming VO paths; an unreferenced import
  # is GC'd at link, so listing it costs nothing.
  WIN_SYS_LIBS="-lwinpthread -lws2_32 -lcrypt32 \
    -lavrt -ldwmapi -luxtheme -lgdi32 -limm32 -lntdll -lole32 -luser32 -lwinmm \
    -lshlwapi -lshell32 -lsetupapi -lcfgmgr32 -lversion -lshcore -lpathcch -luuid"
  C_LINK_ARGS="-static -L$DIST/lib -L${WIN_SYSROOT_LIB} $STATIC_RUNTIME_LDFLAGS $EXPORT_HYGIENE_LDFLAGS $WIN_USR_LIBS -lstdc++ $WIN_SYS_LIBS"
  CPP_LINK_ARGS="-static -L$DIST/lib -L${WIN_SYSROOT_LIB} $STATIC_RUNTIME_LDFLAGS_CXX $EXPORT_HYGIENE_LDFLAGS $WIN_USR_LIBS $WIN_SYS_LIBS"

  # GCC's partial inlining clones an exported function into `<fn>.part.N`, and
  # GNU mingw ld force-exports that clone (it inherits MPV_EXPORT's dllexport)
  # ON TOP of the DEF — leaking a 55th `mpv_*` export (seen as
  # `mpv_render_context_free.part.0` on win-x86_64). Disable it so the export
  # table is exactly the DEF's 54. GCC-only: clang (llvm-mingw, win-arm64)
  # neither knows the flag nor emits `.part` clones.
  NO_PARTIAL_INLINING=""
  [[ "$CROSS_TOOLCHAIN_KIND" == "gnu" ]] && NO_PARTIAL_INLINING="-fno-partial-inlining"

  meson setup build \
    --cross-file "$CROSS_MESON_FILE" \
    --prefix="$DIST" --libdir=lib \
    --buildtype=release \
    --default-library=shared \
    $(mpv_common_args) \
    -Dwasapi=enabled \
    -Dwin32-threads=enabled \
    -Dc_args="-I$DIST/include $WIN_FLAGS $(eh_frame_cflags) $NO_PARTIAL_INLINING" \
    -Dcpp_args="-I$DIST/include $WIN_FLAGS $NO_PARTIAL_INLINING" \
    -Dc_link_args="$C_LINK_ARGS" \
    -Dcpp_link_args="$CPP_LINK_ARGS"
  verify_mpv_config "build" "windows"

  ninja -C build install
popd
ok "mpv ✓"

# ── Finalize ──────────────────────────────────────────────────────────────────
release_dir="$LIBMPV_SCRIPTS_ROOT/builds/release"
mkdir -p "$release_dir"

# Output filename uses the platform-canonical folder arch ('arm64' for
# Windows aarch64), matching the layout under windows/libs/<arch>/.
# The build produces libmpv-2.dll (the '-2' is the mpv ABI/soname version
# baked into the meson library() call); we rename it to drop the suffix.
OUT_ARCH="$(cross_folder_arch windows "$ARCH")"
OUT_FILE="$release_dir/libmpv_windows-${OUT_ARCH}.dll"
cp "$DIST/bin/libmpv-2.dll" "$OUT_FILE"
# Strip the shipped DLL — meson leaves the COFF symbol table + DWARF debug
# sections in the .dll (~2.5-3.4M of dead weight). The mpv_* exports live in the
# PE export table (.edata), NOT the COFF symbol table, so --strip-all keeps the
# full public API. (Linux/Android already strip; Windows/macOS/iOS did not.)
"$STRIP" --strip-all "$OUT_FILE"

log "=== Build libmpv for Windows COMPLETED! ==="
log "Artifact: $OUT_FILE"

cleanup_build "$BUILD_DIR"
