# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
# shellcheck shell=bash disable=SC2164  # pushd and popd run under the caller's set -e

# Shared parts of build_libmpv_macos.sh and build_libmpv_ios.sh (and so of
# build_libmpv_tvos.sh, which runs the iOS script). Sourced after
# _helpers.sh, _versions.sh, _audio_only.sh and _cross.sh. Do not run
# directly.
#
# What differs stays in each script: macOS builds one tree per arch and lipos
# them into a versioned framework; iOS and tvOS build slices per SDK into one
# tree and ship shallow frameworks.

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu)}"

# Optional ccache/sccache wrapper (export CC_PREFIX=ccache)
CC_PREFIX="${CC_PREFIX:-}"
CC_BIN="${CC_PREFIX:+${CC_PREFIX} }clang"
CXX_BIN="${CC_PREFIX:+${CC_PREFIX} }clang++"

# ── Build log ─────────────────────────────────────────────────────────────────
# apple_start_log <name>: mirror all stdout + stderr to
# builds/logs/build_<name>_<timestamp>.log. Every invocation gets its own file
# so we can diff across runs. Each line in the log is prefixed with
# [YYYY-MM-DD HH:MM:SS] so we can measure how long each phase of the build
# actually took (the terminal stays clean — timestamps live only in the
# file). Old logs (>20) are pruned automatically.
apple_start_log() {
  LOG_DIR="$LIBMPV_SCRIPTS_ROOT/builds/logs"
  mkdir -p "$LOG_DIR"
  ls -t "$LOG_DIR"/build_"$1"_*.log 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
  LOG_FILE="$LOG_DIR/build_$1_$(date +%Y%m%d_%H%M%S).log"
  exec > >(tee >(while IFS= read -r line; do
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
  done >> "$LOG_FILE")) 2>&1
  echo "════════════════════════════════════════════════════════════"
  echo "Build started: $(date)"
  echo "Log file:      $LOG_FILE"
  echo "FFmpeg:        $FFMPEG_VERSION   mpv: $MPV_VERSION"
  echo "════════════════════════════════════════════════════════════"
}

# ── Requirements ─────────────────────────────────────────────────────────────
# apple_check_tools <tool...>: install the missing ones with Homebrew.
apple_check_tools() {
  log "Checking tools..."
  local missing=() tool
  for tool in "$@"; do
    command -v "$tool" &>/dev/null || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing tools: ${missing[*]}"
    command -v brew &>/dev/null || fail "Homebrew required to install: ${missing[*]}"
    brew install "${missing[@]}" 2>/dev/null || true
  fi
  ok "Tools OK"
}

# apple_toolchain_notes <sdk>...: Xcode and the version of each SDK the build
# compiles against, for the "toolchain" of the build record (toolchain_note
# of _audio_only.sh). The compiler line comes from $CC. Nothing here stops a
# build: a tool that does not answer leaves its entry out.
apple_toolchain_notes() {
  local xcode sdk version
  xcode="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')" || true
  [[ -n "$xcode" ]] && toolchain_note xcode "$xcode"
  for sdk in "$@"; do
    version="$(xcrun --sdk "$sdk" --show-sdk-version 2>/dev/null)" || true
    [[ -n "$version" ]] && toolchain_note "sdk-$sdk" "$version"
  done
  return 0
}

# apple_host <arch>: the autoconf host triple. autoconf picks arch-specific
# asm from $host; without --host it defaults to the build machine's arch,
# wrong for a cross-compiled x86_64 slice on an Apple-Silicon host.
apple_host() {
  case "$1" in
    arm64)  echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
  esac
}

# ── meson machine files ──────────────────────────────────────────────────────
# apple_meson_binaries <pkg-config>: the [binaries] section.
apple_meson_binaries() {
  cat << EOF
[binaries]
c = '${CC_BIN}'
cpp = '${CXX_BIN}'
objc = '${CC_BIN}'
objcpp = '${CXX_BIN}'
ar = 'ar'
strip = 'strip'
pkg-config = '$1'
EOF
}

# apple_meson_options <arch> <min version flag> <sysroot> [c_args extra]:
# the [built-in options] section, with the ThinLTO and visibility flags of
# the deps. <sysroot> may be empty. [c_args extra] is a meson array fragment
# (", 'a', 'b'") of C-only flags: it must go in this array, NOT in a
# command-line -Dc_args, which REPLACES the array (it does not append) and
# drops -arch and -isysroot from the compile (meson's SDK symbol checks then
# fail, and a cross-compiled x86_64 slice gets arm64 objects).
apple_meson_options() {
  local base="'-arch', '$1', '$2'"
  [[ -n "$3" ]] && base="$base, '-isysroot', '$3'"
  local lto_arg=""
  [[ "${ENABLE_LTO_DEPS:-1}" != "0" ]] && lto_arg=", '-flto=thin'"
  local vis_arg=""
  [[ "${VIS_HIDDEN:-1}" != "0" ]] && vis_arg=", '-fvisibility=hidden', '-fvisibility-inlines-hidden'"
  cat << EOF
[built-in options]
c_args = [${base}${lto_arg}${vis_arg}${4:-}]
cpp_args = [${base}${lto_arg}${vis_arg}]
objc_args = [${base}${lto_arg}${vis_arg}]
objcpp_args = [${base}${lto_arg}${vis_arg}]
c_link_args = [${base}${lto_arg}]
cpp_link_args = [${base}${lto_arg}]
objc_link_args = [${base}${lto_arg}]
objcpp_link_args = [${base}${lto_arg}]
EOF
}

