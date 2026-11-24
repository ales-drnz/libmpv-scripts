#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# ohos_sdk.sh <dest dir> [native] [toolchains]
#
# Unpacks parts of the public OpenHarmony SDK for Linux (Apache-2.0) into
# <dest dir>: "native" is the native SDK (the OHOS clang 15 with libc++ and
# compiler-rt, the musl sysroot of the API headers and stubs), "toolchains"
# is hdc. Both by default.
#
# The SDK is one tarball of every host (3.7 GB). The Linux zips are its
# first members, so it is read as a stream and tar stops at the last one
# asked for: about 1 GB comes down, not the whole. The tarball's own
# checksum needs all of it, so the checksums pinned are the zips' (an
# OpenHarmony SDK release ships each zip inside the tarball unchanged).
#
# Re-running with the same pins is a no-op.
# =============================================================================

set -euo pipefail

# OpenHarmony 7.0 Release, API 26 (native and toolchains 26.0.0.38). The
# dated name is the build of 29-08-2026 and does not move; the undated
# ohos-sdk-windows_linux-public.tar.gz beside it is replaced by each rebuild.
OHOS_SDK_URL="https://repo.huaweicloud.com/openharmony/os/7.0-Release/ohos-sdk-windows_linux-public_20260829.tar.gz"
OHOS_SDK_VERSION="26.0.0.38"
OHOS_NATIVE_ZIP="ohos-sdk/linux/native-linux-x64-${OHOS_SDK_VERSION}-Release.zip"
OHOS_NATIVE_SHA256="ab828a0f960a829e7b75d764158696a8b926cf8a3035cbd313ff98daf0c69fe0"
OHOS_TOOLCHAINS_ZIP="ohos-sdk/linux/toolchains-linux-x64-${OHOS_SDK_VERSION}-Release.zip"
OHOS_TOOLCHAINS_SHA256="50b8c27dbba4d9ee34840613b08f988cd164e30d46dadaa149883b6f14fd83b7"

dest="${1:?usage: ohos_sdk.sh <dest dir> [native] [toolchains]}"
shift
parts=("$@")
(( ${#parts[@]} )) || parts=(native toolchains)

# Each part has its own lock, <dest>/.lock-<part>, with its pin: a part
# already there at the same pin is kept, and only the missing ones are
# streamed.
members=() pins="" want=()
for part in "${parts[@]}"; do
  case "$part" in
    native)     zip="$OHOS_NATIVE_ZIP";     sha="$OHOS_NATIVE_SHA256" ;;
    toolchains) zip="$OHOS_TOOLCHAINS_ZIP"; sha="$OHOS_TOOLCHAINS_SHA256" ;;
    *) echo "ohos_sdk.sh: unknown part $part (native or toolchains)" >&2; exit 2 ;;
  esac
  lock="$OHOS_SDK_URL $sha $zip"
  if [[ -f "$dest/.lock-$part" ]] && [[ "$(cat "$dest/.lock-$part")" == "$lock" ]]; then
    echo "ohos_sdk.sh: $dest/$part already holds $OHOS_SDK_VERSION"
    continue
  fi
  want+=("$part")
  members+=("$zip")
  pins+="$sha  $zip"$'\n'
done
(( ${#want[@]} )) || exit 0

mkdir -p "$dest"
work="$dest/.download"
rm -rf "$work"
mkdir -p "$work"

# --occurrence: tar exits once it has each member, and curl then stops on
# the closed pipe (its exit status is that of the pipe, so it is not
# checked, and its "failure writing output" is that stop: the checksums
# below are what counts).
echo "ohos_sdk.sh: streaming ${members[*]} from $OHOS_SDK_URL"
set +o pipefail
curl -fsL --retry 3 "$OHOS_SDK_URL" | tar -xzf - -C "$work" --occurrence=1 "${members[@]}"
set -o pipefail
for m in "${members[@]}"; do
  [[ -f "$work/$m" ]] || { echo "ohos_sdk.sh: $m missing from the stream" >&2; exit 1; }
done
(cd "$work" && sha256sum -c --quiet - <<< "$pins")

for part in "${want[@]}"; do
  rm -rf "${dest:?}/$part" "$dest/.lock-$part"
  case "$part" in
    native)
      # The native SDK without what a build of libmpv never runs (lldb,
      # clangd, the tidy tools, the docs): llvm/bin is 1 GB.
      unzip -q "$work/$OHOS_NATIVE_ZIP" -d "$dest" \
        -x 'native/llvm/bin/lldb*' 'native/llvm/bin/clangd' 'native/llvm/bin/clang-tidy' \
           'native/llvm/lib/liblldb*' 'native/docs/*'
      "$dest/native/llvm/bin/clang" --version | head -1
      lock="$OHOS_SDK_URL $OHOS_NATIVE_SHA256 $OHOS_NATIVE_ZIP"
      ;;
    toolchains)
      unzip -q "$work/$OHOS_TOOLCHAINS_ZIP" -d "$dest"
      LD_LIBRARY_PATH="$dest/toolchains" "$dest/toolchains/hdc" -v
      lock="$OHOS_SDK_URL $OHOS_TOOLCHAINS_SHA256 $OHOS_TOOLCHAINS_ZIP"
      ;;
  esac
  printf '%s' "$lock" > "$dest/.lock-$part"
done
rm -rf "$work"
echo "ohos_sdk.sh: ${want[*]} of $OHOS_SDK_VERSION in $dest"
