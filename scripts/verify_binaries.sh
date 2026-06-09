#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# verify_binaries.sh
#
# Static-analysis sanity check for every binary in builds/release/.
# Verifies, for each libmpv (per platform / per arch):
#   1.  File format / arch matches platform expectation
#   2.  Exactly 54 mpv_* exports, zero leaks
#   3.  Patched mpv properties present (all 10: prefetch-state +
#       -cache-duration, audio-output-state, embedded-cover-art-data/mime,
#       pcm-tap-frame, audio-tap-frames, analyzer-taps, waveform-data/-enabled)
#   4.  FFmpeg patches present (libsmb2 protocol, mov advanced_editlist)
#   5.  Required audio decoder whitelist sample present
#   6.  Required audio filter whitelist sample present
#   7.  No forbidden video decoders (audio-only invariant)
#  7b.  Adaptive feature presence — cross-checks the binary against the
#       current Settings ▸ Patches strip selection (swscale / libass+fonts /
#       GPU-render / Windows icon present iff NOT stripped), and asserts the
#       always-on audio-path features (HTTPS/TLS, rubberband, DASH, OpenSSL,
#       SMB2-when-enabled). Catches a strip that silently didn't take effect.
#   8.  External runtime dependency list (informative)
#   9.  Embedded dep VERSIONS match scripts/_versions.sh — catches the
#       classic "I bumped harfbuzz in _versions.sh but the build cache held
#       the old binary" drift
#  10.  Mpv API surface hash (sorted mpv_* names → SHA-256/12) — must be
#       IDENTICAL across all 8 binaries (otherwise the API surface drifted
#       between platforms)
#  11.  NEEDED allowlist per platform (catches forbidden runtime
#       dependencies — e.g. `libstdc++.so` on Android, removed in API 37)
#  12.  UND symbol resolvability: every undefined dynamic symbol must be
#       exported by at least one NEEDED library (or be a known weak / loader
#       stub). Catches transitive-static-dep leaks like a libavformat →
#       OpenSSL TLS-symbol failure that would only bite at runtime.
#  13.  dlopen / LoadLibrary load test — actually loads the binary with
#       RTLD_NOW so the dynamic linker resolves every symbol up-front.
#       Linux native arch runs in-container, foreign arch via
#       qemu-user-static. Windows DLLs run via Wine. Catches symbol-version
#       mismatches that only show at runtime.
#  14.  Stub-function detection (Android only) — JNI_OnLoad's bl/callq
#       target is disassembled and checked for non-trivial size. Catches
#       the case where ffmpeg was built without --enable-jni and
#       av_jni_set_java_vm is a 2-instruction stub returning ENOSYS.
#       Defense-in-depth for the build-time config audit.
#  15.  Code-signing identity (Apple xcframeworks) — each slice's embedded
#       code-signing identifier must equal its CFBundleIdentifier, or iOS
#       installd rejects the device install (MismatchedBundleIDSigningIdentifier).
#       Parses the Mach-O CodeDirectory directly (no macOS codesign needed), so
#       it runs in-container. Catches the libmpv-r9 bare-Mach-O re-sign bug that
#       every other layer missed (only a physical-device install enforces it).
#
# All inspection runs inside the mpv-build-env Docker container so we have
# a single toolchain (binutils, llvm-readobj, llvm-objdump, qemu-user,
# wine) regardless of which OS / arch the binary targets. macOS + iOS
# binaries skip the load test (would need Xcode); the static layers (1-12)
# still run and are sufficient to catch the same class of bug at link time.
#
# Exit code: 0 if every check on every binary passes, non-zero otherwise.
#
# Usage (from project root or scripts/):
#   ./scripts/verify_binaries.sh           # all binaries
#   ./scripts/verify_binaries.sh linux     # only linux/*
#   ./scripts/verify_binaries.sh windows   # only windows/*
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Per-OS check applicability matrix
# ─────────────────────────────────────────────────────────────────────────────
# Every binary is reported against the SAME 15 categories, so the per-OS output
# is consistent and directly comparable. Each category resolves to one of:
#   ✓ / ⚠ / ✗  it ran and asserted a result
#   N/A        it intentionally does NOT apply to this platform — a one-line
#              reason is always emitted (see na()), never a silent gap
#   ·          informational only (enumerates state; asserts nothing)
#
#  #  Category                  macOS  iOS  Linux  Win  Android   reason when N/A
#  1  Format / arch               ✓    ✓     ✓     ✓     ✓
#  2  Exports (54 mpv_*)          ✓    ✓     ✓     ✓     ✓
#  3  mpv patched properties      ✓    ✓     ✓     ✓     ✓
#  4  FFmpeg patches              ✓    ✓     ✓     ✓     ✓
#  5  Audio decoders              ✓    ✓     ✓     ✓     ✓
#  6  Audio filters               ✓    ✓     ✓     ✓     ✓
#  7  Audio-only invariant        ✓    ✓     ✓     ✓     ✓
# 7b  Feature presence (strips)    ✓    ✓     ✓     ✓     ✓    adaptive to Settings ▸ Patches (swscale/libass/GPU/win-icon + core protocols)
#  8  Runtime dependencies        ·    ·     ·     ·     ·    info; the allowlist assertion is #11
#  9  Dependency versions         ✓    ✓     ✓     ✓     ✓
# 10  API surface hash            ·    ·     ·     ·     ·    info; asserted globally by the cross-platform audit
# 11  NEEDED allowlist            ✓    ✓     ✓     ✓     ✓
# 12  UND resolvability          N/A  N/A    ✓    N/A    ✓    nm/ELF-based; Mach-O & PE binds are resolved by their own loader (#13)
# 13  Runtime load test          ✓†   N/A    ✓     ✓    N/A   needs the platform's real loader (Apple dyld; no emulator-less Android path)
# 14  Stub detection             N/A  N/A   N/A   N/A    ✓    targets Android's JNI_OnLoad→av_jni_set_java_vm chain only
# 15  Code-signing identity       ✓    ✓    N/A   N/A   N/A   Apple-only: signing identifier must == CFBundleIdentifier (iOS device install)
#
#  † macOS L13 runs the REAL dyld dlopen(RTLD_NOW) when verify is invoked
#    natively on a macOS host (./scripts/verify_binaries.sh macos) — clang
#    compiles the dlopen_test helper and loads the universal dylib's host-arch
#    slice. Inside the Linux build container it self-reports N/A with that
#    pointer (a Mach-O can't load under a Linux loader). iOS stays N/A (device
#    arm64 slice; the simulator slice needs the iOS Simulator runtime).
#
# Static categories (1-11, plus 7b) run on EVERY artifact — including the
# macOS/iOS xcframeworks, whose inner Mach-O dylib is extracted and inspected.
# Only the runtime categories (12-14) vary by platform, and every non-applicable
# cell emits its reason, so the report never shows an unexplained gap and the
# per-OS "passed" tally is always paired with an "N/A (reason)" breakdown.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"
source "$SCRIPT_DIR/shared/_audio_only.sh"

ROOT="$(resolve_repo_root "$SCRIPT_DIR")" || exit 1
# Env-overridable so the regression fixture suite can point at a temp dir
# containing intentionally-broken binaries (see builds/release/
# .regression_fixtures/) and confirm the new sanity layers fail correctly.
RELEASE_DIR="${RELEASE_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/release}"
FILTER="${1:-}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Truth tables ──────────────────────────────────────────────────────────────
EXPECTED_MPV_EXPORTS=54

EXPECTED_FORMATS=(
  "libmpv_macos.xcframework.zip|Zip archive data"
  "libmpv_linux-x86_64.so|ELF 64-bit LSB shared object, x86-64"
  "libmpv_linux-aarch64.so|ELF 64-bit LSB shared object, ARM aarch64"
  "libmpv_windows-x86_64.dll|PE32\\+ executable \\(DLL\\).*x86-64"
  "libmpv_windows-arm64.dll|PE32\\+ executable \\(DLL\\).*Aarch64"
  "libmpv_android-arm64-v8a.so|ELF 64-bit LSB shared object, ARM aarch64"
  "libmpv_android-armeabi-v7a.so|ELF 32-bit LSB shared object, ARM"
  "libmpv_android-x86_64.so|ELF 64-bit LSB shared object, x86-64"
  "libmpv_ios.xcframework.zip|Zip archive data"
)

# Every observable property our mpv patch set registers. Validated by
# static string presence (Layer 3) so a patch that silently fails to apply
# — leaving its property name out of the binary — is caught here rather
# than only surfacing as a soft-skipped consumer test later.
#   prefetch_state    : prefetch-state, prefetch-cache-duration
#   audio_output_state: audio-output-state
#   embedded_cover    : embedded-cover-art-data, embedded-cover-art-mime
#   pcm_tap           : pcm-tap-frame
#   filter_label_tap  : audio-tap-frames, analyzer-taps
#   bulk_analysis     : waveform-data, waveform-enabled
MPV_PATCHED_PROPS=(
  prefetch-state prefetch-cache-duration
  audio-output-state
  embedded-cover-art-data embedded-cover-art-mime
  pcm-tap-frame
  audio-tap-frames analyzer-taps
  waveform-data waveform-enabled
)

FFMPEG_PATCH_MARKERS=(
  "libsmb2|libsmb2 SMB2 protocol patch"
  "advanced_editlist|mov demuxer fragmented-MP4 editlist patch"
)

mapfile -t REQUIRED_DECODERS < <(echo "$AUDIO_DECODERS" | tr ',' '\n' | head -8)
mapfile -t REQUIRED_FILTERS  < <(echo "$AUDIO_FILTERS"  | tr ',' '\n' | head -10)

FORBIDDEN_VIDEO=(h264 hevc vp8 vp9 av1 mpeg4 mpeg2video mpeg1video theora prores)

