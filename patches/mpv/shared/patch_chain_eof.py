# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Keep the end of file when a filter change drops the filter holding it.

mp_output_chain_update_filters frees the filters a new `af` list no longer
has, with every frame they hold. A filter with latency (rubberband,
dynaudnorm, loudnorm, afir) can hold the decoder's EOF frame for a few
hundred milliseconds near the end of a file. Removing or rebuilding it
then loses that EOF: the decoder does not send another, the audio chain
never reports the end, and playback stops at the end of the file for
good, with no loop wrap and no next playlist entry.

reinit_audio_filters already issues a refresh seek when the rebuild drops
0.2 s or more of buffered audio while playing. This patch tracks, per user
filter, an EOF that went in and has not come out, flags the chain when such
a filter is freed, and makes reinit_audio_filters refresh-seek in that case
too, in any state but the end of playback, so the decoder produces the tail
and its EOF again. That includes the time between a seek and the restart of
playback: a filter with a long look-ahead (dynaudnorm) takes a short file
whole, EOF included, before it outputs, and a filter change then left the
audio stalled after the little it had already passed on.

Usage: patch_chain_eof.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_lib"))
import anchor  # noqa: E402

MARKER = "MAK_CHAIN_EOF_PATCH_V1"


def apply(p):
    p.edits("filters/f_output_chain.h", [(
        "    bool got_output_eof;\n",
        "    bool got_output_eof;\n"
        "\n"
        f"    /* {MARKER}: a filter change freed a filter holding the input's\n"
        "     * EOF, which will not come again. The user resets the flag. */\n"
        "    bool dropped_eof;\n",
    )])

    p.edits("filters/f_output_chain.c", [
        (
            "    bool failed;\n    bool error_eof_sent;\n};\n",
            "    bool failed;\n    bool error_eof_sent;\n"
            f"\n    /* {MARKER}: an EOF went into f and has not come out. */\n"
            "    bool eof_held;\n};\n",
        ),
        (
            "    u->error_eof_sent = false;\n",
            "    u->error_eof_sent = false;\n"
            f"    u->eof_held = false; /* {MARKER} */\n",
        ),
        (
            "        struct mp_frame frame = mp_pin_out_read(f->ppins[0]);\n"
            "\n"
            "        check_in_format_change(u, frame);\n",
            "        struct mp_frame frame = mp_pin_out_read(f->ppins[0]);\n"
            f"        if (frame.type == MP_FRAME_EOF) /* {MARKER} */\n"
            "            u->eof_held = true;\n"
            "\n"
            "        check_in_format_change(u, frame);\n",
        ),
        (
            "        struct mp_frame frame = mp_pin_out_read(u->f->pins[1]);\n",
            "        struct mp_frame frame = mp_pin_out_read(u->f->pins[1]);\n"
            f"        if (frame.type == MP_FRAME_EOF) /* {MARKER} */\n"
            "            u->eof_held = false;\n",
        ),
        (
            "    for (int n = 0; n < p->num_user_filters; n++) {\n"
            "        if (!used[n])\n"
            "            talloc_free(p->user_filters[n]->wrapper);\n"
            "    }\n",
            "    for (int n = 0; n < p->num_user_filters; n++) {\n"
            "        if (!used[n]) {\n"
            f"            if (p->user_filters[n]->eof_held) /* {MARKER} */\n"
            "                c->dropped_eof = true;\n"
            "            talloc_free(p->user_filters[n]->wrapper);\n"
            "        }\n"
            "    }\n",
        ),
    ])

    p.edits("player/audio.c", [(
        "    if (mpctx->audio_status == STATUS_PLAYING && delay - ndelay >= 0.2)\n"
        "        issue_refresh_seek(mpctx, MPSEEK_EXACT);\n",
        f"    // {MARKER}: or if it dropped the EOF, which the decoder will not\n"
        "    // send again: without the refresh the file would never end. That\n"
        "    // holds before playback restarts too: right after a seek a filter\n"
        "    // with a long look-ahead (dynaudnorm) can hold the rest of a short\n"
        "    // file and its EOF, and the refresh then repeats the seek.\n"
        "    bool dropped_eof = ao_c->filter->dropped_eof;\n"
        "    ao_c->filter->dropped_eof = false;\n"
        "    if ((mpctx->audio_status == STATUS_PLAYING && delay - ndelay >= 0.2) ||\n"
        "        (dropped_eof && mpctx->audio_status != STATUS_EOF))\n"
        "        issue_refresh_seek(mpctx, MPSEEK_EXACT);\n",
    )])


anchor.main(apply, "patch_chain_eof", marker=MARKER)
