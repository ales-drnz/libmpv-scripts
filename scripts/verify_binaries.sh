#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# verify_binaries.sh
#
# Static-analysis sanity check for every binary in builds/release/.
# This file is the driver: the checks are in scripts/verify/, common.sh (the
# tables, the result helpers, check_binary and the layers every platform
# runs) and one file per platform (linux.sh with the ELF layers Android
# shares, android.sh, windows.sh, apple.sh, web.sh).
# Verifies, for each libmpv (per platform / per arch):
#   1.  File format / arch matches platform expectation
#   2.  Exactly 54 mpv_* and 9 mak_pcm_* exports, zero leaks
#   3.  Patched mpv properties present (all 18: prefetch-state,
#       -cache-duration, -open-filename and -playlist-entry-id,
#       audio-output-state, embedded-cover-art-data/mime,
#       pcm-tap-frame, audio-tap-frames, analyzer-taps, waveform-data/-enabled,
#       waveform-duration-hint,
#       loudness-scan-data/-enabled, af-command-saves-args,
#       demuxer-read-error and demuxer-skipped-segments)
#   4.  FFmpeg patches present (libsmb2 protocol, mak_frag_editlist of mov,
#       the segment count of HLS and DASH, filter bounds)
#   5.  Required audio decoder whitelist sample present
#   6.  Required audio filter whitelist sample present
#  6b.  FFmpeg components no decoder or filter check covers: the spdif muxer
#       (audio-spdif passthrough) and the httpproxy, https and tls protocols
#   7.  No forbidden video decoders (audio-only invariant)
#  7b.  Adaptive feature presence — cross-checks the binary against the
#       current Settings ▸ Patches strip selection (swscale / libass+fonts /
#       GPU-render / Windows icon present iff NOT stripped), and asserts the
#       always-on audio-path features (HTTPS/TLS, DASH, OpenSSL,
#       SMB2-when-enabled, embedded-CA-bundle-when-enabled). Catches a strip
#       that silently didn't take effect.
#  7c.  License — LGPL unless LIBMPV_GPL=1 (gpl_build in shared/
#       _audio_only.sh): neither gpl nor rubberband among mpv's enabled
#       features, no librubberband code, and the license texts of the target
#       (licenses_<target>/, licenses.zip) and the license of manifest.json
#       match. The GPL build asserts the opposite.
#   8.  External runtime dependency list (informative)
#   9.  Embedded dep VERSIONS match scripts/shared/_versions.sh — catches the
#       classic "I bumped harfbuzz in _versions.sh but the build cache held
#       the old binary" drift
#  10.  Mpv API surface hash (sorted mpv_* names → SHA-256/12) — must be
#       IDENTICAL across all 10 binaries (otherwise the API surface drifted
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
#  16.  ELF invariants (Linux + Android): SONAME is libmpv_audio_kit.so, no
#       DT_RELR, LOAD segments aligned for 16 KB pages on 64-bit Android, and
#       on Linux no GLIBC symbol version above LINUX_GLIBC_FLOOR.
#
# The web module (libmpv_web.zip) gets its own static checks, check_web_binary:
# the four files of the zip and the record's release and versions, a shared
# memory wasm under its size ceiling, exactly the mpv_* and mak_* exports the
# web build exports, the patched properties, the FFmpeg patches, decoders and
# filters, the webaudio output and the webio protocols, the license and mpv's
# version.
# It runs in the browser in the Build's web job (verify/web/run_checks.sh).
#
# A layer whose tool fails or returns nothing counts as FAILED, never as a
# vacuous pass, and a run that finds no binary at all exits non-zero.
#
# All inspection runs inside the mpv-build-verify Docker image so we have
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
# Every binary is reported against the SAME 16 categories, so the per-OS output
# is consistent and directly comparable. Each category resolves to one of:
#   ✓ / ⚠ / ✗  it ran and asserted a result
#   N/A        it intentionally does NOT apply to this platform — a one-line
#              reason is always emitted (see na()), never a silent gap
#   ·          informational only (enumerates state; asserts nothing)
#
#  #  Category                  macOS  iOS  Linux  Win  Android   reason when N/A
#  1  Format / arch               ✓    ✓     ✓     ✓     ✓
#  2  Exports (54 mpv_*, 9 mak)  ✓    ✓     ✓     ✓     ✓
#  3  mpv patched properties      ✓    ✓     ✓     ✓     ✓
#  4  FFmpeg patches              ✓    ✓     ✓     ✓     ✓
#  5  Audio decoders              ✓    ✓     ✓     ✓     ✓
#  6  Audio filters               ✓    ✓     ✓     ✓     ✓
#  7  Audio-only invariant        ✓    ✓     ✓     ✓     ✓
# 7b  Feature presence (strips)    ✓    ✓     ✓     ✓     ✓    adaptive to Settings ▸ Patches (swscale/libass/GPU/win-icon + core protocols)
# 7c  License                     ✓    ✓     ✓     ✓     ✓    the build's license, against its record and license texts
#  8  Runtime dependencies        ·    ·     ·     ·     ·    info; the allowlist assertion is #11
#  9  Dependency versions         ✓    ✓     ✓     ✓     ✓
# 10  API surface hash            ·    ·     ·     ·     ·    info; asserted globally by the cross-platform audit
# 11  NEEDED allowlist            ✓    ✓     ✓     ✓     ✓
# 12  UND resolvability          N/A  N/A    ✓    N/A    ✓    nm/ELF-based; Mach-O & PE binds are resolved by their own loader (#13)
# 13  Runtime load test          ✓†   N/A    ✓     ✓    N/A   needs the platform's real loader (Apple dyld; no emulator-less Android path)
# 14  Stub detection             N/A  N/A   N/A   N/A    ✓    targets Android's JNI_OnLoad→av_jni_set_java_vm chain only
# 15  Code-signing identity       ✓    ✓    N/A   N/A   N/A   Apple-only: signing identifier must == CFBundleIdentifier (iOS device install)
# 16  ELF invariants             N/A  N/A    ✓    N/A    ✓    SONAME / DT_RELR / page alignment / glibc floor are ELF loader concerns
#
#  tvOS gets the iOS column: the same build with the tvOS SDKs.
#
#  † macOS L13 runs the REAL dyld dlopen(RTLD_NOW) when verify is invoked
#    natively on a macOS host (./scripts/verify_binaries.sh macos) — clang
#    compiles the dlopen_test helper and loads the universal dylib's host-arch
#    slice. Inside the Linux build container it self-reports N/A with that
#    pointer (a Mach-O can't load under a Linux loader). iOS stays N/A (device
#    arm64 slice; the simulator slice needs the iOS Simulator runtime).
#
# Static categories (1-11, plus 7b and 7c) run on EVERY artifact — including the
# macOS/iOS xcframeworks, whose inner Mach-O dylib is extracted and inspected.
# Only the runtime categories (12-14) and the ELF one (16) vary by platform,
# and every non-applicable cell emits its reason, so the report never shows an
# unexplained gap and the per-OS "passed" tally is always paired with an
# "N/A (reason)" breakdown.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"
source "$SCRIPT_DIR/shared/_audio_only.sh"

