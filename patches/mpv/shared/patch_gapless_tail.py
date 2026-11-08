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
run dry only once the queue is empty: the underrun does not hit them.
Upstream mpv master (2026-10-29) has the same code.

A pull output parks early instead. ao_read_data() clears p->playing in
the callback that reads the last sample, while the device still holds
what it just read: end_time_ns, the time the callback gave for its last
sample, is ahead (two periods on SDL, the device latency on PipeWire and
AudioUnit). handle_keep_open() parks at once: time-pos stops short of the
end by that much and keeps creeping while paused (ao_get_delay() counts
end_time_ns down), and the pause resets the device with the tail in it.
The checks of the park were also separate locked reads (playing, then the
queue), which an output thread can change between.

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
  - audio/out/buffer.c: ao_played_out(), the park signal in one locked
    read: not playing, nothing queued, and for a pull output not paused
    the device past end_time_ns. Otherwise it gives the time still to wait.
  - player/playloop.c handle_keep_open(): no park before ao_played_out().
    fill_audio_out_buffers() runs first in the pass, but the output thread
    can stop between the two: then the next pass restarts it, and the park
    comes when the output really played out. A pull output that read its
    last sample sets a timeout for the end of its device, which nothing
    else would wake the core for.
  - player/audio.c uninit_audio_out(): an output that stopped with audio
    queued is started again before the drain, so the end of a playlist
    without keep-open plays the tail too. Of a push output only: the
    drain of a pull output ends once its callback read the last sample,
    and its device loses what it still held (keep-open, as the package
    sets it, waits for it).