# ── Expected dep versions per platform (libplacebo splits by track) ───────────
# All other deps share a single version across all platforms.
expected_version_for() {
  local pkg="$1" platform="$2"
  case "$pkg" in
    ffmpeg)         echo "$FFMPEG_VERSION" ;;
    libass)         echo "$LIBASS_VERSION" ;;
    freetype)       echo "$FREETYPE_VERSION" ;;
    fribidi)        echo "$FRIBIDI_VERSION" ;;
    harfbuzz)       echo "$HARFBUZZ_VERSION" ;;
    fontconfig)     echo "$FONTCONFIG_VERSION" ;;
    zlib)           echo "$ZLIB_VERSION" ;;
    xz|liblzma)     echo "$XZ_VERSION" ;;
    libxml2)        echo "$LIBXML2_VERSION" ;;
    libpng)         echo "$LIBPNG_VERSION" ;;
    rubberband)     echo "$RUBBERBAND_VERSION" ;;
    libsmb2)        echo "$LIBSMB2_VERSION" ;;
    openssl)        echo "$OPENSSL_VERSION" ;;
    libplacebo)
      # macOS / Linux desktop tracks 7.x; iOS / Android / Windows track 6.x.
      case "$platform" in
        macos|linux) echo "7.349.0" ;;
        *)           echo "6.338.2" ;;
      esac ;;
    *) echo "" ;;
  esac
}

# Detect a dep's actual embedded version from the binary's strings dump.
# Returns "" if the version-string pattern wasn't found (i.e., the lib
# doesn't embed a recognisable version string — not necessarily an error).
# `set -o pipefail` is locally disabled because grep returning 1 (no
# match) is an EXPECTED case and would otherwise propagate via pipefail
# and trip set -e in the caller's command substitution.
detect_version_in_binary() {
  set +o pipefail
  local pkg="$1" str="$2"
  # Each dep gets multiple alternative patterns. First match wins.
  # Patterns are based on common embedded version-string formats but
  # stripped/LTO'd binaries may not preserve any of them — that's
  # tolerated (caller treats <unknown> as info, not failure).
  local found=""
  case "$pkg" in
    ffmpeg)
      found=$(grep -oE 'FFmpeg version [0-9]+\.[0-9]+(\.[0-9]+)?'  <<<"$str" | head -1 | awk '{print $3}')
      [[ -z "$found" ]] && found=$(grep -oE 'Lavc[0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | sed 's/^Lavc//' | (
        read v; case "$v" in
          62.28.101) echo "8.1.1" ;;
          61.19.100) echo "7.1.1" ;;
          61.3.100)  echo "7.0.0" ;;
          60.31.102) echo "6.1.1" ;;
          *)         echo "" ;;
        esac))
      ;;
    libplacebo)
      found=$(grep -oE 'libplacebo (v|version )[0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      ;;
    libass)
      found=$(grep -oE 'libass[ /-]v?[0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      ;;
    harfbuzz)
      found=$(grep -oE '(libharfbuzz/|HarfBuzz )[0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      ;;
    freetype)
      found=$(grep -oE 'FreeType [0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | awk '{print $2}')
      ;;
    fribidi)
      found=$(grep -oE 'fribidi[ /-]v?[0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      ;;
    fontconfig)
      found=$(grep -oE 'fontconfig[ /-]v?[0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      ;;
    libpng)
      found=$(grep -oE 'libpng version [0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | awk '{print $3}')
      ;;
    zlib)
      found=$(grep -oE '(zlib|deflate) [0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | awk '{print $2}')
      [[ -z "$found" ]] && found=$(grep -oE 'inflate [0-9]+\.[0-9]+\.[0-9]+ Copyright' <<<"$str" | head -1 | awk '{print $2}')
      ;;
    libxml2)
      found=$(grep -oE 'libxml[ /]v?[0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      ;;
    xz|liblzma)
      found=$(grep -oE '(liblzma|XZ Utils) [0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      ;;
    rubberband)
      found=$(grep -oE 'Rubber Band Library [0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      [[ -z "$found" ]] && found=$(grep -oE 'librubberband[ -]v?[0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      ;;
    libsmb2)
      found=$(grep -oE 'libsmb2[ -]v?[0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
      ;;
    openssl)
      found=$(grep -oE 'OpenSSL [0-9]+\.[0-9]+\.[0-9]+' <<<"$str" | head -1 | awk '{print $2}')
      ;;
  esac
  echo "$found"
}

# Map artifact filename to a canonical platform name (used for libplacebo
# track resolution).
platform_from_artifact() {
  case "$1" in
    *macos*)   echo "macos" ;;
    *ios*)     echo "ios" ;;
    *linux*)   echo "linux" ;;
    *windows*) echo "windows" ;;
    *android*) echo "android" ;;
    *)         echo "unknown" ;;
  esac
}

# ── Output helpers ────────────────────────────────────────────────────────────
PASSED=0; FAILED=0; WARNED=0; SKIPPED_NA=0
declare -A SYMBOL_HASHES_BY_BINARY  # filled per-binary; cross-checked at end

# Structured event emission for the build TUI's Verify view. Off by default, so
# the human-readable output below is byte-identical; set VERIFY_EMIT=1 to also
# print one machine-readable line per event — tab-separated, "@@V1@@"-prefixed.
# The pretty output and these events share stdout; the single pipe the TUI reads
# preserves their order. CUR_BIN / CUR_PHASE carry the context each check is
# tagged with (the binary under test and the phase it belongs to).
CUR_BIN=""; CUR_PHASE=""
emit()  { [[ -n "${VERIFY_EMIT:-}" ]] || return 0; local IFS=$'\t'; printf '@@V1@@\t%s\n' "$*"; }
phase() { CUR_PHASE="$1"; emit phase "$CUR_BIN" "$1"; }

pass()  { printf "  ${GREEN}✓${NC} %s\n" "$*"; PASSED=$((PASSED + 1)); emit check "$CUR_BIN" "$CUR_PHASE" pass "$*"; }
fail()  { printf "  ${RED}✗${NC} %s\n" "$*"; FAILED=$((FAILED + 1)); emit check "$CUR_BIN" "$CUR_PHASE" fail "$*"; }
warn()  { printf "  ${YELLOW}⚠${NC} %s\n" "$*"; WARNED=$((WARNED + 1)); emit check "$CUR_BIN" "$CUR_PHASE" warn "$*"; }
info()  { printf "  ${DIM}· %s${NC}\n" "$*"; emit check "$CUR_BIN" "$CUR_PHASE" info "$*"; }
# na marks a category as Not-Applicable for this platform, with a one-line
# reason (see the matrix at the top). It is distinct from a silent skip: the
# reason is always emitted, and N/A is tallied separately (SKIPPED_NA) so the
# per-OS report shows the SAME set of categories everywhere (✓/⚠/✗/N-A) instead
# of a count that varies for hidden reasons.
na()    { printf "  ${DIM}∅ N/A — %s${NC}\n" "$*"; SKIPPED_NA=$((SKIPPED_NA + 1)); emit check "$CUR_BIN" "$CUR_PHASE" na "$*"; }

