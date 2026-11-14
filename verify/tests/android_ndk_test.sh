#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks the NDK setup of scripts/build_libmpv_android.sh on fake NDKs: the
# functions are taken from the script as they are written and run with a
# HOME, a build directory and a curl of the test. An NDK is used only when
# its source.properties names the pinned revision, the one asked for with
# ANDROID_NDK_ROOT stops the build when it is another, ALLOW_ANY_NDK=1 takes
# any, and a downloaded zip is checked against the SHA-256 of
# _sources.sha256. No network, no NDK.
#
# Usage: bash verify/tests/android_ndk_test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/build_libmpv_android.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

# The pins of the script and its three functions, as text.
{
  grep -E '^NDK_(VERSION|SEMVER)=' "$SCRIPT"
  for f in ndk_revision ndk_pinned find_or_download_ndk; do
    awk -v f="$f" '$0 == f "() {" { on = 1 } on { print } on && $0 == "}" { exit }' "$SCRIPT"
  done
} > "$TMP/ndk.sh"
[[ "$(grep -c '^[a-z_]*() {$' "$TMP/ndk.sh")" == 3 && "$(grep -c '^NDK_' "$TMP/ndk.sh")" == 2 ]]
check $? "the script has NDK_VERSION, NDK_SEMVER and the three functions"
SEMVER="$(sed -n 's/^NDK_SEMVER="\(.*\)"/\1/p' "$TMP/ndk.sh")"
VERSION="$(sed -n 's/^NDK_VERSION="\(.*\)"/\1/p' "$TMP/ndk.sh")"

# ndk <dir> <revision>: a fake NDK.
ndk() { mkdir -p "$1"; printf 'Pkg.Desc = Android NDK\r\nPkg.Revision = %s\r\n' "$2" > "$1/source.properties"; }

