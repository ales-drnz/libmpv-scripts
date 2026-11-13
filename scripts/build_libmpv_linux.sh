#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# build_libmpv_linux.sh
#
# Compiles mpv as libmpv.so for Linux x86_64 / aarch64, natively: the arch
# must match the host's. The scripts still call the triple-prefixed tools
# (e.g. x86_64-linux-gnu-gcc), which the image points at its gcc 10.
#
# === OUTPUT ===
# builds/release/libmpv_linux-<arch>.so
#
# === SYSTEM ===
# Run inside the mpv-build-linux image (`linux` stage of docker/Dockerfile):
# Ubuntu 20.04, glibc 2.31, native arch only, alsa and pulse dev libs. PipeWire
# headers are built here (build_audio_stubs). X11 / VA-API / VDPAU are
# deliberately disabled — this is an audio-only build.
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
source "$SCRIPT_DIR/shared/_audio_only.sh"
source "$SCRIPT_DIR/shared/_cross.sh"
source "$SCRIPT_DIR/build_openssl.sh"


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
# The linux image is native-only (glibc 2.31 base, no multiarch cross): build
# each arch on a host of that arch. See the `linux` stage in docker/Dockerfile.
[[ "$(uname -m)" == "$ARCH" ]] || \
  die "--arch=$ARCH needs a $ARCH host (this one is $(uname -m)); the Linux build is native-only"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# ── Linux-only dependency versions (centralised ones live in _versions.sh) ────
# shellcheck disable=SC2034  # read by the shared builds (_cross.sh, _apple.sh)
LIBPLACEBO_VERSION="7.349.0"
LIBUNIBREAK_VERSION="6.1"

BUILD_DIR="${BUILD_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/work/Linux/$ARCH}"
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
mirror_build_log "$LOG_FILE"
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
HARD_EXTRA="$(hardening_cflags)"      # stack canary and fortify, see _audio_only.sh
export CFLAGS="-O2 -fPIC -I$PREFIX/include $LTO_EXTRA $VIS_EXTRA $SEC_EXTRA $UNWIND_EXTRA $HARD_EXTRA"
export CXXFLAGS="-O2 -fPIC -I$PREFIX/include $LTO_EXTRA $VIS_EXTRA $SEC_EXTRA $UNWIND_EXTRA $HARD_EXTRA"
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
# The deps other targets build the same way (zlib, bzip2, xz, libxml2,
# speexdsp, rubberband, libplacebo, libsmb2, FFmpeg, mpv) are the
# cross_build_* of _cross.sh; the font stack and the audio stubs are here.
# =============================================================================

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

build_ffmpeg() {
  cross_build_ffmpeg linux \
    $FFMPEG_CROSS_ARGS \
    --disable-libxcb \
    --disable-libxcb-shm \
    --disable-libxcb-xfixes \
    --disable-libxcb-shape \
    --extra-cflags="$(eh_frame_cflags) $HARD_EXTRA" \
    --extra-libs="-lm -lpthread -ldl"
}

# ── Audio client libraries as lazily loaded stubs ────────────────────────────
# libmpv must load on systems without PipeWire or PulseAudio, so neither is a
# DT_NEEDED: mpv links Implib.so stubs (tools/implib) that dlopen the real
# library on first use, and the Linux mpv patch checks it is there before
# that first use. The stubs ask the patch for the handle (--dlopen-callback),
# so there is one loader. mpv finds these through their own .pc files, which
# point at the stub archives and, for PipeWire, at headers of the pinned
# PIPEWIRE_VERSION built here (focal's libpipewire is too old for mpv).
STUBS_DIR="$BUILD_DIR/stubs"
# -DNDEBUG: the Implib.so asserts have no side effects (CHECK still aborts),
# and without them no build path (__FILE__) ends up in the library.
STUB_CFLAGS="-O2 -fPIC -DNDEBUG"

