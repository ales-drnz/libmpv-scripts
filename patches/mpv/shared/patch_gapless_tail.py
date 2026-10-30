# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Play the tail of a file that an output underrun left in the queue.

Problem
=======

With gapless audio (the default, weak) fill_audio_out_buffers() turns
STATUS_DRAINING into STATUS_EOF as soon as the decoder is done, while the
output queue (audio-buffer) and the device still hold the tail, up to
about 0.4 s. From then on mpv waits only for ao_is_playing() to go false:

  - a push output (ao_null, ALSA, PulseAudio, OSS, the web module's
    webaudio) whose device ran dry while buffer.c's thread was late takes
    the empty device for the end: ao_play_data() clears p->playing with
    the rest still queued, and p->pending may hold part of a frame;
  - the underrun recovery of fill_audio_out_buffers() runs only in
    STATUS_PLAYING and STATUS_DRAINING, so nothing starts the output again;
  - handle_keep_open() takes !ao_is_playing() for "played out" and pauses:
    eof-reached and pause are yes, time-pos stays at the end minus what is
    still queued (ao_get_delay() counts it), and the tail never plays.
    Without keep-open, uninit_audio_out() drains only an output that
    plays, and the tail goes with ao_uninit().

A busy machine (a CI runner) is enough: a stall of 150 ms or more of the
output thread in the last 0.4 s of the last entry. gapless-audio=no does
not show it: there the status stays DRAINING until the output stopped,
and the recovery restarts it. Pull outputs (CoreAudio, AudioUnit, AAudio,
WASAPI, PipeWire, AudioTrack) read the queue in their callback, which can
run dry only once the queue is empty: they are not affected. Upstream mpv
master (2026-10-29) has the same code.

Fix
===

  - audio/out/buffer.c: ao_has_queued_audio(), whether samples still wait
    for the device: in the queue, or the rest of a frame in p->pending
    (not for write_frames drivers, where p->pending is the frame written).
  - player/audio.c fill_audio_out_buffers(): the underrun recovery also
    runs in STATUS_EOF after the output EOF while audio is still queued
    (the existing path: warn, then ao_start() since out_eof is set), and
    "AO signaled EOF" requires that nothing is queued, so it no longer
    resets away a rest held in p->pending.
  - player/playloop.c handle_keep_open(): no park while audio is queued.
    fill_audio_out_buffers() runs first in the pass, but the output thread
    can stop between the two: then the next pass restarts it, and the park
    comes when the output really played out.
  - player/audio.c uninit_audio_out(): an output that stopped with audio
    queued is started again before the drain, so the end of a playlist
    without keep-open plays the tail too.

No new state: one locked read of the queue per pass while the output
stands still at the end of a file.

MARKER-guarded: MAK_GAPLESS_TAIL_PATCH_V1 in every inserted hunk.

Usage: patch_gapless_tail.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = 'MAK_GAPLESS_TAIL_PATCH_V1'

AO_H = [(
    'bool ao_is_playing(struct ao *ao);\n',
    'bool ao_is_playing(struct ao *ao);\n'
    f'// {MARKER}: samples still wait for the device.\n'
    'bool ao_has_queued_audio(struct ao *ao);\n',
)]

BUFFER_C = [(
    '    mp_mutex_lock(&p->lock);\n'
    '    bool playing = p->playing;\n'
    '    mp_mutex_unlock(&p->lock);\n'
    '\n'
    '    return playing;\n'
    '}\n',
    '    mp_mutex_lock(&p->lock);\n'
    '    bool playing = p->playing;\n'
    '    mp_mutex_unlock(&p->lock);\n'
    '\n'
    '    return playing;\n'
    '}\n'
    '\n'
    f'// {MARKER}: whether samples still wait for the device, in the queue\n'
    '// or as the rest of a frame read from it. An output that is not playing\n'
    '// with such samples stopped on an underrun, not at the end.\n'
    'bool ao_has_queued_audio(struct ao *ao)\n'
    '{\n'
    '    struct buffer_state *p = ao->buffer_state;\n'
    '\n'
    '    mp_mutex_lock(&p->lock);\n'
    '    bool queued = mp_async_queue_get_samples(p->queue) > 0 ||\n'
    '                  (!ao->driver->write_frames && p->pending &&\n'
    '                   mp_aframe_get_size(p->pending) > 0);\n'
    '    mp_mutex_unlock(&p->lock);\n'
    '\n'
    '    return queued;\n'
    '}\n',
)]

