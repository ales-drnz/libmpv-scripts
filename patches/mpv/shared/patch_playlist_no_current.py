#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""playlist-next-playlist and playlist-prev-playlist with no current entry.

playlist_get_first_in_next_playlist() (common/playlist.c), behind those two
commands, compares the source playlist of the entry it found with that of
the current entry, pl->current->playlist_path, without checking there is a
current entry. There is none on an idle core: after `stop keep-playlist`,
whose PT_STOP leaves current NULL with the entries kept, and for entries
appended to an idle core that never started. playlist_get_next() still
finds an entry there (the last one going back once the playlist completed,
the first going forward before it started), so playlist-prev-playlist
dereferenced NULL every time and playlist-next-playlist did for an entry of
a loaded playlist file: the process ended (mpv_audio_kit 0.8.0 reaches the
first through stop(keepPlaylist: true) and previousPlaylist()).

With no current entry there is no "current playlist" to leave: the function
returns NULL, and the command fails as it does with nothing to go to.

Usage: patch_playlist_no_current.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_lib"))
import anchor  # noqa: E402

MARKER = "MAK_PLAYLIST_NO_CURRENT_PATCH_V1"

OLD = (
    "struct playlist_entry *playlist_get_first_in_next_playlist(struct playlist *pl,\n"
    "                                                           int direction)\n"
    "{\n"
)

NEW = OLD + (
    f"    // {MARKER}: the source playlist\n"
    "    // of the current entry is read below; with none (an idle core, after\n"
    "    // stop keep-playlist) there is no playlist to leave.\n"
    "    if (!pl->current)\n"
    "        return NULL;\n"
)


def apply(p):
    p.edits("common/playlist.c", [("first_in_next_playlist guard", OLD, NEW)])


anchor.main(apply, "patch_playlist_no_current", marker=MARKER)
