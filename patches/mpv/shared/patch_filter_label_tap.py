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


MARKER = 'MAK_TAP_PATCH_V3'

# Wire-protocol limits. Keep in sync with the Dart parser.
MAX_TAPS = 8         # max distinct filter names that can be active
MAX_SAMPLES = 4096   # samples per channel returned by a single read


# ─── audio/mak_tap.h ──────────────────────────────────────────────────

TAP_H = (
    '/* ' + MARKER + ' ─── public API for the per-filter audio tap.\n'
    ' *\n'
    ' * mak_tap maintains a fixed-size table of "active taps" (a tap\n'
    ' * being a combination of filter name + side). For each active\n'
    ' * tap, two ring buffers (pre / post) accumulate the most recent\n'
    ' * ~340 ms of post-conversion Float32 samples plus the playback\n'
    ' * PTS at the most-recently-written sample. The audio chain\n'
    ' * calls mak_tap_write() from inside user_wrapper_process for\n'
    ' * every frame the user filter handles; the call short-circuits\n'
    ' * when the filter is not in the active set.\n'
    ' *\n'
    ' * Reads are aligned to a caller-supplied playback PTS so the\n'
    ' * visualiser sees the slice of audio that the AO is playing\n'
    ' * RIGHT NOW, even though the filter chain processes ahead of\n'
    ' * the AO in bursts. The wrapper passes\n'
    ' * `playing_audio_pts(mpctx)` from inside the property getter. */\n'
    '#ifndef MP_AUDIO_MAK_TAP_H_\n'
    '#define MP_AUDIO_MAK_TAP_H_\n'
    '\n'
    '#include <stdbool.h>\n'
    '\n'
    'struct mp_aframe;\n'
    'struct mpv_node;\n'
    '\n'
    f'#define MAK_TAP_MAX        {MAX_TAPS}\n'
    f'#define MAK_TAP_MAX_SAMPLES {MAX_SAMPLES}\n'
    '\n'
    '/* Replace the active-taps list with the comma-separated [csv].\n'
    ' * Empty / NULL clears every tap. Idempotent and threadsafe. */\n'
    'void mak_tap_set_active(const char *csv);\n'
    '\n'
    '/* Returns the current CSV. Caller-owned copy via talloc.\n'
    ' * Returns "" (talloc-allocated) when no tap is active. */\n'
    'char *mak_tap_get_active(void *parent);\n'
    '\n'
    '/* Fast-path check used by the wrapper hook. */\n'
    'bool mak_tap_label_active(const char *name);\n'
    '\n'
    '/* Append `aframe` to the per-tap ring for `name` on the side\n'
    ' * indicated by `is_post`. No-op if the label is not active.\n'
    ' * Encoded passthrough formats (AC3 / DTS / …) are silently\n'
    ' * skipped. */\n'
    'void mak_tap_write(const char *name, bool is_post,\n'
    '                   struct mp_aframe *aframe);\n'
    '\n'
    '/* ' + MARKER + ' ─── pre-DSP waveform fold. Called from the af chain\n'
    ' * user_wrapper_process PRE hook for every audio frame; self-gates to\n'
    ' * the "in" filter and to an active progressive analysis. Converts +\n'
    ' * mono-downmixes the source frame and folds it into the progressive\n'
    ' * waveform envelope. */\n'
    'void mak_waveform_tap_in(const char *name, struct mp_aframe *aframe);\n'
    '\n'
    '/* Build the audio-tap-frames node tree, returning the slice of\n'
    ' * samples that ends at `target_pts_secs` for every active tap.\n'
    ' * `target_pts_secs == NaN` means "return the latest available\n'
    ' * window" (used when playback PTS is unknown / not playing). */\n'
    'int mak_tap_read_all(struct mpv_node *out, void *parent,\n'
    '                     double target_pts_secs);\n'
    '\n'
    '#endif\n'
)


# ─── audio/mak_tap.c ──────────────────────────────────────────────────