# apple_mpv_c_args: the c_args fragment of mpv: the C-only eh_frame trim, and
# -Oz for the orchestration code (placed after meson's own -Os so it wins).
# DSP stays in ffmpeg (and rubberband), untouched by this.
apple_mpv_c_args() {
  local ehf_arg="" _f
  for _f in $(eh_frame_cflags); do ehf_arg="$ehf_arg, '$_f'"; done
  echo "$ehf_arg, '-Oz'"
}

# apple_meson_setup: meson setup without SDKROOT. SDKROOT pointing at the iOS
# SDK makes meson's build-machine sanity check fail (dyld thinks the native
# binary is a simulator program); the machine files carry -isysroot.
apple_meson_setup() {
  (
    unset SDKROOT
    meson setup "$@"
  )
}

# ── Dependencies ─────────────────────────────────────────────────────────────
# Like the cross_build_* of _cross.sh: the prefix, the trees and the flags
# come from the environment (CROSS_PREFIX_DIR, CROSS_BUILD_DIR,
# CROSS_AUTOTOOLS_HOST, CFLAGS on the call). The trees in src/ are reused by
# the next slice, hence the clean before configure.

# zlib with no CHOST: Apple's clang drives the arch through CFLAGS.
apple_build_zlib() {
  [[ -f "$CROSS_PREFIX_DIR/lib/libz.a" ]] && return
  log "Building zlib $ZLIB_VERSION${CROSS_LABEL:+ ($CROSS_LABEL)}..."
  local src="$CROSS_BUILD_DIR/src/zlib-$ZLIB_VERSION.tar.gz"
  download "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$CROSS_BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make distclean 2>/dev/null || make clean 2>/dev/null || true
  ./configure --prefix="$CROSS_PREFIX_DIR" --static
  make -j"$JOBS"; make install
  popd >/dev/null
  cross_ok zlib
}

# speexdsp from the xiph release tarball (configure shipped).
apple_build_speexdsp() {
  [[ -f "$CROSS_PREFIX_DIR/lib/libspeexdsp.a" ]] && return
  log "Building speexdsp $SPEEXDSP_VERSION${CROSS_LABEL:+ ($CROSS_LABEL)}..."
  local src="$CROSS_BUILD_DIR/src/speexdsp-$SPEEXDSP_VERSION.tar.gz"
  download "https://downloads.xiph.org/releases/speex/speexdsp-${SPEEXDSP_VERSION}.tar.gz" "$src"
  local dir; dir="$(extract "$src" "$CROSS_BUILD_DIR/src")"
  pushd "$dir" >/dev/null
  make distclean 2>/dev/null || make clean 2>/dev/null || true
  ./configure $CROSS_AUTOTOOLS_HOST --prefix="$CROSS_PREFIX_DIR" --enable-static --disable-shared
  make -j"$JOBS"; make install
  popd >/dev/null
  cross_ok speexdsp
}

# apple_build_libplacebo <meson machine args...>: libplacebo at
# v$LIBPLACEBO_VERSION, which each platform pins itself. Its headers are
# required by mpv's csputils.h; built minimal (no vulkan, shaderc, d3d11,
# opengl).
apple_build_libplacebo() {
  [[ -f "$CROSS_PREFIX_DIR/lib/libplacebo.a" ]] && return 0
  log "Building libplacebo $LIBPLACEBO_VERSION${CROSS_LABEL:+ ($CROSS_LABEL)}..."
  local gitdir="$CROSS_BUILD_DIR/src/libplacebo-git"
  download_git "https://code.videolan.org/videolan/libplacebo.git" "$gitdir" "v$LIBPLACEBO_VERSION"
  git -C "$gitdir" submodule update --init --recursive
  apply_libplacebo_patches "$gitdir"
  local bdir; bdir="$(cross_bdir libplacebo)"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$CROSS_PREFIX_DIR/lib/pkgconfig" \
  apple_meson_setup "$gitdir" \
    --prefix="$CROSS_PREFIX_DIR" --buildtype=release --default-library=static \
    -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled -Dopengl=disabled \
    -Dd3d11=disabled -Ddemos=false -Dtests=false \
    "$@"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  cross_ok libplacebo
}

