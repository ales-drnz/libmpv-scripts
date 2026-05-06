#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# generate_checksums.sh
#
# Computes SHA-256 checksums for all release binaries (macOS universal,
# iOS xcframework, Android arm64-v8a + armeabi-v7a + x86_64, Linux x86_64 +
# aarch64, Windows x86_64 + arm64), updates them in-place in the platform
# build files, and copies each library to its per-arch destination directory.
#
# Layout installed into the consumer repo:
#   linux/libs/<arch>/libmpv.so
#   windows/libs/<arch>/libmpv.dll
#   android/src/main/jniLibs/<abi>/libmpv.so
#   macos/Frameworks/libmpv.xcframework   (extracted from the .zip)
#   ios/Frameworks/libmpv.xcframework     (extracted from the .zip)
# Plus the SHA-256 written into each platform's build file. The build
# scripts emit ONLY to builds/release/ — this script is the single point
# that installs artifacts into the consumer repo.
#
# Usage (from scripts/):
#   ./generate_checksums.sh
#   ./build checksums
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared/_helpers.sh"
ROOT="$(resolve_repo_root "$SCRIPT_DIR")" || exit 1
RELEASE_DIR="$LIBMPV_SCRIPTS_ROOT/builds/release"

sha256() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# sed in-place that works on both macOS and Linux
sedi() {
  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Update a per-arch SHA-256 variable in a CMakeLists.txt:
#   set(EXPECTED_SHA256_X86_64  "...")
# Tolerates 1+ whitespace between var name and value (we align the
# declarations visually so e.g. AARCH64 lines have 1 space, X86_64 lines
# have 2 to keep the SHA strings column-aligned).
update_cmake_arch_sha() {
  local cmake_file="$1" var_name="$2" new_hash="$3"
  sedi -E "s|set\\(${var_name}[[:space:]]+\"[a-f0-9]{64}\"\\)|set(${var_name}  \"$new_hash\")|" "$cmake_file"
}

echo "=== mpv_audio_kit: updating checksums + copying libraries ==="
echo ""

found=0
missing=0

# ── macOS xcframework (universal: arm64 + x86_64) ───────────────────────────

FILE="$RELEASE_DIR/libmpv_macos.xcframework.zip"
if [ -f "$FILE" ]; then
  found=$((found + 1))
  HASH=$(sha256 "$FILE")
  sedi "s|EXPECTED_SHA256=\"[a-f0-9]\{64\}\"|EXPECTED_SHA256=\"$HASH\"|" "$ROOT/macos/mpv_audio_kit.podspec"
  # Swift Package Manager binaryTarget checksum (same SHA-256 as podspec —
  # SwiftPM's "compute-checksum" is identical to shasum -a 256).
  sedi -E "s|(checksum:[[:space:]]*\")[a-f0-9]{64}|\\1$HASH|" "$ROOT/macos/mpv_audio_kit/Package.swift"
  # Extract the xcframework into the consumer's Frameworks/ slot — inside
  # the SwiftPM package dir, so Package.swift's local .binaryTarget(path:)
  # and the podspec's vendored_frameworks share one location (gitignored).
  # unzip restores the macOS versioned-bundle symlinks stored in the zip.
  DEST="$ROOT/macos/mpv_audio_kit/Frameworks"
  mkdir -p "$DEST"
  rm -rf "$DEST/libmpv.xcframework"
  unzip -q -o "$FILE" -d "$DEST"
  echo "  macos xcframework: $HASH"
  echo "    -> $DEST/libmpv.xcframework"
else
  echo "  macos xcframework: skipped (not built)"
  missing=$((missing + 1))
fi

# ── iOS xcframework (device arm64 + simulator arm64/x86_64) ─────────────────

FILE="$RELEASE_DIR/libmpv_ios.xcframework.zip"
if [ -f "$FILE" ]; then
  found=$((found + 1))
  HASH=$(sha256 "$FILE")
  sedi "s|EXPECTED_SHA256=\"[a-f0-9]\{64\}\"|EXPECTED_SHA256=\"$HASH\"|" "$ROOT/ios/mpv_audio_kit.podspec"
  # Swift Package Manager binaryTarget checksum (same SHA-256 as podspec —
  # SwiftPM's "compute-checksum" is identical to shasum -a 256).
  sedi -E "s|(checksum:[[:space:]]*\")[a-f0-9]{64}|\\1$HASH|" "$ROOT/ios/mpv_audio_kit/Package.swift"
  # Extract the xcframework into the consumer's Frameworks/ slot — inside
  # the SwiftPM package dir, shared with the podspec's vendored_frameworks
  # and Package.swift's local .binaryTarget(path:) (gitignored).
  DEST="$ROOT/ios/mpv_audio_kit/Frameworks"
  mkdir -p "$DEST"
  rm -rf "$DEST/libmpv.xcframework"
  unzip -q -o "$FILE" -d "$DEST"
  echo "  ios xcframework:   $HASH"
  echo "    -> $DEST/libmpv.xcframework"
else
  echo "  ios xcframework: skipped (not built)"
  missing=$((missing + 1))
fi

# ── Android arm64-v8a + x86_64 ──────────────────────────────────────────────
GRADLE="$ROOT/android/build.gradle.kts"

update_android_sha() {
  local abi_filename="$1" new_hash="$2"
  perl -i -0777 -pe \
    "s|(\"file\" to \"\Q$abi_filename\E\",\s*\"sha256\" to \")[a-f0-9]{64}|\${1}$new_hash|" \
    "$GRADLE"
}

FILE_ARM64="$RELEASE_DIR/libmpv_android-arm64-v8a.so"
FILE_ARMV7="$RELEASE_DIR/libmpv_android-armeabi-v7a.so"
FILE_X86="$RELEASE_DIR/libmpv_android-x86_64.so"

if [ -f "$FILE_ARM64" ]; then
  found=$((found + 1))
  HASH=$(sha256 "$FILE_ARM64")
  DEST="$ROOT/android/src/main/jniLibs/arm64-v8a"
  mkdir -p "$DEST"
  cp "$FILE_ARM64" "$DEST/libmpv.so"
  update_android_sha "libmpv_android-arm64-v8a.so" "$HASH"
  echo "  android arm64:     $HASH"
  echo "    -> $DEST/libmpv.so"
else
  echo "  android arm64: skipped (not built)"
  missing=$((missing + 1))
fi

if [ -f "$FILE_ARMV7" ]; then
  found=$((found + 1))
  HASH=$(sha256 "$FILE_ARMV7")
  DEST="$ROOT/android/src/main/jniLibs/armeabi-v7a"
  mkdir -p "$DEST"
  cp "$FILE_ARMV7" "$DEST/libmpv.so"
  update_android_sha "libmpv_android-armeabi-v7a.so" "$HASH"
  echo "  android armv7a:    $HASH"
  echo "    -> $DEST/libmpv.so"
else
  echo "  android armv7a: skipped (not built)"
  missing=$((missing + 1))
fi

if [ -f "$FILE_X86" ]; then
  found=$((found + 1))
  HASH=$(sha256 "$FILE_X86")
  DEST="$ROOT/android/src/main/jniLibs/x86_64"
  mkdir -p "$DEST"
  cp "$FILE_X86" "$DEST/libmpv.so"
  update_android_sha "libmpv_android-x86_64.so" "$HASH"
  echo "  android x86_64:    $HASH"
  echo "    -> $DEST/libmpv.so"
else
  echo "  android x86_64: skipped (not built)"
  missing=$((missing + 1))
fi

# ── Linux x86_64 ────────────────────────────────────────────────────────────

LINUX_CMAKE="$ROOT/linux/CMakeLists.txt"

FILE="$RELEASE_DIR/libmpv_linux-x86_64.so"
if [ -f "$FILE" ]; then
  found=$((found + 1))
  HASH=$(sha256 "$FILE")
  DEST="$ROOT/linux/libs/x86_64"
  mkdir -p "$DEST"
  cp "$FILE" "$DEST/libmpv.so"
  update_cmake_arch_sha "$LINUX_CMAKE" "EXPECTED_SHA256_X86_64" "$HASH"
  echo "  linux x86_64:      $HASH"
  echo "    -> $DEST/libmpv.so"
else
  echo "  linux x86_64: skipped (not built)"
  missing=$((missing + 1))
fi

# ── Linux aarch64 ───────────────────────────────────────────────────────────

FILE="$RELEASE_DIR/libmpv_linux-aarch64.so"
if [ -f "$FILE" ]; then
  found=$((found + 1))
  HASH=$(sha256 "$FILE")
  DEST="$ROOT/linux/libs/aarch64"
  mkdir -p "$DEST"
  cp "$FILE" "$DEST/libmpv.so"
  update_cmake_arch_sha "$LINUX_CMAKE" "EXPECTED_SHA256_AARCH64" "$HASH"
  echo "  linux aarch64:     $HASH"
  echo "    -> $DEST/libmpv.so"
else
  echo "  linux aarch64: skipped (not built)"
  missing=$((missing + 1))
fi

# ── Windows x86_64 ──────────────────────────────────────────────────────────

WINDOWS_CMAKE="$ROOT/windows/CMakeLists.txt"

FILE="$RELEASE_DIR/libmpv_windows-x86_64.dll"
if [ -f "$FILE" ]; then
  found=$((found + 1))
  HASH=$(sha256 "$FILE")
  DEST="$ROOT/windows/libs/x86_64"
  mkdir -p "$DEST"
  cp "$FILE" "$DEST/libmpv.dll"
  update_cmake_arch_sha "$WINDOWS_CMAKE" "EXPECTED_SHA256_X86_64" "$HASH"
  echo "  windows x86_64:    $HASH"
  echo "    -> $DEST/libmpv.dll"
else
  echo "  windows x86_64: skipped (not built)"
  missing=$((missing + 1))
fi

# ── Windows arm64 ───────────────────────────────────────────────────────────

FILE="$RELEASE_DIR/libmpv_windows-arm64.dll"
if [ -f "$FILE" ]; then
  found=$((found + 1))
  HASH=$(sha256 "$FILE")
  DEST="$ROOT/windows/libs/arm64"
  mkdir -p "$DEST"
  cp "$FILE" "$DEST/libmpv.dll"
  update_cmake_arch_sha "$WINDOWS_CMAKE" "EXPECTED_SHA256_ARM64" "$HASH"
  echo "  windows arm64:     $HASH"
  echo "    -> $DEST/libmpv.dll"
else
  echo "  windows arm64: skipped (not built)"
  missing=$((missing + 1))
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [ "$found" -eq 0 ]; then
  echo "No release binaries found in $RELEASE_DIR."
  echo "Build something first (e.g. ./build macos), then re-run checksums."
  exit 1
fi
if [ "$missing" -gt 0 ]; then
  echo "Updated $found binary(s); skipped $missing not present in release."
else
  echo "All $found release binary(s) checksummed and copied."
fi
