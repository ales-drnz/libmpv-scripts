#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks layer 6b of verify_binaries.sh, the FFmpeg muxer and protocols, with
# no toolchain: the layer and its marker table are read out of the script. The
# cases below are strings dumps that pin what each marker must match and what
# it must not. Given libraries as arguments, it then runs the layer on each of
# them as Verify does, and fails when one misses a component.
#
# Usage: bash verify/tests/components_test.sh [libmpv_*.so|.dll|.xcframework.zip ...]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/verify/common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The script runs its checks when sourced, so only the table and the layer
# are loaded. The result helpers below record one letter per marker instead.
table="$(awk '/^FFMPEG_COMPONENT_MARKERS=\(/ { on = 1 } on { print } on && /^\)/ { exit }' "$SCRIPT")"
layer="$(awk '/^layer_ffmpeg_components\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' "$SCRIPT")"
[[ -n "$table" ]] || { echo "FAIL: FFMPEG_COMPONENT_MARKERS not found in $SCRIPT"; exit 1; }
[[ -n "$layer" ]] || { echo "FAIL: layer_ffmpeg_components not found in $SCRIPT"; exit 1; }
eval "$table"
eval "$layer"
V=""
phase() { :; }
pass() { V+="P"; }
fail() { V+="F"; }
(( ${#FFMPEG_COMPONENT_MARKERS[@]} == 4 )) || {
  echo "FAIL: expected 4 markers (spdif, httpproxy, https, tls), found ${#FFMPEG_COMPONENT_MARKERS[@]}"
  exit 1
}

FAILS=0
# expect <case> <verdicts> <strings dump>: verdicts has one P or F per marker,
# in table order (spdif, httpproxy, https, tls).
expect() {
  V=""
  layer_ffmpeg_components "$3" || true
  if [[ "$V" == "$2" ]]; then
    echo "ok   $1: $V"
  else
    echo "FAIL $1: want $2, got ${V:-nothing}"
    FAILS=$((FAILS + 1))
  fi
}

# What strings -a prints for the code of each component.
SPDIF=$'spdif\nspdif_flags\ndtshd_rate'
PROXY=$'httpproxy\nCONNECT %s HTTP/1.1\nHost: %s\nConnection: close'
HTTPS=$'http,https,tls,rtp,tcp,udp,crypto,httpproxy\nhttps'
TLS=$'Certificate Authority database file\nVerify against a specific hostname'
# What every libmpv-r17 binary carries without them: the "httpproxy" URL of
# tls.c, the whitelist of the http protocol, the spdif names of mpv's
# ad_spdif and mpv's own tls options.
COMMON=$'httpproxy\nhttp,https,tls,rtp,tcp,udp,crypto,httpproxy,data\nhttps://\nspdif-ac3\nlibavformat spdif initialization failed.\ntls_verify\nca_file'

expect "all four components" PPPP "$COMMON"$'\n'"$SPDIF"$'\n'"$PROXY"$'\n'"$HTTPS"$'\n'"$TLS"
expect "libmpv-r17: no spdif muxer, no httpproxy" FFPP "$COMMON"$'\n'"$HTTPS"$'\n'"$TLS"
expect "the names mpv and tls.c carry are not the components" FFFF "$COMMON"
expect "the http whitelist is not the https protocol" PPFP "$SPDIF"$'\n'"$PROXY"$'\n'"$TLS"$'\n'"http,https,tls,rtp,tcp,udp,crypto,httpproxy,data"

# Libraries given on the command line: the layer as Verify runs it. An Apple
# xcframework is read from its device slice, as Verify does.
for lib in "$@"; do
  inspect="$lib"
  if [[ "$lib" == *.zip ]]; then
    rm -rf "$TMP/xcf"; mkdir -p "$TMP/xcf"
    unzip -q -o "$lib" -d "$TMP/xcf"
    inspect=$(find "$TMP/xcf" -type f -name libmpv -path '*/libmpv.framework/*' ! -path '*-simulator/*' | sort | head -1)
  fi
  V=""
  layer_ffmpeg_components "$(strings -a "$inspect")" || true
  if [[ "$V" == PPPP ]]; then
    echo "ok   $(basename "$lib"): $V"
  else
    echo "FAIL $(basename "$lib"): $V (spdif, httpproxy, https, tls)"
    FAILS=$((FAILS + 1))
  fi
done

if (( FAILS > 0 )); then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all cases passed"
