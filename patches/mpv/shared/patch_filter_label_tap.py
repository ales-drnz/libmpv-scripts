#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Adds per-filter pre / post audio tap to libmpv's user-filter
processing path, with playback-PTS-aligned reads so the visualiser
sees a smooth signal even though the filter chain processes ahead
of the audio output in bursts.

Problem
=======

The existing `pcm-tap-frame` property exposes the audio that already
flowed through the entire `--af` chain plus the per-AO software
volume — useful for a global spectrum visualiser but useless for a
"FabFilter Pro-Q" style overlay where each plug-in editor wants to
see the signal *immediately before* and *immediately after* its own
filter, separately from every other filter in the chain.

Approach
========

mpv wraps every user-added filter in a generic
`user_wrapper_process` (`filters/f_output_chain.c`) that:

    1. reads a frame from the wrapper's input pin,
    2. forwards it to the inner libavfilter,
    3. reads the processed frame from the inner filter's output,
    4. forwards it to the wrapper's output pin.

This patch keeps that flow intact and adds two surgical hooks: right
before step 2 we APPEND the frame to a per-filter PRE ring; right
before step 4 we APPEND it to a per-filter POST ring. The hooks are
guarded by a tiny "is this filter currently being tapped?" check, so
the cost on a normal playback session (no taps active) is one strcmp
per frame per filter.

Each ring is a rolling buffer (~340 ms at 48 kHz / 2 ch float, 128 KB)
that stores the playback PTS of the most-recently-written sample. On
read, the property getter passes mpv's current `playback_pts` and the
reader returns the slice of samples whose timestamps span that PTS —
so even though the chain runs ahead of the AO and writes in bursts,
the visualiser sees a window of audio aligned with what the AO is
playing right now, advancing smoothly at the audio output rate.

Active-tap selection
====================

A new read-write property `analyzer-taps` carries a comma-separated
list of filter names to tap. Setting it from the wrapper enables the
hooks for the named filters; the empty string disables every tap.
The tap snapshots themselves are read via the new `audio-tap-frames`
property — a `MPV_FORMAT_NODE_MAP` keyed by filter name, each entry
holding `{pre, post}` sub-maps with the same shape as
`pcm-tap-frame` (sample_rate, channels, pts_ns, samples). Empty
sub-maps when no frame has flowed through that side yet.

Format coverage
===============

The hook converts every PCM format mpv's filter chain emits — packed
or planar (`U8 / S16 / S32 / S64 / FLOAT / DOUBLE`, both `*` and
`*P`) — to interleaved Float32 inline, identical to the conversion
used by `mak_pcm_tap`. Encoded passthrough formats (AC3, DTS, …) are
gated by `af_fmt_is_pcm()` and skipped silently.

Files patched
=============

    audio/mak_tap.h                NEW — public API
    audio/mak_tap.c                NEW — singleton ring buffers + reader
    filters/f_output_chain.c       hook inserted in `user_wrapper_process`
    player/command.c               property registration + getters / setter
    meson.build                    new source registered

