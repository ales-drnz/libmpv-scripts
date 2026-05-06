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


# Idempotency marker — re-running the build pipeline against the same
# extracted mpv tree is safe.
MARKER = 'MAK_PCM_TAP_PATCH_V1'


# ─── audio/out/mak_pcm_tap.h ──────────────────────────────────────────

PCM_TAP_H = (
    '/* ' + MARKER + ' ─── public API for the PCM tap.\n'
    ' *\n'
    ' * The tap is a process-wide ring buffer that records the most\n'
    ' * recent ~200 ms of post-DSP audio samples. Producers call\n'
    ' * mak_pcm_tap_write() from the audio thread; the property getter\n'
    ' * in player/command.c calls mak_pcm_tap_read() to expose a\n'
    ' * snapshot to clients via pcm-tap-frame.\n'
    ' *\n'
    ' * The writer accepts every PCM format mpv supports (U8 / S16 /\n'
    ' * S32 / S64 / FLOAT / DOUBLE, packed and planar), converts to\n'
    ' * interleaved Float32 inline, and skips encoded passthrough\n'
    ' * formats (AC3 / DTS / TrueHD / etc.) — those are opaque codec\n'
    ' * bytes, not PCM, and have nothing meaningful to visualise. */\n'
    '#ifndef MP_AUDIO_OUT_MAK_PCM_TAP_H_\n'
    '#define MP_AUDIO_OUT_MAK_PCM_TAP_H_\n'
    '\n'
    '#include <stdbool.h>\n'
    '#include <stddef.h>\n'
    '\n'
    'struct ao;\n'
    'struct mpv_node;\n'
    '\n'
    '/* Called from ao_post_process_data() in audio/out/ao.c on every\n'
    ' * AO chunk. No-op when the AO format is not Float32 interleaved. */\n'
    'void mak_pcm_tap_write(struct ao *ao, void **data, int num_samples);\n'
    '\n'
    '/* Builds an MPV_FORMAT_NODE_MAP describing the most recent\n'
    ' * `max_samples` samples (per channel) in the ring. Returns 0 on\n'
    ' * success and -1 when the ring is empty / the format is unset.\n'
    ' * Allocates via talloc against `parent`; the caller hands the\n'
    ' * resulting node to the property machinery, which frees the\n'
    ' * tree. */\n'
    'int mak_pcm_tap_read(struct mpv_node *out, int max_samples,\n'
    '                     void *parent);\n'
    '\n'
    '#endif\n'
)


# ─── audio/out/mak_pcm_tap.c ──────────────────────────────────────────