# ─────────────────────────────────────────────────────────────────────────────
# Layer 11 — NEEDED allowlist
# ─────────────────────────────────────────────────────────────────────────────
# Each platform has a closed set of system libraries it is allowed to
# reference at runtime. Anything outside the allowlist means we forgot to
# statically link a transitive dependency, OR we picked up a system shim
# that doesn't exist on the user's target (the Android API 37 `libstdc++.so`
# shim case is exactly this).
#
# Lists are deliberately conservative: every entry below maps to a library
# that is either part of the platform's libc/libpthread package or a
# documented system audio backend the build script enables on purpose.
#
# Args: $1 = platform, $2 = newline-separated NEEDED list
layer11_needed_allowlist() {
  local platform="$1" deps="$2"
  phase l11
  local allowed_re=""
  case "$platform" in
    linux)
      # libc + libm + libdl + libpthread + librt = glibc (always present).
      # libstdc++ + libgcc_s = GCC runtime (always present on a Linux desktop).
      # ld-linux* = the dynamic loader itself.
      # libasound / libpulse / libpipewire = audio backends mpv enables.
      # libX11 family + libva + libvdpau = X11 / VA-API / VDPAU stubs (some
      # distros keep them in NEEDED even with the audio-only build).
      # ld-linux variants by arch:
      #   x86_64: ld-linux-x86-64.so.2
      #   aarch64: ld-linux-aarch64.so.1
      #   i386:   ld-linux.so.2
      #   armhf:  ld-linux-armhf.so.3
      allowed_re='^(libc|libm|libdl|libpthread|librt|libresolv|libstdc\+\+|libgcc_s|libasound|libpulse|libpipewire-0\.3|libX11|libXext|libXrandr|libXinerama|libva|libva-drm|libva-x11|libvdpau|ld-linux[-a-zA-Z0-9_]*)\.(so|so\.[0-9]+(\.[0-9]+)*)$'
      ;;
    android)
      # NDK API surface for libmpv: bionic libc + libm + libdl, the loader
      # log, OpenSL ES (audiotrack fallback), AAudio (modern audio output),
      # libandroid (looper / AssetManager). NO libstdc++.so — that's the
      # legacy NDK shim removed in API 37.
      allowed_re='^(libc|libm|libdl|liblog|libOpenSLES|libaaudio|libandroid|libnativewindow|libmediandk|libamidi)\.so$'
      ;;
    windows)
      # PE/COFF NEEDED list comes from `objdump -p | DLL Name:` — stripped of
      # path. The allowlist is the set of system DLLs Microsoft documents as
      # part of the Windows OS ABI. api-ms-win-* are the Universal CRT
      # forwarder DLLs (UCRT). All others must come from inside libmpv.dll.
      # Match is case-insensitive (Windows DLL names are case-folded by
      # the loader); see grep -iE branch below.
      local win_allowed=(
        kernel32 user32 advapi32 ole32 shell32 shlwapi shcore gdi32
        winmm ws2_32 iphlpapi crypt32 secur32 powrprof setupapi
        cfgmgr32 dwmapi dxgi msvcrt ucrtbase ntdll version psapi
        userenv avrt authz bcrypt mf mfplat mfreadwrite mfuuid
        ncrypt pdh propsys wldap32 ccmcpp d2d1 d3d9 d3d10 d3d11
        d3d12 dbghelp oleaut32 imm32 rpcrt4 wininet uxtheme dnsapi
      )
      local win_re_alts; win_re_alts="$(IFS='|'; echo "${win_allowed[*]}")"
      allowed_re="^(${win_re_alts}|api-ms-win-[a-z0-9-]+|d[0-9]+d[0-9_]*)\.dll$"
      ;;
    macos)
      # macOS NEEDED entries are full paths from `otool -L`. Allowlist:
      # libSystem (libc + libm + libdl + libpthread combined), libc++ +
      # libobjc + libiconv (system runtime), and any Apple framework under
      # /System/Library/Frameworks/ or /usr/lib/. The dynamic dylib also
      # reports its own install_name `@rpath/libmpv.framework/libmpv`.
      allowed_re='^(/usr/lib/(libSystem|libc\+\+|libobjc|libiconv|libz|libcompression|libbz2|libxml2|libsqlite3|libnetwork|libresolv|libCoreEntitlements|libFosl)|/System/Library/(Frameworks|PrivateFrameworks)/|@rpath/libmpv\.framework/libmpv)'
      ;;
    ios)
      # The iOS dylib (extracted from the xcframework's device slice) links Apple
      # system frameworks: audio (AVFoundation, AVFAudio, AudioToolbox, CoreAudio,
      # CoreMedia), text shaping (CoreText, via libass), plus Foundation /
      # CoreFoundation / Security … They all live under /System/Library and ship
      # on every device, so allow any of them — the audio-only invariant is
      # enforced separately (§7), not here.
      allowed_re='^(/usr/lib/(libSystem|libc\+\+|libobjc|libiconv)|/System/Library/(Frameworks|PrivateFrameworks)/|@rpath/libmpv\.framework/libmpv)'
      ;;
    *)
      warn "L11: no NEEDED allowlist defined for platform=$platform"
      return 0
      ;;
  esac

  # Windows DLL names are case-insensitive on the OS; match via grep -iE.
  # Linux/Android/macOS NEEDED entries are case-sensitive paths.
  local grep_flags="-E"
  [[ "$platform" == "windows" ]] && grep_flags="-iE"

  local total=0 violations=()
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    total=$((total + 1))
    if ! grep -q $grep_flags "$allowed_re" <<<"$dep"; then
      violations+=("$dep")
    fi
  done <<<"$deps"

  if (( ${#violations[@]} == 0 )); then
    pass "L11 NEEDED allowlist: $total/$total deps in platform whitelist"
  else
    fail "L11 NEEDED allowlist: ${#violations[@]}/$total forbidden dep(s)"
    for v in "${violations[@]}"; do
      printf "       ${RED}✗${NC} %s\n" "$v"
    done | head -10
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 12 — UND symbol resolvability
# ─────────────────────────────────────────────────────────────────────────────
# The dynamic linker, at runtime, resolves every UND (st_shndx=SHN_UNDEF)
# symbol against the union of exports from all NEEDED libraries. If a UND
# symbol has no provider, the load fails. Layer 12 simulates that lookup
# offline by:
#   1. Resolving each NEEDED library to a real .so on the container's
#      filesystem (Linux: /lib/<triple>/, Android: NDK sysroot stubs at
#      /ndk-sysroot/<arch>/, mounted from the host by the build orchestrator).
#   2. Building a sorted union of exported symbol names across all those
#      .so files using `readelf -W --dyn-syms`.
#   3. Diff'ing the binary's UND set against that union via comm -23.
#   4. Filtering the diff against a whitelist of well-known weak symbols
#      and loader stubs that don't need a NEEDED provider (gmon, ITM,
#      __cxa_finalize fallback, etc.).
# Anything left is a runtime-load failure waiting to happen.
#
# Args: $1 = platform, $2 = arch (x86_64|aarch64|arm64-v8a|x86),
#       $3 = artifact path, $4 = newline-separated NEEDED list
layer12_und_resolvable() {
  local platform="$1" arch="$2" artifact="$3" deps="$4"
  phase l12
  local triple="" sysroot=""

  # Map (platform, arch) → multiarch sysroot path within the container.
  case "$platform/$arch" in
    linux/x86_64)         triple="x86_64-linux-gnu" ;;
    linux/aarch64)        triple="aarch64-linux-gnu" ;;
    android/arm64-v8a)    triple="aarch64-linux-android" ;;
    android/armeabi-v7a)  triple="arm-linux-androideabi" ;;
    android/x86_64)       triple="x86_64-linux-android" ;;
    windows/*)
      na "UND resolvability is nm/ELF-based; a PE's imports are bound by the Windows loader at runtime — covered by the L13 LoadLibrary load test instead."
      return 0
      ;;
    macos/*|ios/*)
      na "UND resolvability is nm/ELF-based; a Mach-O dylib's binds are resolved by Apple's dyld (validated at consumer link/load), not introspectable with nm here."
      return 0
      ;;
    *)
      warn "L12: no triple mapping for $platform/$arch"
      return 0
      ;;
  esac

  # Locate exports by walking NEEDED → real .so. Linux: /lib/<triple>/.
  # Android: /ndk-sysroot/<arch>/, expected mounted by the build orchestrator.
  local search_dirs=()
  case "$platform" in
    linux)
      search_dirs=("/lib/$triple" "/usr/lib/$triple" "/lib" "/usr/lib")
      ;;
    android)
      # NDK ships per-API-level stub .so files. We use API 24 stubs (the
      # minimum mpv_audio_kit officially supports).
      search_dirs=(
        "/ndk-sysroot/$triple/24"
        "/ndk-sysroot/$triple"
      )
      if [[ ! -d "/ndk-sysroot/$triple" && ! -d "/ndk-sysroot/$triple/24" ]]; then
        warn "L12: NDK sysroot not mounted at /ndk-sysroot — Android UND check skipped (mount the NDK in './build verify' to enable)"
        return 0
      fi
      ;;
  esac

  # Build exports union. Each NEEDED entry is resolved to its first match
  # under search_dirs. Missing system libs → warning (means our allowlist
  # is right but the container doesn't ship the .so to introspect).
  #
  # We use `nm -D --defined-only --extern-only` (not readelf-awk) for two
  # reasons: (a) nm output is column-stable across binutils versions, and
  # (b) by default it includes every dynamic symbol the dynamic linker
  # would consider during resolution — both GLOBAL and WEAK bindings
  # (huge for C++ stdlib, where most template instantiations are WEAK).
  # The earlier readelf approach with `$5=="GLOBAL"` silently dropped
  # ~4000 weak C++ symbols out of libstdc++.so.6.
  local exports_db="$(mktemp)"
  local missing=()
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    local found=""
    for d in "${search_dirs[@]}"; do
      [[ -f "$d/$dep" ]] && { found="$d/$dep"; break; }
    done
    if [[ -z "$found" ]]; then
      missing+=("$dep")
      continue
    fi
    # nm -D output is "<addr> <type> <name>". Type single letter:
    # T/t=text, D/d=data, B/b=bss, R/r=rodata, W/w=weak, V/v=weak object,
    # i=indirect, U=undefined. We want everything DEFINED — i.e. anything
    # that is NOT 'U'. The dynamic linker resolves UND of one .so against
    # any of these in another .so.
    nm -D --defined-only --extern-only "$found" 2>/dev/null \
      | awk '$2 != "U" && $NF != "" {sub(/@.*/,"",$NF); print $NF}' \
      >> "$exports_db" || true
  done <<<"$deps"

  if (( ${#missing[@]} > 0 )); then
    warn "L12: NEEDED .so missing in container (cannot introspect): ${missing[*]}"
  fi

  # Linux only: also fold in the dynamic linker's exports. ld-linux-*.so
  # provides __libc_start_main, __cxa_finalize, dl_iterate_phdr, etc.,
  # which are referenced by binaries but rarely appear in NEEDED.
  if [[ "$platform" == "linux" ]]; then
    for ld in /lib/ld-linux-${arch//-/_}.so.* /lib/ld-linux*.so.* /lib64/ld-linux*.so.*; do
      [[ -f "$ld" ]] || continue
      nm -D --defined-only --extern-only "$ld" 2>/dev/null \
        | awk '$2 != "U" && $NF != "" {sub(/@.*/,"",$NF); print $NF}' \
        >> "$exports_db" || true
    done
  fi

  sort -u "$exports_db" -o "$exports_db"

  # Get UND symbols of the binary, strip version tag, sort/uniq. Only STRONG
  # undefined (nm type 'U') must resolve against a NEEDED lib. WEAK undefined
  # ('w'/'v') is loader-legal: it resolves to 0 when absent and the caller
  # guards the call — e.g. OpenSSL references getentropy() weakly when built
  # with __ANDROID_API__ < 28 (added to bionic in 28), with a /dev/urandom
  # fallback, so the .so stays correct on the API-24 floor.
  local und_db="$(mktemp)"
  nm -D --undefined-only "$artifact" 2>/dev/null \
    | awk '$1 == "U" && $NF != "" {sub(/@.*/,"",$NF); print $NF}' \
    | sort -u > "$und_db"

  # Whitelist of symbols that legitimately stay UND in a .so:
  #   __gmon_start__, _ITM_*  → gprof / Intel TM stubs (always weak).
  #   _Jv_RegisterClasses     → GCJ stub (weak, deprecated).
  #   _DYNAMIC, _GLOBAL_OFFSET_TABLE_ → loader-internal sections, not real syms.
  #   __cxa_finalize          → glibc 2.2+ exits handler, weak by definition.
  #   __register_atfork       → glibc 2.27+, weak.
  #   _Unwind_*               → libgcc_s, but some distros mark as weak.
  local weak_re='^(__gmon_start__|_ITM_(deregisterTMCloneTable|registerTMCloneTable)|_Jv_RegisterClasses|_DYNAMIC|_GLOBAL_OFFSET_TABLE_|__cxa_finalize|__register_atfork|_edata|_end|__bss_start)$'
  local unresolved="$(mktemp)"
  comm -23 "$und_db" "$exports_db" 2>/dev/null \
    | grep -vE "$weak_re" > "$unresolved" || true

  local und_count exports_count unresolved_count
  und_count=$(wc -l <"$und_db" | tr -d ' ')
  exports_count=$(wc -l <"$exports_db" | tr -d ' ')
  unresolved_count=$(wc -l <"$unresolved" | tr -d ' ')

  if (( unresolved_count == 0 )); then
    pass "L12 UND resolvability: all $und_count UND symbols resolve against $exports_count NEEDED exports"
  else
    fail "L12 UND resolvability: $unresolved_count/$und_count UND symbol(s) NOT resolved by any NEEDED lib"
    head -10 "$unresolved" | sed 's/^/       · /'
    if (( unresolved_count > 10 )); then
      printf "       (+%d more)\n" $((unresolved_count - 10))
    fi
  fi

  rm -f "$exports_db" "$und_db" "$unresolved"
  # Explicit return so the function never propagates a non-zero exit from
  # an optional sub-command — set -e in the caller would otherwise abort
  # the per-binary loop after a mid-flight transient (e.g. a closed pipe
  # in `head | sed`, an arithmetic comparison's status, etc.).
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 13 — runtime load test
# ─────────────────────────────────────────────────────────────────────────────
# This is what catches everything Layers 12+13 might miss: the actual
# dynamic loader walks the binary's relocations and binds every symbol with
# RTLD_NOW semantics. If something is wrong, we get the exact error message
# the user would see at app startup.
#
#   Linux  → compile dlopen_test with the matching cross-gcc, run via
#            qemu-user-static if foreign-arch (image is built native to
#            host arch via $BUILDPLATFORM, so on Apple Silicon arm64 = host
#            and amd64 = qemu; reverse on x86_64 hosts).
#   Windows→ cross-compile winload_test.exe with x86_64-w64-mingw32-gcc or
#            aarch64-w64-mingw32-clang, run via wine64.
#   Android→ skipped: no easy emulator-less load path. Layers 12+13 carry
#            the load.
#   macOS  → skipped here: the artifact path under .xcframework requires
#            xcrun on the host. The maintainer's local `flutter test` on
#            macOS already exercises the dyld load.
#   iOS    → skipped: static archive, no runtime loader. Validated at
#            consumer link-time when building the iOS test_app.
#
# Args: $1 = platform, $2 = arch, $3 = artifact path, $4 = inspect path
#       (the extracted inner Mach-O for xcframeworks; == artifact otherwise)
layer13_load_test() {
  local platform="$1" arch="$2" artifact="$3" inspect="${4:-$3}"
  phase l13

  case "$platform" in
    linux)
      _l13_linux_dlopen "$arch" "$artifact"
      ;;
    windows)
      _l13_windows_loadlibrary "$arch" "$artifact"
      ;;
    android)
      na "no emulator-less Android load path; UND resolvability (L12) + JNI stub detection (L14) carry the runtime guarantee here."
      ;;
    macos)
      # Runs the REAL dyld load when verify is invoked natively on a macOS host
      # (./scripts/verify_binaries.sh macos). Inside the Linux build container it
      # self-reports N/A with that pointer — a macOS dylib cannot be dlopen'd by a
      # Linux loader.
      _l13_macos_dlopen "$inspect"
      ;;
    ios)
      na "iOS device slice targets arm64-ios; no host loader (the simulator slice needs the iOS Simulator runtime, not plain dyld). Static layers (1-11) + the consumer link-time check cover it."
      ;;
    *)
      warn "L13: no load test for platform=$platform"
      ;;
  esac
}

