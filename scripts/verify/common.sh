# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
# shellcheck shell=bash

# The parts of verify_binaries.sh every platform runs: the truth tables, the
# result helpers (pass, fail, warn, info, na and the @@V1@@ events), the
# per-platform layers whose cases span platforms (L11 NEEDED allowlist, the
# L13 dispatcher, 7b features, 7c license, 6b FFmpeg components),
# check_binary, which runs every layer on one artifact, and the
# cross-platform audit. Sourced by verify_binaries.sh, first. Do not run
# directly.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Truth tables ──────────────────────────────────────────────────────────────
EXPECTED_MPV_EXPORTS=54
# The live PCM input API (patch_pcm_stream.py), exported next to mpv_*.
EXPECTED_MAK_PCM_EXPORTS=9

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
  "libmpv_tvos.xcframework.zip|Zip archive data"
  "libmpv_tizen-armv7l.so|ELF 32-bit LSB shared object, ARM, EABI5"
  "libmpv_tizen-x86_64.so|ELF 64-bit LSB shared object, x86-64"
)

# Every observable property our mpv patch set registers. Validated by
# static string presence (Layer 3) so a patch that silently fails to apply
# — leaving its property name out of the binary — is caught here rather
# than only surfacing as a soft-skipped consumer test later.
#   prefetch          : prefetch-state, prefetch-cache-duration,
#                       prefetch-open-filename, prefetch-playlist-entry-id
#   audio_output_state: audio-output-state
#   embedded_cover    : embedded-cover-art-data, embedded-cover-art-mime
#   pcm_tap           : pcm-tap-frame
#   filter_label_tap  : audio-tap-frames, analyzer-taps
#   bulk_analysis     : waveform-data, waveform-enabled,
#                       waveform-duration-hint (an option), duration-estimated
#   loudness_scan     : loudness-scan-data, loudness-scan-enabled
#   af_command_args   : af-command-saves-args
#   read_error        : demuxer-read-error, demuxer-skipped-segments, mak-end-file-fields
#   keep_open_park    : keep-open-parked
MPV_PATCHED_PROPS=(
  prefetch-state prefetch-cache-duration
  prefetch-open-filename prefetch-playlist-entry-id
  audio-output-state
  embedded-cover-art-data embedded-cover-art-mime
  pcm-tap-frame
  audio-tap-frames analyzer-taps
  waveform-data waveform-enabled waveform-duration-hint duration-estimated
  loudness-scan-data loudness-scan-enabled
  af-command-saves-args
  demuxer-read-error demuxer-skipped-segments mak-end-file-fields
  keep-open-parked
)

# mak_frag_editlist is the option patch_ffmpeg_advanced_editlist.py adds to
# mov.c (upstream has advanced_editlist itself, so that name proves nothing).
# "ended on a read error" is the warning patch_ffmpeg_segment_skips.py adds to
# hls.c and dashdec.c; its option name is no marker, since mpv reads it.
# "Chunked stream ends without its last chunk" is the error
# patch_ffmpeg_http_read_errors.py adds to http.c, which the web build has
# not (webio reads http there).
FFMPEG_PATCH_MARKERS=(
  "libsmb2|libsmb2 SMB2 protocol patch"
  "mak_frag_editlist|mov demuxer fragmented-MP4 editlist patch"
  "ended on a read error|HLS and DASH segment count (read_error)"
  "Chunked stream ends without its last chunk|http read errors (read_error)"
)