A pull output paused in that final latency lost it too. buffer.c resumed
a pull output only while it was playing, which it no longer is once its
callback read the last sample: set_pause() never started the device
again, the rest stayed in it, and end_time_ns, left in the past, made it
played out at once. While paused, ao_get_delay() counted end_time_ns
down, and time-pos crept to the end. PipeWire, WASAPI and AAudio pause
in hardware; an output without set_pause() resets its device on a pause,
and what it held goes (upstream as well).

  - audio/out/buffer.c ao_get_delay(): a pull output paused in hardware
    returns the delay saved at the pause (queued_time_ns), and the pause
    and the resume set it under the buffer lock, with hw_paused, so a
    read in between never sees the old one. Until libmpv-r23 this was
    fix 4 of patch_audiotrack.py, on Android only: there an AudioTrack
    buffer, about 140 ms, on PipeWire a quantum.
  - audio/out/buffer.c ao_set_paused(): the resume starts a pull output
    paused in hardware also when its callback read the last sample, and
    end_time_ns waits again for the rest.

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
    'bool ao_has_queued_audio(struct ao *ao);\n'
    f'// {MARKER}: the output played all it was given.\n'
    'bool ao_played_out(struct ao *ao, double *wait);\n',
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
    '}\n'
    '\n'
    f'// {MARKER}: whether the output played all it was given, in one\n'
    '// locked read: not playing, nothing queued, and for a pull output that\n'
    '// is not paused the device past the last sample its callback read.\n'
    '// Paused, whether nothing is left for the resume: nothing queued, and\n'
    '// the device holds nothing, by what its hardware pause kept (the delay\n'
    '// of a push output at the pause, the rest of a pull output). Only while\n'
    '// hw_paused: ao_reset() and the resume clear it, and prepause_state of\n'
    '// an earlier pause outlives them. p->playing says nothing then:\n'
    '// ao_start() after a seek in pause sets it, and the output thread that\n'
    '// would clear it waits for the resume.\n'
    '// Otherwise *wait (if set) is the time still to wait for that, 0 if\n'
    '// the output still plays, waits for data or is paused.\n'
    'bool ao_played_out(struct ao *ao, double *wait)\n'
    '{\n'
    '    struct buffer_state *p = ao->buffer_state;\n'
    '    double left = 0;\n'
    '\n'
    '    mp_mutex_lock(&p->lock);\n'
    '    bool queued = mp_async_queue_get_samples(p->queue) > 0 ||\n'
    '                  (!ao->driver->write_frames && p->pending &&\n'
    '                   mp_aframe_get_size(p->pending) > 0);\n'
    '    bool done;\n'
    '    if (p->paused) {\n'
    '        double held = 0;\n'
    '        if (p->hw_paused)\n'
    '            held = ao->driver->write ? p->prepause_state.delay\n'
    '                                     : MP_TIME_NS_TO_S(p->queued_time_ns);\n'
    '        done = !queued && held <= 0;\n'
    '    } else {\n'
    '        done = !p->playing && !queued;\n'
    '        if (done && !ao->driver->write) {\n'
    '            int64_t now = mp_time_ns();\n'
    '            if (p->end_time_ns > now) {\n'
    '                left = MP_TIME_NS_TO_S(p->end_time_ns - now);\n'
    '                done = false;\n'
    '            }\n'
    '        }\n'
    '    }\n'
    '    mp_mutex_unlock(&p->lock);\n'
    '\n'
    '    if (wait)\n'
    '        *wait = left;\n'
    '    return done;\n'
    '}\n',
), (
    '    } else {\n'
    '        int64_t end = p->end_time_ns;\n',
    f'    }} else if (p->hw_paused) {{\n'
    f'        // {MARKER}: paused in hardware, the device plays\n'
    '        // nothing: the delay is the one saved at the pause, not one\n'
    '        // that runs down on the clock.\n'
    '        driver_delay = MPMAX(0, MP_TIME_NS_TO_S(p->queued_time_ns));\n'
    '    } else {\n'
    '        int64_t end = p->end_time_ns;\n',
), (
    '                is_hw_paused = p->hw_paused = !!ao->driver->set_pause;\n',
    '                is_hw_paused = p->hw_paused = !!ao->driver->set_pause;\n'
    f'                // {MARKER}: saved with hw_paused, under the lock\n'
    '                // ao_get_delay takes.\n'
    '                if (is_hw_paused)\n'
    '                    p->queued_time_ns = p->end_time_ns - mp_time_ns();\n',
), (
    '    } else if (p->playing && p->paused && !paused) {\n',
    f'    // {MARKER}: a pull output paused in hardware after its callback\n'
    '    // read the last sample still holds the rest in its device.\n'
    '    } else if ((p->playing || (!ao->driver->write && p->hw_paused)) &&\n'
    '               p->paused && !paused) {\n',
), (
    '            is_hw_paused = p->hw_paused;\n'
    '            p->hw_paused = false;\n',
    '            is_hw_paused = p->hw_paused;\n'
    '            p->hw_paused = false;\n'
    f'            // {MARKER}\n'
    '            if (is_hw_paused)\n'
    '                p->end_time_ns = p->queued_time_ns + mp_time_ns();\n',
), (
    '                ao->driver->set_pause(ao, true);\n'
    '                p->queued_time_ns = p->end_time_ns - mp_time_ns();\n'
    '            } else {\n'
    '                p->end_time_ns = p->queued_time_ns + mp_time_ns();\n'
    '                ao->driver->set_pause(ao, false);\n',
    f'                ao->driver->set_pause(ao, true); /* {MARKER} */\n'
    '            } else {\n'
    '                ao->driver->set_pause(ao, false);\n',
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
    f'            // {MARKER}: nor before the output played out: audio\n'
    '            // still queued (it stopped on an underrun; the next pass\n'
    '            // starts it again), or a pull device still playing the\n'
    '            // last samples its callback read (woken at their end).\n'
    '            double wait = 0;\n'
    '            if (mpctx->ao && (mpctx->ao_chain\n'
    '                    ? !ao_played_out(mpctx->ao, &wait)\n'
    '                    : ao_is_playing(mpctx->ao)))\n'
    '            {\n'
    '                if (wait > 0)\n'
    '                    mp_set_timeout(mpctx, wait);\n'
    '                return;\n'
    '            }\n',
)]


def apply(p):
    p.edits('audio/out/ao.h', AO_H)
    p.edits('audio/out/buffer.c', BUFFER_C)
    p.edits('player/audio.c', AUDIO_C)
    p.edits('player/playloop.c', PLAYLOOP_C)


anchor.main(apply, 'patch_gapless_tail', marker=MARKER)