# macOS dlopen(RTLD_NOW) on a Darwin host. Closes the L13 gap for macOS: when
# verify runs natively on the Mac (clang present), it compiles the shared
# dlopen_test helper with the host clang and loads the universal dylib's
# host-arch slice — the exact dyld bind a Flutter app does at startup — then
# creates + initializes an mpv handle and reads back patched properties.
_l13_macos_dlopen() {
  local dylib="$1"
  if [[ "$(uname -s)" != "Darwin" ]]; then
    na "macOS dlopen needs a macOS host; this run is on $(uname -s) (e.g. the Linux build container — a Mach-O dylib cannot be loaded there). Run ./scripts/verify_binaries.sh macos natively on macOS to exercise the real dyld load; static layers (1-11) validate the dylib here."
    return 0
  fi
  if ! command -v clang >/dev/null 2>&1; then
    na "macOS dlopen needs clang (Xcode Command Line Tools) on the host; not found. Static layers (1-11) validate the dylib."
    return 0
  fi
  if [[ -z "$dylib" || ! -f "$dylib" ]]; then
    warn "L13 macOS: inner libmpv dylib not found to dlopen"
    return 0
  fi
  local helper_src="$LIBMPV_SCRIPTS_ROOT/verify/dlopen_test.c"
  if [[ ! -f "$helper_src" ]]; then
    warn "L13: dlopen helper missing: $helper_src"
    return 0
  fi
  local helper_bin; helper_bin="$(mktemp)"
  # macOS: dlopen/dlsym live in libSystem (no -ldl needed). Build for the host
  # arch so dlopen resolves the matching universal slice.
  if ! clang -O0 -o "$helper_bin" "$helper_src" 2>/dev/null; then
    fail "L13: dlopen helper failed to compile with host clang"
    rm -f "$helper_bin"
    return 0
  fi
  # The shipped dylib is adhoc-signed but the build's `strip -x` rewrote the
  # Mach-O AFTER signing, so its CodeDirectory hashes no longer match. On Apple
  # Silicon the kernel SIGKILLs any process that dlopen()s a broken-signature
  # image, so re-sign an adhoc COPY (the original is untouched; a consumer app
  # re-signs the dylib as part of its own bundle anyway). codesign is part of
  # the Xcode CLT that already provides clang above.
  local load_dylib="$dylib" signed_copy=""
  if command -v codesign >/dev/null 2>&1; then
    signed_copy="$(mktemp)"
    if cp "$dylib" "$signed_copy" && codesign --force --sign - "$signed_copy" 2>/dev/null; then
      load_dylib="$signed_copy"
    else
      rm -f "$signed_copy"; signed_copy=""
    fi
  fi
  local TO=()
  if command -v timeout  >/dev/null 2>&1; then TO=(timeout 60)
  elif command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout 60); fi
  local out rc
  out="$("${TO[@]}" "$helper_bin" "$load_dylib" 2>&1)"; rc=$?
  rm -f "$helper_bin"; [[ -n "$signed_copy" ]] && rm -f "$signed_copy"
  case "$rc" in
    0)   pass "L13 dlopen(RTLD_NOW, host dyld): loads + initializes + patched props respond at runtime ($(uname -m) slice)" ;;
    124) fail "L13 dlopen timed out after 60s: $out" ;;
    137) fail "L13 dlopen killed (SIGKILL=137) — likely a code-signature rejection the adhoc re-sign didn't fix: $out" ;;
    *)   fail "L13 dlopen failed (exit=$rc): $out" ;;
  esac
  return 0
}

_l13_linux_dlopen() {
  local arch="$1" artifact="$2"
  local cc="" qemu=""
  case "$arch" in
    x86_64)  cc="x86_64-linux-gnu-gcc"  qemu="qemu-x86_64-static"  ;;
    aarch64) cc="aarch64-linux-gnu-gcc" qemu="qemu-aarch64-static" ;;
    *) warn "L13: unsupported linux arch=$arch"; return 0 ;;
  esac

  local helper_src="$LIBMPV_SCRIPTS_ROOT/verify/dlopen_test.c"
  if [[ ! -f "$helper_src" ]]; then
    warn "L13: dlopen helper missing: $helper_src"
    return 0
  fi

  local helper_bin
  helper_bin="$(mktemp)"
  if ! "$cc" -O0 -o "$helper_bin" "$helper_src" -ldl 2>/dev/null; then
    fail "L13: dlopen helper failed to cross-compile for $arch"
    rm -f "$helper_bin"
    return 0
  fi

  # Decide native vs qemu based on host arch (image arch). qemu-user-static
  # is invoked only when foreign — qemu adds ~50ms overhead but is otherwise
  # transparent.
  local host_arch; host_arch="$(uname -m)"
  local runner=()
  case "$host_arch/$arch" in
    x86_64/x86_64|aarch64/aarch64) ;;
    *)
      if ! command -v "$qemu" >/dev/null 2>&1; then
        warn "L13: qemu-user-static missing for $arch on $host_arch host — load test skipped"
        rm -f "$helper_bin"
        return 0
      fi
      runner=("$qemu")
      ;;
  esac

  # Stage the binary + helper next to each other so dlopen() finds it via
  # rpath-less name. We pass the absolute path anyway, so this is just for
  # tidiness.
  # 60s timeout guards against any future regression where dlopen hangs on
  # a misbehaving constructor or fork+exec inside a static dep.
  local out rc
  out="$(timeout 60 "${runner[@]}" "$helper_bin" "$artifact" 2>&1)"
  rc=$?
  rm -f "$helper_bin"
  case "$rc" in
    0)   pass "L13 dlopen(RTLD_NOW): loads + initializes + patched props respond at runtime" ;;
    124) fail "L13 dlopen timed out after 60s: $out" ;;
    *)   fail "L13 dlopen failed (exit=$rc): $out" ;;
  esac
  return 0
}

# Wine state for L13. Set once per run.
WINE_PREFIX_READY=0

# _wine_prepare exports a valid XDG_RUNTIME_DIR + HOME (Wine and Box64/FEX spin
# on "XDG_RUNTIME_DIR is invalid or not set in the environment" without one) and
# initializes the Wine prefix a single time, so the per-DLL load test below isn't
# racing a from-scratch wineboot under its own timeout.
_wine_prepare() {
  local wine_bin="$1"
  export HOME="${HOME:-/root}"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/wine-xdg}"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
  [[ "$WINE_PREFIX_READY" == "1" ]] && return 0
  WINE_PREFIX_READY=1
  log "L13: initializing the Wine prefix once (slow under arm64 emulation)…"
  WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;mshtml=" \
    timeout 180 "$wine_bin" wineboot --init >/dev/null 2>&1 || true
}

