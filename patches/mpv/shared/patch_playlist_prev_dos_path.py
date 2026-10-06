# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Build the playlist-prev-playlist prefixes as copies on Windows.

playlist_get_first_in_same_playlist() (common/playlist.c, the code behind
`playlist-prev-playlist`) tests whether the current playlist-path starts with
the entry's playlist-path plus a separator. It appends "/" to its copy with
talloc_strdup_append(), which may move the string but leaves the local
pointer on the old block. Under HAVE_DOS_PATHS, Windows only, the second test
then appends "\\" to that freed block: mpv aborts on the ta canary assertion
(ta.c, line 291) or corrupts its heap. Had the block not moved, the second
prefix would have been "path/\\" instead of "path\\".

This patch builds each prefix as its own copy of the stripped path, so
nothing is appended in place. Other platforms only lose a reallocation.

Usage: patch_playlist_prev_dos_path.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "MAK_PLAYLIST_PREV_DOS_PATH_PATCH_V1"

root = Path(sys.argv[1])
playlist = root / "common/playlist.c"

OLD = (
    "    if (bstr_startswith(bstr0(current_playlist_path),\n"
    "                        bstr0(talloc_strdup_append(playlist_path, \"/\")))\n"
    "#if HAVE_DOS_PATHS\n"
    "        ||\n"
    "        bstr_startswith(bstr0(current_playlist_path),\n"
    "                        bstr0(talloc_strdup_append(playlist_path, \"\\\\\")))\n"
    "#endif\n"
)

NEW = (
    f"    // {MARKER}: each prefix is a copy. Appending in place left\n"
    "    // playlist_path on a freed block for the Windows test below.\n"
    "    if (bstr_startswith(bstr0(current_playlist_path),\n"
    "                        bstr0(talloc_asprintf(tmp, \"%s/\", playlist_path)))\n"
    "#if HAVE_DOS_PATHS\n"
    "        ||\n"
    "        bstr_startswith(bstr0(current_playlist_path),\n"
    "                        bstr0(talloc_asprintf(tmp, \"%s\\\\\", playlist_path)))\n"
    "#endif\n"
)

text = playlist.read_text()
if MARKER in text:
    print(f"Already patched: {playlist.name}")
    sys.exit(0)
if text.count(OLD) != 1:
    sys.exit(f"patch_playlist_prev_dos_path: anchor not found once in {playlist}")
playlist.write_text(text.replace(OLD, NEW, 1))
print(f"Patched: {playlist}")