# Env-overridable so the regression fixture suite can point at a temp dir
# containing intentionally-broken binaries (see builds/release/
# .regression_fixtures/) and confirm the new sanity layers fail correctly.
RELEASE_DIR="${RELEASE_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/release}"
FILTER="${1:-}"

# The checks live in scripts/verify/: common.sh first (the tables, the
# result helpers and check_binary), then one file per platform. A new
# platform adds its file to this list.
for part in common linux android windows apple web tizen; do
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/verify/$part.sh"
done

# ── Main ──────────────────────────────────────────────────────────────────────
echo
printf "${BOLD}═════ libmpv binary verification ═════${NC}\n"
echo "Release dir: $RELEASE_DIR"
if [[ -n "$FILTER" ]]; then echo "Filter: only ${FILTER}*"; fi
echo

found=0
shopt -s nullglob
for f in "$RELEASE_DIR"/libmpv_*; do
  [[ -f "$f" ]] || continue
  if [[ -n "$FILTER" && "$(basename "$f")" != *"$FILTER"* ]]; then
    continue
  fi
  found=$((found + 1))
  case "$(basename "$f")" in
    libmpv_web.*) check_web_binary "$f" ;;
    *) check_binary "$f" ;;
  esac
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

(( found == 0 )) && { printf "${RED}No binary found in %s${NC}\n" "$RELEASE_DIR"; exit 1; }
(( FAILED > 0 )) && exit 1
exit 0
