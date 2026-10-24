#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Builds mak_spike.c natively against a released libmpv (same patches, same
# FFmpeg lists) and runs it with the given arguments: the decode times the
# web numbers are compared with.
#
#   run_native.sh <libmpv .so> <mpv source tree> <work dir> [spike args...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$(readlink -f "${1:?libmpv .so}")"
mpv_src="${2:?mpv source tree, for include/mpv/client.h}"
work="${3:?work dir}"
shift 3
mkdir -p "$work/lib"
# The kit names the library libmpv_audio_kit.so (its SONAME).
cp "$lib" "$work/lib/libmpv_audio_kit.so"
cc -O2 -Wall -I"$mpv_src/include" "$HERE/mak_spike.c" -o "$work/native_spike" \
  -L"$work/lib" -l:libmpv_audio_kit.so -lm -Wl,-rpath,"$work/lib"
exec "$work/native_spike" "$@"
