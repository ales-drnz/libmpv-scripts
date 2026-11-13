#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks the version guard patch_read_error.py writes next to
# mak_protocol_seek in stream/stream_lavf.c (F5-18): that function sets
# fields of AVIOContext the way aviobuf.c of the FFmpeg it was read against
# uses them, and no anchor watches FFmpeg from mpv. The guard taken from the
# patched file must stop the preprocessor on a libavformat outside 60 to 62
# and pass inside, and with MAK_PROTOCOL_SEEK_UNCHECKED defined.
#
# Usage: bash verify/tests/patches/read_error_guard_test.sh <patched mpv source dir> <work dir>

set -uo pipefail

SRC="${1:?usage: read_error_guard_test.sh <patched mpv source dir> <work dir>}"
T="${2:?usage: read_error_guard_test.sh <patched mpv source dir> <work dir>}"
CC="${CC:-gcc}"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

sed -n '/^#if (LIBAVFORMAT_VERSION_MAJOR </,/^#endif/p' "$SRC/stream/stream_lavf.c" > "$T/guard.h"
[[ -s "$T/guard.h" ]] && grep -q '^#error' "$T/guard.h"
check $? "stream_lavf.c has the guard, with an #error"
grep -q 'mak_protocol_seek' "$T/guard.h"; check $? "the error names mak_protocol_seek"

# pp <libavformat major> [flags]: preprocesses the guard for that version.
pp() {
  local v="$1"; shift
  { echo "#define LIBAVFORMAT_VERSION_MAJOR $v"; cat "$T/guard.h"; } |
    "$CC" -E "$@" -x c - > /dev/null 2> "$T/pp-$v.log"
}
for v in 60 61 62; do pp "$v"; check $? "libavformat $v passes"; done
for v in 59 63; do ! pp "$v"; check $? "libavformat $v stops the build"; done
pp 63 -DMAK_PROTOCOL_SEEK_UNCHECKED; check $? "libavformat 63 passes with MAK_PROTOCOL_SEEK_UNCHECKED"

echo "read_error_guard_test: $fails failure(s)"
(( fails == 0 ))