build_audio_stubs() {
  # Cache key: a change of PipeWire version or stub flags rebuilds the stubs.
  local key="pipewire $PIPEWIRE_VERSION, $STUB_CFLAGS"
  [[ -f "$STUBS_DIR/pkgconfig/libpipewire-0.3.pc" && \
     -f "$STUBS_DIR/pkgconfig/libpulse.pc" && \
     "$(cat "$STUBS_DIR/.key" 2>/dev/null)" == "$key" ]] && return
  log "Building PipeWire $PIPEWIRE_VERSION (headers and stub source)..."
  local sdk="$BUILD_DIR/pipewire-sdk"
  local dir="$BUILD_DIR/src/pipewire-$PIPEWIRE_VERSION"
  download_git "https://gitlab.freedesktop.org/pipewire/pipewire.git" "$dir" "$PIPEWIRE_VERSION"
  local bdir="$BUILD_DIR/build/pipewire"
  rm -rf "$bdir" "$sdk"
  # Plain flags: none of the LTO/visibility tuning belongs in a library that
  # only lends its headers and its exported symbol list. auto-features only
  # turns off the `auto` features; the ones listed after it default to
  # `enabled` in 0.3.57 (dbus among them, which would need libdbus).
  CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" LDFLAGS="" \
    meson setup "$bdir" "$dir" --prefix="$sdk" --libdir=lib --buildtype=release \
      --auto-features=disabled '-Dsession-managers=[]' \
      -Djack-devel=false -Dlegacy-rtkit=false \
      -Dexamples=disabled -Dtests=disabled \
      -Dsystemd-user-service=disabled -Dpipewire-jack=disabled \
      -Dpipewire-v4l2=disabled -Dspa-plugins=disabled \
      -Daudiomixer=disabled -Daudioconvert=disabled \
      -Dbluez5-backend-hsp-native=disabled \
      -Dbluez5-backend-hfp-native=disabled \
      -Dbluez5-backend-ofono=disabled -Dbluez5-backend-hsphfpd=disabled \
      -Dcontrol=disabled -Daudiotestsrc=disabled -Dsupport=disabled \
      -Ddbus=disabled -Dvideoconvert=disabled -Dvideotestsrc=disabled \
      -Dvolume=disabled -Dflatpak=disabled
  ninja -C "$bdir" -j"$JOBS"
  ninja -C "$bdir" install

  mkdir -p "$STUBS_DIR/pkgconfig"
  local pulse_so="/usr/lib/$CROSS_TRIPLE/libpulse.so.0"
  [[ -f "$pulse_so" ]] || die "libpulse not found at $pulse_so (libpulse-dev missing?)"
  make_stub pipewire "$sdk/lib/libpipewire-0.3.so.0"
  make_stub pulse "$pulse_so"

  cat > "$STUBS_DIR/pkgconfig/libpipewire-0.3.pc" <<EOF
Name: libpipewire-0.3
Description: PipeWire client library, through a lazily loaded stub
Version: $PIPEWIRE_VERSION
Cflags: -I$sdk/include/pipewire-0.3 -I$sdk/include/spa-0.2 -D_REENTRANT
Libs: $STUBS_DIR/libpipewire-stub.a -ldl -lpthread
EOF
  cat > "$STUBS_DIR/pkgconfig/libpulse.pc" <<EOF
Name: libpulse
Description: PulseAudio client library, through a lazily loaded stub
Version: $(PKG_CONFIG_LIBDIR="/usr/lib/$CROSS_TRIPLE/pkgconfig:/usr/share/pkgconfig" pkg-config --modversion libpulse)
Cflags: -D_REENTRANT
Libs: $STUBS_DIR/libpulse-stub.a -ldl -lpthread
EOF
  printf '%s\n' "$key" > "$STUBS_DIR/.key"
  ok "Audio library stubs ✓"
}

