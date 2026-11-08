# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Tell the park of keep-open from a pause of the client at the end.

Problem
=======

With gapless audio the decoder reaches EOF while the output still holds
the tail, up to about 0.4 s: eof-reached is yes and the audio plays on
until handle_keep_open() pauses the core once the output played out.
A client sees the park as eof-reached and pause both yes. Two things go
wrong when the client pauses in that tail itself:

  - set_pause_state() hands ao_set_paused() the EOF of the audio status,
    and ao_set_paused() drains an output that still plays before it
    pauses at EOF ("for gapless"). The pause of the client blocks the
    core until the tail has played (up to its length plus 0.25 s), and
    then pauses at the end: the pause never pauses.
  - Without the drain, eof-reached and pause are yes with the tail still
    queued, which a client cannot tell from the park: it takes the file
    for ended, and a play then starts it again from 0.

Fix
===

  - player/core.h: mak_keep_open_parked, whether keep-open parked the
    current file: at its end with the output played out.
  - player/playloop.c handle_keep_open(): sets it right before the pause
    of the park, so the notification of pause finds it. A client that
    paused in the tail gets it once a resume let the output play out.
  - player/playloop.c set_pause_state(): an unpause clears it, and only
    the pause of the park, or one after the file ended, drains the output
    at EOF; any other pause at EOF pauses at once, the tail kept for the
    resume. After the end (keep-open=no, a pause in an on_unload or
    on_after_end_file hook) no resume can play the tail: the idle core
    closes a paused output without a drain, and the tail would go.
  - player/playloop.c reset_playback_state(): a seek and a new file
    clear it; player/loadfile.c terminate_playback, the end of every file
    (stop, the next file, an error), too, so the idle core after a stop
    at the park reads no park.
  - the read-only flag property keep-open-parked, notified at each change.

Without keep-open-pause no park comes and the flag stays no.

MARKER-guarded: MAK_KEEP_OPEN_PARK_PATCH_V1 in every inserted hunk.

Usage: patch_keep_open_park.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402
import property_seam as seam  # noqa: E402

MARKER = 'MAK_KEEP_OPEN_PARK_PATCH_V1'

CORE_H = [(
    '    bool playback_initialized; // playloop can be run/is running\n',
    '    bool playback_initialized; // playloop can be run/is running\n'
    f'    // {MARKER}: keep-open parked the current file, at its end with\n'
    '    // the output played out (the keep-open-parked property).\n'
    '    bool mak_keep_open_parked;\n',
)]

PLAYLOOP_C = [
    ('playloop.c includes', '#include "video/out/vo.h"\n',
     '#include "video/out/vo.h"\n'
     '\n'
     f'// {MARKER}: sets keep-open-parked and notifies a change. Core\n'
     '// thread.\n'
     'static void mak_set_keep_open_parked(struct MPContext *mpctx, bool parked)\n'
     '{\n'
     '    if (mpctx->mak_keep_open_parked == parked)\n'
     '        return;\n'
     '    mpctx->mak_keep_open_parked = parked;\n'
     '    mp_notify_property(mpctx, "keep-open-parked");\n'
     '}\n'),
    ('set_pause_state unpause', '    opts->pause = user_pause;\n',
     f'    // {MARKER}: a resume leaves the park.\n'
     '    if (!user_pause)\n'
     '        mak_set_keep_open_parked(mpctx, false);\n'
     '    opts->pause = user_pause;\n'),
    ('set_pause_state drain',
     '            bool eof = mpctx->audio_status == STATUS_EOF;\n'
     '            ao_set_paused(mpctx->ao, internal_paused, eof);\n',
     f'            // {MARKER}: only the park, or a pause after the end of\n'
     '            // the file, drains the output at EOF. A pause of the\n'
     '            // client in the tail pauses at once and keeps the tail for\n'
     '            // the resume; after the end the idle core closes a paused\n'
     '            // output with no drain, and the tail would go.\n'
     '            bool eof = mpctx->audio_status == STATUS_EOF &&\n'
     '                       (mpctx->mak_keep_open_parked ||\n'
     '                        mpctx->stop_play == AT_END_OF_FILE);\n'
     '            ao_set_paused(mpctx->ao, internal_paused, eof);\n'),
    ('reset_playback_state',
     '    mpctx->hrseek_active = false;\n'
     '    mpctx->hrseek_lastframe = false;\n',
     f'    // {MARKER}: a seek or a new file leaves the park.\n'
     '    mak_set_keep_open_parked(mpctx, false);\n'
     '    mpctx->hrseek_active = false;\n'
     '    mpctx->hrseek_lastframe = false;\n'),
    ('handle_keep_open park',
     '            set_pause_state(mpctx, true);\n'
     '        }\n'
     '    }\n'
     '}\n'
     '\n'
     'static void handle_chapter_change',
     f'            // {MARKER}: the park, set before the pause so that its\n'
     '            // notification finds it.\n'
     '            mak_set_keep_open_parked(mpctx, true);\n'
     '            set_pause_state(mpctx, true);\n'
     '        }\n'
     '    }\n'
     '}\n'
     '\n'
     'static void handle_chapter_change'),
]

LOADFILE_C = [(
    'terminate_playback',
    '    if (mpctx->stop_play != AT_END_OF_FILE)\n'
    '        clear_audio_output_buffers(mpctx);\n'
    '\n'
    '    update_core_idle_state(mpctx);\n',
    '    if (mpctx->stop_play != AT_END_OF_FILE)\n'
    '        clear_audio_output_buffers(mpctx);\n'
    '\n'
    f'    // {MARKER}: the end of the file leaves the park.\n'
    '    if (mpctx->mak_keep_open_parked) {\n'
    '        mpctx->mak_keep_open_parked = false;\n'
    '        mp_notify_property(mpctx, "keep-open-parked");\n'
    '    }\n'
    '\n'
    '    update_core_idle_state(mpctx);\n',
)]

# The property registration, in player/mak_property_table.inc.
COMMAND_TABLE = (
    f'    /* {MARKER} */\n'
    '    {"keep-open-parked", mp_property_keep_open_parked},\n'
)

# The getter, in player/mak_property_getters.inc.
COMMAND_GETTER = (
    f'/* {MARKER} ─── read-only flag: keep-open parked the current file, at\n'
    ' * its end with the output played out. A pause of the client at the end\n'
    ' * leaves it no. */\n'
    'static int mp_property_keep_open_parked(void *ctx, struct m_property *prop,\n'
    '                                        int action, void *arg)\n'
    '{\n'
    '    MPContext *mpctx = ctx;\n'
    '    return m_property_bool_ro(action, arg, mpctx->mak_keep_open_parked);\n'
    '}\n'
    '\n'
)


def apply(p):
    p.edits('player/core.h', [('playback_initialized field',) + CORE_H[0]])
    p.edits('player/playloop.c', PLAYLOOP_C)
    p.edits('player/loadfile.c', LOADFILE_C)
    seam.table(p, COMMAND_TABLE)
    seam.getters(p, COMMAND_GETTER)


anchor.main(apply, 'patch_keep_open_park', marker=MARKER,
            usage='<mpv source dir>')
