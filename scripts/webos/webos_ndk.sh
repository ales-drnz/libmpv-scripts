# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
# shellcheck shell=bash

# LG's webOS NDK, the one flutter-webos builds apps with: its release and
# checksum, and the TVs' sysroot taken out of it. The webos stage of
# docker/Dockerfile installs the whole NDK at the same version and checksum
# (verify/tests/webos_ndk_test.sh checks they agree). Its licence allows it
# on our machines only: neither the installer nor the sysroot is published.
# Sourced; do not run directly.

WEBOS_NDK_VERSION="11.2.0"
WEBOS_NDK_SHA256="3c93af87505a8771d5662cc4a15b596d46791e3c7d8a0cb9113fa8e846e15a42"
WEBOS_NDK_TARGET="ca9v1-webosmllib32-linux-gnueabi"

webos_ndk_url() {
  local name="webos-ndk-flutter-starfish-x86_64-ca9v1-$WEBOS_NDK_VERSION.sh"
  echo "https://github.com/lg-flutter-webos/ndk/releases/download/$WEBOS_NDK_VERSION/$name"
}

# webos_ndk_sysroot <dir>: the TVs' sysroot of the NDK in <dir>/sysroot,
# kept while it is of this checksum. The installer is a shell script ahead
# of a tar.xz: only the target's sysroot is unpacked, the installer never
# runs. Prints the sysroot's path.
webos_ndk_sysroot() {
  local dir="$1" sysroot="$1/sysroot" installer="$1/webos-ndk.sh"
  if [[ -f "$sysroot/.ndk" && "$(cat "$sysroot/.ndk")" == "$WEBOS_NDK_SHA256" ]]; then
    echo "$sysroot"; return 0
  fi
  mkdir -p "$dir"
  if ! echo "$WEBOS_NDK_SHA256  $installer" | sha256sum -c --status - 2>/dev/null; then
    curl -fsSL --retry 3 -o "$installer.part" "$(webos_ndk_url)" || return 1
    echo "$WEBOS_NDK_SHA256  $installer.part" | sha256sum -c --status - || {
      echo "webos_ndk_sysroot: the NDK installer does not match its SHA-256" >&2
      rm -f "$installer.part"; return 1
    }
    mv "$installer.part" "$installer"
  fi
  local marker
  marker="$(grep -na -m1 '^MARKER:$' "$installer" | cut -d: -f1)"
  [[ -n "$marker" ]] || { echo "webos_ndk_sysroot: no payload in the installer" >&2; return 1; }
  rm -rf "$sysroot" "$dir/unpack"; mkdir -p "$dir/unpack"
  tail -n +"$((marker + 1))" "$installer" \
    | tar -xJ -C "$dir/unpack" "./sysroots/$WEBOS_NDK_TARGET" || return 1
  mv "$dir/unpack/sysroots/$WEBOS_NDK_TARGET" "$sysroot"
  rm -rf "$dir/unpack"
  # A merged /usr: the loader the binaries name is /lib/ld-linux.so.3.
  [[ -e "$sysroot/lib" ]] || ln -s usr/lib "$sysroot/lib"
  echo "$WEBOS_NDK_SHA256" > "$sysroot/.ndk"
  echo "$sysroot"
}