AUDIO_C = [
    (
        '    if (ao_c->ao && !ao_is_playing(ao_c->ao) && !ao_c->underrun &&\n'
        '        (mpctx->audio_status == STATUS_PLAYING ||\n'
        '         mpctx->audio_status == STATUS_DRAINING))\n'
        '    {\n'
        '        // Should be playing, but somehow isn\'t.\n'
        '\n'
        '        if (ao_c->out_eof && !mp_async_queue_get_frames(ao_c->ao_queue)) {\n',
        f'    // {MARKER}: with gapless audio the status is EOF once the\n'
        '    // decoder is done, while the output still holds the tail. An\n'
        '    // output that stopped with audio queued ran dry: play the rest.\n'
        '    if (ao_c->ao && !ao_is_playing(ao_c->ao) && !ao_c->underrun &&\n'
        '        (mpctx->audio_status == STATUS_PLAYING ||\n'
        '         mpctx->audio_status == STATUS_DRAINING ||\n'
        '         (mpctx->audio_status == STATUS_EOF && ao_c->out_eof &&\n'
        '          ao_has_queued_audio(ao_c->ao))))\n'
        '    {\n'
        '        // Should be playing, but somehow isn\'t.\n'
        '\n'
        '        if (ao_c->out_eof && !mp_async_queue_get_frames(ao_c->ao_queue) &&\n'
        f'            !ao_has_queued_audio(ao_c->ao)) /* {MARKER} */\n'
        '        {\n',
    ),
    (
        '        if ((mpctx->opts->gapless_audio || mpctx->stop_play == AT_END_OF_FILE) &&\n'
        '            ao_is_playing(mpctx->ao) && !get_internal_paused(mpctx))\n'
        '        {\n',
        '        if ((mpctx->opts->gapless_audio || mpctx->stop_play == AT_END_OF_FILE) &&\n'
        f'            !get_internal_paused(mpctx) && /* {MARKER} */\n'
        '            !ao_is_playing(mpctx->ao) && ao_has_queued_audio(mpctx->ao))\n'
        '        {\n'
        '            MP_VERBOSE(mpctx, "restarting audio to play its tail\\n");\n'
        '            ao_start(mpctx->ao);\n'
        '        }\n'
        '        if ((mpctx->opts->gapless_audio || mpctx->stop_play == AT_END_OF_FILE) &&\n'
        '            ao_is_playing(mpctx->ao) && !get_internal_paused(mpctx))\n'
        '        {\n',
    ),
]

PLAYLOOP_C = [(
    '        if (opts->keep_open_pause) {\n'
    '            if (mpctx->ao && ao_is_playing(mpctx->ao))\n'
    '                return;\n',
    '        if (opts->keep_open_pause) {\n'
    f'            // {MARKER}: nor while audio is queued (the output\n'
    '            // stopped on an underrun; the next pass starts it again).\n'
    '            if (mpctx->ao && (ao_is_playing(mpctx->ao) ||\n'
    '                (mpctx->ao_chain && ao_has_queued_audio(mpctx->ao))))\n'
    '                return;\n',
)]


def apply(p):
    p.edits('audio/out/ao.h', AO_H)
    p.edits('audio/out/buffer.c', BUFFER_C)
    p.edits('player/audio.c', AUDIO_C)
    p.edits('player/playloop.c', PLAYLOOP_C)


anchor.main(apply, 'patch_gapless_tail', marker=MARKER)