# find <case> [env...]: find_or_download_ndk with HOME and BUILD_DIR of the
# case, the pins of $TMP/pins and a curl that serves $TMP/served.zip (or
# fails without it). Prints ANDROID_NDK_ROOT; the messages go to <case>.log.
find() {
  local name="$1"; shift
  mkdir -p "$TMP/$name/home" "$TMP/$name/build"
  env -u ANDROID_NDK_ROOT -u ALLOW_ANY_NDK HOME="$TMP/$name/home" TMPDIR="$TMP/$name" \
      STRICT_SOURCES=0 "$@" bash -c "
    set -euo pipefail
    source '$ROOT/scripts/shared/_helpers.sh'
    SOURCES_SHA256_FILE='$TMP/pins'
    BUILD_DIR='$TMP/$name/build'
    curl() { local out=; while (( \$# )); do [[ \$1 == -o ]] && out=\$2; shift; done
             [[ -f '$TMP/served.zip' ]] && cp '$TMP/served.zip' \"\$out\"; }
    uname() { echo Linux; }
    source '$TMP/ndk.sh'
    find_or_download_ndk
    echo \"\$ANDROID_NDK_ROOT\"" 2> "$TMP/$name.log"
}
: > "$TMP/pins"

# ── An NDK on the machine ────────────────────────────────────────────────────
ndk "$TMP/sdk/home/Android/Sdk/ndk/$SEMVER" "$SEMVER"
got="$(find sdk)"; [[ $? == 0 && "$got" == "$TMP/sdk/home/Android/Sdk/ndk/$SEMVER" ]]
check $? "the pinned NDK of the SDK is used"

# A directory with the name of the pinned NDK and another NDK inside, and a
# newer NDK beside it: neither is used, and with nothing to download the
# build stops.
ndk "$TMP/other/home/Android/Sdk/ndk/$SEMVER" 27.0.12077973
ndk "$TMP/other/home/Android/Sdk/ndk/99.0.1" 99.0.1
if find other > /dev/null; then false; else true; fi
check $? "another NDK under the pinned name, and a newer one, are passed over"
grep -q 'No SHA-256 for https://dl.google.com/android/repository/android-ndk-.*-linux.zip' "$TMP/other.log"
check $? "a zip with no pin stops the build before the download, without STRICT_SOURCES"

got="$(find other ALLOW_ANY_NDK=1)"; [[ $? == 0 && "$got" == "$TMP/other/home/Android/Sdk/ndk/$SEMVER" ]]
check $? "ALLOW_ANY_NDK=1 takes the NDK it finds"
grep -q "NDK 27.0.12077973 .* is not the pinned $SEMVER" "$TMP/other.log"
check $? "and says which one it is"

# ── ANDROID_NDK_ROOT ─────────────────────────────────────────────────────────
ndk "$TMP/env-ndk" 27.0.12077973
if find env ANDROID_NDK_ROOT="$TMP/env-ndk" > /dev/null; then false; else true; fi
check $? "ANDROID_NDK_ROOT with another NDK stops the build"
grep -q "is NDK 27.0.12077973, this build pins $SEMVER" "$TMP/env.log"
check $? "and names the two revisions"
got="$(find env ANDROID_NDK_ROOT="$TMP/env-ndk" ALLOW_ANY_NDK=1)"; [[ $? == 0 && "$got" == "$TMP/env-ndk" ]]
check $? "ALLOW_ANY_NDK=1 lets it through"
ndk "$TMP/env-good" "$SEMVER"
got="$(find env2 ANDROID_NDK_ROOT="$TMP/env-good")"; [[ $? == 0 && "$got" == "$TMP/env-good" ]]
check $? "ANDROID_NDK_ROOT with the pinned NDK is used"

# ── The download ─────────────────────────────────────────────────────────────
URL="https://dl.google.com/android/repository/android-ndk-$VERSION-linux.zip"
grep -q "  $URL\$" "$ROOT/scripts/shared/_sources.sha256" &&
  grep -q "  ${URL/-linux/-darwin}\$" "$ROOT/scripts/shared/_sources.sha256"
check $? "_sources.sha256 pins the linux and the darwin zip of NDK $VERSION"

zip_of() { # zip_of <revision>: $TMP/served.zip with android-ndk-<version>/ of that revision
  rm -rf "$TMP/zip" "$TMP/served.zip"
  ndk "$TMP/zip/android-ndk-$VERSION" "$1"
  python3 -I - "$TMP/zip" "$TMP/served.zip" <<'PY'
import pathlib, sys, zipfile
src = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(sys.argv[2], "w") as z:
    for f in sorted(p for p in src.rglob("*") if p.is_file()):
        z.write(f, f.relative_to(src).as_posix())
PY
}
if command -v unzip > /dev/null; then
  zip_of "$SEMVER"
  printf '%s  %s\n' "$(sha256sum "$TMP/served.zip" | cut -d' ' -f1)" "$URL" > "$TMP/pins"
  got="$(find dl)"; [[ $? == 0 && "$got" == "$TMP/dl/build/ndk/android-ndk-$VERSION" ]]
  check $? "a zip with the pinned SHA-256 is unpacked and used"
  [[ ! -e "$TMP/dl/build/ndk/ndk.zip" ]]; check $? "the zip is removed once unpacked"

  printf '%064d  %s\n' 0 "$URL" > "$TMP/pins"
  if find bad > /dev/null; then false; else true; fi
  check $? "a zip with another SHA-256 stops the build"
  grep -q 'SHA-256 mismatch' "$TMP/bad.log" && [[ ! -e "$TMP/bad/build/ndk/ndk.zip" &&
    ! -e "$TMP/bad/build/ndk/android-ndk-$VERSION" ]]
  check $? "and is neither kept nor unpacked"

  # The right bytes for the pin, the wrong NDK inside: NDK_SEMVER and
  # NDK_VERSION no longer name the same release.
  zip_of 27.0.12077973
  printf '%s  %s\n' "$(sha256sum "$TMP/served.zip" | cut -d' ' -f1)" "$URL" > "$TMP/pins"
  if find semver > /dev/null; then false; else true; fi
  check $? "a zip whose NDK is not NDK_SEMVER stops the build"
else
  echo "skip the download: no unzip"
fi

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "android_ndk_test: ok"