_l13_windows_loadlibrary() {
  local arch="$1" artifact="$2"

  # Which (host, PE) combos can we actually LoadLibrary under Wine?
  #   • x86_64 host → distro Wine runs an x86_64 PE natively.
  #   • arm64 host with Hangover (Wine + WoW64 + FEX/Box64; see
  #     docker/Dockerfile) → loads BOTH x86_64 (via the libarm64ecfex FEX
  #     emulator) and aarch64 (native) Windows PEs. This is what lets a
  #     single arm64 machine runtime-validate every Windows binary.
  # Anything else falls back to L11 (NEEDED allowlist, static).
  local host_arch; host_arch="$(uname -m)"
  local pe_arch_norm="$arch"
  [[ "$pe_arch_norm" == "arm64" ]] && pe_arch_norm="aarch64"

  local fex_dll="/usr/lib/wine/aarch64-windows/libarm64ecfex.dll"
  local can_run=0 via="native Wine"
  if [[ "$host_arch" == "x86_64" && "$pe_arch_norm" == "x86_64" ]]; then
    can_run=1
  elif [[ "$host_arch" == "aarch64" || "$host_arch" == "arm64" ]] && [[ -f "$fex_dll" ]]; then
    can_run=1; via="Hangover/FEX"
  fi

  if [[ $can_run -eq 0 ]]; then
    info "L13: Windows LoadLibrary skipped (host=$host_arch PE=$pe_arch_norm, no capable Wine — install Hangover for arm64). L11 NEEDED allowlist still validates."
    return 0
  fi

  if ! command -v wine >/dev/null 2>&1; then
    warn "L13: wine not installed in container — Windows load test skipped"
    return 0
  fi
  local wine_bin; wine_bin="$(command -v wine64 2>/dev/null || command -v wine)"

  local cc=""
  case "$pe_arch_norm" in
    x86_64)  cc="x86_64-w64-mingw32-gcc" ;;
    aarch64) cc="${LLVM_MINGW_DIR:-/opt/llvm-mingw}/bin/aarch64-w64-mingw32-clang" ;;
  esac

  local helper_src="$LIBMPV_SCRIPTS_ROOT/verify/winload_test.c"
  if [[ ! -f "$helper_src" ]]; then
    warn "L13: winload helper missing: $helper_src"
    return 0
  fi

  # Compile the helper into its OWN dedicated directory, and below run it with
  # the working directory set to THAT directory (passing the DLL by absolute
  # path). This is load-bearing on arm64: Box64/WowBox64/FEX, when launching an
  # x86_64 PE whose working directory differs from the executable's own module
  # directory, faults during process *teardown* and exits 29 — even though the
  # LoadLibrary + mpv_create + mpv_initialize + patched-property reads all
  # succeed. Bisected exhaustively: exit-code 29 ⇔ (cwd ≠ helper's module dir)
  # AND x86_64-via-Box64; native aarch64 PEs and an x86_64 host are immune.
  # Co-locating the cwd with the helper sidesteps the quirk so the real runtime
  # test runs to completion and PASSES, instead of warning "inconclusive". It's
  # cheap and harmless on the native-host path.
  local helper_dir; helper_dir="$(mktemp -d)"
  local helper_exe="$helper_dir/winload_test.exe"
  if ! "$cc" -O0 -o "$helper_exe" "$helper_src" -static 2>/dev/null; then
    fail "L13: winload helper failed to cross-compile for $pe_arch_norm"
    rm -rf "$helper_dir"
    return 0
  fi

  # Ensure XDG_RUNTIME_DIR/HOME are set and the Wine prefix is initialized once
  # (see _wine_prepare) — without a valid XDG_RUNTIME_DIR, Wine + Box64/FEX loop
  # on "XDG_RUNTIME_DIR is invalid or not set" and the load test hangs to its
  # timeout. WINEDEBUG=-all + the gecko/mono overrides keep wineboot quiet.
  _wine_prepare "$wine_bin"
  local out rc dll_abs
  dll_abs="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"
  out="$(cd "$helper_dir" && \
    HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;mshtml=" \
    timeout 90 "$wine_bin" "winload_test.exe" "$dll_abs" 2>&1)"
  rc=$?
  rm -rf "$helper_dir"
  case "$rc" in
    0)
      pass "L13 LoadLibrary ($via): DLL loads + initializes + patched props respond at runtime"
      ;;
    1)
      # The helper's deliberate failure (LoadLibrary / GetProcAddress / init /
      # patched-property mismatch) — a real defect, with a diagnostic on stderr.
      # Filter the Box64/Wine startup noise so the actual reason is visible.
      fail "L13 LoadLibrary failed: $(printf '%s' "$out" | grep -avE 'BOX64|WowBox64|XDG_RUNTIME|^wine:|created the configuration' | tail -2 | tr '\n' ' ')"
      ;;
    124)
      # A timeout under Box64/FEX emulation means the runtime check couldn't
      # finish — not that the DLL is broken. The static layers (L11 NEEDED
      # allowlist) already validate it, so warn instead of failing.
      warn "L13 LoadLibrary inconclusive: Wine/emulation timed out after 90s (prefix init under Box64/FEX is slow). Static checks still validate the DLL."
      ;;
    *)
      # The helper only ever returns 0 or 1. The previously-common code 29 (a
      # Box64/FEX teardown fault) is fixed by the cwd co-location above, so any
      # OTHER abnormal code now means an unexpected emulator crash, not a broken
      # DLL — still inconclusive (the static layers validate it), but surface the
      # code so a genuinely new emulator regression is visible.
      warn "L13 LoadLibrary inconclusive: helper exited abnormally (code $rc) under Box64/FEX emulation — unexpected (the cwd-teardown fix should prevent code 29). Static checks still validate the DLL."
      ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 14 — stub-function detection (defense in depth for Layer 0)
# ─────────────────────────────────────────────────────────────────────────────
# A binary can pass every previous layer (correct format, exports, NEEDED,
# UND resolvability, even a real dlopen) and STILL be functionally broken
# at runtime if a critical internal function was compiled as an
# unconditional-error stub. Concrete case that bit us:
#
#   - ffmpeg's `libavcodec/jni.c` defines `av_jni_set_java_vm` only when
#     CONFIG_JNI=1; otherwise the file falls through to a 2-instruction
#     stub that returns AVERROR(ENOSYS) without storing the VM pointer.
#   - Layer 0 (build-time config audit) catches this PRE-link.
#   - Layer 14 catches it POST-link, as a redundant guard for when
#     binaries are built outside our control (e.g. CI fetches them).
#
# Algorithm (Android only — the only platform with a critical exported
# entry point that delegates to an internal function):
#   1. Find JNI_OnLoad's address (it's exported and in our version script).
#   2. Disassemble JNI_OnLoad's first ~16 instructions.
#   3. Find its `bl <addr>` (aarch64) or `callq <addr>` (x86_64).
#   4. Disassemble the target's first ~32 instructions.
#   5. Count instructions before the first `ret`. Real
#      av_jni_set_java_vm has 30+ (prologue, mutex_lock, globals, mutex_
#      unlock, epilogue); stub has 2 (mov, ret).
#
# < 5 instructions → fail loudly with the diagnostic the maintainer needs
# (almost always: "ffmpeg was built without --enable-jni").
layer14_stub_detection() {
  local platform="$1" arch="$2" artifact="$3"
  phase l14
  case "$platform" in
    android) _l14_jni_onload_real "$arch" "$artifact" ;;
    *)       na "stub detection targets Android's JNI_OnLoad→av_jni_set_java_vm delegate chain, which only exists on Android." ;;
  esac
  return 0
}

