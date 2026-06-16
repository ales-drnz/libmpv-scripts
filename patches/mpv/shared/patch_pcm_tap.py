#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patches mpv to expose the post-DSP audio output samples as a polled
read-only client API property `pcm-tap-frame`, suitable for driving
real-time spectrum analyzers / visualizers from a wrapper.

Problem
=======

libmpv has no public API for "give me the most recent N samples of
audio that just played". The audio path is one-way: decoder → af chain
→ ao_driver → device, with no host-accessible tap. mpv's existing
visualizer scripts work around this by routing the audio through
`lavfi-complex` filters that render `showcqt` to a synthetic VIDEO
track — useful inside mpv's own video pipeline, useless when the
host wants numerical FFT bins for a custom UI.

This patch adds an in-process ring buffer that the wrapper polls via
`mpv_get_property("pcm-tap-frame")`. The tap is placed at the central
point every audio output funnels through (post-AF chain, post-volume,
about to hit the AO driver), so the bytes the host sees are exactly
the bytes the speakers are about to play.

Tap point
=========

`audio/out/ao.c::ao_post_process_data()` runs after the af chain and
the per-AO software volume gain, on every chunk every AO consumes
(both push and pull drivers route through it). One memcpy per AO
chunk, ~one per ~10 ms at 48 kHz / 2 ch / 480-frame buffers.

Property
========

    pcm-tap-frame    MPV_FORMAT_NODE → MAP with
                       sample_rate : INT64 (Hz)
                       channels    : INT64 (interleaved channel count)
                       pts_ns      : INT64 (mp_time_ns() of last write)
                       samples     : BYTE_ARRAY (interleaved Float32
                                     samples, latest window of up to
                                     ~200 ms of audio)
                     M_PROPERTY_UNAVAILABLE if no audio has flowed yet
                     OR if the AO is not running with float interleaved
                     samples (the wrapper requests this via
                     `--audio-format=float` at init).

Format coverage
===============

The tap converts every PCM format mpv supports — packed and planar:
`U8 / S16 / S32 / S64 / FLOAT / DOUBLE` (`* / *P`) — into Float32
interleaved on the way into the ring buffer. The conversion is a
single per-sample multiply + cast (deinterleave for planar inputs),
trivially fast on the audio thread.

Encoded passthrough formats (`AF_FORMAT_S_AC3`, `S_DTS`, `S_TRUEHD`,
`S_EAC3`, `S_DTSHD`, `S_AAC`, `S_MP3`) are skipped: those are opaque
codec bytes flowing through HDMI / S/PDIF, not PCM samples — there
is nothing meaningful to visualise. `af_fmt_is_pcm()` gates the path.

Threading
=========

Single-producer single-consumer ring. Producer = AO thread (push) or
audio API render callback (pull). Consumer = client thread reading
the property.

The shared state (`g_tap`) is protected by an `mp_mutex` (mpv's
portable mutex wrapper — a pthread mutex on POSIX, an SRWLOCK on
Windows).
Audio-thread mutex hold time is bounded to one `memcpy` of ≤ 4 KB
(typical AO chunk × 4 B per float sample × 2 channels) — sub-µs on
modern hardware, well under any audio period. mpv's own AO buffer
code already takes a mutex on the same thread, so this matches the
existing concurrency budget.

Multi-Player note
=================

The ring is process-wide singleton state: there is one ring shared by
every libmpv instance loaded into the process. With more than one
Player playing simultaneously, the ring interleaves samples from all
of them — visually noisy in a visualizer, but functionally benign
(no UB, no crash). The 99% case (one Player) is exact.

Files patched
=============

    audio/out/mak_pcm_tap.h   NEW — public symbols
    audio/out/mak_pcm_tap.c   NEW — ring buffer + property reader
    audio/out/ao.c            tap call inserted at end of
                              `ao_post_process_data()`
    player/command.c          property registration + getter
    meson.build               new source file added to the build

Usage
=====

    python3 patch_pcm_tap.py <mpv_source_dir>

Composes with `patch_audio_output_state.py` and
`patch_embedded_cover_art.py` — different files / disjoint anchors.