# apple_build_rubberband <meson machine args...>: GPL build only (gpl_build).
apple_build_rubberband() {
  [[ -f "$CROSS_PREFIX_DIR/lib/librubberband.a" ]] && return
  log "Building rubberband $RUBBERBAND_VERSION${CROSS_LABEL:+ ($CROSS_LABEL)}..."
  local src="$CROSS_BUILD_DIR/src/rubberband-$RUBBERBAND_VERSION.tar.bz2"
  download "https://breakfastquay.com/files/releases/rubberband-${RUBBERBAND_VERSION}.tar.bz2" "$src"
  local dir; dir="$(extract "$src" "$CROSS_BUILD_DIR/src")"
  # rubberband 4.0+ uses unqualified `size_t` in src/common/mathmisc.{h,cpp};
  # modern gcc/clang under -std=c++20 rejects it. Inject <stddef.h>. Idempotent.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/rubberband/patch_rubberband_size_t.py" "$dir"
  local bdir; bdir="$(cross_bdir rubberband)"; mkdir -p "$bdir"
  pushd "$bdir" >/dev/null
  PKG_CONFIG_PATH="$CROSS_PREFIX_DIR/lib/pkgconfig" \
  apple_meson_setup "$dir" \
    --prefix="$CROSS_PREFIX_DIR" --buildtype=release --default-library=static \
    -Dfft=builtin -Dresampler=speex \
    -Dladspa=disabled -Dvamp=disabled -Djni=disabled \
    "$@"
  ninja -j"$JOBS"; ninja install
  popd >/dev/null
  cross_ok rubberband
}

# apple_mpv_export_filter <mpv dir> <prefix>: inject the export filter into
# mpv's libmpv `library()` call so ld64 only exposes mpv_* in the final
# dylib's symbol table. It writes <prefix> into meson.build, so each arch or
# slice has its own mpv tree.
apple_mpv_export_filter() {
  if [[ "${VIS_HIDDEN:-1}" != "0" ]]; then
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/apple/patch_export_filter.py" \
      "$1" "$SCRIPT_DIR/shared/mpv.exports" "$2"
  fi
}

# ── Framework ────────────────────────────────────────────────────────────────
# apple_sign <Mach-O>: ad hoc signature after the last edit of the binary
# (strip, install_name_tool and bitcode_strip all invalidate the linker's).
# On Apple Silicon a broken-signature dylib SIGKILLs on dlopen; a consumer
# app re-signs on embed, direct host loads do not, and the later
# `codesign --deep` on the xcframework does NOT reliably re-sign this inner
# Mach-O. --identifier is MANDATORY: it must equal the Info.plist
# CFBundleIdentifier. Signed without it, the identifier defaults to
# `libmpv-<hash>`, and iOS installd rejects the device install
# (MismatchedBundleIDSigningIdentifier); Xcode keeps it when it re-signs.
apple_sign() {
  codesign -s - --force --identifier com.ales-drnz.libmpv "$1" 2>/dev/null
}

apple_write_modulemap() {
  cat > "$1" <<'EOF'
framework module mpv {
  umbrella header "client.h"
  export *
  module * { export * }
}
EOF
}

# apple_write_info_plist <file> <minimum version key> <version>.
# CFBundleExecutable must match the binary filename (`libmpv`, no extension):
# Apple validation tools reject mismatches.
apple_write_info_plist() {
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>libmpv</string>
<key>CFBundleIdentifier</key><string>com.ales-drnz.libmpv</string>
<key>CFBundleName</key><string>libmpv</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>${MPV_VERSION}</string>
<key>CFBundleVersion</key><string>1</string>
<key>$2</key><string>$3</string>
</dict></plist>
EOF
}

# Privacy manifest declaring the required-reason APIs libmpv uses internally
# (file timestamps via fstat for cache files; monotonic clock via
# clock_gettime for playback timing). Mandatory since May 2024 for any
# third-party SDK that touches these APIs.
apple_write_privacy_manifest() {
  cat > "$1" <<'EOF'
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

# apple_write_licenses <platform> <src dir> <mpv tree>: the license texts of
# what the framework links (write_licenses). Every arch or slice extracts the
# same sources; <mpv tree> is the mpv dir of the first one.
apple_write_licenses() {
  local licenses=("mpv=$3" ffmpeg openssl libplacebo libxml2 zlib bzip2 xz speexdsp)
  patch_on libsmb2 && licenses+=(libsmb2)
  gpl_build && licenses+=(rubberband)
  libass_stripped || licenses+=(expat libpng freetype fribidi harfbuzz fontconfig libass)
  write_licenses "$1" "$2" "${licenses[@]}"
}