# make_stub <name> <library.so>: $STUBS_DIR/lib<name>-stub.a, trampolines for
# every function <library.so> exports, loaded through mak_<name>_dlopen.
make_stub() {
  local name="$1" lib="$2" out="$STUBS_DIR/$1"
  rm -rf "$out"; mkdir -p "$out"
  python3 "$LIBMPV_SCRIPTS_ROOT/tools/implib/implib-gen.py" -q \
    --target "$CROSS_TRIPLE" --dlopen-callback "mak_${name}_dlopen" \
    --outdir "$out" "$lib"
  local f objs=()
  for f in "$out"/*.tramp.S "$out"/*.init.c; do
    "$CC" $STUB_CFLAGS -c "$f" -o "$f.o"
    objs+=("$f.o")
  done
  rm -f "$STUBS_DIR/lib${name}-stub.a"
  "$AR" rcs "$STUBS_DIR/lib${name}-stub.a" "${objs[@]}"
}

build_mpv() {
  [[ -f "$PREFIX/lib/libmpv.so" ]] && return
  log "Building mpv $MPV_VERSION..."
  cross_mpv_source
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/linux/patch_optional_audio_libs.py" "$CROSS_MPV_DIR"

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
  # hardening_ldflags (full RELRO, BIND_NOW, NX stack) goes here and not in
  # LDFLAGS: -Dc_link_args makes meson drop the environment's. The audio
  # stubs do not mind BIND_NOW, see hardening_cflags in _audio_only.sh.
  local link_extra=() hard_ld
  hard_ld="$(hardening_ldflags)"
  if [[ "${VIS_HIDDEN:-1}" != "0" || "${SECTION_GC:-1}" != "0" ]]; then
    # Shared ELF flags from _audio_only.sh: -Bsymbolic without relocation packing
    # (`none`): RELR would need glibc 2.36 on the user's machine, see
    # mpv_elf_size_ldflags. Android asks for APS2 instead. The SONAME suffix
    # renames the library to the kit's own name, see MPV_SONAME.
    # See the note in build_libmpv_android.sh: `local x="$(cmd)"` would mask a
    # failure inside the command substitution from set -e.
    local ld_args
    ld_args="$hard_ld -Wl,--gc-sections,--exclude-libs=ALL,--no-undefined$(mpv_elf_size_ldflags none)$(mpv_soname_ldflags)"
    [[ "${VIS_HIDDEN:-1}" != "0" ]] && \
      ld_args="$ld_args,--version-script=${SCRIPT_DIR}/shared/mpv.ver"
    local extra_libs="-lssl -lcrypto -lxml2 -lbz2 -llzma"
    link_extra+=("-Dc_link_args=$ld_args $extra_libs")
    link_extra+=("-Dcpp_link_args=$ld_args $extra_libs")
  else
    link_extra+=("-Dc_link_args=$hard_ld" "-Dcpp_link_args=$hard_ld")
  fi

  # The stub .pc files come first, so libpipewire-0.3 and libpulse resolve to
  # the stubs (see build_audio_stubs).
  PKG_CONFIG_LIBDIR="$STUBS_DIR/pkgconfig:$PKG_CONFIG_LIBDIR" \
  cross_mpv_build linux --cross-file "$CROSS_MESON_FILE" \
    --prefix="$PREFIX" \
    --buildtype=release \
    --default-library=shared \
    $(mpv_common_args) \
    -Dalsa=enabled \
    -Dpulse=enabled \
    -Dpipewire=enabled \
    -Dc_args="$(eh_frame_cflags) $HARD_EXTRA" \
    "${link_extra[@]}"
}

# =============================================================================
# Finalize: stage the .so, strip it, audit external NEEDED entries.
# =============================================================================

finalize() {
  local release_dir="$LIBMPV_SCRIPTS_ROOT/builds/release"
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
  assert_soname "$out"
  assert_no_relr "$out"
  assert_hardening "$out"
  assert_no_needed "$out" 'libpipewire|libpulse'
  assert_glibc_floor "$out" "$LINUX_GLIBC_FLOOR"
  write_build_record "linux-$ARCH" "$PREFIX"
  local licenses=(mpv ffmpeg openssl libplacebo libxml2 zlib bzip2 xz speexdsp pipewire implib)
  patch_on libsmb2 && licenses+=(libsmb2)
  gpl_build && licenses+=(rubberband)
  libass_stripped || licenses+=(expat libpng freetype fribidi harfbuzz fontconfig libunibreak libass)
  write_licenses "linux-$ARCH" "$BUILD_DIR/src" "${licenses[@]}"

  # Dynsym hygiene check. readelf -W --dyn-syms columns:
  #   Num Value Size Type Bind Vis Ndx Name
  # ($1) ($2)  ($3)  ($4)  ($5) ($6)($7)($8)
  # Defined global functions = Bind=GLOBAL, Type=FUNC, Ndx!=UND.
  local total_syms mpv_syms
  total_syms="$("$READELF" -W --dyn-syms "$out" 2>/dev/null | awk '$5=="GLOBAL" && $4=="FUNC" && $7!="UND" {n++} END{print n+0}')"
  mpv_syms="$("$READELF"   -W --dyn-syms "$out" 2>/dev/null | awk '$5=="GLOBAL" && $4=="FUNC" && $7!="UND" && $8 ~ /^mpv_/ {n++} END{print n+0}')"
  ok "Symbols: $total_syms total, $mpv_syms mpv_*"
  # 63 in libmpv-r24. More than 200: the version script was not bound into
  # the link; none: readelf could not read the library. Both stop the build,
  # as on macOS.
  [[ "$mpv_syms" -gt 0 ]] || die "No mpv_* symbol exported by $out"
  if [[ "${VIS_HIDDEN:-1}" != "0" && "$total_syms" -gt 200 ]]; then
    die "Export-filter regression: expected ~60 exported symbols with" \
        "VIS_HIDDEN=1 but got $total_syms"
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

  # The compression deps take -Os on top of the global flags (the last -O
  # wins), keeping the LTO, visibility and section flags; bzip2 has no
  # configure and takes its whole CFLAGS. DSP and crypto deps (openssl,
  # rubberband in the GPL build) keep -O2.
  CFLAGS="$CFLAGS -Os" cross_build_zlib
  CFLAGS="-Os -fPIC -D_FILE_OFFSET_BITS=64 $HARD_EXTRA" cross_build_bzip2
  CFLAGS="$CFLAGS -Os" cross_build_xz
  build_audio_stubs

  # Font stack — built ONLY when libass is kept (strip_libass disabled in
  # Settings ▸ Patches). By default libass is stripped from mpv, so the whole
  # chain (expat, libpng, freetype ×2, fribidi, harfbuzz, fontconfig, unibreak,
  # libass) is dead weight and skipped. mpv re-detects libass via pkg-config
  # when these are present; see libass_stripped() in _audio_only.sh.
  if ! libass_stripped; then
    cross_build_expat
    build_libpng
    build_freetype
    build_fribidi
    build_harfbuzz
    build_freetype_round2
    build_fontconfig
    build_libunibreak
    build_libass
  fi

  cross_build_speexdsp
  # librubberband (GPL-2.0+) only in the GPL build (gpl_build in _audio_only.sh).
  if gpl_build; then
    cross_build_rubberband
  fi

  cross_build_libplacebo

  build_openssl_linux
  cross_build_libsmb2
  CFLAGS="$CFLAGS -Os" cross_build_libxml2
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