This tap feeds the spectrum / VU visualizer only. The progressive
waveform does NOT use it: it folds PRE-DSP frames straight from the af
chain "in" filter (see `patch_filter_label_tap.py` →
`mak_waveform_tap_in`), so there is no link-time dependency between this
patch and `patch_bulk_analysis.py`.
"""
import os
import sys

SRC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'pcm_tap')


def read_src(name):
    with open(os.path.join(SRC_DIR, name)) as f:
        return f.read()


# Idempotency marker — re-running the build pipeline against the same
# extracted mpv tree is safe.
MARKER = 'MAK_PCM_TAP_PATCH_V1'


# ─── audio/out/mak_pcm_tap.h ──────────────────────────────────────────

# The real C source lives in pcm_tap/mak_pcm_tap.h next to this
# script — edit it THERE; this patch only copies it into the tree.
PCM_TAP_H = read_src('mak_pcm_tap.h')


# ─── audio/out/mak_pcm_tap.c ──────────────────────────────────────────

# The real C source lives in pcm_tap/mak_pcm_tap.c next to this
# script — edit it THERE; this patch only copies it into the tree.
PCM_TAP_C = read_src('mak_pcm_tap.c')


# ─── audio/out/ao.c ───────────────────────────────────────────────────

# Anchor on the full body of `ao_post_process_data` for safety. Insert
# a tap call after the per-plane gain loop. Pristine body lifted from
# v0.41.0 of audio/out/ao.c.
AO_PRISTINE = (
    'void ao_post_process_data(struct ao *ao, void **data, int num_samples)\n'
    '{\n'
    '    bool planar = af_fmt_is_planar(ao->format);\n'
    '    int planes = planar ? ao->channels.num : 1;\n'
    '    int plane_samples = num_samples * (planar ? 1: ao->channels.num);\n'
    '    for (int n = 0; n < planes; n++)\n'
    '        process_plane(ao, data[n], plane_samples);\n'
    '}'
)

AO_PATCHED = (
    'void ao_post_process_data(struct ao *ao, void **data, int num_samples)\n'
    '{\n'
    '    bool planar = af_fmt_is_planar(ao->format);\n'
    '    int planes = planar ? ao->channels.num : 1;\n'
    '    int plane_samples = num_samples * (planar ? 1: ao->channels.num);\n'
    '    for (int n = 0; n < planes; n++)\n'
    '        process_plane(ao, data[n], plane_samples);\n'
    '    /* ' + MARKER + ' ── tap post-DSP samples for visualizer use. */\n'
    '    mak_pcm_tap_write(ao, data, num_samples);\n'
    '}'
)

# Anchor on the includes block. ao.c ends its includes with
# "common/global.h" — append our header there so `mak_pcm_tap_write`
# resolves at compile time. Stable across recent mpv releases.
AO_INCLUDE_PRISTINE = '#include "common/global.h"'

AO_INCLUDE_PATCHED = (
    '#include "common/global.h"\n'
    '/* ' + MARKER + ' */\n'
    '#include "audio/out/mak_pcm_tap.h"'
)


def patch_ao_c(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if AO_INCLUDE_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (ao.c includes) not found in {path}.'
        )
    if AO_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (ao_post_process_data body) not found in {path}.'
        )
    text = text.replace(AO_INCLUDE_PRISTINE, AO_INCLUDE_PATCHED, 1)
    text = text.replace(AO_PRISTINE, AO_PATCHED, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── player/command.c ─────────────────────────────────────────────────

# Property table. We anchor on `audio-bitrate` — far from the anchors
# used by patch_audio_output_state.py (`audio-out-params`) and
# patch_embedded_cover_art.py (`audio-device-list`), so all three
# patches compose in any order.
COMMAND_TABLE_PRISTINE = (
    '    {"audio-bitrate", mp_property_packet_bitrate, '
    '.priv = (void *)&(const int){STREAM_AUDIO}},'
)

COMMAND_TABLE_PATCHED = (
    '    {"audio-bitrate", mp_property_packet_bitrate, '
    '.priv = (void *)&(const int){STREAM_AUDIO}},\n'
    '    /* ' + MARKER + ' */\n'
    '    {"pcm-tap-frame", mp_property_pcm_tap_frame},'
)

# Insert the getter just before mp_property_audio_params (same insertion
# point as the audio-output-state and embedded-cover-art patches; all
# three compose because each just prepends a fresh function definition).
COMMAND_GETTER_ANCHOR = (
    'static int mp_property_audio_params(void *ctx, struct m_property *prop,'
)

COMMAND_GETTER_INSERT = (
    '/* ' + MARKER + ' ─── read-only property: snapshot of the most\n'
    ' * recent samples that flowed through the AO. Returns a\n'
    ' * MAP_NODE { sample_rate, channels, pts_ns, samples }, or\n'
    ' * M_PROPERTY_UNAVAILABLE if no audio has flowed yet (or the AO\n'
    ' * is not running with float-interleaved samples). The wrapper\n'
    ' * polls this at its configured emit rate (typically 30 fps); we\n'
    ' * intentionally do NOT call mp_notify_property here — pushing\n'
    ' * change events for every AO chunk would saturate the event\n'
    ' * channel. */\n'
    'static int mp_property_pcm_tap_frame(void *ctx, struct m_property *prop,\n'
    '                                     int action, void *arg)\n'
    '{\n'
    '    switch (action) {\n'
    '        case M_PROPERTY_GET_TYPE:\n'
    '            *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_NODE};\n'
    '            return M_PROPERTY_OK;\n'
    '        case M_PROPERTY_GET:\n'
    '        case M_PROPERTY_GET_NODE: {\n'
    '            /* Window: 4096 samples (~85 ms at 48 kHz) — enough\n'
    '             * for a 4096-bin FFT, the largest size the wrapper\n'
    '             * exposes. Smaller window sizes the consumer wants\n'
    '             * are sliced Dart-side. */\n'
    '            struct mpv_node n = {0};\n'
    '            if (mak_pcm_tap_read(&n, 4096, arg) < 0)\n'
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

# Anchor on a stable include line in command.c. The file ends its
# includes with "command.h" — append the tap header there.
COMMAND_INCLUDE_PRISTINE = '#include "command.h"'

COMMAND_INCLUDE_PATCHED = (
    '#include "command.h"\n'
    '/* ' + MARKER + ' */\n'
    '#include "audio/out/mak_pcm_tap.h"'
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
    # Idempotency: the cover-art and audio-output-state patches use the
    # same `#include "command.h"` line as one of their anchors, so
    # other patches may have already inserted lines below it. We only
    # append our include if our marker isn't already there — guarded
    # at the top of this function.
    text = text.replace(COMMAND_INCLUDE_PRISTINE, COMMAND_INCLUDE_PATCHED, 1)
    text = text.replace(COMMAND_TABLE_PRISTINE, COMMAND_TABLE_PATCHED, 1)
    text = text.replace(COMMAND_GETTER_ANCHOR, COMMAND_GETTER_INSERT, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── meson.build ──────────────────────────────────────────────────────

# Anchor on the line that lists `audio/out/ao.c`. The build references
# every source file explicitly (no glob), so we must add the new one.
MESON_PRISTINE = "    'audio/out/ao.c',"

MESON_PATCHED = (
    "    'audio/out/ao.c',\n"
    "    # " + MARKER + "\n"
    "    'audio/out/mak_pcm_tap.c',"
)


def patch_meson(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if MESON_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (audio/out/ao.c entry) not found in {path}.'
        )
    text = text.replace(MESON_PRISTINE, MESON_PATCHED, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── new files ────────────────────────────────────────────────────────

def write_new_file(path, content):
    """Idempotent: refuse to clobber a different file with the same name,
    but rewrite if the marker is present (i.e. a prior run wrote it)."""
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
    write_new_file(os.path.join(src, 'audio', 'out', 'mak_pcm_tap.h'),
                   PCM_TAP_H)
    write_new_file(os.path.join(src, 'audio', 'out', 'mak_pcm_tap.c'),
                   PCM_TAP_C)
    patch_ao_c(os.path.join(src, 'audio', 'out', 'ao.c'))
    patch_command_c(os.path.join(src, 'player', 'command.c'))
    patch_meson(os.path.join(src, 'meson.build'))


if __name__ == '__main__':
    main()
