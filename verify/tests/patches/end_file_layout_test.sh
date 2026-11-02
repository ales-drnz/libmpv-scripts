#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks the layout of mpv_event_end_file with the fields of
# patch_read_error.py, in include/mpv/client.h of a patched tree, on the
# ABIs libmpv-scripts builds for. A client that reads the fields through a
# copy of the struct (mpv_audio_kit over FFI, the web module through
# mak_web_layout() of scripts/web/mak_web.c) relies on one layout
# everywhere:
#
#   field                   offset
#   mak_read_error (int)    28
#   mak_skipped_segments    32 (int64_t)
#   mak_duration (double)   40
#   mak_position (double)   48
#   sizeof                  56
#
# The same on every target: a 4-byte int64_t alignment (i386) or an 8-byte
# one (the rest) puts no padding anywhere. With clang every target is
# checked (freestanding, no sysroot needed); without it only the host, and
# i386 when gcc -m32 works.
#
# Usage: bash verify/tests/patches/end_file_layout_test.sh <patched mpv source dir> <work dir>

set -uo pipefail

SRC="${1:?usage: end_file_layout_test.sh <patched mpv source dir> <work dir>}"
T="${2:?usage: end_file_layout_test.sh <patched mpv source dir> <work dir>}"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

grep -q 'double mak_position;' "$SRC/include/mpv/client.h"
check $? "client.h has the END_FILE fields of patch_read_error.py"

cat > "$T/layout.c" <<'C'
#include <stddef.h>
#include <mpv/client.h>
#define AT(f, n) _Static_assert(offsetof(mpv_event_end_file, f) == n, #f " at " #n)
AT(reason, 0);
AT(error, 4);
AT(playlist_entry_id, 8);
AT(playlist_insert_id, 16);
AT(playlist_insert_num_entries, 24);
AT(mak_read_error, 28);
AT(mak_skipped_segments, 32);
AT(mak_duration, 40);
AT(mak_position, 48);
_Static_assert(sizeof(mpv_event_end_file) == 56, "sizeof 56");
C

if command -v clang > /dev/null; then
  for target in x86_64-linux-gnu i686-linux-gnu aarch64-linux-android armv7a-linux-androideabi \
                x86_64-w64-windows-gnu aarch64-w64-windows-gnu arm64-apple-macos x86_64-apple-macos \
                arm64-apple-ios wasm32-unknown-emscripten; do
    clang --target="$target" -ffreestanding -fsyntax-only -I"$SRC/include" "$T/layout.c" \
      > "$T/$target.log" 2>&1
    r=$?
    check $r "$target: the layout above"
    (( r == 0 )) || sed 's/^/     /' "$T/$target.log" | head -5
  done
else
  echo "no clang: the host only"
  gcc -fsyntax-only -I"$SRC/include" "$T/layout.c" > "$T/host.log" 2>&1
  check $? "host: the layout above"
  if echo 'int main(void) { return 0; }' | gcc -m32 -x c - -o "$T/m32" 2> /dev/null; then
    gcc -m32 -fsyntax-only -I"$SRC/include" "$T/layout.c" > "$T/i386.log" 2>&1
    check $? "i386: the layout above"
  fi
fi

echo "end_file_layout_test: $fails failure(s)"
(( fails == 0 ))
