# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Forget the last chapter seek when a client sets chapter-list.

Setting `chapter` seeks and records the index in last_chapter_seek, which
get_current_chapter() (player/playloop.c) returns as long as no other kind
of seek comes, even when it lies past the end of the chapter list. Only a
new file reset it. Writing a shorter `chapter-list` to the same file left
it on an index of the old list, so `chapter` reported a chapter that no
longer exists and `chapter-metadata` read chapters[index] past the end of
the new array: a crash, from the property observer of any client that
watches it (mpv_audio_kit does).

parse_node_chapters() (player/command.c, the setter of chapter-list) now
resets the seek record as a file load does, so the current chapter comes
from the position in the new list. It is the only place that replaces the
chapters of a file that plays. A guard in the chapter-metadata getter alone
would stop the crash but leave `chapter` past the end of the list.

Usage: patch_chapter_list_reset.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_lib"))
import anchor  # noqa: E402

MARKER = "MAK_CHAPTER_LIST_RESET_PATCH_V1"

OLD = (
    "    talloc_free(mpctx->chapters);\n"
    "    mpctx->num_chapters = 0;\n"
    "    mpctx->chapters = talloc_array(NULL, struct demux_chapter, 0);\n"
)

NEW = OLD + (
    f"    // {MARKER}: the last chapter seek named an\n"
    "    // index of the old list. Kept, get_current_chapter() returned it past\n"
    "    // the end of a shorter list, and chapter-metadata read beyond it.\n"
    "    mpctx->last_chapter_seek = -2;\n"
    "    mpctx->last_chapter_flag = false;\n"
)


def apply(p):
    p.edits("player/command.c", [("parse_node_chapters reset", OLD, NEW)])


anchor.main(apply, "patch_chapter_list_reset", marker=MARKER)