TAP_C = (
    '/* ' + MARKER + ' ─── per-filter pre / post audio tap.\n'
    ' *\n'
    ' * Concurrency model\n'
    ' * -----------------\n'
    ' *\n'
    ' * Producer (writer): the audio-filter thread, which calls\n'
    ' *     mak_tap_write() from inside user_wrapper_process for every\n'
    ' *     frame the active filters produce. The chain is\n'
    ' *     single-threaded — only one writer at a time per ring.\n'
    ' *\n'
    ' * Consumer (reader): the mpv main thread, which drains the ring\n'
    ' *     via the audio-tap-frames property getter at the wrapper\'s\n'
    ' *     polling cadence (typically 30 Hz).\n'
    ' *\n'
    ' * Coordinator: any thread setting / clearing the active-tap list\n'
    ' *     via mak_tap_set_active(), guarded by a small mutex.\n'
    ' *\n'
    ' * Hot-path synchronisation uses an SPSC seqlock — the canonical\n'
    ' * lock-free pattern for real-time audio. The writer never blocks\n'
    ' * on a reader; the reader retries on contention (rare in practice\n'
    ' * because writes are short and reads infrequent). Each tap_ring\n'
    ' * has its own atomic sequence counter:\n'
    ' *\n'
    ' *     even = stable     (data may be read)\n'
    ' *     odd  = writing    (reader must retry)\n'
    ' *\n'
    ' * The slot table itself uses an _Atomic bool per slot for the\n'
    ' * "used" flag, so find_slot() on the audio thread is also\n'
    ' * lock-free. set_active still takes a tiny mutex to serialise\n'
    ' * concurrent subscriber additions / removals. */\n'
    '#include <math.h>\n'
    '#include <stdatomic.h>\n'
    '#include <stdbool.h>\n'
    '#include <stdint.h>\n'
    '#include <string.h>\n'
    '\n'
    '#include "mpv_talloc.h"\n'
    '#include <mpv/client.h>\n'
    '\n'
    '#include "audio/aframe.h"\n'
    '#include "audio/format.h"\n'
    '#include "audio/mak_tap.h"\n'
    '#include "audio/mak_waveform.h"\n'
    '#include "audio/mak_wave_fold.h"\n'
    '#include "osdep/threads.h"\n'
    '\n'
    '/* Format-adaptive ring sizing.\n'
    ' *\n'
    ' * The ring is allocated dynamically at format-detection time\n'
    ' * (see mak_tap_write) so a 44.1 kHz mono stream and a 384 kHz\n'
    ' * 5.1 stream both get a buffer that covers the same number of\n'
    ' * SECONDS of audio rather than the same number of bytes. This\n'
    ' * matches the canonical JUCE prepareToPlay model — the audio\n'
    ' * thread allocates only at format change (rare, equivalent to\n'
    ' * file load), not in the per-frame hot path.\n'
    ' *\n'
    ' * TAP_BUFFER_SECONDS — target coverage in seconds. 3.0 s\n'
    ' *   matches the iZotope Ozone "Average Time" middle preset and\n'
    ' *   covers mpv\'s observed ~1.2 s chain pre-buffer with a 2.5×\n'
    ' *   safety margin.\n'
    ' *\n'
    ' * TAP_MAX_RING_BYTES — per-ring memory cap. 16 MB is enough for\n'
    ' *   3 s at 384 kHz stereo float (12 MB) but caps the worst case\n'
    ' *   at 384 kHz 7.1 (1 s coverage) and 768 kHz 7.1 (520 ms). Total\n'
    ' *   worst case if every slot were active: 8 slots × 2 sides ×\n'
    ' *   16 MB = 256 MB. Typical case (1 pro window, 48 kHz stereo):\n'
    ' *   ~2.3 MB total.\n'
    ' *\n'
    ' * When the requested PTS-aligned read falls outside the ring\'s\n'
    ' * coverage (only possible at the cap, on extreme hi-res), the\n'
    ' * reader degrades gracefully to "latest available window" rather\n'
    ' * than freezing on a stale slice — same behaviour every DAW\n'
    ' * spectrum analyser uses (VLC visual.c, JUCE AudioVisualiser-\n'
    ' * Component, Voxengo SPAN). */\n'
    '#define TAP_BUFFER_SECONDS  3.0\n'
    '#define TAP_MAX_RING_BYTES  (16 * 1024 * 1024)\n'
    '#define TAP_MAX_CHANNELS    8\n'
    '/* Scratch space for one frame conversion to interleaved Float32 — */\n'
    '/* must fit the largest frame the chain may produce. 8K floats =     */\n'
    '/* 4 K stereo samples or 2 K 4-ch samples, plenty for typical mpv.   */\n'
    '#define TAP_SCRATCH_FLOATS (8 * 1024)\n'
    '/* Cap reader spin retries on seqlock contention. With brief\n'
    ' * writers (~10 µs) and a 30 Hz reader cadence, contention is\n'
    ' * exceptional; the cap exists only to defend against a runaway\n'
    ' * writer (e.g. a stalled scheduler) starving the reader\n'
    ' * forever. On give-up we return whatever the last partial copy\n'
    ' * read — visually a one-frame glitch, never a crash. */\n'
    '#define TAP_SEQLOCK_MAX_RETRIES 1024\n'
    '\n'
    'struct tap_ring {\n'
    '    /* SPSC seqlock — even = stable, odd = writer in progress.\n'
    '     * Writer increments to odd before any field write, increments\n'
    '     * back to even after all writes; reader spins until even,\n'
    '     * snapshots, and validates the seq is unchanged. */\n'
    '    _Atomic uint_fast32_t seq;\n'
    '\n'
    '    int     sample_rate;\n'
    '    int     channels;\n'
    '    /* Playback PTS (seconds) of the *next-to-be-written* sample,\n'
    '     * i.e. the time-coordinate of the byte at write_pos. Updated\n'
    '     * after every successful write. NaN until the first write\n'
    '     * with a valid frame PTS. */\n'
    '    double  end_pts_secs;\n'
    '    size_t  write_pos;     /* next byte to write (wraps) */\n'
    '    size_t  valid_bytes;   /* total valid bytes in ring */\n'
    '    /* Allocated and effective capacity in bytes. The buf is\n'
    '     * orphan-talloc\'d (parent NULL) ONCE on the first write that\n'
    '     * detects a valid format, sized to cover TAP_BUFFER_SECONDS at\n'
    '     * that format and capped at TAP_MAX_RING_BYTES. After that the\n'
    '     * buf pointer NEVER changes — set_active doesn\'t touch it,\n'
    '     * format changes don\'t reallocate it. This eliminates the\n'
    '     * use-after-free window a free / realloc inside the seqlock\n'
    '     * would otherwise open: the seqlock catches torn DATA but not\n'
    '     * a torn pointer (the reader\'s memcpy on the stale ptr would\n'
    '     * already be reading freed memory by the time the seq mismatch\n'
    '     * tells it to retry).\n'
    '     *\n'
    '     * alloc_bytes — immutable after first alloc, total bytes\n'
    '     *   actually allocated for buf.\n'
    '     * capacity    — frame-aligned working size for the current\n'
    '     *   (sample_rate, channels). Recomputed on every format change\n'
    '     *   as `(alloc_bytes / frame_bytes) * frame_bytes`. The wrap\n'
    '     *   math (writer + reader) uses capacity, not alloc_bytes, so\n'
    '     *   the tail (alloc_bytes - capacity, < frame_bytes) is\n'
    '     *   harmlessly unused under that format. */\n'
    '    size_t   alloc_bytes;\n'
    '    size_t   capacity;\n'
    '    uint8_t *buf;\n'
    '};\n'
    '\n'
    'struct tap_slot {\n'
    '    /* Atomic so find_slot() can probe without a lock. The audio\n'
    '     * thread runs find_slot per frame; we want zero overhead\n'
    '     * when no taps are active. */\n'
    '    _Atomic bool     used;\n'
    '    /* Written under activation_lock; read after a `used == true`\n'
    '     * acquire-load (the release-store on `used` publishes the\n'
    '     * preceding name write). */\n'
    '    char             name[64];\n'
    '    struct tap_ring  pre;\n'
    '    struct tap_ring  post;\n'
    '};\n'
    '\n'
    'static struct {\n'
    '    /* Serialises set_active / get_active calls — these touch the\n'
    '     * whole slot table at once and run rarely (on subscriber\n'
    '     * subscribe / unsubscribe), so a mutex is fine. */\n'
    '    mp_mutex         activation_lock;\n'
    '    struct tap_slot  slots[MAK_TAP_MAX];\n'
    '    /* Single-writer scratch; the audio chain is single-threaded\n'
    '     * so concurrent writers cannot collide here. */\n'
    '    float            scratch[TAP_SCRATCH_FLOATS];\n'
    '} g_tap = { .activation_lock = MP_STATIC_MUTEX_INITIALIZER };\n'
    '\n'
    '/* Lock-free probe — atomic_load on the slot.used flag (acquire\n'
    ' * orders the subsequent name read against the matching\n'
    ' * activation\'s release-store on used). Returns the slot index\n'
    ' * or -1 when not active. Hot path on the audio thread. */\n'
    'static int find_slot(const char *name)\n'
    '{\n'
    '    if (!name) return -1;\n'
    '    for (int i = 0; i < MAK_TAP_MAX; i++) {\n'
    '        if (atomic_load_explicit(&g_tap.slots[i].used,\n'
    '                                  memory_order_acquire) &&\n'
    '            strcmp(g_tap.slots[i].name, name) == 0) {\n'
    '            return i;\n'
    '        }\n'
    '    }\n'
    '    return -1;\n'
    '}\n'
    '\n'
    '/* Reset a ring\'s metadata. Called by the writer (under seqlock)\n'
    ' * on format change to discard accumulated samples, and by the\n'
    ' * activation path (set_active) to clear stale state when a slot\n'
    ' * is re-armed. The buf pointer + capacity are NOT touched here —\n'
    ' * those are owned exclusively by the writer (single-thread\n'
    ' * invariant) and freed/reallocated inside the writer\'s seqlock.\n'
    ' * Leaving the buffer alive across activation cycles costs at most\n'
    ' * 8 slots × 2 sides × 16 MB = 256 MB worst case (typical: a few\n'
    ' * MB) but eliminates the use-after-free race that would arise if\n'
    ' * the main thread freed the buffer mid-write. */\n'
    'static void reset_ring(struct tap_ring *r)\n'
    '{\n'
    '    r->sample_rate  = 0;\n'
    '    r->channels     = 0;\n'
    '    r->end_pts_secs = NAN;\n'
    '    r->write_pos    = 0;\n'
    '    r->valid_bytes  = 0;\n'
    '    /* seq stays where it is — the seqlock invariant is preserved\n'
    '     * because the activation_lock barrier orders the next write\n'
    '     * after this reset. */\n'
    '}\n'
    '\n'
    'void mak_tap_set_active(const char *csv)\n'
    '{\n'
    '    mp_mutex_lock(&g_tap.activation_lock);\n'
    '\n'
    '    /* Phase 1: tear down every active slot. Release-store on\n'
    '     * `used = false` makes the deactivation visible to the\n'
    '     * audio thread\'s acquire-load in find_slot. */\n'
    '    for (int i = 0; i < MAK_TAP_MAX; i++) {\n'
    '        atomic_store_explicit(&g_tap.slots[i].used, false,\n'
    '                              memory_order_release);\n'
    '    }\n'
    '    /* Phase 2: clear name + ring metadata. Buf pointers stay\n'
    '     * alive — only the writer (audio thread) touches them, and\n'
    '     * only inside its seqlock critical section. An in-flight\n'
    '     * writer that already passed find_slot continues safely\n'
    '     * against the still-valid buf; its write goes to the now-\n'
    '     * orphaned ring and the next reader for that slot won\'t see\n'
    '     * it (used == false). */\n'
    '    for (int i = 0; i < MAK_TAP_MAX; i++) {\n'
    '        g_tap.slots[i].name[0] = 0;\n'
    '        reset_ring(&g_tap.slots[i].pre);\n'
    '        reset_ring(&g_tap.slots[i].post);\n'
    '    }\n'
    '\n'
    '    if (!csv || !*csv) {\n'
    '        mp_mutex_unlock(&g_tap.activation_lock);\n'
    '        return;\n'
    '    }\n'
    '\n'
    '    /* Phase 3: parse CSV, populate slots, publish via release-\n'
    '     * store on `used = true`. Name is written before the publish\n'
    '     * so an audio thread that sees used==true reads a consistent\n'
    '     * name. */\n'
    '    int slot = 0;\n'
    '    const char *p = csv;\n'
    '    while (*p && slot < MAK_TAP_MAX) {\n'
    '        const char *end = strchr(p, \',\');\n'
    '        size_t len = end ? (size_t)(end - p) : strlen(p);\n'
    '        while (len > 0 && (*p == \' \' || *p == \'\\t\')) { p++; len--; }\n'
    '        while (len > 0 && (p[len-1] == \' \' || p[len-1] == \'\\t\')) len--;\n'
    '        if (len > 0 && len < sizeof(g_tap.slots[slot].name)) {\n'
    '            memcpy(g_tap.slots[slot].name, p, len);\n'
    '            g_tap.slots[slot].name[len] = 0;\n'
    '            atomic_store_explicit(&g_tap.slots[slot].used, true,\n'
    '                                  memory_order_release);\n'
    '            slot++;\n'
    '        }\n'
    '        if (!end) break;\n'
    '        p = end + 1;\n'
    '    }\n'
    '    mp_mutex_unlock(&g_tap.activation_lock);\n'
    '}\n'
    '\n'
    'char *mak_tap_get_active(void *parent)\n'
    '{\n'
    '    mp_mutex_lock(&g_tap.activation_lock);\n'
    '    /* Worst case: MAK_TAP_MAX × 64-char names + commas. */\n'
    '    char *out = talloc_size(parent, MAK_TAP_MAX * 64);\n'
    '    out[0] = 0;\n'
    '    bool first = true;\n'
    '    for (int i = 0; i < MAK_TAP_MAX; i++) {\n'
    '        if (!atomic_load_explicit(&g_tap.slots[i].used,\n'
    '                                   memory_order_acquire))\n'
    '            continue;\n'
    '        if (!first) strcat(out, ",");\n'
    '        strcat(out, g_tap.slots[i].name);\n'
    '        first = false;\n'
    '    }\n'
    '    mp_mutex_unlock(&g_tap.activation_lock);\n'
    '    return out;\n'
    '}\n'
    '\n'
    'bool mak_tap_label_active(const char *name)\n'
    '{\n'
    '    /* Lock-free fast path on the audio thread. With no taps\n'
    '     * active, every slot.used atomic_load reports false on the\n'
    '     * first iteration and the function returns ~immediately\n'
    '     * (no strcmp, no lock). */\n'
    '    return find_slot(name) >= 0;\n'
    '}\n'
    '\n'
    '/* Convert a planar / packed PCM aframe into interleaved Float32,\n'
    ' * writing into `dst` (capacity `dst_cap` floats). Returns the\n'
    ' * number of float samples written, or 0 if the format is not\n'
    ' * supported. Mirrors mak_pcm_tap.c::convert_to_float. */\n'
    'static size_t convert_aframe(struct mp_aframe *aframe,\n'
    '                             float *dst, size_t dst_cap,\n'
    '                             int *out_channels, int *out_rate)\n'
    '{\n'
    '    int format   = mp_aframe_get_format(aframe);\n'
    '    if (!af_fmt_is_pcm(format)) return 0;\n'
    '    int channels = mp_aframe_get_channels(aframe);\n'
    '    int rate     = mp_aframe_get_rate(aframe);\n'
    '    int samples  = mp_aframe_get_size(aframe);\n'
    '    if (channels <= 0 || rate <= 0 || samples <= 0) return 0;\n'
    '    if (channels > TAP_MAX_CHANNELS) channels = TAP_MAX_CHANNELS;\n'
    '\n'
    '    size_t total = (size_t)samples * (size_t)channels;\n'
    '    if (total == 0 || total > dst_cap) {\n'
    '        /* truncate to fit */\n'
    '        samples = (int)(dst_cap / (size_t)channels);\n'
    '        total   = (size_t)samples * (size_t)channels;\n'
    '        if (total == 0) return 0;\n'
    '    }\n'
    '\n'
    '    uint8_t **data = mp_aframe_get_data_ro(aframe);\n'
    '    if (!data) return 0;\n'
    '\n'
    '    *out_channels = channels;\n'
    '    *out_rate     = rate;\n'
    '\n'
    '    switch (format) {\n'
    '        case AF_FORMAT_FLOAT:\n'
    '            memcpy(dst, data[0], total * sizeof(float));\n'
    '            return total;\n'
    '        case AF_FORMAT_FLOATP: {\n'
    '            float **p = (float **)data;\n'
    '            for (int s = 0; s < samples; s++)\n'
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
    '            for (int s = 0; s < samples; s++)\n'
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
    '            for (int s = 0; s < samples; s++)\n'
    '                for (int c = 0; c < channels; c++)\n'
    '                    dst[s * channels + c] = (float)p[c][s] * scale;\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_S64: {\n'
    '            const int64_t *p = (const int64_t *)data[0];\n'
    '            const float scale = 1.0842021724855044e-19f;\n'
    '            for (size_t i = 0; i < total; i++)\n'
    '                dst[i] = (float)p[i] * scale;\n'
    '            return total;\n'
    '        }\n'
    '        case AF_FORMAT_S64P: {\n'
    '            int64_t **p = (int64_t **)data;\n'
    '            const float scale = 1.0842021724855044e-19f;\n'
    '            for (int s = 0; s < samples; s++)\n'
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
    '            for (int s = 0; s < samples; s++)\n'
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
    '            for (int s = 0; s < samples; s++)\n'
    '                for (int c = 0; c < channels; c++)\n'
    '                    dst[s * channels + c] = (float)p[c][s];\n'
    '            return total;\n'
    '        }\n'
    '        default:\n'
    '            return 0;\n'
    '    }\n'
    '}\n'
    '\n'
    '/* ' + MARKER + ' ─── pre-DSP waveform fold from the af chain\n'
    ' * "in" filter (PRE side). Converts + mono-downmixes the SOURCE frame\n'
    ' * (pre volume / ReplayGain / EQ — those run later on the AO thread)\n'
    ' * and folds it into the progressive waveform envelope, per-bin by PTS.\n'
    ' * Only fires for the "in" filter and only while a progressive analysis\n'
    ' * is active; for every other filter / state it is one strcmp + one\n'
    ' * atomic load. Single-threaded core path — reuses g_tap.scratch\n'
    ' * sequentially with mak_tap_write (never concurrently). */\n'
    'void mak_waveform_tap_in(const char *name, struct mp_aframe *aframe)\n'
    '{\n'
    '    if (!name || !aframe) return;\n'
    '    if (strcmp(name, "in") != 0) return;\n'
    '    if (!mak_waveform_wants_frames()) return;\n'
    '    int gen = mak_waveform_current_gen();\n'
    '    int channels = 0, rate = 0;\n'
    '    size_t produced = convert_aframe(aframe, g_tap.scratch,\n'
    '                                     TAP_SCRATCH_FLOATS,\n'
    '                                     &channels, &rate);\n'
    '    if (produced == 0 || channels <= 0 || rate <= 0) return;\n'
    '    int n = (int)(produced / (size_t)channels);\n'
    '    if (n <= 0) return;\n'
    '    /* Mono downmix into a process-static buffer (single-threaded core\n'
    '     * path; n <= TAP_SCRATCH_FLOATS since produced == n * channels). */\n'
    '    static float mono[TAP_SCRATCH_FLOATS];\n'
    '    mak_downmix_mono(g_tap.scratch, n, channels, mono);\n'
    '    mak_waveform_fold_samples(mono, n, mp_aframe_get_pts(aframe),\n'
    '                              rate, gen);\n'
    '}\n'
    '\n'
    'void mak_tap_write(const char *name, bool is_post,\n'
    '                   struct mp_aframe *aframe)\n'
    '{\n'
    '    if (!name || !aframe) return;\n'
    '\n'
    '    /* Lock-free probe — early-exit when the label is not in\n'
    '     * the active set (zero atomic-load cost when nothing is\n'
    '     * being tapped, which is the steady-state). */\n'
    '    int idx = find_slot(name);\n'
    '    if (idx < 0) return;\n'
    '    struct tap_ring *ring = is_post ? &g_tap.slots[idx].post\n'
    '                                    : &g_tap.slots[idx].pre;\n'
    '\n'
    '    /* Convert the aframe into the per-process scratch. The\n'
    '     * audio chain is single-threaded so concurrent writers\n'
    '     * cannot collide here, and we do this OUTSIDE the seqlock\n'
    '     * critical section so the conversion (which dominates the\n'
    '     * write cost) does not delay any concurrent reader. */\n'
    '    int channels = 0, rate = 0;\n'
    '    size_t produced = convert_aframe(aframe, g_tap.scratch,\n'
    '                                     TAP_SCRATCH_FLOATS,\n'
    '                                     &channels, &rate);\n'
    '    if (produced == 0 || channels <= 0 || rate <= 0) return;\n'
    '\n'
    '    /* PTS extraction (also outside seqlock — pure read of frame\n'
    '     * metadata). */\n'
    '    int frame_size   = mp_aframe_get_size(aframe);\n'
    '    double frame_pts = mp_aframe_get_pts(aframe);\n'
    '\n'
    '    /* SEQLOCK BEGIN — increment to odd, signalling readers to\n'
    '     * retry. Release ordering ensures all subsequent ring\n'
    '     * writes are observed AFTER this transition. */\n'
    '    uint_fast32_t s = atomic_load_explicit(&ring->seq,\n'
    '                                            memory_order_relaxed);\n'
    '    atomic_store_explicit(&ring->seq, s + 1, memory_order_release);\n'
    '\n'
    '    /* First-write allocation. The buf is sized once on the first\n'
    '     * format we see and STAYS that size for the slot\'s lifetime.\n'
    '     * Subsequent format changes (different file, different rate /\n'
    '     * channels) reuse the same buffer — only the metadata resets.\n'
    '     *\n'
    '     * This is the canonical real-time-safe pattern: allocate\n'
    '     * exactly once, never free during operation, never realloc\n'
    '     * after the seqlock could be observed by a reader. A free +\n'
    '     * realloc inside the seqlock would race the reader\'s memcpy:\n'
    '     * the reader\'s seq retry catches torn DATA but not a torn\n'
    '     * POINTER — by the time the reader\'s seq mismatch tells it to\n'
    '     * abort, its memcpy has already touched freed memory.\n'
    '     *\n'
    '     * Side effect: if the first format is, say, 48 kHz stereo\n'
    '     * (1.15 MB for 3 s) and the user later opens a 384 kHz file,\n'
    '     * coverage shrinks from 3 s to ~96 ms. The soft fallback in\n'
    '     * build_ring_node degrades to "latest available window"; the\n'
    '     * visualiser keeps refreshing, just without strict PTS\n'
    '     * alignment for the few-frame chain pre-buffer phase — same\n'
    '     * trade-off VLC / JUCE / Voxengo accept. Reverse case (high\n'
    '     * rate first, low rate later) gives extra headroom for free. */\n'
    '    /* First-write allocation. Sized once based on the FIRST format\n'
    '     * we see, capped at TAP_MAX_RING_BYTES. Buf pointer +\n'
    '     * alloc_bytes are immutable for the rest of the slot\'s life. */\n'
    '    if (ring->buf == NULL) {\n'
    '        size_t frame_bytes = (size_t)channels * sizeof(float);\n'
    '        size_t needed =\n'
    '            (size_t)((double)TAP_BUFFER_SECONDS *\n'
    '                     (double)rate *\n'
    '                     (double)frame_bytes);\n'
    '        if (needed > TAP_MAX_RING_BYTES) needed = TAP_MAX_RING_BYTES;\n'
    '        if (needed < frame_bytes) needed = frame_bytes;\n'
    '\n'
    '        ring->buf = talloc_size(NULL, needed);\n'
    '        ring->alloc_bytes = ring->buf ? needed : 0;\n'
    '    }\n'
    '\n'
    '    /* Format change (or first frame): reset metadata + recompute\n'
    '     * the frame-aligned wrap budget against the immutable\n'
    '     * alloc_bytes. The buf pointer is untouched — only metadata\n'
    '     * changes — so no UAF window opens for the reader. */\n'
    '    if (ring->channels != channels || ring->sample_rate != rate) {\n'
    '        size_t frame_bytes = (size_t)channels * sizeof(float);\n'
    '        size_t cap = (ring->alloc_bytes / frame_bytes) * frame_bytes;\n'
    '        if (cap == 0) cap = frame_bytes;\n'
    '        ring->capacity     = cap;\n'
    '        ring->valid_bytes  = 0;\n'
    '        ring->write_pos    = 0;\n'
    '        ring->channels     = channels;\n'
    '        ring->sample_rate  = rate;\n'
    '        ring->end_pts_secs = NAN;\n'
    '    }\n'
    '\n'
    '    if (ring->buf == NULL || ring->capacity == 0) {\n'
    '        /* Allocation failed — close the seqlock cleanly and bail.\n'
    '         * Reader will see valid_bytes==0 and report no data. */\n'
    '        atomic_store_explicit(&ring->seq, s + 2, memory_order_release);\n'
    '        return;\n'
    '    }\n'
    '\n'
    '    /* Append to the ring with wrap. */\n'
    '    size_t bytes = produced * sizeof(float);\n'
    '    if (bytes > ring->capacity) bytes = ring->capacity;\n'
    '    const uint8_t *src = (const uint8_t *)g_tap.scratch;\n'
    '    size_t remaining = bytes;\n'
    '    while (remaining > 0) {\n'
    '        size_t free_until_end = ring->capacity - ring->write_pos;\n'
    '        size_t copy = remaining < free_until_end ? remaining\n'
    '                                                 : free_until_end;\n'
    '        memcpy(&ring->buf[ring->write_pos], src, copy);\n'
    '        ring->write_pos = (ring->write_pos + copy) % ring->capacity;\n'
    '        src += copy;\n'
    '        remaining -= copy;\n'
    '    }\n'
    '    ring->valid_bytes += bytes;\n'
    '    if (ring->valid_bytes > ring->capacity)\n'
    '        ring->valid_bytes = ring->capacity;\n'
    '\n'
    '    /* Advance the playback-PTS coordinate of the ring tail. */\n'
    '    if (frame_pts > -1e18 && frame_size > 0 && rate > 0) {\n'
    '        ring->end_pts_secs =\n'
    '            frame_pts + (double)frame_size / (double)rate;\n'
    '    } else if (!isnan(ring->end_pts_secs) &&\n'
    '               rate > 0 && frame_size > 0) {\n'
    '        ring->end_pts_secs += (double)frame_size / (double)rate;\n'
    '    }\n'
    '\n'
    '    /* SEQLOCK END — increment to even, ring is stable again. */\n'
    '    atomic_store_explicit(&ring->seq, s + 2, memory_order_release);\n'
    '}\n'
    '\n'
    '/* Build a {sample_rate, channels, pts_ns, samples} map for `ring`,\n'
    ' * returning the slice of samples that ENDS at `target_pts_secs`.\n'
    ' * When `target_pts_secs` is NaN we fall back to the latest\n'
    ' * window.\n'
    ' *\n'
    ' * SPSC-seqlock retry: snapshots the ring fields + memcpy-s the\n'
    ' * slice in one atomic pass. If the writer interrupts (seq goes\n'
    ' * odd), retries up to TAP_SEQLOCK_MAX_RETRIES. The byte_array\'s\n'
    ' * data buffer is talloc\'d once and overwritten on retries — no\n'
    ' * leak (talloc reuses the slot). */\n'
    'static void build_ring_node(struct mpv_node *out, void *parent_list,\n'
    '                            struct tap_ring *ring,\n'
    '                            double target_pts_secs)\n'
    '{\n'
    '    struct mpv_node_list *map =\n'
    '        talloc_zero(parent_list, struct mpv_node_list);\n'
    '    map->num    = 5;\n'
    '    map->keys   = talloc_array(map, char *, 5);\n'
    '    map->values = talloc_array(map, struct mpv_node, 5);\n'
    '\n'
    '    /* Allocate the byte_array up-front at the maximum window\n'
    '     * size; we shrink ba->size below if the ring has less. */\n'
    '    struct mpv_byte_array *ba =\n'
    '        talloc_zero(map, struct mpv_byte_array);\n'
    '    size_t max_bytes =\n'
    '        (size_t)MAK_TAP_MAX_SAMPLES * TAP_MAX_CHANNELS * sizeof(float);\n'
    '    ba->data = talloc_size(ba, max_bytes);\n'
    '\n'
    '    int     rate      = 0;\n'
    '    int     channels  = 0;\n'
    '    int64_t pts_ns    = 0;\n'
    '    size_t  bytes     = 0;\n'
    '    bool    have_data = false;\n'
    '    /* Write generation = the validated even seq of the snapshot. The\n'
    '     * writer bumps seq by 2 per completed write and never resets it,\n'
    '     * so an unchanged seq across polls means identical ring contents.\n'
    '     * Exposed so the Dart poll loop can skip redundant dispatches\n'
    '     * during pause / EOF. Read inside the seqlock validation, so it\n'
    '     * is inherently consistent with the data — no extra tearing. */\n'
    '    uint_fast32_t gen = 0;\n'
    '\n'
    '    /* Seqlock snapshot loop. Reader spins while writer holds the\n'
    '     * seqlock open (odd seq). Retries if the writer raced through\n'
    '     * the entire critical section while we were copying. */\n'
    '    int retries = 0;\n'
    '    while (retries++ < TAP_SEQLOCK_MAX_RETRIES) {\n'
    '        uint_fast32_t s1 = atomic_load_explicit(&ring->seq,\n'
    '                                                memory_order_acquire);\n'
    '        if (s1 & 1u) continue;            /* writer in progress */\n'
    '\n'
    '        /* Snapshot all metadata + compute slice geometry. The\n'
    '         * buf pointer is immutable after first allocation (only\n'
    '         * the writer ever sets it, and only once), so the\n'
    '         * snapshot can never see a torn buf. The capacity field\n'
    '         * IS mutated by the writer on format change and is\n'
    '         * therefore inside the seqlock-protected snapshot — the\n'
    '         * seq mismatch check below forces a retry if the writer\n'
    '         * ran a format change between our two seq reads. */\n'
    '        rate     = ring->sample_rate;\n'
    '        channels = ring->channels;\n'
    '        size_t write_pos   = ring->write_pos;\n'
    '        size_t valid_bytes = ring->valid_bytes;\n'
    '        size_t capacity    = ring->capacity;\n'
    '        uint8_t *buf       = ring->buf;\n'
    '        double end_pts     = ring->end_pts_secs;\n'
    '\n'
    '        if (rate <= 0 || channels <= 0 || valid_bytes == 0 ||\n'
    '            capacity == 0 || buf == NULL)\n'
    '        {\n'
    '            /* Empty ring → still need to confirm the read was\n'
    '             * not interrupted before declaring "no data". */\n'
    '            uint_fast32_t s2 = atomic_load_explicit(\n'
    '                &ring->seq, memory_order_acquire);\n'
    '            if (s1 == s2) { have_data = false; gen = s1; break; }\n'
    '            continue;\n'
    '        }\n'
    '\n'
    '        size_t frame_bytes  = (size_t)channels * sizeof(float);\n'
    '        size_t window_bytes =\n'
    '            (size_t)MAK_TAP_MAX_SAMPLES * frame_bytes;\n'
    '        if (window_bytes > valid_bytes) window_bytes = valid_bytes;\n'
    '\n'
    '        double delta_secs = 0.0;\n'
    '        if (!isnan(target_pts_secs) && !isnan(end_pts))\n'
    '            delta_secs = end_pts - target_pts_secs;\n'
    '        if (delta_secs < 0) delta_secs = 0;\n'
    '\n'
    '        size_t delta_bytes_unaligned =\n'
    '            (size_t)(delta_secs * rate * (double)frame_bytes);\n'
    '        size_t delta_bytes =\n'
    '            (delta_bytes_unaligned / frame_bytes) * frame_bytes;\n'
    '        /* Soft fallback: if the requested PTS-aligned slice falls\n'
    '         * outside the ring\'s coverage (only possible at the\n'
    '         * TAP_MAX_RING_BYTES cap, on extreme hi-res), degrade to\n'
    '         * "latest available window" rather than freezing on stale\n'
    '         * data or returning empty. Same behaviour as VLC visual.c,\n'
    '         * JUCE AudioVisualiserComponent, Voxengo SPAN. The visual\n'
    '         * effect is a brief constant lead during the chain pre-\n'
    '         * buffer phase, fully resolved within one paint as the AO\n'
    '         * catches up to the chain. */\n'
    '        if (delta_bytes + window_bytes > valid_bytes) {\n'
    '            delta_bytes = 0;\n'
    '        }\n'
    '\n'
    '        size_t end_byte =\n'
    '            (write_pos + capacity - delta_bytes) % capacity;\n'
    '        size_t start =\n'
    '            (end_byte + capacity - window_bytes) % capacity;\n'
    '\n'
    '        /* Copy the slice. If the writer wraps in here, the seq\n'
    '         * check below catches it and we retry. */\n'
    '        if (start + window_bytes <= capacity) {\n'
    '            memcpy(ba->data, &buf[start], window_bytes);\n'
    '        } else {\n'
    '            size_t first = capacity - start;\n'
    '            memcpy(ba->data, &buf[start], first);\n'
    '            memcpy((char *)ba->data + first, &buf[0],\n'
    '                   window_bytes - first);\n'
    '        }\n'
    '\n'
    '        /* Validate the snapshot — if the writer touched the ring\n'
    '         * any time during the snapshot, retry. */\n'
    '        uint_fast32_t s2 = atomic_load_explicit(&ring->seq,\n'
    '                                                memory_order_acquire);\n'
    '        if (s1 == s2) {\n'
    '            bytes = window_bytes;\n'
    '            if (!isnan(end_pts)) {\n'
    '                double slice_end_secs = end_pts -\n'
    '                    ((double)delta_bytes / (double)frame_bytes /\n'
    '                     (double)rate);\n'
    '                pts_ns = (int64_t)(slice_end_secs * 1e9);\n'
    '            }\n'
    '            have_data = true;\n'
    '            gen = s1;\n'
    '            break;\n'
    '        }\n'
    '        /* else loop and retry — typical contention is ≤ 1 retry. */\n'
    '    }\n'
    '\n'
    '    map->keys[0] = talloc_strdup(map, "sample_rate");\n'
    '    map->values[0] = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_INT64, .u.int64 = rate};\n'
    '    map->keys[1] = talloc_strdup(map, "channels");\n'
    '    map->values[1] = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_INT64, .u.int64 = channels};\n'
    '    map->keys[2] = talloc_strdup(map, "pts_ns");\n'
    '    map->values[2] = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_INT64, .u.int64 = pts_ns};\n'
    '\n'
    '    ba->size = have_data ? bytes : 0;\n'
    '    map->keys[3] = talloc_strdup(map, "samples");\n'
    '    map->values[3] = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_BYTE_ARRAY, .u.ba = ba};\n'
    '\n'
    '    map->keys[4] = talloc_strdup(map, "seq");\n'
    '    map->values[4] = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_INT64, .u.int64 = (int64_t)gen};\n'
    '\n'
    '    *out = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_NODE_MAP, .u.list = map};\n'
    '}\n'
    '\n'
    'int mak_tap_read_all(struct mpv_node *out, void *parent,\n'
    '                     double target_pts_secs)\n'
    '{\n'
    '    (void)parent;\n'
    '    if (!out) return -1;\n'
    '\n'
    '    /* Brief activation_lock just to capture a stable snapshot of\n'
    '     * which slots are active + their names. Per-ring data is\n'
    '     * read lock-free below via the seqlock pattern, so a long\n'
    '     * memcpy of audio samples never blocks the audio thread. */\n'
    '    mp_mutex_lock(&g_tap.activation_lock);\n'
    '    int      idx_buf[MAK_TAP_MAX];\n'
    '    char    *name_buf[MAK_TAP_MAX];\n'
    '    int      active_count = 0;\n'
    '    for (int i = 0; i < MAK_TAP_MAX; i++) {\n'
    '        if (!atomic_load_explicit(&g_tap.slots[i].used,\n'
    '                                   memory_order_acquire))\n'
    '            continue;\n'
    '        idx_buf[active_count]  = i;\n'
    '        name_buf[active_count] = strdup(g_tap.slots[i].name);\n'
    '        active_count++;\n'
    '    }\n'
    '    mp_mutex_unlock(&g_tap.activation_lock);\n'
    '\n'
    '    struct mpv_node_list *root =\n'
    '        talloc_zero(NULL, struct mpv_node_list);\n'
    '    root->num    = active_count;\n'
    '    root->keys   = talloc_array(root, char *, active_count);\n'
    '    root->values = talloc_array(root, struct mpv_node, active_count);\n'
    '\n'
    '    for (int j = 0; j < active_count; j++) {\n'
    '        int i = idx_buf[j];\n'
    '        root->keys[j] = talloc_strdup(root, name_buf[j]);\n'
    '        free(name_buf[j]);\n'
    '\n'
    '        struct mpv_node_list *sides =\n'
    '            talloc_zero(root, struct mpv_node_list);\n'
    '        sides->num    = 2;\n'
    '        sides->keys   = talloc_array(sides, char *, 2);\n'
    '        sides->values = talloc_array(sides, struct mpv_node, 2);\n'
    '        sides->keys[0] = talloc_strdup(sides, "pre");\n'
    '        build_ring_node(&sides->values[0], sides,\n'
    '                        &g_tap.slots[i].pre, target_pts_secs);\n'
    '        sides->keys[1] = talloc_strdup(sides, "post");\n'
    '        build_ring_node(&sides->values[1], sides,\n'
    '                        &g_tap.slots[i].post, target_pts_secs);\n'
    '        root->values[j] = (struct mpv_node){\n'
    '            .format = MPV_FORMAT_NODE_MAP, .u.list = sides};\n'
    '    }\n'
    '\n'
    '    *out = (struct mpv_node){\n'
    '        .format = MPV_FORMAT_NODE_MAP, .u.list = root};\n'
    '    return 0;\n'
    '}\n'
)


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