_l14_jni_onload_real() {
  local arch="$1" so="$2"
  local nm objdump
  case "$arch" in
    arm64-v8a)   nm="aarch64-linux-gnu-nm";    objdump="aarch64-linux-gnu-objdump"    ;;
    armeabi-v7a) nm="arm-linux-gnueabihf-nm";  objdump="arm-linux-gnueabihf-objdump"  ;;
    x86_64)      nm="x86_64-linux-gnu-nm";     objdump="x86_64-linux-gnu-objdump"     ;;
    *) warn "L14: unknown android arch $arch"; return 0 ;;
  esac

  # JNI_OnLoad must be exported (Layer 2 already validates it; reading it
  # here gives us the address for follow-up disassembly).
  local jni_addr
  jni_addr=$("$nm" -D --defined-only "$so" 2>/dev/null \
    | awk '$3=="JNI_OnLoad" {print "0x"$1; exit}')
  if [[ -z "$jni_addr" ]]; then
    fail "L14: JNI_OnLoad missing — Android JNI bootstrap not wired"
    return 0
  fi

  # Disassemble JNI_OnLoad's first ~16 instructions (64 bytes), look for
  # the bl/callq target. JNI_OnLoad is a 4-instruction wrapper around
  # av_jni_set_java_vm so the call is always within the first 16 bytes.
  # binutils objdump emits `bl 917d0c <symbol+offset>` (no `0x` prefix)
  # whereas llvm-objdump emits `bl 0x917d0c`; awk-extract the address
  # field robustly across both.
  local jni_addr_dec=$((jni_addr))
  local target
  target=$("$objdump" -d \
      --start-address=$jni_addr_dec --stop-address=$((jni_addr_dec + 64)) \
      "$so" 2>/dev/null \
    | awk '
        # aarch64 binutils → "bl 917d0c <sym+off>"
        # x86_64  binutils → "call a01750 <sym+off>"
        # llvm-objdump     → "bl 0x917d0c" / "callq 0xa01750"
        $0 ~ /[[:space:]](bl|call|callq)[[:space:]]/ {
          for (i=1; i<=NF; i++) {
            if ($i == "bl" || $i == "call" || $i == "callq") {
              v = $(i+1)
              sub(/<.*/, "", v)        # strip "<symbol+offset>" suffix
              sub(/^0x/, "", v)        # strip "0x" prefix if present
              if (v ~ /^[0-9a-fA-F]+$/) { print "0x" v; exit }
            }
          }
        }')

  if [[ -z "$target" ]]; then
    fail "L14: JNI_OnLoad has no bl/callq instruction — likely a no-op stub"
    return 0
  fi

  # Disassemble target's first 64 instructions (256 bytes), count
  # instructions before first `ret` / `retq`.
  local target_dec=$((target))
  local n_insns
  n_insns=$("$objdump" -d \
      --start-address=$target_dec --stop-address=$((target_dec + 256)) \
      "$so" 2>/dev/null \
    | awk '
        # Count instructions until the function returns. Return idioms are
        # arch-specific: x86 ret/retq, AArch64 ret, ARM32 bx lr /
        # pop {..,pc} / ldm ..,{..,pc} / mov pc,lr. Without the ARM32 forms
        # the counter never terminates on a 32-bit-ARM .so and a real
        # function reads as a 0-instruction stub.
        /^[[:space:]]*[0-9a-f]+:/ {
          n++
          if ($0 ~ /[[:space:]](ret|retq)([[:space:]]|$)/ ||
              $0 ~ /[[:space:]]bx[[:space:]]+lr([[:space:]]|$)/ ||
              $0 ~ /\{[^}]*pc[[:space:]]*\}/ ||
              $0 ~ /[[:space:]]mov[[:space:]]+pc,[[:space:]]*lr/) { print n; exit }
        }')

  if [[ -z "$n_insns" ]] || (( n_insns < 5 )); then
    fail "L14: JNI_OnLoad → av_jni_set_java_vm at $target is a stub (${n_insns:-0} insns before ret); ffmpeg likely missing --enable-jni"
  else
    pass "L14 stub detection: JNI_OnLoad chain is real ($n_insns insns, target $target)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 7b — adaptive feature presence (tracks Settings ▸ Patches strips)
# ─────────────────────────────────────────────────────────────────────────────
# Cross-checks the binary against the CURRENT reduction-patch selection (read
# from DISABLED_PATCHES via _audio_only.sh, which the build TUI writes into
# _user_overrides.sh). For each toggleable strip we look for a marker string
# that is reliably present ONLY when the subsystem is actually linked — chosen
# empirically against the shipped binaries so it survives strip + LTO:
#
#   strip_swscale       → "libswscale"          (av_log version banner row + lib)
#   strip_libass        → "FreeType"/"HarfBuzz" (font stack; the bare "libass"
#                                                 token is NOT used — the
#                                                 "libass-version" property name
#                                                 persists even when stripped)
#   strip_mpv_dead      → "gpu-next"/"vo_gpu"   (the GPU VO names; "screenshot"
#                                                 / "libplacebo" persist when
#                                                 stripped so are NOT used)
#   strip_win_resources → a PE ".rsrc" section  (Windows only; the icon resource)
#
# A marker being PRESENT is strong evidence the subsystem is linked (a removed
# library leaves no string literals behind). A marker being ABSENT is weaker —
# aggressive LTO could remove it even when the code is in — so the assertion is
# asymmetric: a feature that must be STRIPPED but whose marker is present is a
# hard fail (the strip silently didn't take); a feature that must be KEPT but
# whose marker is missing is a warn (surfaced; the L13 load test + build-time
# config audit carry the runtime guarantee). The common case — verifying a
# default all-stripped build — asserts every marker absent and passes cleanly.
#
# It also asserts the always-on audio-path features are present (HTTPS/TLS,
# rubberband, DASH, OpenSSL, and SMB2 when the libsmb2 patch is enabled).

# _feat_assert <label> <present|absent> <marker-hit-count>
_feat_assert() {
  local label="$1" expected="$2" found="$3"
  if [[ "$expected" == absent ]]; then
    if (( found > 0 )); then
      fail "feature $label: present but selection says STRIPPED (marker hits=$found) — strip patch did not take effect"
    else
      pass "feature $label: correctly absent (stripped)"
    fi
  else
    if (( found > 0 )); then
      pass "feature $label: present as selected (marker hits=$found)"
    else
      warn "feature $label: selected as KEPT but no static marker found (LTO may have removed it; L13 load + build-time config audit cover the runtime guarantee)"
    fi
  fi
}

# Args: $1 platform  $2 str_text  $3 inspect-path  $4 LLVM bin dir
layer_feature_presence() {
  local platform="$1" str="$2" inspect="$3" LD="$4"
  phase features
  local n

  # swscale — "libswscale" appears 0× on a stripped binary (verified on the
  # shipped linux/android artifacts).
  n=$(grep -cF "libswscale" <<<"$str" || true)
  if swscale_stripped; then _feat_assert "libswscale (pixel scaler)" absent "$n"
  else                      _feat_assert "libswscale (pixel scaler)" present "$n"; fi

  # libass + font stack — FreeType/HarfBuzz are 0× when stripped; they only
  # enter the binary via the font chain that strip_libass removes.
  n=$(grep -ciE 'freetype|harfbuzz' <<<"$str" || true)
  if libass_stripped; then _feat_assert "libass + font stack" absent "$n"
  else                     _feat_assert "libass + font stack" present "$n"; fi

  # GPU/render/screenshot stack — the GPU VO names gpu-next/vo_gpu are 0× when
  # strip_mpv_dead removed video/out/*.
  n=$(grep -ciE 'gpu-next|vo_gpu' <<<"$str" || true)
  if patch_on strip_mpv_dead; then _feat_assert "GPU/render stack" absent "$n"
  else                             _feat_assert "GPU/render stack" present "$n"; fi

  # Windows icon/manifest/version resources — a PE .rsrc section. No-op patch
  # off Windows, so there is nothing to assert there.
  if [[ "$platform" == windows ]]; then
    local rsrc=0
    if [[ -x "$LD/llvm-objdump" ]]; then
      rsrc=$("$LD/llvm-objdump" -h "$inspect" 2>/dev/null | grep -c '\.rsrc' || true)
    elif command -v objdump >/dev/null 2>&1; then
      rsrc=$(objdump -h "$inspect" 2>/dev/null | grep -c '\.rsrc' || true)
    fi
    if patch_on strip_win_resources; then
      if (( rsrc > 0 )); then fail "feature Windows icon/.rsrc: present but selection says STRIPPED"
      else                    pass "feature Windows icon/.rsrc: correctly absent (stripped)"; fi
    else
      if (( rsrc > 0 )); then pass "feature Windows icon/.rsrc: present as selected"
      else                    warn "feature Windows icon/.rsrc: selected as KEPT but no .rsrc section found"; fi
    fi
  else
    na "Windows icon/resources strip is a no-op off Windows (the resource block is win32-gated)."
  fi

  # ── Always-on audio-path features — must be present on every platform ──
  local e mk lbl
  for e in "https:HTTPS/TLS protocol" "rubberband:rubberband (pitch/tempo)" "dash:DASH demuxer" "OpenSSL:OpenSSL TLS backend"; do
    mk="${e%%:*}"; lbl="${e#*:}"
    if grep -qiF "$mk" <<<"$str"; then pass "feature present: $lbl"
    else fail "feature MISSING: $lbl (marker '$mk')"; fi
  done
  # SMB2/NAS — adaptive on the libsmb2 patch (same selection that gates the
  # protocol in ffmpeg_common_args).
  n=$(grep -ciE 'smb2' <<<"$str" || true)
  if patch_on libsmb2; then
    if (( n > 0 )); then pass "feature present: SMB2/NAS protocol"
    else fail "feature MISSING: SMB2/NAS protocol (libsmb2 patch enabled)"; fi
  else
    info "SMB2/NAS protocol: libsmb2 patch disabled — not asserted"
  fi
}

# Map a libmpv_<plat>-<arch>.<ext> filename → arch token.
arch_from_artifact() {
  case "$1" in
    *-x86_64.*)        echo "x86_64" ;;
    *-aarch64.*)       echo "aarch64" ;;
    *-armeabi-v7a.*)   echo "armeabi-v7a" ;;
    *-arm64-v8a.*)     echo "arm64-v8a" ;;
    *-arm64.*)         echo "arm64" ;;
    *)                 echo "" ;;
  esac
}

# Layer 15: Apple code-signing identity. For every slice in a libmpv.xcframework
# the embedded code-signing identifier (parsed from the Mach-O CodeDirectory)
# must equal that framework's CFBundleIdentifier. iOS `installd` rejects a
# device install on any mismatch (MismatchedBundleIDSigningIdentifier) — the
# exact libmpv-r9 / 0.3.5 regression, which passed every other layer because
# only a physical-device install enforces this rule (Simulator, macOS, dlopen
# and flutter test all ignore it). The signature is parsed directly
# (verify/codesign_ident.py), so this runs in the build container — meson
# already requires python3 — without needing macOS-only `codesign`.
# Args: $1 = platform, $2 = extracted xcframework dir ($xcf_tmp, may be empty)
layer15_codesign_identity() {
  local platform="$1" xcf_dir="$2"
  phase l15
  case "$platform" in
    macos|ios) ;;
    *) na "Apple code-signing only; $platform binaries are not embedded-signed .framework bundles (the identifier==bundle-id rule is an Apple loader concern)."; return 0 ;;
  esac
  if [[ -z "$xcf_dir" || ! -d "$xcf_dir" ]]; then
    warn "L15: xcframework not extracted — cannot inspect signing identity"
    return 0
  fi
  local helper="$LIBMPV_SCRIPTS_ROOT/verify/codesign_ident.py"
  if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "$helper" ]]; then
    na "needs python3 + verify/codesign_ident.py to parse the Mach-O CodeDirectory; neither present here."
    return 0
  fi
  local out rc
  out="$(python3 "$helper" "$xcf_dir" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    while IFS= read -r line; do [[ -n "$line" ]] && info "$line"; done <<<"$out"
    pass "L15 code-signing identity == CFBundleIdentifier on every slice (installs on a physical iPhone)"
  else
    while IFS= read -r line; do [[ -n "$line" ]] && printf "     %s\n" "$line"; done <<<"$out"
    fail "L15 code-signing identity != CFBundleIdentifier — iOS installd would reject this on a physical device (MismatchedBundleIDSigningIdentifier)"
  fi
}