PCM_TAP_C = (
    '/* ' + MARKER + ' ─── PCM tap: ring buffer for post-DSP audio\n'
    ' * samples, polled via the pcm-tap-frame property. See\n'
    ' * scripts/patches/mpv/patch_pcm_tap.py in the wrapper repo for\n'
    ' * the rationale. */\n'
    '#include <stdatomic.h>\n'
    '#include <stdbool.h>\n'
    '#include <stdint.h>\n'
    '#include <string.h>\n'
    '\n'
    '#include "mpv_talloc.h"\n'
    '\n'
    '#include <mpv/client.h>\n'
    '\n'
    '#include "audio/format.h"\n'
    '#include "audio/out/ao.h"\n'
    '#include "audio/out/internal.h"\n'
    '#include "audio/out/mak_pcm_tap.h"\n'
    '#include "osdep/threads.h"\n'
    '#include "osdep/timer.h"\n'
    '\n'
    '/* 200 ms @ 48 kHz / 2 channels / Float32 ≈ 76 KB. The cap is a\n'
    ' * static upper bound; the actual valid bytes track what the AO\n'
    ' * has produced so far (`valid_bytes`). */\n'
    '#define MAK_PCM_TAP_CAPACITY (256 * 1024)\n'
    '\n'
    '/* Scratch buffer for format conversion. 64K floats = 256 KB —\n'
    ' * enough for a 32K-sample stereo chunk or an 8K-sample 8-channel\n'
    ' * chunk. Realistic AO chunks are 1–2K samples × 2–6 channels, so\n'
    ' * this never overflows in practice; if a producer ever sends a chunk\n'
    ' * larger than the scratch, convert_to_float drops it whole (returns 0\n'
    ' * — rare and visually benign, skips the visualizer for one frame). */\n'
    '#define MAK_PCM_TAP_SCRATCH_FLOATS (64 * 1024)\n'
    '\n'
    'struct mak_pcm_tap {\n'
    '    mp_mutex lock;\n'
    '    uint8_t         buf[MAK_PCM_TAP_CAPACITY];\n'
    '    float           scratch[MAK_PCM_TAP_SCRATCH_FLOATS];\n'
    '    size_t          write_pos;     /* next byte to write (wraps) */\n'
    '    size_t          valid_bytes;   /* total valid bytes in ring */\n'
    '    int             sample_rate;\n'
    '    int             channels;\n'
    '    int64_t         last_pts_ns;   /* mp_time_ns() at last write */\n'
    '};\n'
    '\n'
    'static struct mak_pcm_tap g_tap = {\n'
    '    .lock = MP_STATIC_MUTEX_INITIALIZER,\n'
    '};\n'
    '\n'
    '/* Lazy-activation gate. Set the first time a client reads the tap\n'
    ' * (the visualizer frame); until then the AO-thread write path returns\n'
    ' * immediately, so the per-sample convert + ring memcpy cost nothing\n'
    ' * for the common case where nothing consumes the tap. */\n'
    'static atomic_bool g_tap_armed = false;\n'
    '\n'
    '/* Format normalisation: every supported PCM format → interleaved\n'
    ' * Float32 in `dst`. Returns the number of float samples written\n'
    ' * (== num_samples * channels), or 0 if the format is unsupported.\n'
    ' * Per-sample cost is one mul + cast; trivially fast on audio\n'
    ' * thread budgets. */\n'
    'static size_t convert_to_float(int format, void **data,\n'
    '                               int num_samples, int channels,\n'
    '                               float *dst, size_t dst_capacity)\n'
    '{\n'
    '    size_t total = (size_t)num_samples * (size_t)channels;\n'
    '    if (total == 0 || total > dst_capacity)\n'
    '        return 0;\n'
    '    switch (format) {\n'
    '        case AF_FORMAT_FLOAT: {\n'
    '            memcpy(dst, data[0], total * sizeof(float));\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_FLOATP: {\n'
    '            float **p = (float **)data;\n'
    '            for (int s = 0; s < num_samples; s++)\n'
    '                for (int c = 0; c < channels; c++)\n'
    '                    dst[s * channels + c] = p[c][s];\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_S16: {\n'
    '            const int16_t *p = (const int16_t *)data[0];\n'
    '            const float scale = 1.0f / 32768.0f;\n'
    '            for (size_t i = 0; i < total; i++)\n'
    '                dst[i] = (float)p[i] * scale;\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_S16P: {\n'
    '            int16_t **p = (int16_t **)data;\n'
    '            const float scale = 1.0f / 32768.0f;\n'
    '            for (int s = 0; s < num_samples; s++)\n'
    '                for (int c = 0; c < channels; c++)\n'
    '                    dst[s * channels + c] = (float)p[c][s] * scale;\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_S32: {\n'
    '            const int32_t *p = (const int32_t *)data[0];\n'
    '            const float scale = 1.0f / 2147483648.0f;\n'
    '            for (size_t i = 0; i < total; i++)\n'
    '                dst[i] = (float)p[i] * scale;\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_S32P: {\n'
    '            int32_t **p = (int32_t **)data;\n'
    '            const float scale = 1.0f / 2147483648.0f;\n'
    '            for (int s = 0; s < num_samples; s++)\n'
    '                for (int c = 0; c < channels; c++)\n'
    '                    dst[s * channels + c] = (float)p[c][s] * scale;\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_S64: {\n'
    '            const int64_t *p = (const int64_t *)data[0];\n'
    '            /* 1.0 / 9.2233720368547758e18 ≈ float scale for INT64_MAX */\n'
    '            const float scale = 1.0842021724855044e-19f;\n'
    '            for (size_t i = 0; i < total; i++)\n'
    '                dst[i] = (float)p[i] * scale;\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_S64P: {\n'
    '            int64_t **p = (int64_t **)data;\n'
    '            const float scale = 1.0842021724855044e-19f;\n'
    '            for (int s = 0; s < num_samples; s++)\n'
    '                for (int c = 0; c < channels; c++)\n'
    '                    dst[s * channels + c] = (float)p[c][s] * scale;\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_U8: {\n'
    '            const uint8_t *p = (const uint8_t *)data[0];\n'
    '            const float scale = 1.0f / 128.0f;\n'
    '            for (size_t i = 0; i < total; i++)\n'
    '                dst[i] = ((float)p[i] - 128.0f) * scale;\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_U8P: {\n'
    '            uint8_t **p = (uint8_t **)data;\n'
    '            const float scale = 1.0f / 128.0f;\n'
    '            for (int s = 0; s < num_samples; s++)\n'
    '                for (int c = 0; c < channels; c++)\n'
    '                    dst[s * channels + c] =\n'
    '                        ((float)p[c][s] - 128.0f) * scale;\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_DOUBLE: {\n'
    '            const double *p = (const double *)data[0];\n'
    '            for (size_t i = 0; i < total; i++)\n'
    '                dst[i] = (float)p[i];\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_DOUBLEP: {\n'
    '            double **p = (double **)data;\n'
    '            for (int s = 0; s < num_samples; s++)\n'
    '                for (int c = 0; c < channels; c++)\n'
    '                    dst[s * channels + c] = (float)p[c][s];\n'
    '            return total;\n'
    '        }\n'
    '        default:\n'
    '            return 0;\n'
    '    }\n'
    '}\n'
    '\n'
    'void mak_pcm_tap_write(struct ao *ao, void **data, int num_samples)\n'
    '{\n'
    '    if (!ao || !data || num_samples <= 0)\n'
    '        return;\n'
    '    /* Lazy activation — skip everything until a client has read the\n'
    '     * tap at least once. Relaxed: a one-chunk delay in seeing the arm\n'
    '     * only blanks the very first frame, which is imperceptible. */\n'
    '    if (!atomic_load_explicit(&g_tap_armed, memory_order_relaxed))\n'
    '        return;\n'
    '    /* Skip non-PCM (S/PDIF passthrough: AC3, DTS, TrueHD, …):\n'
    '     * those are opaque codec bytes, not samples we can visualise. */\n'
    '    if (!af_fmt_is_pcm(ao->format))\n'
    '        return;\n'
    '    int channels = ao->channels.num;\n'
    '    if (channels <= 0)\n'
    '        return;\n'
    '\n'
    '    mp_mutex_lock(&g_tap.lock);\n'
    '\n'
    '    size_t produced = convert_to_float(ao->format, data, num_samples,\n'
    '                                       channels, g_tap.scratch,\n'
    '                                       MAK_PCM_TAP_SCRATCH_FLOATS);\n'
    '    if (produced == 0) {\n'
    '        mp_mutex_unlock(&g_tap.lock);\n'
    '        return;\n'
    '    }\n'
    '\n'
    '    g_tap.sample_rate = ao->samplerate;\n'
    '    g_tap.channels    = channels;\n'
    '    g_tap.last_pts_ns = mp_time_ns();\n'
    '\n'
    '    size_t frame_bytes = produced * sizeof(float);\n'
    '    if (frame_bytes > MAK_PCM_TAP_CAPACITY)\n'
    '        frame_bytes = MAK_PCM_TAP_CAPACITY;\n'
    '\n'
    '    const uint8_t *src = (const uint8_t *)g_tap.scratch;\n'
    '    size_t remaining = frame_bytes;\n'
    '    while (remaining > 0) {\n'
    '        size_t free_until_end = MAK_PCM_TAP_CAPACITY - g_tap.write_pos;\n'
    '        size_t copy = remaining < free_until_end ? remaining\n'
    '                                                 : free_until_end;\n'
    '        memcpy(&g_tap.buf[g_tap.write_pos], src, copy);\n'
    '        g_tap.write_pos = (g_tap.write_pos + copy) % MAK_PCM_TAP_CAPACITY;\n'
    '        src += copy;\n'
    '        remaining -= copy;\n'
    '    }\n'
    '    g_tap.valid_bytes += frame_bytes;\n'
    '    if (g_tap.valid_bytes > MAK_PCM_TAP_CAPACITY)\n'
    '        g_tap.valid_bytes = MAK_PCM_TAP_CAPACITY;\n'
    '\n'
    '    mp_mutex_unlock(&g_tap.lock);\n'
    '}\n'
    '\n'
    'int mak_pcm_tap_read(struct mpv_node *out, int max_samples, void *parent)\n'
    '{\n'
    '    (void)parent;  /* Property machinery owns the returned tree —\n'
    '                    * it expects each top-level allocation rooted at\n'
    '                    * NULL (talloc_zero(NULL, …)). The `arg` pointer\n'
    '                    * passed by the caller is the destination\n'
    '                    * mpv_node, NOT a talloc context. See\n'
    '                    * `mp_property_embedded_cover_art_data` and\n'
    '                    * `screenshot-raw` for the canonical pattern. */\n'
    '    if (!out || max_samples <= 0)\n'
    '        return -1;\n'
    '\n'
    '    atomic_store_explicit(&g_tap_armed, true, memory_order_relaxed);\n'
    '    mp_mutex_lock(&g_tap.lock);\n'
    '\n'
    '    int channels = g_tap.channels;\n'
    '    int rate     = g_tap.sample_rate;\n'
    '    int64_t pts  = g_tap.last_pts_ns;\n'
    '    if (channels <= 0 || rate <= 0 || g_tap.valid_bytes == 0) {\n'
    '        mp_mutex_unlock(&g_tap.lock);\n'
    '        return -1;\n'
    '    }\n'
    '\n'
    '    size_t frame_bytes  = (size_t)channels * sizeof(float);\n'
    '    size_t window_bytes = (size_t)max_samples * frame_bytes;\n'
    '    if (window_bytes > g_tap.valid_bytes)\n'
    '        window_bytes = g_tap.valid_bytes;\n'
    '\n'
    '    /* Build the MAP_NODE tree. Top-level list rooted at NULL —\n'
    '     * children parented to it so the entire tree frees via a\n'
    '     * single talloc_free chain when mpv_free_node_contents runs. */\n'
    '    struct mpv_node_list *list =\n'
    '        talloc_zero(NULL, struct mpv_node_list);\n'
    '    list->num    = 4;\n'
    '    list->keys   = talloc_array(list, char *, 4);\n'
    '    list->values = talloc_array(list, struct mpv_node, 4);\n'
    '\n'
    '    struct mpv_byte_array *ba =\n'
    '        talloc_zero(list, struct mpv_byte_array);\n'
    '    ba->data = talloc_size(ba, window_bytes);\n'
    '    ba->size = window_bytes;\n'
    '\n'
    '    /* Most-recent window ends at write_pos (exclusive). Walk back\n'
    '     * window_bytes with wrap. */\n'
    '    size_t start = (g_tap.write_pos + MAK_PCM_TAP_CAPACITY - window_bytes)\n'
    '                       % MAK_PCM_TAP_CAPACITY;\n'
    '    if (start + window_bytes <= MAK_PCM_TAP_CAPACITY) {\n'
    '        memcpy(ba->data, &g_tap.buf[start], window_bytes);\n'
    '    } else {\n'
    '        size_t first = MAK_PCM_TAP_CAPACITY - start;\n'
    '        memcpy(ba->data, &g_tap.buf[start], first);\n'
    '        memcpy((char *)ba->data + first, &g_tap.buf[0],\n'
    '               window_bytes - first);\n'
    '    }\n'
    '\n'
    '    mp_mutex_unlock(&g_tap.lock);\n'
    '\n'
    '    list->keys[0] = talloc_strdup(list, "sample_rate");\n'
    '    list->values[0] = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_INT64, .u.int64 = rate};\n'
    '    list->keys[1] = talloc_strdup(list, "channels");\n'
    '    list->values[1] = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_INT64, .u.int64 = channels};\n'
    '    list->keys[2] = talloc_strdup(list, "pts_ns");\n'
    '    list->values[2] = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_INT64, .u.int64 = pts};\n'
    '    list->keys[3] = talloc_strdup(list, "samples");\n'
    '    list->values[3] = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_BYTE_ARRAY, .u.ba = ba};\n'
    '\n'
    '    *out = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_NODE_MAP, .u.list = list};\n'
    '    return 0;\n'
    '}\n'
)


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