# FFmpeg components the kit relies on outside the decoder and filter lists:
# the spdif muxer behind audio-spdif, and the protocols an https source needs,
# through an HTTP proxy too. Each entry is "<ERE>|<label>", and the ERE matches
# a string that only that component's code carries. The bare names do not
# work: "httpproxy" is also in tls.c and in the http whitelists, and "https"
# is everywhere.
#   spdif_flags         : option of the spdif muxer (spdifenc.c)
#   CONNECT %s HTTP/1.1 : request line of http_proxy_open (http.c)
#   ...,httpproxy$      : default_whitelist of the https protocol; the http
#                         one ends in ",data"
#   Verify against ...  : TLS_COMMON_OPTIONS help (tls.h), in every backend
FFMPEG_COMPONENT_MARKERS=(
  "spdif_flags|spdif muxer (audio-spdif passthrough)"
  "CONNECT %s HTTP/1\.1|httpproxy protocol (https through an HTTP proxy)"
  "http,https,tls,rtp,tcp,udp,crypto,httpproxy$|https protocol"
  "Verify against a specific hostname|tls protocol"
)

mapfile -t REQUIRED_DECODERS < <(echo "$AUDIO_DECODERS" | tr ',' '\n' | head -8)
mapfile -t REQUIRED_FILTERS  < <(echo "$AUDIO_FILTERS"  | tr ',' '\n')

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
    rubberband)     if gpl_build; then echo "$RUBBERBAND_VERSION"; fi ;;
    libsmb2)        echo "$LIBSMB2_VERSION" ;;
    openssl)        echo "$OPENSSL_VERSION" ;;
    libplacebo)
      # macOS / Linux desktop tracks 7.x; iOS / Android / Windows track 6.x.
      case "$platform" in
        macos|linux|tizen) echo "7.349.0" ;;
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
    *tvos*)    echo "tvos" ;;
    *ios*)     echo "ios" ;;
    *linux*)   echo "linux" ;;
    *tizen*)   echo "tizen" ;;
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
      # libasound = ALSA, the one audio backend linked. PipeWire and
      # PulseAudio are loaded at run time and must NOT be NEEDED.
      # libX11 family + libva + libvdpau = X11 / VA-API / VDPAU stubs (some
      # distros keep them in NEEDED even with the audio-only build).
      # ld-linux variants by arch:
      #   x86_64: ld-linux-x86-64.so.2
      #   aarch64: ld-linux-aarch64.so.1
      #   i386:   ld-linux.so.2
      #   armhf:  ld-linux-armhf.so.3
      allowed_re='^(libc|libm|libdl|libpthread|librt|libresolv|libstdc\+\+|libgcc_s|libasound|libX11|libXext|libXrandr|libXinerama|libva|libva-drm|libva-x11|libvdpau|ld-linux[-a-zA-Z0-9_]*)\.(so|so\.[0-9]+(\.[0-9]+)*)$'
      ;;
    tizen)
      # glibc, and the two audio APIs of ao_tizen (capi-base-common comes
      # with them). Anything else is missing on the TV: libgcc and
      # libstdc++ are linked in.
      allowed_re='^(libc|libm|libdl|libpthread|librt|ld-linux|libcapi-media-audio-io|libcapi-media-sound-manager|libcapi-base-common)\.so(\.[0-9]+)*$'
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
    ios|tvos)
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

  if (( total == 0 )); then
    fail "L11 NEEDED allowlist: no NEEDED entries read (tool failure or unreadable binary)"
  elif (( ${#violations[@]} == 0 )); then
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
    tizen)
      _l13_tizen_dlopen "$arch" "$artifact"
      ;;
    macos)
      # Runs the REAL dyld load when verify is invoked natively on a macOS host
      # (./scripts/verify_binaries.sh macos). Inside the Linux build container it
      # self-reports N/A with that pointer — a macOS dylib cannot be dlopen'd by a
      # Linux loader.
      _l13_macos_dlopen "$inspect"
      ;;
    ios)
      na "$platform device slice targets arm64-$platform; no host loader (the simulator slice needs the Simulator runtime, not plain dyld). Static layers (1-11) + the consumer link-time check cover it."
      ;;
    tvos)
      na "$platform device slice targets arm64-$platform; no host loader (the simulator slice needs the Simulator runtime, not plain dyld). Static layers (1-11) cover it: no consumer build of tvOS runs in CI."
      ;;
    *)
      warn "L13: no load test for platform=$platform"
      ;;
  esac
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
# DASH, OpenSSL, and SMB2 when the libsmb2 patch is enabled). rubberband is
# the license's, in layer_license.

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
  for e in "https:HTTPS/TLS protocol" "dash:DASH demuxer" "OpenSSL:OpenSSL TLS backend"; do
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

  # Embedded CA bundle — adaptive on the embed_cacert patch. The Mozilla root
  # store is compiled into the OpenSSL TLS backend verbatim, so the bundle's
  # provenance header survives as a string in the binary's read-only data.
  n=$(grep -cF "Certificate data from Mozilla" <<<"$str" || true)
  if patch_on embed_cacert; then
    if (( n > 0 )); then pass "feature present: embedded CA bundle"
    else fail "feature MISSING: embedded CA bundle (embed_cacert patch enabled)"; fi
  else
    info "embedded CA bundle: embed_cacert patch disabled — not asserted"
  fi
}