# ── Per-binary check runner ───────────────────────────────────────────────────
check_binary() {
  local artifact="$1"
  local name; name="$(basename "$artifact")"
  local platform; platform="$(platform_from_artifact "$name")"

  printf "\n${BOLD}════ %s ${DIM}[%s]${NC}\n" "$name" "$platform"
  CUR_BIN="$name"; CUR_PHASE=""
  emit bin "$name" "$platform"

  # ── 1. format/arch ──
  phase fmt
  local actual_format expected_format=""
  actual_format="$(file -b "$artifact")"
  printf "  ${DIM}format: %s${NC}\n" "$actual_format"
  for entry in "${EXPECTED_FORMATS[@]}"; do
    if [[ "$entry" == "$name|"* ]]; then
      expected_format="${entry#*|}"; break
    fi
  done
  if [[ -z "$expected_format" ]]; then
    warn "no expected format declared for $name"
  elif echo "$actual_format" | grep -qE "$expected_format"; then
    pass "format/arch matches"
  else
    fail "format/arch mismatch (wanted: $expected_format)"
  fi

  # xcframework.zip: only validate format + skip rest
  # ── Resolve what to inspect ──
  # For an xcframework.zip the real binary is the Mach-O dylib(s) inside, so
  # extract it and run the static layers on the primary slice — don't just
  # trust the outer .zip's format. (The L13 runtime load test still can't run
  # for Apple targets — it needs Xcode/dyld — but every static check can.)
  local LD="${LLVM_MINGW_DIR:-/opt/llvm-mingw}/bin"
  local inspect="$artifact" kind="" xcf_tmp=""
  case "$name" in
    *.dll)   kind="dll" ;;
    *.so)    kind="so" ;;
    *.dylib) kind="dylib" ;;
    *.xcframework.zip)
      kind="dylib"
      xcf_tmp="$(mktemp -d)"
      unzip -qo "$artifact" -d "$xcf_tmp" 2>/dev/null || true
      # The framework binary is named `libmpv` inside `libmpv.framework`
      # (macOS nests it under Versions/A/; iOS is flat). Prefer the device
      # slice over the simulator one.
      inspect=$(find "$xcf_tmp" -type f -name libmpv -path '*/libmpv.framework/*' ! -path '*-simulator/*' 2>/dev/null | sort | head -1)
      [[ -z "$inspect" ]] && inspect=$(find "$xcf_tmp" -type f -name libmpv -path '*/libmpv.framework/*' 2>/dev/null | sort | head -1)
      if [[ -z "$inspect" || ! -f "$inspect" ]]; then
        fail "xcframework: could not find the inner libmpv dylib to inspect"
        [[ -n "$xcf_tmp" ]] && rm -rf "$xcf_tmp"
        emit bindone "$name"
        return 0
      fi
      local _slice="${inspect#*libmpv.xcframework/}"; _slice="${_slice%%/*}"
      info "(xcframework — inspecting inner $_slice slice)"
      ;;
  esac

  # ── Pull symbols, deps, strings via the cross-toolchain (all on PATH inside
  # the mpv-build-env container). ──
  local exports deps str_text
  case "$kind" in
    dll)
      exports=$("$LD/llvm-readobj" --coff-exports "$inspect" 2>/dev/null | awk '/Name:/ {print $2}')
      deps=$("$LD/llvm-objdump" -p "$inspect" 2>/dev/null | awk '/DLL Name:/ {print $3}')
      ;;
    so)
      local NM READELF
      if echo "$name" | grep -qE 'aarch64|arm64-v8a'; then
        NM=aarch64-linux-gnu-nm READELF=aarch64-linux-gnu-readelf
      else
        NM=x86_64-linux-gnu-nm READELF=x86_64-linux-gnu-readelf
      fi
      exports=$("$NM" --dynamic --defined-only --extern-only "$inspect" 2>/dev/null | awk '$2 == "T" {print $3}')
      deps=$("$READELF" -d "$inspect" 2>/dev/null | awk '/NEEDED/ {gsub(/[\[\]]/, "", $NF); print $NF}')
      ;;
    dylib)
      # Mach-O. In the Linux build container we use llvm-mingw's llvm-objdump
      # (it reads Mach-O cross-platform); when verify runs natively on a macOS
      # host that toolchain is absent, so fall back to llvm-objdump on PATH or,
      # last, the host's own nm/otool — this makes `verify_binaries.sh macos`
      # work end-to-end on the Mac (and reach the L13 host dlopen test).
      # --exports-trie gives the actual exported symbols; sort -u dedups across a
      # universal binary's fat slices so a 54-symbol dylib still counts 54, not
      # 108. --dylibs-used = deps. `|| true`: don't let a non-zero exit (pipefail)
      # abort the whole script — an empty result just surfaces as a failed
      # exports check, which is visible rather than fatal.
      local OBJDUMP=""
      if [[ -x "$LD/llvm-objdump" ]]; then OBJDUMP="$LD/llvm-objdump"
      elif command -v llvm-objdump >/dev/null 2>&1; then OBJDUMP="$(command -v llvm-objdump)"; fi
      if [[ -n "$OBJDUMP" ]]; then
        exports=$({ "$OBJDUMP" --macho --exports-trie "$inspect" 2>/dev/null \
                  | awk '$1 ~ /^0x/ {n=$NF; sub(/^_/, "", n); print n}' | sort -u; } || true)
        # Dep lines are the load-command paths; the `<file>:` and per-arch
        # `<file> (architecture …):` header lines end in ':' — exclude them so a
        # universal binary's arch headers aren't mistaken for forbidden deps.
        deps=$({ "$OBJDUMP" --macho --dylibs-used "$inspect" 2>/dev/null | awk '/^[[:space:]]*\// && !/:$/ {print $1}' | sort -u; } || true)
      else
        # Host (macOS) fallback: nm -gU = exported defined symbols; otool -L = deps.
        exports=$({ nm -gU "$inspect" 2>/dev/null | awk '{n=$NF; sub(/^_/, "", n); print n}' | sort -u; } || true)
        deps=$({ otool -L "$inspect" 2>/dev/null | awk 'NR>1 && /\// {print $1}' | sort -u; } || true)
      fi
      ;;
  esac
  str_text=$(strings -a "$inspect" 2>/dev/null)

  # ── 2. mpv_* exports ──
  phase exports
  # Per-platform allowlist of additional exports that are NOT leaks. On
  # Android the binary intentionally exposes `JNI_OnLoad` so that
  # System.loadLibrary("mpv") can register the JavaVM with ffmpeg before
  # the audiotrack AO initializes.
  local allowed_extra_re='^$'
  case "$platform" in
    android) allowed_extra_re='^JNI_OnLoad$' ;;
  esac

  local total_exports mpv_exports leaks
  total_exports=$(grep -cE '.' <<<"$exports" || true)
  mpv_exports=$(grep -cE '^_?mpv_' <<<"$exports" || true)
  local allowed_extras
  allowed_extras=$(grep -cE "$allowed_extra_re" <<<"$exports" || true)
  leaks=$((total_exports - mpv_exports - allowed_extras))
  if (( mpv_exports == EXPECTED_MPV_EXPORTS )); then
    pass "mpv_* exports: $mpv_exports/$EXPECTED_MPV_EXPORTS"
  else
    fail "mpv_* exports: expected $EXPECTED_MPV_EXPORTS, got $mpv_exports"
  fi
  if (( leaks == 0 )); then
    if (( allowed_extras > 0 )); then
      pass "no symbol leaks ($allowed_extras platform-allowed extra: $(grep -E "$allowed_extra_re" <<<"$exports" | tr '\n' ' '))"
    else
      pass "no symbol leaks (0 non-mpv exports)"
    fi
  elif [[ "$platform" == "macos" || "$platform" == "ios" ]]; then
    # Apple dynamic libraries legitimately export a few CoreFoundation/runtime
    # interop globals alongside mpv_* (the build's own dynsym-hygiene budget is
    # ~60 symbols). Surface them, but don't fail the audio-only invariant on it.
    warn "$leaks non-mpv export(s) — Apple interop globals (expected): $(grep -vE '^_?mpv_' <<<"$exports" | tr '\n' ' ' | head -c 120)"
  else
    fail "$leaks symbols leaked from static deps"
    grep -vE "(^_?mpv_)|($allowed_extra_re)" <<<"$exports" | head -3 | sed 's/^/     · /'
  fi

  # ── 2b. Per-slice integrity (Mach-O universal binaries) ──
  # The export/leak checks above read the fat binary in AGGREGATE: `sort -u`
  # merges symbols across slices, so a broken/stub slice (e.g. an x86_64 slice
  # that lost `-arch` at compile time and shipped as a ~40 KB stub with 0 mpv_*
  # exports) hides behind a healthy arm64 slice and the count still reads 54.
  # Validate EACH architecture slice independently: a real libmpv is multi-MB
  # with exactly $EXPECTED_MPV_EXPORTS mpv_* exports; a stub has neither.
  if [[ "$kind" == "dylib" ]] && file "$inspect" 2>/dev/null | grep -q 'universal binary'; then
    phase slices
    local _have_lipo=0; command -v lipo >/dev/null 2>&1 && _have_lipo=1
    local _archs=""
    if (( _have_lipo )); then
      _archs=$(lipo -archs "$inspect" 2>/dev/null)
    elif [[ -n "$OBJDUMP" ]]; then
      _archs=$("$OBJDUMP" --macho --universal-headers "$inspect" 2>/dev/null | awk '/architecture /{print $2}')
    fi
    if [[ -z "${_archs// }" ]]; then
      warn "universal binary: could not enumerate slices — per-slice check skipped"
    else
      local _a
      for _a in $_archs; do
        local _sz=0 _sexp="" _smpv
        if (( _have_lipo )); then
          local _thin; _thin="$(mktemp)"
          if lipo "$inspect" -thin "$_a" -output "$_thin" 2>/dev/null; then
            _sz=$(stat -f%z "$_thin" 2>/dev/null || stat -c%s "$_thin" 2>/dev/null || echo 0)
            if [[ -n "$OBJDUMP" ]]; then
              _sexp=$({ "$OBJDUMP" --macho --exports-trie "$_thin" 2>/dev/null | awk '$1 ~ /^0x/ {n=$NF; sub(/^_/,"",n); print n}'; } || true)
            else
              _sexp=$({ nm -gU "$_thin" 2>/dev/null | awk '{n=$NF; sub(/^_/,"",n); print n}'; } || true)
            fi
          fi
          rm -f "$_thin"
        elif [[ -n "$OBJDUMP" ]]; then
          _sexp=$({ "$OBJDUMP" --macho --arch="$_a" --exports-trie "$inspect" 2>/dev/null | awk '$1 ~ /^0x/ {n=$NF; sub(/^_/,"",n); print n}'; } || true)
        fi
        _smpv=$(grep -cE '^_?mpv_' <<<"$_sexp" || true)
        if (( _smpv != EXPECTED_MPV_EXPORTS )); then
          fail "slice $_a: $_smpv mpv_* exports (expected $EXPECTED_MPV_EXPORTS) — stub/broken slice"
        elif (( _sz > 0 && _sz < 1000000 )); then
          fail "slice $_a: undersized ($_sz bytes) — likely a stub, not a real libmpv"
        elif (( _sz > 0 )); then
          pass "slice $_a: real ($_smpv mpv_* exports, $_sz bytes)"
        else
          pass "slice $_a: real ($_smpv mpv_* exports)"
        fi
      done
    fi
  fi

  # ── 3. patched mpv properties ──
  phase patches
  for prop in "${MPV_PATCHED_PROPS[@]}"; do
    if grep -qF "$prop" <<<"$str_text"; then
      pass "mpv patch present: $prop"
    else
      fail "mpv patch MISSING: $prop"
    fi
  done

  # ── 4. ffmpeg patches ──
  phase ffmpeg
  for entry in "${FFMPEG_PATCH_MARKERS[@]}"; do
    local marker="${entry%%|*}" desc="${entry#*|}"
    if grep -qF "$marker" <<<"$str_text"; then
      pass "ffmpeg patch present: $desc"
    else
      fail "ffmpeg patch MISSING: $desc"
    fi
  done

  # ── 5. audio decoders ──
  phase decoders
  local missing_dec=0
  for dec in "${REQUIRED_DECODERS[@]}"; do
    grep -qF "$dec" <<<"$str_text" || missing_dec=$((missing_dec + 1))
  done
  if (( missing_dec == 0 )); then
    pass "audio decoders sample (${#REQUIRED_DECODERS[@]}) present"
  else
    fail "$missing_dec/${#REQUIRED_DECODERS[@]} sampled audio decoders missing"
  fi

  # ── 6. audio filters ──
  phase filters
  local missing_flt=0
  for flt in "${REQUIRED_FILTERS[@]}"; do
    grep -qF "$flt" <<<"$str_text" || missing_flt=$((missing_flt + 1))
  done
  if (( missing_flt == 0 )); then
    pass "audio filters sample (${#REQUIRED_FILTERS[@]}) present"
  else
    fail "$missing_flt/${#REQUIRED_FILTERS[@]} sampled audio filters missing"
  fi

  # ── 7. audio-only invariant: no video decoder compiled in ──
  phase audioonly
  # ffmpeg names each decoder's AVCodec struct `ff_<name>_decoder`. We match the
  # EXACT video-decoder symbol (e.g. `ff_av1_decoder`) — exact so it can never
  # false-match an audio codec like wmav1, whose symbol `ff_wmav1_decoder`
  # contains the substring "av1_decoder". (The old unanchored grep flagged
  # wmav1 as "av1" — a phantom video codec.) When the binary also embeds the
  # ffmpeg ./configure line, its --enable-decoder='…' list is parsed as an
  # authoritative cross-check (exact comma-token match).
  local enable_line enabled=""
  # `|| true`: on a stripped binary grep finds no config string and exits 1,
  # which (with set -o pipefail) would abort the whole script via set -e.
  enable_line=$(grep -oE "\-\-enable-decoder='[^']*'" <<<"$str_text" | head -1 || true)
  [[ -n "$enable_line" ]] && enabled=",$(sed -E "s/^[^']*'([^']*)'.*/\1/" <<<"$enable_line" | tr -d ' '),"
  local vid_found=()
  for vid in "${FORBIDDEN_VIDEO[@]}"; do
    if grep -qF "ff_${vid}_decoder" <<<"$str_text" \
       || { [[ -n "$enabled" ]] && [[ "$enabled" == *",${vid},"* ]]; }; then
      vid_found+=("$vid")
    fi
  done
  if (( ${#vid_found[@]} == 0 )); then
    pass "audio-only invariant: no video decoder present"
  else
    fail "audio-only invariant: VIDEO decoder(s) compiled in: ${vid_found[*]}"
  fi

  # ── 7b. adaptive feature presence (tracks Settings ▸ Patches strips) ──
  layer_feature_presence "$platform" "$str_text" "$inspect" "$LD" || true

  # ── 8. external runtime deps (informative) ──
  phase deps
  local dep_count
  dep_count=$(grep -cE '.' <<<"$deps" || true)
  info "runtime deps ($dep_count): $(tr '\n' ' ' <<<"$deps" | head -c 180)"

  # ── 9. embedded dep versions vs _versions.sh ──
  phase versions
  printf "  ${DIM}version manifest (%s track):${NC}\n" "$platform"
  local ver_checked=0 ver_ok=0 ver_drift=0 ver_unknown=0
  for pkg in ffmpeg libplacebo libass harfbuzz freetype fribidi fontconfig \
             libpng zlib libxml2 xz rubberband libsmb2 openssl; do
    local expected actual
    expected="$(expected_version_for "$pkg" "$platform")"
    actual="$(detect_version_in_binary "$pkg" "$str_text")"
    if [[ -z "$expected" ]]; then continue; fi
    ver_checked=$((ver_checked + 1))
    if [[ -z "$actual" ]]; then
      printf "    ${DIM}· %-12s expected %-10s  (no version-string in binary — strip/LTO)${NC}\n" "$pkg" "$expected"
      ver_unknown=$((ver_unknown + 1))
    elif [[ "$actual" == "$expected" ]]; then
      printf "    ${GREEN}✓${NC} %-12s %s\n" "$pkg" "$actual"
      ver_ok=$((ver_ok + 1))
    else
      printf "    ${RED}✗${NC} %-12s expected %-10s  found ${RED}%s${NC} (drift!)\n" "$pkg" "$expected" "$actual"
      ver_drift=$((ver_drift + 1))
    fi
  done
  if (( ver_drift == 0 )); then
    if (( ver_ok > 0 )); then
      pass "dep version manifest: $ver_ok/$ver_checked detected versions match (${ver_unknown} not embedded)"
    else
      info "dep version manifest: 0 detectable (all stripped); manual audit recommended"
    fi
  else
    fail "dep version DRIFT: $ver_drift/$ver_checked mismatch against _versions.sh"
  fi

  # ── 10. mpv API surface hash ──
  phase apihash
  local sym_hash
  sym_hash=$(grep -E '^_?mpv_' <<<"$exports" | sed 's/^_//' | sort -u | sha256sum | cut -c1-12)
  SYMBOL_HASHES_BY_BINARY["$name"]="$sym_hash"
  info "mpv API surface hash: $sym_hash"

  # ── 11-14. Sanity layers ─────────────────────────────────────────────────
  # Each layer call ends with `|| true` so a fail() inside it (which
  # increments FAILED but is NOT itself a script-level error) cannot trip
  # set -e and abort the per-binary loop. The summary at the end of the
  # script reads $FAILED and exits non-zero if anything failed.
  local arch
  arch="$(arch_from_artifact "$name")"

  # Layer 11: NEEDED allowlist — purely static, runs on every artifact.
  layer11_needed_allowlist "$platform" "$deps" || true

  # Layer 12: UND symbol resolvability. Runs the real nm-based check on Linux +
  # Android; self-dispatches an N/A-with-reason on Windows / macOS / iOS (whose
  # imports are bound by their own loader, see L13). Always called so every
  # binary reports this category — no silent gap.
  layer12_und_resolvable "$platform" "$arch" "$artifact" "$deps" || true

  # Layer 13: actual dlopen / LoadLibrary load test. Pass the extracted inner
  # dylib ($inspect) so the macOS host load test loads the real Mach-O, not the
  # outer .xcframework.zip.
  layer13_load_test "$platform" "$arch" "$artifact" "$inspect" || true

  # Layer 14: stub-function detection — Android only (defense-in-depth
  # for the ffmpeg --enable-jni / CONFIG_JNI=0 silent-stub bug class).
  layer14_stub_detection "$platform" "$arch" "$artifact" || true

  # Layer 15: Apple code-signing identity (xcframework slices) — runs off the
  # already-extracted tree ($xcf_tmp) before it is removed below.
  layer15_codesign_identity "$platform" "$xcf_tmp" || true

  [[ -n "$xcf_tmp" ]] && rm -rf "$xcf_tmp"
  emit bindone "$name"
}

# ── Cross-platform aggregator (run after every binary checked) ────────────────
cross_platform_audit() {
  CUR_BIN=""; CUR_PHASE="xaudit"
  printf "\n${BOLD}═════ Cross-platform audit ═════${NC}\n"

  # ── API surface consistency ──
  local hashes
  hashes=$(printf '%s\n' "${SYMBOL_HASHES_BY_BINARY[@]}" | sort -u)
  local unique
  unique=$(wc -l <<<"$hashes" | tr -d ' ')
  if (( unique == 1 )); then
    pass "API surface IDENTICAL across all $((${#SYMBOL_HASHES_BY_BINARY[@]})) binaries (hash $(head -1 <<<"$hashes"))"
    emit xaudit pass "API surface identical across ${#SYMBOL_HASHES_BY_BINARY[@]} binaries (hash $(head -1 <<<"$hashes"))"
  else
    fail "API surface DIVERGES across $((${#SYMBOL_HASHES_BY_BINARY[@]})) binaries: $unique distinct hashes"
    emit xaudit fail "API surface diverges across ${#SYMBOL_HASHES_BY_BINARY[@]} binaries: $unique distinct hashes"
    for name in "${!SYMBOL_HASHES_BY_BINARY[@]}"; do
      printf "     · %-40s %s\n" "$name" "${SYMBOL_HASHES_BY_BINARY[$name]}"
    done
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo
printf "${BOLD}═════ libmpv binary verification ═════${NC}\n"
echo "Release dir: $RELEASE_DIR"
if [[ -n "$FILTER" ]]; then echo "Filter: only ${FILTER}*"; fi
echo

found=0
for f in "$RELEASE_DIR"/libmpv_*; do
  [[ -f "$f" ]] || continue
  if [[ -n "$FILTER" && "$(basename "$f")" != *"$FILTER"* ]]; then
    continue
  fi
  found=$((found + 1))
  check_binary "$f"
done

if (( found > 1 )); then
  cross_platform_audit
fi

echo
printf "${BOLD}═════ Summary ═════${NC}\n"
echo "  Binaries checked: $found"
printf "  ${GREEN}Passed: %d${NC}    " "$PASSED"
printf "${YELLOW}Warned: %d${NC}    " "$WARNED"
printf "${RED}Failed: %d${NC}    " "$FAILED"
printf "${DIM}N/A: %d${NC}\n" "$SKIPPED_NA"
echo
emit summary "$PASSED" "$FAILED" "$WARNED" "$SKIPPED_NA" "$found"

(( FAILED > 0 )) && exit 1
exit 0
