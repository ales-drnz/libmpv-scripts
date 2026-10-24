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

Each ring is a rolling buffer (3 s of Float32 at the stream's format,
at most 16 MB) that stores the playback PTS of the most-recently-written
sample. On read, the property getter passes mpv's current `playback_pts`
and the reader returns the slice of samples whose timestamps span that
PTS. So even though the chain runs ahead of the AO and writes in
bursts, the visualiser sees a window of audio aligned with what the AO
is playing right now, advancing smoothly at the audio output rate.

Active-tap selection
====================

A new read-write property `analyzer-taps` carries a comma-separated
list of chain labels to tap (`@label:` in the `af` string; mpv_audio_kit
labels every typed stage `aek_<filter>_<n>`). Taps key on the label, not
the filter type, so two instances of one filter in the chain have two
separate rings. Setting it from the wrapper enables the hooks for the
named stages; the empty string disables every tap. The tap snapshots
themselves are read via the new `audio-tap-frames` property — a
`MPV_FORMAT_NODE_MAP` keyed by label, each entry
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
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

# V4 keys the taps on chain labels (V3 keyed them on filter names). A tree
# patched by an older version fails in check_stale_marker instead of being
# skipped as already patched.
MARKER = 'MAK_TAP_PATCH_V4'
MARKER_RE = re.compile(r'MAK_TAP_PATCH_V\d+')

# Wire-protocol limits. Keep in sync with the Dart parser.
MAX_TAPS = 8         # max distinct chain labels tapped at once; labels of
                     # 64 chars or more are ignored (mak_tap.c slot name)
MAX_SAMPLES = 4096   # samples per channel returned by a single read


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
    '        if (frame.type == MP_FRAME_AUDIO && u->label &&\n'
    '            mak_tap_label_active(u->label))\n'
    '            mak_tap_write(u->label, false, frame.data);\n'
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
    '        if (frame.type == MP_FRAME_AUDIO && u->label &&\n'
    '            mak_tap_label_active(u->label))\n'
    '            mak_tap_write(u->label, true, frame.data);\n'
    '\n'
    '        mp_pin_in_write(f->ppins[1], frame);'
)


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
    ' * of chain labels whose pre / post audio frames should be\n'
    ' * captured into the audio-tap-frames map (at most MAK_TAP_MAX,\n'
    ' * each under 64 chars). Setting it to "" or NULL clears every\n'
    ' * tap. The wrapper sets this on pro-window open / close and\n'
    ' * polls audio-tap-frames at its own rate. */\n'
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
    '/* ' + MARKER + ' ─── read-only NODE_MAP keyed by chain label,\n'
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



def check_stale_marker(p, rels):
    """A file patched by an older version of this patch stops it: delete the
    extracted mpv source so it is extracted and patched again."""
    for rel in rels:
        if not p.exists(rel):
            continue
        stale = set(MARKER_RE.findall(p.text(rel))) - {MARKER}
        if stale:
            p.fail(f'{rel} carries {", ".join(sorted(stale))}, an older version '
                   f'of this patch. Delete the extracted mpv source so it is '
                   f'extracted and patched again.')


def apply(p):
    check_stale_marker(p, ['audio/mak_tap.h', 'audio/mak_tap.c',
                           'filters/f_output_chain.c', 'player/command.c',
                           'meson.build'])
    # The real C sources live in filter_label_tap/ next to this script —
    # edit them THERE; this patch only copies them into the tree.
    for name in ('mak_tap.h', 'mak_tap.c'):
        p.new_file('audio/' + name, p.asset('filter_label_tap/' + name))
    p.edits('filters/f_output_chain.c', [
        ('user_filters.h include', OUTPUT_CHAIN_INCLUDE_PRISTINE,
         OUTPUT_CHAIN_INCLUDE_PATCHED),
        ('user_wrapper_process PRE block', USER_WRAPPER_PRE_PRISTINE,
         USER_WRAPPER_PRE_PATCHED),
        ('user_wrapper_process POST block', USER_WRAPPER_POST_PRISTINE,
         USER_WRAPPER_POST_PATCHED),
    ])
    p.edits('player/command.c', [
        ('command.c includes', COMMAND_INCLUDE_PRISTINE, COMMAND_INCLUDE_PATCHED),
        ('audio-bitrate property entry', COMMAND_TABLE_PRISTINE,
         COMMAND_TABLE_PATCHED),
        ('mp_property_audio_params getter', COMMAND_GETTER_ANCHOR,
         COMMAND_GETTER_INSERT),
    ])
    if p.marked('meson.build'):
        print('Already patched: meson.build')
    else:
        # The most-specific form first (both prior patches present).
        p.optional('meson.build', [
            (MESON_AFTER_BULK, MESON_AFTER_BULK_PATCHED),
            (MESON_AFTER_PCM_TAP, MESON_AFTER_PCM_TAP_PATCHED),
            (MESON_AFTER_BULK_ONLY, MESON_AFTER_BULK_ONLY_PATCHED),
            (MESON_PRISTINE, MESON_PATCHED),
        ], 'audio/out/ao.c entry')


anchor.main(apply, 'patch_filter_label_tap', marker=MARKER,
            usage='<mpv_src_dir>')