Composes with `patch_pcm_tap.py`, `patch_bulk_analysis.py`, and the
other shared patches — disjoint anchors.
"""
import os
import sys

SRC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'filter_label_tap')


def read_src(name):
    with open(os.path.join(SRC_DIR, name)) as f:
        return f.read()


MARKER = 'MAK_TAP_PATCH_V3'

# Wire-protocol limits. Keep in sync with the Dart parser.
MAX_TAPS = 8         # max distinct filter names that can be active
MAX_SAMPLES = 4096   # samples per channel returned by a single read


# ─── audio/mak_tap.h ──────────────────────────────────────────────────

# The real C source lives in filter_label_tap/mak_tap.h next to this
# script — edit it THERE; this patch only copies it into the tree.
TAP_H = read_src('mak_tap.h')


# ─── audio/mak_tap.c ──────────────────────────────────────────────────

# The real C source lives in filter_label_tap/mak_tap.c next to this
# script — edit it THERE; this patch only copies it into the tree.
TAP_C = read_src('mak_tap.c')


# ─── filters/f_output_chain.c ─────────────────────────────────────────

OUTPUT_CHAIN_INCLUDE_PRISTINE = '#include "user_filters.h"'

OUTPUT_CHAIN_INCLUDE_PATCHED = (
    '#include "user_filters.h"\n'
    '/* ' + MARKER + ' */\n'
    '#include "audio/mak_tap.h"'
)

# Anchor on the exact pristine bodies of the two `if (mp_pin_can_transfer_data(...))`
# blocks inside `user_wrapper_process`. We insert one mak_tap_write before
# the frame leaves for the inner filter (PRE) and one before it leaves the
# wrapper (POST). The hook is guarded internally by `mak_tap_label_active`,
# so the cost when no tap is active is one strcmp per frame per filter.

USER_WRAPPER_PRE_PRISTINE = (
    '    if (mp_pin_can_transfer_data(u->f->pins[0], f->ppins[0])) {\n'
    '        struct mp_frame frame = mp_pin_out_read(f->ppins[0]);\n'
    '\n'
    '        check_in_format_change(u, frame);\n'
    '\n'
    '        double pts = mp_frame_get_pts(frame);\n'
    '        if (pts != MP_NOPTS_VALUE)\n'
    '            u->last_in_pts = pts;\n'
    '\n'
    '        mp_pin_in_write(u->f->pins[0], frame);\n'
    '    }'
)

USER_WRAPPER_PRE_PATCHED = (
    '    if (mp_pin_can_transfer_data(u->f->pins[0], f->ppins[0])) {\n'
    '        struct mp_frame frame = mp_pin_out_read(f->ppins[0]);\n'
    '\n'
    '        check_in_format_change(u, frame);\n'
    '\n'
    '        double pts = mp_frame_get_pts(frame);\n'
    '        if (pts != MP_NOPTS_VALUE)\n'
    '            u->last_in_pts = pts;\n'
    '\n'
    '        /* ' + MARKER + ' */\n'
    '        if (frame.type == MP_FRAME_AUDIO && u->name &&\n'
    '            mak_tap_label_active(u->name))\n'
    '            mak_tap_write(u->name, false, frame.data);\n'
    '\n'
    '        /* ' + MARKER + ' ─── pre-DSP fold for the progressive waveform\n'
    '         * (self-gates to the "in" filter + active progressive). */\n'
    '        if (frame.type == MP_FRAME_AUDIO && u->name)\n'
    '            mak_waveform_tap_in(u->name, frame.data);\n'
    '\n'
    '        mp_pin_in_write(u->f->pins[0], frame);\n'
    '    }'
)

USER_WRAPPER_POST_PRISTINE = (
    '    if (mp_pin_can_transfer_data(f->ppins[1], u->f->pins[1])) {\n'
    '        struct mp_frame frame = mp_pin_out_read(u->f->pins[1]);\n'
    '\n'
    '        double pts = mp_frame_get_pts(frame);\n'
    '        if (pts != MP_NOPTS_VALUE)\n'
    '            u->last_out_pts = pts;\n'
    '\n'
    '        mp_pin_in_write(f->ppins[1], frame);'
)

USER_WRAPPER_POST_PATCHED = (
    '    if (mp_pin_can_transfer_data(f->ppins[1], u->f->pins[1])) {\n'
    '        struct mp_frame frame = mp_pin_out_read(u->f->pins[1]);\n'
    '\n'
    '        double pts = mp_frame_get_pts(frame);\n'
    '        if (pts != MP_NOPTS_VALUE)\n'
    '            u->last_out_pts = pts;\n'
    '\n'
    '        /* ' + MARKER + ' */\n'
    '        if (frame.type == MP_FRAME_AUDIO && u->name &&\n'
    '            mak_tap_label_active(u->name))\n'
    '            mak_tap_write(u->name, true, frame.data);\n'
    '\n'
    '        mp_pin_in_write(f->ppins[1], frame);'
)


def patch_output_chain(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if OUTPUT_CHAIN_INCLUDE_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (user_filters.h include) not found in {path}.'
        )
    if USER_WRAPPER_PRE_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (user_wrapper_process PRE block) not found '
            f'in {path}.'
        )
    if USER_WRAPPER_POST_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (user_wrapper_process POST block) not '
            f'found in {path}.'
        )
    text = text.replace(OUTPUT_CHAIN_INCLUDE_PRISTINE,
                        OUTPUT_CHAIN_INCLUDE_PATCHED, 1)
    text = text.replace(USER_WRAPPER_PRE_PRISTINE,
                        USER_WRAPPER_PRE_PATCHED, 1)
    text = text.replace(USER_WRAPPER_POST_PRISTINE,
                        USER_WRAPPER_POST_PATCHED, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── player/command.c ─────────────────────────────────────────────────

# Anchor on the same `audio-bitrate` table entry the other shared
# patches use. Append two new property entries — disjoint with both
# patch_pcm_tap.py and patch_bulk_analysis.py.
COMMAND_TABLE_PRISTINE = (
    '    {"audio-bitrate", mp_property_packet_bitrate, '
    '.priv = (void *)&(const int){STREAM_AUDIO}},'
)

COMMAND_TABLE_PATCHED = (
    '    {"audio-bitrate", mp_property_packet_bitrate, '
    '.priv = (void *)&(const int){STREAM_AUDIO}},\n'
    '    /* ' + MARKER + ' */\n'
    '    {"analyzer-taps", mp_property_analyzer_taps},\n'
    '    {"audio-tap-frames", mp_property_audio_tap_frames},'
)

COMMAND_GETTER_ANCHOR = (
    'static int mp_property_audio_params(void *ctx, struct m_property *prop,'
)

COMMAND_GETTER_INSERT = (
    '/* ' + MARKER + ' ─── read-write property: comma-separated list\n'
    ' * of user-filter names whose pre / post audio frames should be\n'
    ' * captured into the audio-tap-frames map. Setting it to "" or\n'
    ' * NULL clears every tap. The wrapper sets this on pro-window\n'
    ' * open / close and polls audio-tap-frames at its own rate. */\n'
    'static int mp_property_analyzer_taps(void *ctx, struct m_property *prop,\n'
    '                                     int action, void *arg)\n'
    '{\n'
    '    switch (action) {\n'
    '        case M_PROPERTY_GET_TYPE:\n'
    '            *(struct m_option *)arg =\n'
    '                (struct m_option){.type = CONF_TYPE_STRING};\n'
    '            return M_PROPERTY_OK;\n'
    '        case M_PROPERTY_GET: {\n'
    '            char *s = mak_tap_get_active(NULL);\n'
    '            *(char **)arg = s;\n'
    '            return M_PROPERTY_OK;\n'
    '        }\n'
    '        case M_PROPERTY_SET: {\n'
    '            const char *s = *(char **)arg;\n'
    '            mak_tap_set_active(s);\n'
    '            return M_PROPERTY_OK;\n'
    '        }\n'
    '    }\n'
    '    return M_PROPERTY_NOT_IMPLEMENTED;\n'
    '}\n'
    '\n'
    '/* ' + MARKER + ' ─── read-only NODE_MAP keyed by filter name,\n'
    ' * each entry mapping to { pre, post } sub-maps with sample data\n'
    ' * (sample_rate, channels, pts_ns, samples). Empty MAP when no\n'
    ' * tap is active.\n'
    ' *\n'
    ' * The reader passes the player\'s current audio playback PTS so\n'
    ' * mak_tap_read_all can return the slice of the rolling ring\n'
    ' * that the AO is playing right now — even though the filter\n'
    ' * chain processes ahead of the AO and writes in bursts, the\n'
    ' * window the wrapper sees evolves at the steady AO consumption\n'
    ' * rate. NaN target means "give me the latest available". */\n'
    'static int mp_property_audio_tap_frames(void *ctx, struct m_property *prop,\n'
    '                                        int action, void *arg)\n'
    '{\n'
    '    MPContext *mpctx = ctx;\n'
    '    switch (action) {\n'
    '        case M_PROPERTY_GET_TYPE:\n'
    '            *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_NODE};\n'
    '            return M_PROPERTY_OK;\n'
    '        case M_PROPERTY_GET:\n'
    '        case M_PROPERTY_GET_NODE: {\n'
    '            double target = NAN;\n'
    '            if (mpctx->playback_initialized &&\n'
    '                mpctx->audio_status >= STATUS_PLAYING &&\n'
    '                mpctx->audio_status < STATUS_EOF)\n'
    '            {\n'
    '                double pts = playing_audio_pts(mpctx);\n'
    '                if (pts != MP_NOPTS_VALUE) target = pts;\n'
    '            }\n'
    '            struct mpv_node n = {0};\n'
    '            if (mak_tap_read_all(&n, arg, target) < 0)\n'
    '                return M_PROPERTY_UNAVAILABLE;\n'
    '            *(struct mpv_node *)arg = n;\n'
    '            return M_PROPERTY_OK;\n'
    '        }\n'
    '    }\n'
    '    return M_PROPERTY_NOT_IMPLEMENTED;\n'
    '}\n'
    '\n'
    + COMMAND_GETTER_ANCHOR
)

COMMAND_INCLUDE_PRISTINE = '#include "command.h"'

COMMAND_INCLUDE_PATCHED = (
    '#include "command.h"\n'
    '/* ' + MARKER + ' */\n'
    '#include "audio/mak_tap.h"'
)


def patch_command_c(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if COMMAND_INCLUDE_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (command.c includes) not found in {path}.'
        )
    if COMMAND_TABLE_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (audio-bitrate property entry) not found '
            f'in {path}.'
        )
    if COMMAND_GETTER_ANCHOR not in text:
        raise RuntimeError(
            f'Pristine anchor (mp_property_audio_params getter) not '
            f'found in {path}.'
        )
    text = text.replace(COMMAND_INCLUDE_PRISTINE, COMMAND_INCLUDE_PATCHED, 1)
    text = text.replace(COMMAND_TABLE_PRISTINE, COMMAND_TABLE_PATCHED, 1)
    text = text.replace(COMMAND_GETTER_ANCHOR, COMMAND_GETTER_INSERT, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── meson.build ──────────────────────────────────────────────────────

# Compose with patch_pcm_tap.py and patch_bulk_analysis.py — each adds
# its own audio/* source. We anchor on `audio/out/ao.c` with optional
# preceding patches.
MESON_AFTER_BULK = (
    "    'audio/out/ao.c',\n"
    "    # MAK_PCM_TAP_PATCH_V1\n"
    "    'audio/out/mak_pcm_tap.c',\n"
    "    # MAK_WAVEFORM_PATCH_V1\n"
    "    'audio/mak_waveform.c',"
)

MESON_AFTER_BULK_PATCHED = (
    "    'audio/out/ao.c',\n"
    "    # MAK_PCM_TAP_PATCH_V1\n"
    "    'audio/out/mak_pcm_tap.c',\n"
    "    # MAK_WAVEFORM_PATCH_V1\n"
    "    'audio/mak_waveform.c',\n"
    "    # " + MARKER + "\n"
    "    'audio/mak_tap.c',"
)

MESON_AFTER_PCM_TAP = (
    "    'audio/out/ao.c',\n"
    "    # MAK_PCM_TAP_PATCH_V1\n"
    "    'audio/out/mak_pcm_tap.c',"
)

MESON_AFTER_PCM_TAP_PATCHED = (
    "    'audio/out/ao.c',\n"
    "    # MAK_PCM_TAP_PATCH_V1\n"
    "    'audio/out/mak_pcm_tap.c',\n"
    "    # " + MARKER + "\n"
    "    'audio/mak_tap.c',"
)

MESON_AFTER_BULK_ONLY = (
    "    'audio/out/ao.c',\n"
    "    # MAK_WAVEFORM_PATCH_V1\n"
    "    'audio/mak_waveform.c',"
)

MESON_AFTER_BULK_ONLY_PATCHED = (
    "    'audio/out/ao.c',\n"
    "    # MAK_WAVEFORM_PATCH_V1\n"
    "    'audio/mak_waveform.c',\n"
    "    # " + MARKER + "\n"
    "    'audio/mak_tap.c',"
)

MESON_PRISTINE = "    'audio/out/ao.c',"

MESON_PATCHED = (
    "    'audio/out/ao.c',\n"
    "    # " + MARKER + "\n"
    "    'audio/mak_tap.c',"
)


def patch_meson(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    # Try the most-specific anchors first (both prior patches present).
    if MESON_AFTER_BULK in text:
        text = text.replace(MESON_AFTER_BULK, MESON_AFTER_BULK_PATCHED, 1)
    elif MESON_AFTER_PCM_TAP in text:
        text = text.replace(MESON_AFTER_PCM_TAP,
                            MESON_AFTER_PCM_TAP_PATCHED, 1)
    elif MESON_AFTER_BULK_ONLY in text:
        text = text.replace(MESON_AFTER_BULK_ONLY,
                            MESON_AFTER_BULK_ONLY_PATCHED, 1)
    elif MESON_PRISTINE in text:
        text = text.replace(MESON_PRISTINE, MESON_PATCHED, 1)
    else:
        raise RuntimeError(
            f'Pristine anchor (audio/out/ao.c entry) not found in {path}.'
        )
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── new files ────────────────────────────────────────────────────────

def write_new_file(path, content):
    if os.path.exists(path):
        with open(path) as f:
            existing = f.read()
        if MARKER in existing:
            print(f'Already present: {path}')
            return
        raise RuntimeError(
            f'Refusing to overwrite an unrecognised file at {path}'
        )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(content)
    print(f'Created:  {path}')


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <mpv_src_dir>')
        sys.exit(1)
    src = sys.argv[1]
    write_new_file(os.path.join(src, 'audio', 'mak_tap.h'), TAP_H)
    write_new_file(os.path.join(src, 'audio', 'mak_tap.c'), TAP_C)
    patch_output_chain(os.path.join(src, 'filters', 'f_output_chain.c'))
    patch_command_c(os.path.join(src, 'player', 'command.c'))
    patch_meson(os.path.join(src, 'meson.build'))


if __name__ == '__main__':
    main()