# Layer 7c: the license. The default build is LGPL-3.0-or-later; LIBMPV_GPL=1
# (gpl_build) is the GPL build with librubberband. Checked on what the binary
# says of itself, not on a plain search for "gpl" or "rubberband": the meson
# command line mpv embeds ("Configuration: ... -Dgpl=false ...
# -Drubberband=disabled") names both in either build. So:
#   - the token list of "List of enabled features:" (mpv's FULLCONFIG, the
#     mpv-configuration of a player) holds gpl and rubberband only in the GPL
#     build;
#   - librubberband's code (the RubberBand:: classes, the messages of
#     af_rubberband) is there only in the GPL build: every line of strings
#     that names it, except the meson command line;
#   - licenses_<target>/ next to the binary (write_licenses) has the texts of
#     that license, the texts of the toolchain runtime libraries the target
#     links statically (Windows: mingw-w64's winpthreads and CRT; Android,
#     Windows arm64 and web: LLVM's libc++, libc++abi, libunwind and
#     compiler-rt; web: Emscripten and its musl) and THIRD_PARTY_LICENSES.txt, and licenses.zip and manifest.json, when write_manifest.sh
#     has run, have the target's texts and the license.
# FFmpeg's own license string does not survive LTO and --gc-sections; its
# CONFIG_GPL is asserted at build time (verify_ffmpeg_config).
# Args: $1 artifact name, $2 str_text
layer_license() {
  local name="$1" str="$2"
  phase license
  local target="${name#libmpv_}"; target="${target%%.*}"
  local want="LGPL-3.0-or-later" mpv_text="LICENSE.LGPL" ffmpeg_text="COPYING.LGPLv3"
  if gpl_build; then
    want="GPL-3.0-or-later" mpv_text="LICENSE.GPL" ffmpeg_text="COPYING.GPLv3"
  fi

  local feats
  feats="$(grep -oE 'List of enabled features: .*' <<<"$str" | head -1 || true)"
  feats=" ${feats#List of enabled features: } "
  if [[ "$feats" == "  " ]]; then
    fail "license: no \"List of enabled features\" in the binary (tool failure, or mpv's FULLCONFIG gone)"
  else
    local has_gpl=0 has_rb=0
    [[ "$feats" == *" gpl "* ]] && has_gpl=1
    [[ "$feats" =~ \ rubberband[^\ ]*\  ]] && has_rb=1
    if gpl_build; then
      if (( has_gpl && has_rb )); then pass "license: gpl and rubberband among mpv's enabled features (GPL build)"
      else fail "license: the GPL build lacks gpl or rubberband among mpv's enabled features:${feats% }"; fi
    else
      if (( has_gpl || has_rb )); then fail "license: gpl or rubberband among mpv's enabled features of the LGPL build:${feats% }"
      else pass "license: neither gpl nor rubberband among mpv's enabled features"; fi
    fi
  fi

  local n
  n=$(grep -iE 'rubber ?band' <<<"$str" | grep -cvE -- '-Drubberband=|^List of enabled features: ' || true)
  if gpl_build; then
    if (( n > 0 )); then pass "license: librubberband linked (GPL build, marker hits=$n)"
    else warn "license: GPL build but no librubberband marker (LTO may have removed it; the build-time config audit covers it)"; fi
  else
    if (( n > 0 )); then fail "license: librubberband code in the LGPL build (marker hits=$n)"
    else pass "license: no librubberband code"; fi
  fi

  local dir="$RELEASE_DIR/licenses_$target" f missing=()
  if [[ -f "$dir/README.txt" ]]; then
    if head -1 "$dir/README.txt" | grep -qF ": $want"; then pass "license: $(basename "$dir")/README.txt says $want"
    else fail "license: $(basename "$dir")/README.txt does not say $want: $(head -1 "$dir/README.txt")"; fi
    for f in "mpv/$mpv_text" mpv/Copyright "ffmpeg/$ffmpeg_text" ffmpeg/LICENSE.md libmpv-scripts/LICENSE \
             libmpv-scripts/NOTICE THIRD_PARTY_LICENSES.txt; do
      [[ -s "$dir/$f" ]] || missing+=("$f")
    done
    local toolchain=()
    case "$target" in
      windows-*) toolchain+=(winpthreads/COPYING mingw-w64-crt/COPYING.MinGW-w64-runtime.txt) ;;
      web) toolchain+=(emscripten/LICENSE musl/COPYRIGHT) ;;
    esac
    case "$target" in
      android-*|windows-arm64|web)
        toolchain+=(llvm-runtimes/{libcxx,libcxxabi,libunwind,compiler-rt}/LICENSE.TXT) ;;
    esac
    for f in ${toolchain[@]+"${toolchain[@]}"}; do
      [[ -s "$dir/$f" ]] || missing+=("$f")
    done
    if gpl_build; then [[ -d "$dir/rubberband" ]] || missing+=("rubberband/")
    elif [[ -e "$dir/rubberband" ]]; then fail "license: rubberband texts in the LGPL build's $(basename "$dir")"; fi
    if (( ${#missing[@]} == 0 )); then pass "license: the texts of mpv, FFmpeg, libmpv-scripts${toolchain[0]:+ and the toolchain runtimes}, and THIRD_PARTY_LICENSES.txt, in $(basename "$dir")"
    else fail "license: missing in $(basename "$dir"): ${missing[*]}"; fi
  else
    fail "license: no license texts $dir/README.txt (write_licenses)"
  fi
  if [[ -f "$RELEASE_DIR/licenses.zip" ]]; then
    # The whole listing first: grep -q leaves at the first match, and the
    # SIGPIPE of unzip would fail the pipeline under pipefail.
    local zip_names
    zip_names="$(unzip -Z1 "$RELEASE_DIR/licenses.zip" 2>/dev/null || true)"
    if grep -qx "$target/README.txt" <<<"$zip_names"; then
      pass "license: licenses.zip has $target/"
    else
      fail "license: licenses.zip has no $target/README.txt"
    fi
  fi
  if [[ -f "$RELEASE_DIR/manifest.json" ]]; then
    local got
    got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("license"))' "$RELEASE_DIR/manifest.json" 2>/dev/null || true)"
    if [[ "$got" == "$want" ]]; then pass "license: manifest.json says $want"
    else fail "license: manifest.json says ${got:-nothing}, not $want"; fi
  fi
}

# Layer 6b: every FFMPEG_COMPONENT_MARKERS entry must be in the binary, on
# every platform. No patch or selection turns them off.
# Args: $1 str_text
layer_ffmpeg_components() {
  local str="$1" entry marker label
  phase components
  for entry in "${FFMPEG_COMPONENT_MARKERS[@]}"; do
    marker="${entry%%|*}"; label="${entry#*|}"
    if grep -qE -- "$marker" <<<"$str"; then pass "ffmpeg component present: $label"
    else fail "ffmpeg component MISSING: $label"; fi
  done
}

# Map a libmpv_<plat>-<arch>.<ext> filename → arch token.
arch_from_artifact() {
  case "$1" in
    *-x86_64.*)        echo "x86_64" ;;
    *-aarch64.*)       echo "aarch64" ;;
    *-armeabi-v7a.*)   echo "armeabi-v7a" ;;
    *-arm64-v8a.*)     echo "arm64-v8a" ;;
    *-arm64.*)         echo "arm64" ;;
    *-armv7l.*)        echo "armv7l" ;;
    *)                 echo "" ;;
  esac
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
      phase slices
      _xcf_slices_check "$platform" "${inspect%%/libmpv.xcframework/*}"
      ;;
  esac

  # ── Pull symbols, deps, strings via the cross-toolchain (all on PATH inside
  # the mpv-build-verify container). ──
  local exports deps str_text
  case "$kind" in
    dll)
      exports=$("$LD/llvm-readobj" --coff-exports "$inspect" 2>/dev/null | awk '/Name:/ {print $2}')
      deps=$("$LD/llvm-objdump" -p "$inspect" 2>/dev/null | awk '/DLL Name:/ {print $3}')
      ;;
    so)
      local NM READELF
      if [[ "$platform" == tizen ]]; then
        NM="$(_llvm_tool nm)" READELF="$(_llvm_tool readelf)"
      elif echo "$name" | grep -qE 'aarch64|arm64-v8a'; then
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
  str_text=$(strings -a "$inspect" 2>/dev/null || true)
  [[ -n "$str_text" ]] || fail "strings produced no output for $name (tool failure)"

  # ── 2. mpv_* exports ──
  phase exports
  # Per-platform allowlist of additional exports that are NOT leaks. On
  # Android the binary intentionally exposes `JNI_OnLoad` so that
  # System.loadLibrary("mpv_audio_kit") can register the JavaVM with
  # ffmpeg before the audiotrack AO initializes.
  local allowed_extra_re='^$'
  case "$platform" in
    android) allowed_extra_re='^JNI_OnLoad$' ;;
  esac

  local total_exports mpv_exports mak_exports leaks
  total_exports=$(grep -cE '.' <<<"$exports" || true)
  mpv_exports=$(grep -cE '^_?mpv_' <<<"$exports" || true)
  mak_exports=$(grep -cE '^_?mak_pcm_' <<<"$exports" || true)
  local allowed_extras
  allowed_extras=$(grep -cE "$allowed_extra_re" <<<"$exports" || true)
  leaks=$((total_exports - mpv_exports - mak_exports - allowed_extras))
  if (( mpv_exports == EXPECTED_MPV_EXPORTS )); then
    pass "mpv_* exports: $mpv_exports/$EXPECTED_MPV_EXPORTS"
  else
    fail "mpv_* exports: expected $EXPECTED_MPV_EXPORTS, got $mpv_exports"
  fi
  if (( mak_exports == EXPECTED_MAK_PCM_EXPORTS )); then
    pass "mak_pcm_* exports: $mak_exports/$EXPECTED_MAK_PCM_EXPORTS"
  else
    fail "mak_pcm_* exports: expected $EXPECTED_MAK_PCM_EXPORTS, got $mak_exports"
  fi
  if (( leaks == 0 )); then
    if (( allowed_extras > 0 )); then
      pass "no symbol leaks ($allowed_extras platform-allowed extra: $(grep -E "$allowed_extra_re" <<<"$exports" | tr '\n' ' '))"
    else
      pass "no symbol leaks (0 non-mpv exports)"
    fi
  elif [[ "$platform" == "macos" || "$platform" == "ios" || "$platform" == "tvos" ]]; then
    # Apple dynamic libraries legitimately export a few CoreFoundation/runtime
    # interop globals alongside mpv_* (the build's own dynsym-hygiene budget is
    # ~60 symbols). Surface them, but don't fail the audio-only invariant on it.
    warn "$leaks non-mpv export(s) — Apple interop globals (expected): $(grep -vE '^_?(mpv|mak_pcm)_' <<<"$exports" | tr '\n' ' ' | head -c 120)"
  else
    fail "$leaks symbols leaked from static deps"
    grep -vE "(^_?mpv_)|(^_?mak_pcm_)|($allowed_extra_re)" <<<"$exports" | head -3 | sed 's/^/     · /'
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
  # The filter bounds patch is always applied. Its chorus message marks it
  # whenever chorus is among the selected filters.
  if [[ ",$AUDIO_FILTERS," == *",chorus,"* ]]; then
    if grep -qF "Invalid delay, decay, speed or depth for voice" <<<"$str_text"; then
      pass "ffmpeg patch present: filter bounds"
    else
      fail "ffmpeg patch MISSING: filter bounds (chorus message)"
    fi
  fi

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
    pass "audio filters (all ${#REQUIRED_FILTERS[@]}) present"
  else
    fail "$missing_flt/${#REQUIRED_FILTERS[@]} audio filters missing"
  fi

  # ── 6b. FFmpeg muxer and protocols outside the lists above ──
  layer_ffmpeg_components "$str_text" || fail "6b: layer aborted (exit $?)"

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
  layer_feature_presence "$platform" "$str_text" "$inspect" "$LD" || fail "7b: layer aborted (exit $?)"

  # ── 7c. license: LGPL, or GPL with rubberband (LIBMPV_GPL) ──
  layer_license "$name" "$str_text" || fail "7c: layer aborted (exit $?)"

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

  # ── 11-16. Sanity layers ─────────────────────────────────────────────────
  # Each layer call ends with `|| fail` so a non-zero return cannot trip
  # set -e and abort the per-binary loop, but still counts. The `||` also
  # turns set -e off inside the layer, so every layer checks its own tool
  # output and fails on an empty one. The summary at the end of the script
  # reads $FAILED and exits non-zero if anything failed.
  local arch
  arch="$(arch_from_artifact "$name")"

  # Layer 11: NEEDED allowlist — purely static, runs on every artifact.
  layer11_needed_allowlist "$platform" "$deps" || fail "L11: layer aborted (exit $?)"

  # Layer 12: UND symbol resolvability. Runs the real nm-based check on Linux +
  # Android; self-dispatches an N/A-with-reason on Windows / macOS / iOS (whose
  # imports are bound by their own loader, see L13). Always called so every
  # binary reports this category — no silent gap.
  layer12_und_resolvable "$platform" "$arch" "$artifact" "$deps" || fail "L12: layer aborted (exit $?)"

  # Layer 13: actual dlopen / LoadLibrary load test. Pass the extracted inner
  # dylib ($inspect) so the macOS host load test loads the real Mach-O, not the
  # outer .xcframework.zip.
  layer13_load_test "$platform" "$arch" "$artifact" "$inspect" || fail "L13: layer aborted (exit $?)"

  # Layer 14: stub-function detection — Android only (defense-in-depth
  # for the ffmpeg --enable-jni / CONFIG_JNI=0 silent-stub bug class).
  layer14_stub_detection "$platform" "$arch" "$artifact" || fail "L14: layer aborted (exit $?)"

  # Layer 15: Apple code-signing identity (xcframework slices) — runs off the
  # already-extracted tree ($xcf_tmp) before it is removed below.
  layer15_codesign_identity "$platform" "$xcf_tmp" || fail "L15: layer aborted (exit $?)"

  # Layer 16: ELF loader invariants — Linux + Android.
  layer16_elf_invariants "$platform" "$arch" "$artifact" "${READELF:-}" || fail "L16: layer aborted (exit $?)"

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
