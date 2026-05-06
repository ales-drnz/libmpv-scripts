#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Adds a process-wide bulk waveform analyzer to libmpv.

Problem
=======

A waveform overview needs the *entire* min/max envelope of the track
immediately on file load, not progressively as the audio plays. The
existing `pcm-tap-frame` property only ever exposes the *latest*
~85 ms of post-DSP samples; a wrapper that polls it can build a
progressive envelope as playback advances, but cannot show the
silent / loud regions ahead of the playhead.

This patch ships a separate, libav-direct decode path that runs on a
detached coordinator thread the moment a file finishes loading. The
coordinator probes the source, partitions the bin output across
`MAK_WAVEFORM_WORKERS` worker threads (4 by default), and spawns one
worker per region. Each worker opens its own `AVFormatContext`, seeks
to its assigned `[sample_start, sample_end)` slice, decodes to mono
Float32, and updates a disjoint output slice — no locking on the
decode hot path.

Single-level fixed-resolution envelope
======================================

The output is a single envelope of exactly `MAK_WAVEFORM_BINS` min/max
pairs (2000), or fewer if the track is shorter than that many samples.
This is sized for a single-audio player's overview strip — not a DAW
with deep zoom — so one fixed resolution is enough.

Gating
======

The analyzer is OFF by default. It only runs when the read-write flag
property `waveform-enabled` is set true. `mak_waveform_start()`
self-gates on this flag, so `loadfile.c` can call it unconditionally
on every file-load — it is a cheap no-op while disabled. Enabling the
flag mid-track kicks the analyzer for the already-loaded file.

Performance (Apple Silicon M-series, 5 minutes audio per file,
median of 5 runs, host ffmpeg 8.x):

    file                 single-thread    parallel-4w
    sine FLAC                  ~165 ms          ~46 ms
    complex FLAC               ~175 ms          ~49 ms
    pinknoise FLAC             ~190 ms          ~54 ms
    pinknoise MP3              ~200 ms          ~60 ms

Even single-thread is ~1500x realtime; parallel-4w is ~5000-6500x.

Threading
=========

One coordinator + N workers. Coordinator owns the per-track
`AVCodecParameters` snapshot, the global min/max bin arrays, and the
join point for the workers. Workers write to disjoint slices of those
arrays (no overlap by construction → no mutex on the hot path). Final
commit to the visible `g_wave` state is done by the coordinator under
`g_wave.lock`, only if the generation is still current.

Cancellation
============

Detached coordinator (never joined). Each `start()` bumps a global
generation counter; coordinator and workers carry their own gen and:
  - exit early on the next 1024-sample boundary if their gen != the
    current one,
  - refuse to commit the final result if their gen is stale.

This avoids blocking the mpv main thread on a still-decoding analysis
during a track-change boundary.

Two strategies, one property
============================

The coordinator probes the source with libav and picks the strategy
automatically (no URL-scheme heuristic, no caller hint), exposing the
result through the single `waveform-data` property so the wrapper never
has to care which path produced the envelope:

  * **Complete, seekable file** (local OR an HTTP byte-range file such as
    a Plex/Jellyfin direct-play part): the bulk path. Workers seek to
    disjoint regions and the full envelope lands at once (state `ready`).
    Local files fan out to all workers; an HTTP file uses ONE worker —
    re-opening a signed / connection-capped URL N times can throttle or
    desync, so a single sequential reader is the safe choice.

  * **Adaptive / live source** (DASH/HLS — a Plex/Jellyfin transcode —
    or any non-seekable stream): PROGRESSIVE. The bulk path is invalid
    (no complete file to seek). Detected from the libav demuxer NAME
    (DASH/HLS report "seekable" within segments, so the name is the
    reliable discriminator) plus `AVFMTCTX_UNSEEKABLE` / a non-seekable
    AVIO. We lay out a fixed bin axis from mpv's duration and grow it
    bin-by-bin from playback: the af chain "in" filter (PRE side) folds
    each PRE-DSP frame into the envelope per-bin by PTS (state
    `progressive`). See `mak_waveform_fold_samples` and
    `patch_filter_label_tap.py` → `mak_waveform_tap_in`.

  * **Unknown duration** (true live): no fixed `[0, total]` axis exists, so
    state `rolling` — a sliding window of ABSOLUTE media-time bins, grown by
    the same af-tap fold and retained in lockstep with the demuxer's seekable
    cache (state `rolling`, `range_start_us`/`range_end_us` give the absolute
    span; bins older than the cache begin are evicted, never before). See
    `arm_rolling` + `mak_waveform_update_cache_range`.

The progressive path taps the af chain directly, so there is no link-time
dependency on `patch_pcm_tap.py` (which now serves only the visualizer).

Multi-Player note
=================

Like `pcm-tap-frame`, the bulk-analysis state is a process-wide
singleton. With more than one Player loaded into the same process the
LAST `loadfile` wins; every Player sees the same `waveform-data` until
the next track-change. Pragmatic — the typical app runs one Player —
and matches the existing tap's concurrency model.

Files patched
=============

    audio/mak_waveform.h   NEW — public API
    audio/mak_waveform.c   NEW — coordinator + workers + property reader
    player/loadfile.c      kicks `mak_waveform_start` after FILE_LOADED
    player/command.c       property registration + getter/setter
    meson.build            new source file added to the build

Usage
=====

    python3 patch_bulk_analysis.py <mpv_source_dir>

Composes with `patch_pcm_tap.py`, `patch_audio_output_state.py`,
`patch_embedded_cover_art.py`, `patch_prefetch_*.py` — disjoint
anchors.
"""
import os
import sys


# Provenance tag stamped into every patched region and generated file so a
# patched mpv tree is easy to grep. This is NOT an idempotency guard: the
# patcher always applies the current patch and assumes a FRESH (git-restored)
# mpv source tree. There is no version skipping and no legacy fallback —
# re-running on an already-patched tree is unsupported (restore first).
MARKER = 'MAK_WAVEFORM_PATCH'

# Fixed bin count for the single-level envelope. Every track produces
# exactly this many min/max pairs, or fewer if the track has fewer
# total samples (bins clamp to min(WAVEFORM_BINS, total_samples)).
# Storage cost per track: 2000 floats × 2 arrays = 16 KB.
WAVEFORM_BINS = 2000

# Worker count for the parallel decode path. 4 gives near-linear
# speedup on local files; beyond that I/O contention starts to hurt.
WAVEFORM_WORKERS = 4


# ─── audio/mak_waveform.h ─────────────────────────────────────────────

WAVEFORM_H = f'''/* {MARKER} ─── public API for the bulk waveform analyzer.
 *
 * The analyzer runs on a detached coordinator thread spawned on
 * MPV_EVENT_FILE_LOADED. The coordinator partitions the source into
 * MAK_WAVEFORM_WORKERS regions, spawns one worker per region, joins
 * them, then commits the result. Cancellation uses a generation
 * counter — every start() bumps it; stale coordinators/workers see
 * their gen != current and self-exit.
 *
 * Output is a single fixed-resolution envelope of up to
 * MAK_WAVEFORM_BINS min/max pairs (fewer for very short tracks).
 *
 * The analyzer is gated: it is OFF by default and only runs while the
 * waveform-enabled flag is set. mak_waveform_start() self-gates, so
 * the loadfile hook can call it unconditionally. */
#ifndef MP_AUDIO_MAK_WAVEFORM_H_
#define MP_AUDIO_MAK_WAVEFORM_H_

#include <stdbool.h>
#include <stddef.h>

struct mpv_node;

#define MAK_WAVEFORM_BINS    {WAVEFORM_BINS}
#define MAK_WAVEFORM_WORKERS {WAVEFORM_WORKERS}

/* Begin analysis for the just-loaded file. No-op if the analyzer is
 * disabled or [url] is null/empty. Bumps the generation counter so any
 * in-flight coordinator/workers self-cancel.
 *
 * Classification uses what mpv ALREADY knows (passed in by the caller) so a
 * network adaptive source is never re-opened here. Re-opening a Jellyfin/Plex
 * HLS transcode would be a second concurrent open of the same live transcode:
 * the server kills+restarts it on each init-segment request, so the probe and
 * the player's own open kill each other → HTTP 500 → no waveform + desync.
 * Strategy:
 *   - **network + adaptive** ([format_name] hls/dash/applehttp) OR
 *     **network + non-seekable**: arm PROGRESSIVE ([duration_secs] > 0) or
 *     ROLLING (unknown) DIRECTLY — grown from playback by the af-tap, NO
 *     second open of [url].
 *   - **everything else** (local file, or a seekable HTTP byte-range part —
 *     e.g. a Plex/Jellyfin DIRECT-PLAY original file): hand to the coordinator,
 *     which probes [url] with libav and BULK-decodes a complete seekable file
 *     up-front (re-opening a local/static file is harmless — no transcode to
 *     kill). A *local* adaptive source (local .m3u8) still goes progressive via
 *     the coordinator's own probe.
 *
 * [format_name] is the lavf format name (mpv's `demuxer->filetype`, e.g.
 * "hls" / "flac"; may be NULL). [is_network] / [seekable] come straight from
 * mpv's demuxer. The coordinator takes its own copy of the URL. */
void mak_waveform_start(const char *url, double duration_secs,
                        const char *format_name, bool is_network,
                        bool seekable);

/* Whether a PROGRESSIVE analysis is live and wants per-frame folds from
 * the af-tap dispatcher (checked once per input frame). */
bool mak_waveform_wants_frames(void);

/* Live generation: the af-tap captures it and passes it back to
 * mak_waveform_fold_samples so a frame from a torn-down chain (the
 * previous track) is dropped instead of folded into the new envelope. */
int mak_waveform_current_gen(void);

/* Fold [n] mono Float32 samples (already converted + downmixed by the
 * af-tap dispatcher) into the PROGRESSIVE envelope at media time
 * [pts_secs]; [rate] is the frame's sample rate. Pre-DSP, per-bin via the
 * shared kernel — same mapping as the bulk path. No-op unless [gen] is
 * still the live generation. Runs on the core thread (the filter chain),
 * never the AO hot path. */
void mak_waveform_fold_samples(const float *mono, int n, double pts_secs,
                               int rate, int gen);

/* Evict the ROLLING (live) window in lockstep with the demuxer's seekable
 * cache: [begin_secs, end_secs] is the cached range (negative = unknown).
 * Drops only bins older than begin (no longer seekable) and records the
 * absolute span surfaced through waveform-data. No-op outside ROLLING mode.
 * No start-time rebase is needed: mpv applies its ts_offset to the demuxer
 * output, so these cache times, the af-tap frame PTS, and time-pos already
 * share one timeline. Called from the property getter at the poll cadence. */
void mak_waveform_update_cache_range(double begin_secs, double end_secs);

/* Bumps the generation counter, signalling any in-flight coordinator
 * to bail. Idempotent. */
void mak_waveform_stop(void);

/* Enable / disable the analyzer. Disabling also stops any in-flight
 * analysis. Enabling does NOT itself kick a decode — the caller is
 * responsible for calling mak_waveform_start() for the loaded file. */
void mak_waveform_set_enabled(bool on);

/* Whether the analyzer is currently enabled. */
bool mak_waveform_is_enabled(void);

/* Builds an MPV_FORMAT_NODE_MAP describing the current bulk-
 * analysis state (idle / decoding / ready / failed). When ready,
 * the map carries the per-bin "min" and "max" Float32 byte arrays.
 * The caller hands the resulting node to the property machinery
 * which frees the talloc tree. Always returns 0. */
int mak_waveform_read(struct mpv_node *out, void *parent);

#endif
'''


# ─── audio/mak_wave_fold.h ────────────────────────────────────────────
# Single source of truth for the min/max-per-bin math, shared by BOTH the
# bulk worker decode (mak_waveform.c process path) and the progressive
# pre-DSP frame fold. Header-only static inline so both compile the SAME
# code with no extra translation unit / meson anchor. Plain string (not an
# f-string) so the C braces need no escaping; the literal tag below just
# matches the MARKER provenance stamp used in the other generated files.
WAVE_FOLD_H = '''/* MAK_WAVEFORM_PATCH ─── shared min/max-per-bin kernel.
 *
 * Used by the bulk parallel decode AND the progressive pre-DSP fold, so
 * the two envelopes are produced by identical math (same downmix, same
 * bin mapping, same seed/widen rule) and converge bin-for-bin over the
 * region both have seen. No state — pure helpers, safe from any thread.
 */
#ifndef MP_AUDIO_MAK_WAVE_FOLD_H_
#define MP_AUDIO_MAK_WAVE_FOLD_H_

#include <stdint.h>
#include <stddef.h>

/* Fold sample [s] into one bin's cells. First touch seeds min==max==s and
 * marks the bin filled; later touches only widen. [bfilled] lets a reader
 * tell "not yet seen" (0) from "seen, and silent" (1, min~=max~=0) — the
 * progressive path needs this so unplayed bins aren't drawn as real zeros. */
static inline void mak_fold_bin(float s, float *bmin, float *bmax,
                                uint8_t *bfilled)
{
    if (!*bfilled) {
        *bmin = s;
        *bmax = s;
        *bfilled = 1;
    } else {
        if (s < *bmin) *bmin = s;
        if (s > *bmax) *bmax = s;
    }
}

/* Canonical absolute-sample -> bin mapping. Identical denominator for both
 * paths (total_samples derived once from the container), so a given sample
 * lands in the same bin regardless of who folds it. Clamped to [0,bins). */
static inline int64_t mak_sample_to_bin(int64_t abs_sample, int bins,
                                        int64_t total_samples)
{
    if (total_samples <= 0 || bins <= 0)
        return 0;
    int64_t b = abs_sample * (int64_t)bins / total_samples;
    if (b < 0)
        b = 0;
    if (b >= bins)
        b = bins - 1;
    return b;
}

/* Average-downmix [n_per_ch] frames of INTERLEAVED float ([ch] channels)
 * into mono [dst]. Conversion to interleaved float is the caller's job
 * (bulk via swresample, progressive via the af-tap convert path) — this
 * is only the channel fold, so both paths get the exact same mono signal. */
static inline void mak_downmix_mono(const float *interleaved, int n_per_ch,
                                    int ch, float *dst)
{
    if (ch <= 1) {
        for (int i = 0; i < n_per_ch; i++)
            dst[i] = interleaved[i];
        return;
    }
    const float inv = 1.0f / (float)ch;
    for (int i = 0; i < n_per_ch; i++) {
        const float *base = interleaved + (size_t)i * ch;
        float acc = 0.0f;
        for (int c = 0; c < ch; c++)
            acc += base[c];
        dst[i] = acc * inv;
    }
}

#endif
'''


# ─── audio/mak_waveform.c ─────────────────────────────────────────────

WAVEFORM_C = f'''/* {MARKER} ─── bulk waveform analyzer.
 *
 * Spawns a coordinator on every mak_waveform_start() (when enabled).
 * The coordinator probes the source URL, computes the bin count for
 * the single fixed-resolution envelope, partitions the bin range
 * across MAK_WAVEFORM_WORKERS worker threads on disjoint sample
 * regions, and joins them before committing the final result. Each
 * worker opens its own AVFormatContext, seeks to its region, decodes
 * to mono Float32, and writes into its dedicated bin slice — no
 * locking on the decode hot path. See patch_bulk_analysis.py in the
 * wrapper repo for benchmark numbers and the rationale behind the
 * design. */
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#include "mpv_talloc.h"
#include "osdep/threads.h"
#include <mpv/client.h>

#include "audio/mak_waveform.h"
#include "audio/mak_wave_fold.h"

/* States surfaced through the property — match the C string exactly
 * with the Dart-side enum. */
enum mak_wave_state {{
    MAK_WAVE_IDLE        = 0,
    MAK_WAVE_DECODING    = 1,
    MAK_WAVE_READY       = 2,
    MAK_WAVE_FAILED      = 3,
    MAK_WAVE_PROGRESSIVE = 4,  /* network: envelope grown from playback */
    MAK_WAVE_ROLLING     = 5,  /* live: cache-aligned sliding window */
}};

static const char *state_string(enum mak_wave_state s)
{{
    switch (s) {{
        case MAK_WAVE_DECODING:    return "decoding";
        case MAK_WAVE_READY:       return "ready";
        case MAK_WAVE_FAILED:      return "failed";
        case MAK_WAVE_PROGRESSIVE: return "progressive";
        case MAK_WAVE_ROLLING:     return "rolling";
        case MAK_WAVE_IDLE:
        default:                   return "idle";
    }}
}}

/* Master gate. OFF by default — the analyzer does nothing until a
 * waveform-enabled set lands. */
static atomic_bool g_enabled = false;

struct mak_wave {{
    mp_mutex lock;
    enum mak_wave_state state;
    int64_t  duration_us;
    int      bins;
    /* High-water mark of filled bins. BULK: trims the flat dead tail left
     * when the duration estimate overshoots (VBR / rounded-duration
     * containers). PROGRESSIVE: the furthest bin playback has reached, so
     * the reader emits only what has been played. 0 = "not computed",
     * reader falls back to bins. */
    int      valid_bins;
    float   *bins_min;
    float   *bins_max;
    /* Per-bin "has a sample yet" flag. Lets the reader expose "filled" so
     * the UI tells unplayed bins (0) from played-but-silent (1). BULK has
     * no per-bin flag (every emitted bin is filled by construction);
     * PROGRESSIVE allocates and grows it as the af-tap folds frames. */
    bool     progressive;
    uint8_t *bins_filled;
    double   duration_secs;
    /* ROLLING (true live, unknown duration): a cache-aligned sliding window.
     * Reuses bins_min/max/filled as a LINEAR buffer where index k holds the
     * absolute bin (roll_base_bin + k); valid_bins is the count held. The
     * base advances only when the demuxer evicts that audio from its
     * back-buffer (see mak_waveform_update_cache_range), so a bin is never
     * dropped while it is still seekable. The absolute media span surfaced to
     * the wrapper for placement + seeking is derived in mak_waveform_read
     * straight from the bin grid (roll_base_bin/roll_lead/valid_bins). */
    bool     rolling;
    int64_t  roll_base_bin;
    double   roll_bin_secs;
    /* Generation: bumped on every start(). A coordinator/worker
     * carries its own gen; if g_wave.current_gen drifts past it,
     * it self-cancels on the next sample-boundary check. */
    atomic_int current_gen;
}};

static struct mak_wave g_wave = {{
    .lock = MP_STATIC_MUTEX_INITIALIZER,
    .state = MAK_WAVE_IDLE,
}};

/* Sample budget per worker cancellation check. 4096 samples is
 * ~85 ms at 48 kHz — short enough that a stale worker exits within
 * ~85 ms of the new file landing. */
#define MAK_WAVE_CANCEL_CHECK_INTERVAL 4096

/* ─── per-worker slice ────────────────────────────────────────────── */

struct worker_chunk {{
    int      my_gen;
    const char *url;             /* shared, owned by coordinator */
    int      audio_idx;
    enum AVCodecID codec_id;
    AVCodecParameters *codecpar; /* shared, used to init each ctx */
    int      sample_rate;
    int64_t  total_samples;
    int64_t  sample_start;       /* inclusive, in source sample-frame units */
    int64_t  sample_end;         /* exclusive */
    int64_t  time_base_num;
    int64_t  time_base_den;
    /* Output slice. total_bins is the global envelope size; the
     * worker writes only [bin_start, bin_end) — disjoint by
     * construction. out_min / out_max point into the coordinator's
     * global arrays. bins_filled has length bin_end - bin_start. */
    int      total_bins;
    int      bin_start;          /* inclusive */
    int      bin_end;            /* exclusive */
    float   *out_min;
    float   *out_max;
    uint8_t *bins_filled;
    int      status;             /* 0 = ok */
}};

/* Bin a chunk of [count] mono Float32 samples into the worker's
 * slice of the envelope. Samples that fall outside [bin_start,
 * bin_end) are skipped. */
static void process_samples(const float *samples, int count,
                            int64_t *emitted, int64_t total_samples,
                            struct worker_chunk *a)
{{
    int64_t e = *emitted;
    for (int i = 0; i < count; i++) {{
        float s = samples[i];
        if (a->total_bins > 0) {{
            int64_t bin_idx = e * a->total_bins / total_samples;
            if (bin_idx >= a->bin_start && bin_idx < a->bin_end) {{
                int local = (int)(bin_idx - a->bin_start);
                if (!a->bins_filled[local]) {{
                    a->out_min[local] = s;
                    a->out_max[local] = s;
                    a->bins_filled[local] = 1;
                }} else {{
                    if (s < a->out_min[local]) a->out_min[local] = s;
                    if (s > a->out_max[local]) a->out_max[local] = s;
                }}
            }}
        }}
        e++;
    }}
    *emitted = e;
}}

/* Forward decl: the per-worker probe reuses the coordinator's generation-abort
 * callback (defined below, just before coordinator_main). */
static int coord_interrupt_cb(void *opaque);

static MP_THREAD_VOID worker_chunk_thread(void *p)
{{
    struct worker_chunk *a = p;
    a->status = -1;

    AVFormatContext *fmt = NULL;
    AVCodecContext  *dec = NULL;
    SwrContext      *swr = NULL;
    AVFrame         *iframe = NULL;
    AVPacket        *pkt = NULL;
    float           *out_buf = NULL;
    int              out_buf_capacity = 0;
    int              ret = 0;
    int              samples_since_check = 0;

    /* Same generation-abort + I/O timeout as the coordinator probe, so a
     * superseded or stalled worker drops its (possibly session-capped) network
     * connection instead of blocking on it. &a->my_gen lives for the worker's
     * whole lifetime (the chunk outlives the thread, joined in the coordinator). */
    fmt = avformat_alloc_context();
    if (!fmt) goto cleanup;
    fmt->interrupt_callback.callback = coord_interrupt_cb;
    fmt->interrupt_callback.opaque   = &a->my_gen;
    AVDictionary *open_opts = NULL;
    av_dict_set(&open_opts, "rw_timeout", "5000000", 0);  /* 5 s (microseconds) */
    av_dict_set(&open_opts, "timeout",    "5000000", 0);  /* 5 s (HTTP/TCP) */
    int open_ret = avformat_open_input(&fmt, a->url, NULL, &open_opts);
    av_dict_free(&open_opts);
    if (open_ret < 0) goto cleanup;
    if (avformat_find_stream_info(fmt, NULL) < 0)          goto cleanup;

    const AVCodec *codec = avcodec_find_decoder(a->codec_id);
    if (!codec) goto cleanup;
    dec = avcodec_alloc_context3(codec);
    if (!dec) goto cleanup;
    if (avcodec_parameters_to_context(dec, a->codecpar) < 0) goto cleanup;
    if (avcodec_open2(dec, codec, NULL) < 0) goto cleanup;

    AVChannelLayout out_layout = AV_CHANNEL_LAYOUT_MONO;
    ret = swr_alloc_set_opts2(&swr,
        &out_layout, AV_SAMPLE_FMT_FLT, a->sample_rate,
        &dec->ch_layout, dec->sample_fmt, a->sample_rate,
        0, NULL);
    if (ret < 0 || !swr) goto cleanup;
    if (swr_init(swr) < 0) goto cleanup;

    iframe = av_frame_alloc();
    pkt    = av_packet_alloc();
    if (!iframe || !pkt) goto cleanup;
    out_buf_capacity = 8192;
    out_buf = av_malloc(out_buf_capacity * sizeof(float));
    if (!out_buf) goto cleanup;

    /* Seek to the assigned region (skipped for the first worker
     * which already starts at sample 0). AV_TIME_BASE units; the
     * BACKWARD flag lands us on the nearest preceding keyframe. */
    if (a->sample_start > 0) {{
        int64_t seek_us = a->sample_start * 1000000 / a->sample_rate;
        if (av_seek_frame(fmt, -1, seek_us, AVSEEK_FLAG_BACKWARD) < 0)
            goto cleanup;
        avcodec_flush_buffers(dec);
    }}

    int64_t emitted_samples = 0;
    int     stream_pos_initialized = 0;

    while (1) {{
        if (atomic_load(&g_wave.current_gen) != a->my_gen) goto cleanup;

        ret = av_read_frame(fmt, pkt);
        if (ret == AVERROR_EOF) break;
        if (ret < 0) goto cleanup;
        if (pkt->stream_index != a->audio_idx) {{
            av_packet_unref(pkt);
            continue;
        }}
        ret = avcodec_send_packet(dec, pkt);
        av_packet_unref(pkt);
        if (ret < 0) continue;

        while (1) {{
            ret = avcodec_receive_frame(dec, iframe);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) goto cleanup;

            /* Compute the absolute source-sample position of this
             * frame from its PTS. After a backward seek the decoder
             * re-emits frames before sample_start; the bin filter
             * inside process_samples drops them. */
            int64_t frame_sample_pos;
            if (iframe->pts != AV_NOPTS_VALUE) {{
                frame_sample_pos = av_rescale(iframe->pts,
                    a->sample_rate * a->time_base_num, a->time_base_den);
            }} else if (!stream_pos_initialized) {{
                frame_sample_pos = a->sample_start;
            }} else {{
                frame_sample_pos = emitted_samples;
            }}
            stream_pos_initialized = 1;

            /* Stop early once the frame starts past our region. */
            if (frame_sample_pos >= a->sample_end) {{
                av_frame_unref(iframe);
                goto done_decode;
            }}

            int needed = swr_get_out_samples(swr, iframe->nb_samples);
            if (needed > out_buf_capacity) {{
                int new_cap = needed + 1024;
                float *grown = av_realloc(out_buf,
                    (size_t)new_cap * sizeof(float));
                if (!grown) {{ av_frame_unref(iframe); goto cleanup; }}
                out_buf = grown;
                out_buf_capacity = new_cap;
            }}
            uint8_t *out_data[1] = {{ (uint8_t *)out_buf }};
            int converted = swr_convert(swr, out_data, out_buf_capacity,
                (const uint8_t **)iframe->data, iframe->nb_samples);
            av_frame_unref(iframe);
            if (converted <= 0) continue;

            /* Initialize emitted_samples to the first frame's
             * absolute position after the seek. */
            if (emitted_samples == 0 && frame_sample_pos > 0)
                emitted_samples = frame_sample_pos;

            process_samples(out_buf, converted,
                            &emitted_samples, a->total_samples, a);

            samples_since_check += converted;
            if (samples_since_check >= MAK_WAVE_CANCEL_CHECK_INTERVAL) {{
                samples_since_check = 0;
                if (atomic_load(&g_wave.current_gen) != a->my_gen)
                    goto cleanup;
            }}
            if (emitted_samples >= a->sample_end) goto done_decode;
        }}
    }}
done_decode:

    a->status = 0;

cleanup:
    if (out_buf)  av_free(out_buf);
    if (pkt)      av_packet_free(&pkt);
    if (iframe)   av_frame_free(&iframe);
    if (swr)      swr_free(&swr);
    if (dec)      avcodec_free_context(&dec);
    if (fmt)      avformat_close_input(&fmt);
    MP_THREAD_RETURN();
}}

/* ─── coordinator ─────────────────────────────────────────────────── */

struct coord_args {{
    char  *url;          /* coordinator takes ownership */
    int    my_gen;
    double duration_secs; /* caller's (mpv's) duration — PROGRESSIVE axis */
}};

static void reset_g_wave_locked(void);

static void worker_publish_state(int my_gen, enum mak_wave_state s)
{{
    mp_mutex_lock(&g_wave.lock);
    if (atomic_load(&g_wave.current_gen) == my_gen)
        g_wave.state = s;
    mp_mutex_unlock(&g_wave.lock);
}}

/* Arm PROGRESSIVE mode: lay out a fixed bin axis from [duration_secs] and
 * let the af-tap grow the envelope from playback (mak_waveform_fold_samples).
 * Used for sources we cannot parallel-decode (DASH/HLS transcode, live,
 * non-seekable). No-op if a newer generation has started. Without a usable
 * duration there is no axis, so the state goes FAILED. */
static void arm_progressive(int my_gen, double duration_secs)
{{
    int pbins = duration_secs > 0 ? (int)(duration_secs / 0.04) : 0;
    if (pbins > MAK_WAVEFORM_BINS) pbins = MAK_WAVEFORM_BINS;
    mp_mutex_lock(&g_wave.lock);
    if (atomic_load(&g_wave.current_gen) != my_gen) {{
        mp_mutex_unlock(&g_wave.lock);
        return;
    }}
    reset_g_wave_locked();
    if (pbins >= 1) {{
        float   *pmin = av_calloc(pbins, sizeof(float));
        float   *pmax = av_calloc(pbins, sizeof(float));
        uint8_t *pfil = av_calloc(pbins, sizeof(uint8_t));
        if (pmin && pmax && pfil) {{
            g_wave.bins          = pbins;
            g_wave.valid_bins    = 0;  /* grows via fold high-water */
            g_wave.bins_min      = pmin;
            g_wave.bins_max      = pmax;
            g_wave.bins_filled   = pfil;
            g_wave.duration_secs = duration_secs;
            g_wave.duration_us   = (int64_t)(duration_secs * 1e6);
            g_wave.progressive   = true;
            g_wave.state         = MAK_WAVE_PROGRESSIVE;
        }} else {{
            if (pmin) av_free(pmin);
            if (pmax) av_free(pmax);
            if (pfil) av_free(pfil);
            g_wave.state = MAK_WAVE_FAILED;
        }}
    }} else {{
        g_wave.state = MAK_WAVE_FAILED;
    }}
    mp_mutex_unlock(&g_wave.lock);
}}

/* Fixed bin width for the ROLLING (live) window — 40 ms, matching the
 * progressive cadence. MAK_WAVE_ROLL_BIN_US is that same width as an exact
 * integer so the surfaced axis carries no float drift.
 *
 * Cache-driven eviction (mak_waveform_update_cache_range) is the normal way
 * bins leave the window; MAK_WAVE_ROLL_BINS is only a memory backstop against
 * a pathologically large demuxer back-buffer. 131072 bins × 40 ms ≈ 87 min
 * (~1.2 MB across the three arrays) — comfortably past mpv's default 125 MiB
 * back-buffer at typical audio bitrates, so eviction fires first and never
 * drops a still-seekable bin. If the back-buffer is enlarged far beyond that
 * AND the user scrolls past the cap, the oldest bins are dropped silently
 * (graceful: the absolute axis stays consistent). Raise this to cover a
 * deliberately huge back-buffer. */
#define MAK_WAVE_ROLL_BIN_SECS 0.04
#define MAK_WAVE_ROLL_BIN_US   40000   /* 0.04 s, exact — no float rounding */
#define MAK_WAVE_ROLL_BINS     131072

/* Arm ROLLING mode for a true-live source (unknown duration). Unlike
 * PROGRESSIVE — which lays a fixed axis over a known total — this keeps a
 * sliding window of ABSOLUTE media-time bins, retained in lockstep with the
 * demuxer's seekable cache (mak_waveform_update_cache_range). The af-tap
 * grows it via mak_waveform_fold_samples, exactly as progressive does. */
static void arm_rolling(int my_gen)
{{
    mp_mutex_lock(&g_wave.lock);
    if (atomic_load(&g_wave.current_gen) != my_gen) {{
        mp_mutex_unlock(&g_wave.lock);
        return;
    }}
    reset_g_wave_locked();
    const int cap = MAK_WAVE_ROLL_BINS;
    float   *pmin = av_calloc(cap, sizeof(float));
    float   *pmax = av_calloc(cap, sizeof(float));
    uint8_t *pfil = av_calloc(cap, sizeof(uint8_t));
    if (pmin && pmax && pfil) {{
        g_wave.bins           = cap;
        g_wave.valid_bins     = 0;
        g_wave.bins_min       = pmin;
        g_wave.bins_max       = pmax;
        g_wave.bins_filled    = pfil;
        g_wave.progressive    = true;   /* shares the af-tap fold path */
        g_wave.rolling        = true;
        g_wave.roll_base_bin  = 0;
        g_wave.roll_bin_secs  = MAK_WAVE_ROLL_BIN_SECS;
        g_wave.duration_secs  = 0;
        g_wave.duration_us    = 0;
        g_wave.state          = MAK_WAVE_ROLLING;
    }} else {{
        if (pmin) av_free(pmin);
        if (pmax) av_free(pmax);
        if (pfil) av_free(pfil);
        g_wave.state = MAK_WAVE_FAILED;
    }}
    mp_mutex_unlock(&g_wave.lock);
}}

/* Evict the rolling window in lockstep with the demuxer's seekable cache:
 * [begin_secs, end_secs] is the cached range (negative = unknown). Drops
 * only bins older than begin (which are no longer seekable), so nothing
 * still reachable by a backward seek is forgotten. Records the absolute
 * span for the reader. No-op outside ROLLING mode. Runs on the core thread
 * from the property getter, at the wrapper's poll cadence. */
void mak_waveform_update_cache_range(double begin_secs, double end_secs)
{{
    mp_mutex_lock(&g_wave.lock);
    if (g_wave.rolling && g_wave.state == MAK_WAVE_ROLLING &&
        g_wave.roll_bin_secs > 0 && g_wave.bins > 0 &&
        g_wave.bins_min && g_wave.bins_max && g_wave.bins_filled) {{
        const int cap = g_wave.bins;
        if (begin_secs >= 0) {{
            int64_t new_base = (int64_t)(begin_secs / g_wave.roll_bin_secs);
            if (new_base > g_wave.roll_base_bin) {{
                int64_t shift = new_base - g_wave.roll_base_bin;
                if (shift >= g_wave.valid_bins) {{
                    g_wave.valid_bins = 0;
                }} else {{
                    int keep = g_wave.valid_bins - (int)shift;
                    memmove(g_wave.bins_min, g_wave.bins_min + shift,
                            (size_t)keep * sizeof(float));
                    memmove(g_wave.bins_max, g_wave.bins_max + shift,
                            (size_t)keep * sizeof(float));
                    memmove(g_wave.bins_filled, g_wave.bins_filled + shift,
                            (size_t)keep);
                    g_wave.valid_bins = keep;
                }}
                g_wave.roll_base_bin = new_base;
                /* Restore the invariant: bins_filled[k]==0 for k>=valid_bins. */
                memset(g_wave.bins_filled + g_wave.valid_bins, 0,
                       (size_t)(cap - g_wave.valid_bins));
            }}
        }}
        /* The reported range is derived from the bin grid by the reader
         * (bin-quantized → stable); eviction here only advances the base. The
         * demuxer forward edge (end_secs) is not part of the folded waveform,
         * so it's ignored for the axis. */
        (void)end_secs;
    }}
    mp_mutex_unlock(&g_wave.lock);
}}

/* Abort a coordinator's blocking probe (avformat_open_input /
 * avformat_find_stream_info) as soon as a newer mak_waveform_start()
 * supersedes it: libav polls this callback during in-flight I/O, so a
 * superseded probe drops its (possibly stalled) connection immediately
 * instead of holding the socket open until the network call returns on its
 * own. Without it, rapid track changes against a session-capped server (a
 * Jellyfin/Plex HLS transcode keyed by PlaySessionId) pile up blocked
 * probes that exhaust the server's connection budget, leaving every later
 * track stuck in DECODING with no envelope. Returns nonzero to abort. */
static int coord_interrupt_cb(void *opaque)
{{
    int my_gen = *(int *)opaque;
    return atomic_load(&g_wave.current_gen) != my_gen;
}}

static MP_THREAD_VOID coordinator_main(void *p)
{{
    struct coord_args *args = p;
    int    my_gen   = args->my_gen;
    char  *url      = args->url;
    double dur_secs = args->duration_secs;
    free(args);

    AVFormatContext   *probe_fmt = NULL;
    AVCodecParameters *codecpar_copies[MAK_WAVEFORM_WORKERS] = {{0}};
    mp_thread          threads[MAK_WAVEFORM_WORKERS];
    struct worker_chunk chunks[MAK_WAVEFORM_WORKERS] = {{0}};
    int                spawned = 0;
    int                bins = 0;
    float             *bins_min = NULL;
    float             *bins_max = NULL;
    uint8_t           *bins_filled = NULL;
    int                audio_idx = -1;
    bool               ok = false;

    worker_publish_state(my_gen, MAK_WAVE_DECODING);
    if (atomic_load(&g_wave.current_gen) != my_gen) goto cleanup;

    /* Pre-allocate the probe context so we can install the interrupt
     * callback + an I/O timeout BEFORE the (blocking) open. The callback
     * aborts this probe if a newer start() bumps the generation; the
     * timeout bounds a single stalled connection. Together they stop blocked
     * probes from piling up on a session-capped transcode server (the cause
     * of the "no waveform + no artwork until restart" stall). */
    probe_fmt = avformat_alloc_context();
    if (!probe_fmt) goto fail;
    probe_fmt->interrupt_callback.callback = coord_interrupt_cb;
    probe_fmt->interrupt_callback.opaque   = &my_gen;
    AVDictionary *probe_opts = NULL;
    av_dict_set(&probe_opts, "rw_timeout", "5000000", 0);  /* 5 s (microseconds) */
    av_dict_set(&probe_opts, "timeout",    "5000000", 0);  /* 5 s (HTTP/TCP) */
    int probe_ret = avformat_open_input(&probe_fmt, url, NULL, &probe_opts);
    av_dict_free(&probe_opts);
    if (probe_ret < 0) goto fail;
    if (avformat_find_stream_info(probe_fmt, NULL) < 0)       goto fail;

    for (unsigned i = 0; i < probe_fmt->nb_streams; i++) {{
        if (probe_fmt->streams[i]->codecpar->codec_type ==
            AVMEDIA_TYPE_AUDIO) {{
            audio_idx = (int)i;
            break;
        }}
    }}
    if (audio_idx < 0) goto fail;

    AVStream *st = probe_fmt->streams[audio_idx];
    int sample_rate = st->codecpar->sample_rate;
    if (sample_rate <= 0) goto fail;

    /* Track duration in microseconds. Prefer the format-level duration;
     * fall back to the audio stream's own duration, then to the caller's
     * (mpv's) duration hint. */
    int64_t duration_us = 0;
    if (probe_fmt->duration > 0) duration_us = probe_fmt->duration;
    if (duration_us <= 0 && st->duration > 0) {{
        duration_us = av_rescale_q(st->duration,
                                   st->time_base, AV_TIME_BASE_Q);
    }}
    if (duration_us <= 0 && dur_secs > 0)
        duration_us = (int64_t)(dur_secs * 1e6);

    /* ── Classify the source (fully automatic, no caller hint) ──────────
     * Bulk parallel decode needs a complete, randomly seekable file. An
     * adaptive/segmented stream (DASH/HLS — a Plex/Jellyfin transcode), a
     * live source, or a non-seekable input cannot be bulk-decoded. mpv's
     * libav probe gives us everything:
     *   - the demuxer NAME is the reliable DASH/HLS discriminator (those
     *     report "seekable" within segments, so seekability alone is not
     *     enough; a live DASH doesn't even set AVFMTCTX_UNSEEKABLE);
     *   - AVFMTCTX_UNSEEKABLE / a non-seekable AVIO catches live / pipe.
     * Those go PROGRESSIVE — grown from playback by the af-tap — using
     * mpv's duration as the axis (no duration ⇒ FAILED, no axis). */
    const char *fmt_name = (probe_fmt->iformat && probe_fmt->iformat->name)
                           ? probe_fmt->iformat->name : "";
    bool is_adaptive = strstr(fmt_name, "dash") ||
                       strstr(fmt_name, "hls")  ||
                       strstr(fmt_name, "applehttp");
    bool unseekable  = (probe_fmt->ctx_flags & AVFMTCTX_UNSEEKABLE) ||
                       (probe_fmt->pb &&
                        !(probe_fmt->pb->seekable & AVIO_SEEKABLE_NORMAL));
    bool is_network  = strstr(url, "://") != NULL;

    if (is_adaptive || unseekable) {{
        double eff_dur = dur_secs > 0 ? dur_secs : duration_us / 1e6;
        if (eff_dur > 0)
            arm_progressive(my_gen, eff_dur);
        else
            arm_rolling(my_gen);   /* true live: no axis → cache-aligned roll */
        goto cleanup;
    }}
    if (duration_us <= 0) goto fail;

    int64_t total_samples = (int64_t)duration_us * sample_rate / 1000000;
    if (total_samples <= 0) goto fail;

    /* Seekable complete file (local OR HTTP byte-range). Local fans out to
     * all workers; an HTTP file uses ONE — independently re-opening a signed
     * / connection-capped URL (Plex/Jellyfin direct-play) N times may
     * throttle or desync, so a single sequential reader is the safe choice. */
    int nworkers = is_network ? 1 : MAK_WAVEFORM_WORKERS;

    /* Fixed bin count, clamped down for tracks shorter than the
     * target resolution. Allocate the global min/max arrays. */
    bins = MAK_WAVEFORM_BINS;
    if ((int64_t)bins > total_samples) bins = (int)total_samples;
    if (bins < 1) goto fail;
    bins_min = av_calloc(bins, sizeof(float));
    bins_max = av_calloc(bins, sizeof(float));
    bins_filled = av_calloc(bins, sizeof(uint8_t));
    if (!bins_min || !bins_max || !bins_filled) goto fail;

    /* Spawn the workers (nworkers: all for local, 1 for HTTP). Each worker
     * covers a disjoint sample range and a disjoint bin slice. */
    for (int w = 0; w < nworkers; w++) {{
        int64_t ss = total_samples * w / nworkers;
        int64_t se = total_samples * (w + 1) / nworkers;

        codecpar_copies[w] = avcodec_parameters_alloc();
        if (!codecpar_copies[w]) goto fail;
        if (avcodec_parameters_copy(codecpar_copies[w],
                                    st->codecpar) < 0) goto fail;

        int bs = (int)((int64_t)bins * w / nworkers);
        int be = (int)((int64_t)bins * (w + 1) / nworkers);

        chunks[w] = (struct worker_chunk){{
            .my_gen        = my_gen,
            .url           = url,
            .audio_idx     = audio_idx,
            .codec_id      = st->codecpar->codec_id,
            .codecpar      = codecpar_copies[w],
            .sample_rate   = sample_rate,
            .total_samples = total_samples,
            .sample_start  = ss,
            .sample_end    = se,
            .time_base_num = st->time_base.num,
            .time_base_den = st->time_base.den,
            .total_bins    = bins,
            .bin_start     = bs,
            .bin_end       = be,
            .out_min       = bins_min + bs,
            .out_max       = bins_max + bs,
            .bins_filled   = av_calloc(be - bs > 0 ? be - bs : 1, 1),
            .status        = -1,
        }};
        if (!chunks[w].bins_filled) goto fail;

        if (mp_thread_create(&threads[w],
                             worker_chunk_thread, &chunks[w]) != 0) goto fail;
        spawned++;
    }}

    /* Join all workers. */
    bool all_ok = true;
    for (int w = 0; w < spawned; w++) {{
        mp_thread_join(threads[w]);
        if (chunks[w].status != 0) all_ok = false;
    }}
    if (!all_ok) goto fail;

    /* High-water mark of bins any worker actually filled. bins_filled is
     * still alive here (freed in cleanup); ranges are disjoint, so the
     * global max is the answer. valid_bins stays 0 if nothing filled, and
     * the reader then falls back to the full bin count. */
    int valid_bins = 0;
    for (int w = 0; w < spawned; w++) {{
        struct worker_chunk *c = &chunks[w];
        if (!c->bins_filled)
            continue;
        for (int local = c->bin_end - c->bin_start - 1; local >= 0; local--) {{
            if (c->bins_filled[local]) {{
                int gb = c->bin_start + local + 1;
                if (gb > valid_bins) valid_bins = gb;
                break;
            }}
        }}
    }}

    /* Merge the disjoint per-worker fill flags into one global mask. Without
     * it the bulk path leaves g_wave.bins_filled NULL and the reader
     * fabricates "all filled", so a bin no worker ever touched (a decode gap
     * or failed sub-range that still sits inside the valid_bins high-water)
     * would render as a real silent sample instead of an unloaded baseline.
     * The per-worker slices are disjoint by construction. */
    for (int w = 0; w < spawned; w++) {{
        struct worker_chunk *c = &chunks[w];
        if (!c->bins_filled) continue;
        int slice = c->bin_end - c->bin_start;
        if (slice > 0)
            memcpy(bins_filled + c->bin_start, c->bins_filled, (size_t)slice);
    }}

    /* Commit — only if we are still the current generation. */
    mp_mutex_lock(&g_wave.lock);
    if (atomic_load(&g_wave.current_gen) == my_gen) {{
        if (g_wave.bins_min) av_free(g_wave.bins_min);
        if (g_wave.bins_max) av_free(g_wave.bins_max);
        if (g_wave.bins_filled) av_free(g_wave.bins_filled);
        g_wave.bins        = bins;
        g_wave.valid_bins  = valid_bins;
        g_wave.bins_min    = bins_min;
        g_wave.bins_max    = bins_max;
        g_wave.bins_filled = bins_filled;
        bins_min = NULL;  /* ownership moved into g_wave */
        bins_max = NULL;
        bins_filled = NULL;
        g_wave.duration_us = duration_us;
        g_wave.state       = MAK_WAVE_READY;
        ok = true;
    }}
    mp_mutex_unlock(&g_wave.lock);
    goto cleanup;

fail:
    /* Tear down any workers already spawned before declaring failure
     * (otherwise we'd leak threads and their open AVFormatContexts). */
    for (int w = 0; w < spawned; w++) mp_thread_join(threads[w]);
    spawned = 0;
    worker_publish_state(my_gen, MAK_WAVE_FAILED);

cleanup:
    (void)ok;
    for (int w = 0; w < MAK_WAVEFORM_WORKERS; w++) {{
        if (chunks[w].bins_filled)
            av_free(chunks[w].bins_filled);
        if (codecpar_copies[w]) avcodec_parameters_free(&codecpar_copies[w]);
    }}
    if (bins_min) av_free(bins_min);
    if (bins_max) av_free(bins_max);
    if (bins_filled) av_free(bins_filled);
    if (probe_fmt) avformat_close_input(&probe_fmt);
    free(url);
    MP_THREAD_RETURN();
}}

/* ─── public entry points ─────────────────────────────────────────── */

static void reset_g_wave_locked(void)
{{
    if (g_wave.bins_min) {{
        av_free(g_wave.bins_min);
        g_wave.bins_min = NULL;
    }}
    if (g_wave.bins_max) {{
        av_free(g_wave.bins_max);
        g_wave.bins_max = NULL;
    }}
    if (g_wave.bins_filled) {{
        av_free(g_wave.bins_filled);
        g_wave.bins_filled = NULL;
    }}
    g_wave.bins          = 0;
    g_wave.valid_bins    = 0;
    g_wave.duration_us   = 0;
    g_wave.progressive   = false;
    g_wave.duration_secs = 0;
    g_wave.rolling        = false;
    g_wave.roll_base_bin  = 0;
    g_wave.roll_bin_secs  = 0;
}}

void mak_waveform_start(const char *url, double duration_secs,
                        const char *format_name, bool is_network,
                        bool seekable)
{{
    if (!atomic_load(&g_enabled)) return;
    if (!url || !*url) return;

    /* Bump the generation up front so any in-flight coordinator/workers and
     * af-tap folds from the previous track self-cancel, and reset the visible
     * state to "decoding" so a wrapper polling before the strategy arms does
     * not see a stale "ready" from the previous track. */
    int new_gen = atomic_fetch_add(&g_wave.current_gen, 1) + 1;
    mp_mutex_lock(&g_wave.lock);
    g_wave.state = MAK_WAVE_DECODING;
    reset_g_wave_locked();
    mp_mutex_unlock(&g_wave.lock);

    /* ── NETWORK adaptive / non-seekable: arm DIRECTLY, never re-open ──────
     * mpv already classified the source (format name + is_network + seekable),
     * so do NOT spawn the coordinator probe for a network HLS/DASH transcode or
     * a non-seekable network stream. A probe would be a SECOND concurrent open
     * of the same live transcode: Jellyfin's DynamicHls kills+restarts the
     * transcode on each init-segment request, so the probe and the player's own
     * open kill each other → HTTP 500 → no waveform + playback desync.
     * arm_progressive/arm_rolling need nothing from a probe (the af-tap supplies
     * the sample rate per frame), only the duration axis mpv hands us. Keyed on
     * the lavf NAME, not is_network alone: a seekable network DIRECT-PLAY file
     * ("flac"/"mov"…) must still bulk-decode, so it falls through below. */
    const char *fn = format_name ? format_name : "";
    bool name_adaptive = strstr(fn, "dash") ||
                         strstr(fn, "hls")  ||
                         strstr(fn, "applehttp");
    if (is_network && (name_adaptive || !seekable)) {{
        if (duration_secs > 0)
            arm_progressive(new_gen, duration_secs);
        else
            arm_rolling(new_gen);   /* unknown duration → cache-aligned roll */
        return;
    }}

    /* Local file, or a seekable HTTP byte-range part (direct-play): hand to the
     * coordinator. It probes [url] with libav and BULK-decodes a complete
     * seekable file; a *local* adaptive source still routes to progressive via
     * the coordinator's own classification. Re-opening here is safe — a local
     * or static file has no transcode to kill. */
    struct coord_args *args = calloc(1, sizeof(*args));
    if (!args) return;
    args->url           = strdup(url);
    args->my_gen        = new_gen;
    args->duration_secs = duration_secs;
    if (!args->url) {{ free(args); return; }}

    mp_thread t;
    if (mp_thread_create(&t, coordinator_main, args) != 0) {{
        free(args->url);
        free(args);
        worker_publish_state(new_gen, MAK_WAVE_FAILED);
        return;
    }}
    mp_thread_detach(t);
}}

void mak_waveform_stop(void)
{{
    int new_gen = atomic_fetch_add(&g_wave.current_gen, 1) + 1;
    mp_mutex_lock(&g_wave.lock);
    g_wave.state = MAK_WAVE_IDLE;
    reset_g_wave_locked();
    mp_mutex_unlock(&g_wave.lock);
    (void)new_gen;
}}

void mak_waveform_set_enabled(bool on)
{{
    atomic_store(&g_enabled, on);
    /* Turning the gate off also cancels any in-flight analysis and
     * clears the visible state. */
    if (!on)
        mak_waveform_stop();
}}

bool mak_waveform_is_enabled(void)
{{
    return atomic_load(&g_enabled);
}}

/* Whether a PROGRESSIVE analysis is live and wants per-frame folds from
 * the af-tap dispatcher. Cheap gate checked once per input frame. */
bool mak_waveform_wants_frames(void)
{{
    if (!atomic_load(&g_enabled)) return false;
    mp_mutex_lock(&g_wave.lock);
    bool want = g_wave.progressive &&
                (g_wave.state == MAK_WAVE_PROGRESSIVE ||
                 g_wave.state == MAK_WAVE_ROLLING);
    mp_mutex_unlock(&g_wave.lock);
    return want;
}}

/* Live generation, captured at the af-tap call site and handed back to
 * mak_waveform_fold_samples so a frame from a torn-down chain (the
 * previous track) is dropped instead of folded into the new envelope. */
int mak_waveform_current_gen(void)
{{
    return atomic_load(&g_wave.current_gen);
}}

/* Fold [n] mono Float32 samples — already converted + downmixed by the
 * af-tap dispatcher — into the PROGRESSIVE envelope, per-bin by source
 * position. The first sample is at media time [pts_secs]; [rate] is the
 * frame's sample rate (sample j sits at pts_secs + j/rate). Binning goes
 * through the shared kernel (same mapping as the bulk path); a run-walk
 * reduces each contiguous same-bin run to one min/max widen. [gen] must
 * still be current or the frame is dropped. Grows the high-water
 * valid_bins so the reader emits only what playback has reached. */
void mak_waveform_fold_samples(const float *mono, int n, double pts_secs,
                               int rate, int gen)
{{
    if (!mono || n <= 0 || rate <= 0) return;
    if (!(pts_secs >= 0)) return;            /* also rejects NaN */
    mp_mutex_lock(&g_wave.lock);
    const bool live_gen = atomic_load(&g_wave.current_gen) == gen;
    if (live_gen && g_wave.progressive && g_wave.bins > 0 &&
        g_wave.bins_min && g_wave.bins_max && g_wave.bins_filled) {{
        if (g_wave.rolling && g_wave.state == MAK_WAVE_ROLLING &&
            g_wave.roll_bin_secs > 0) {{
            /* ROLLING: absolute media-time bins into the linear sliding
             * window. Invariant: bins_filled[k]==0 for k >= valid_bins, so a
             * first touch always seeds; eviction (memmove + memset) keeps it. */
            const double bs  = g_wave.roll_bin_secs;
            const int    cap = g_wave.bins;
            int i = 0;
            while (i < n) {{
                int64_t ab = (int64_t)((pts_secs + (double)i / rate) / bs);
                if (ab < g_wave.roll_base_bin) {{ i++; continue; }}
                int64_t local = ab - g_wave.roll_base_bin;
                /* Backstop: slide the window forward if it would overflow
                 * capacity (the demuxer normally evicts well before this). */
                if (local >= cap) {{
                    int64_t shift = local - (cap - 1);
                    if (shift >= g_wave.valid_bins) {{
                        g_wave.valid_bins = 0;
                    }} else {{
                        int keep = g_wave.valid_bins - (int)shift;
                        memmove(g_wave.bins_min, g_wave.bins_min + shift,
                                (size_t)keep * sizeof(float));
                        memmove(g_wave.bins_max, g_wave.bins_max + shift,
                                (size_t)keep * sizeof(float));
                        memmove(g_wave.bins_filled, g_wave.bins_filled + shift,
                                (size_t)keep);
                        g_wave.valid_bins = keep;
                    }}
                    g_wave.roll_base_bin += shift;
                    memset(g_wave.bins_filled + g_wave.valid_bins, 0,
                           (size_t)(cap - g_wave.valid_bins));
                    local -= shift;
                }}
                const int li = (int)local;
                float rmin = mono[i];
                float rmax = mono[i];
                int j = i + 1;
                while (j < n &&
                       (int64_t)((pts_secs + (double)j / rate) / bs) == ab) {{
                    if (mono[j] < rmin) rmin = mono[j];
                    if (mono[j] > rmax) rmax = mono[j];
                    j++;
                }}
                mak_fold_bin(rmin, &g_wave.bins_min[li], &g_wave.bins_max[li],
                             &g_wave.bins_filled[li]);
                mak_fold_bin(rmax, &g_wave.bins_min[li], &g_wave.bins_max[li],
                             &g_wave.bins_filled[li]);
                if (li + 1 > g_wave.valid_bins)
                    g_wave.valid_bins = li + 1;
                i = j;
            }}
        }} else if (g_wave.state == MAK_WAVE_PROGRESSIVE &&
                   g_wave.duration_secs > 0) {{
            const int     bins  = g_wave.bins;
            const int64_t total = (int64_t)(g_wave.duration_secs * rate);
            const int64_t base  = (int64_t)llround(pts_secs * rate);
            int i = 0;
            while (i < n) {{
                int64_t b = mak_sample_to_bin(base + i, bins, total);
                float rmin = mono[i];
                float rmax = mono[i];
                int j = i + 1;
                while (j < n &&
                       mak_sample_to_bin(base + j, bins, total) == b) {{
                    if (mono[j] < rmin) rmin = mono[j];
                    if (mono[j] > rmax) rmax = mono[j];
                    j++;
                }}
                mak_fold_bin(rmin, &g_wave.bins_min[b], &g_wave.bins_max[b],
                             &g_wave.bins_filled[b]);
                mak_fold_bin(rmax, &g_wave.bins_min[b], &g_wave.bins_max[b],
                             &g_wave.bins_filled[b]);
                if ((int)b + 1 > g_wave.valid_bins)
                    g_wave.valid_bins = (int)b + 1;
                i = j;
            }}
        }}
    }}
    mp_mutex_unlock(&g_wave.lock);
}}

int mak_waveform_read(struct mpv_node *out, void *parent)
{{
    (void)parent;
    if (!out) return -1;

    mp_mutex_lock(&g_wave.lock);
    enum mak_wave_state state = g_wave.state;
    int64_t duration_us = g_wave.duration_us;
    int64_t range_start_us = 0;
    int64_t range_end_us   = 0;
    int     roll_lead      = 0;  /* ROLLING: leading not-yet-filled bins to skip */
    bool    has_data    = (state == MAK_WAVE_READY ||
                           state == MAK_WAVE_PROGRESSIVE ||
                           state == MAK_WAVE_ROLLING);

    /* ROLLING has no total. The axis is derived straight from the bin grid so
     * it is bin-quantized and stable across polls: the surfaced window starts
     * at the first FILLED bin (roll_base_bin + roll_lead) and spans the held
     * bins, each MAK_WAVE_ROLL_BIN_US wide. Integer math (no float * 1e6)
     * guarantees duration_us == held*BIN_US exactly and duration/bins == 0.04
     * in the wrapper — no rounding drift.
     *
     * No start-time rebase is needed: mpv applies its ts_offset
     * (= -demuxer->start_time under the default --rebase-start-time) on the
     * demuxer OUTPUT — to both the packets fed to the decoder (demux.c
     * dequeue_packet) and the seek ranges from demux_get_reader_state — so
     * the af-tap frame PTS that build these bins, the cache begin/end that
     * evict them, and the wrapper playhead (time-pos) are ALL already on the
     * same rebased timeline. The bin grid therefore matches time-pos directly.
     * The demuxer's cache begin/end are used only to evict, never the axis. */
    if (state == MAK_WAVE_ROLLING) {{
        /* Skip leading not-yet-filled bins. The demuxer's seekable-range begin
         * can sit a bin or two before the first audio we have actually folded
         * (e.g. AAC decoder delay ≈ 0.05 s), which would otherwise render as an
         * empty gap at the window's left edge. Anchor the surfaced window at
         * the first filled bin; interior gaps (filled==0) are kept as-is. */
        if (g_wave.bins_filled) {{
            while (roll_lead < g_wave.valid_bins &&
                   !g_wave.bins_filled[roll_lead])
                roll_lead++;
        }}
        int held = g_wave.valid_bins - roll_lead;
        if (held < 0) held = 0;
        range_start_us =
            (g_wave.roll_base_bin + roll_lead) * MAK_WAVE_ROLL_BIN_US;
        range_end_us =
            (g_wave.roll_base_bin + g_wave.valid_bins) * MAK_WAVE_ROLL_BIN_US;
        duration_us = (int64_t)held * MAK_WAVE_ROLL_BIN_US;
    }}

    /* Snapshot the bin data so the lock can be released before we
     * touch talloc (which can call into the allocator). */
    int      snap_bins = 0;
    float   *snap_min  = NULL;
    float   *snap_max  = NULL;
    uint8_t *snap_fill = NULL;

    if (has_data) {{
        /* ROLLING emits exactly the held window [0, valid_bins) — that IS the
         * cached span, placed in absolute time via range_*_us. BULK trims to
         * valid_bins — drops the flat dead tail left by a duration overshoot.
         * PROGRESSIVE must emit the FULL bin axis: the not-yet-played bins
         * (filled == 0) are what lets the renderer map the played region onto
         * [0, playhead] and draw the rest as a baseline. So trim for ROLLING
         * and BULK, full axis for PROGRESSIVE. */
        /* ROLLING anchors the surfaced window at the first FILLED bin: roll_lead
         * leading empties were counted above, so emit exactly the held span
         * [roll_lead, valid_bins) and shift the copy by off == roll_lead so the
         * emitted bins line up with range_start_us (held * BIN == duration_us,
         * one bin == 0.04 s exactly). Interior gaps (filled==0 past roll_lead)
         * are preserved. BULK/PROGRESSIVE start at bin 0 (off == 0), byte-for-
         * byte unchanged. */
        int off = g_wave.rolling ? roll_lead : 0;
        int b = g_wave.rolling
                ? (g_wave.valid_bins - roll_lead)
                : ((!g_wave.progressive &&
                    g_wave.valid_bins > 0 && g_wave.valid_bins <= g_wave.bins)
                   ? g_wave.valid_bins : g_wave.bins);
        if (b > 0 && g_wave.bins_min && g_wave.bins_max) {{
            snap_min  = av_malloc((size_t)b * sizeof(float));
            snap_max  = av_malloc((size_t)b * sizeof(float));
            snap_fill = av_malloc((size_t)b);   /* one byte per bin */
            if (snap_min && snap_max && snap_fill) {{
                memcpy(snap_min, g_wave.bins_min + off, (size_t)b * sizeof(float));
                memcpy(snap_max, g_wave.bins_max + off, (size_t)b * sizeof(float));
                /* "filled" lets the UI tell "not yet played" (0) from
                 * "played + silent" (1). PROGRESSIVE tracks it per bin;
                 * BULK has no per-bin flag here but every emitted bin is
                 * filled by construction (valid_bins is the fill high-water),
                 * so report all-1. */
                if (g_wave.bins_filled)
                    memcpy(snap_fill, g_wave.bins_filled + off, (size_t)b);
                else
                    memset(snap_fill, 1, (size_t)b);
                snap_bins = b;
            }}
        }}
    }}
    mp_mutex_unlock(&g_wave.lock);

    bool emit_data = has_data && snap_min && snap_max && snap_fill &&
                     snap_bins > 0;

    /* Top-level map:
     * {{ state, duration_us, min, max, filled, range_start_us, range_end_us }}.
     * The range_* keys carry the absolute media placement of a ROLLING
     * window; they are 0 for the other states. */
    struct mpv_node_list *list = talloc_zero(NULL, struct mpv_node_list);
    list->num    = 7;
    list->keys   = talloc_array(list, char *, 7);
    list->values = talloc_array(list, struct mpv_node, 7);

    list->keys[0] = talloc_strdup(list, "state");
    list->values[0] = (struct mpv_node){{
        .format = MPV_FORMAT_STRING,
        .u.string = talloc_strdup(list, state_string(state))}};
    list->keys[1] = talloc_strdup(list, "duration_us");
    list->values[1] = (struct mpv_node){{
        .format = MPV_FORMAT_INT64, .u.int64 = duration_us}};

    struct mpv_byte_array *ba_min = talloc_zero(list, struct mpv_byte_array);
    struct mpv_byte_array *ba_max = talloc_zero(list, struct mpv_byte_array);
    if (emit_data) {{
        size_t bytes = (size_t)snap_bins * sizeof(float);
        ba_min->data = talloc_size(ba_min, bytes);
        ba_min->size = bytes;
        memcpy(ba_min->data, snap_min, bytes);
        ba_max->data = talloc_size(ba_max, bytes);
        ba_max->size = bytes;
        memcpy(ba_max->data, snap_max, bytes);
    }}
    list->keys[2] = talloc_strdup(list, "min");
    list->values[2] = (struct mpv_node){{
        .format = MPV_FORMAT_BYTE_ARRAY, .u.ba = ba_min}};
    list->keys[3] = talloc_strdup(list, "max");
    list->values[3] = (struct mpv_node){{
        .format = MPV_FORMAT_BYTE_ARRAY, .u.ba = ba_max}};

    struct mpv_byte_array *ba_fill = talloc_zero(list, struct mpv_byte_array);
    if (emit_data) {{
        ba_fill->data = talloc_size(ba_fill, (size_t)snap_bins);
        ba_fill->size = (size_t)snap_bins;
        memcpy(ba_fill->data, snap_fill, (size_t)snap_bins);
    }}
    list->keys[4] = talloc_strdup(list, "filled");
    list->values[4] = (struct mpv_node){{
        .format = MPV_FORMAT_BYTE_ARRAY, .u.ba = ba_fill}};

    list->keys[5] = talloc_strdup(list, "range_start_us");
    list->values[5] = (struct mpv_node){{
        .format = MPV_FORMAT_INT64, .u.int64 = range_start_us}};
    list->keys[6] = talloc_strdup(list, "range_end_us");
    list->values[6] = (struct mpv_node){{
        .format = MPV_FORMAT_INT64, .u.int64 = range_end_us}};

    if (snap_min)  av_free(snap_min);
    if (snap_max)  av_free(snap_max);
    if (snap_fill) av_free(snap_fill);

    *out = (struct mpv_node){{
        .format = MPV_FORMAT_NODE_MAP, .u.list = list}};
    return 0;
}}
'''


# ─── player/loadfile.c ────────────────────────────────────────────────

LOADFILE_INCLUDE_PRISTINE = '#include "audio/out/ao.h"'

LOADFILE_INCLUDE_PATCHED = (
    '#include "audio/out/ao.h"\n'
    '/* ' + MARKER + ' */\n'
    '#include "audio/mak_waveform.h"'
)


# Anchor: the FILE_LOADED notification line. We insert a start() call
# right after it so the analyzer kicks the moment mpv tells the world
# the file is loaded. start() self-gates on waveform-enabled, so this
# unconditional call is a cheap no-op when the analyzer is disabled.
# Pristine line lifted from mpv 0.41.0.
LOADFILE_NOTIFY_PRISTINE = (
    '    mp_notify(mpctx, MPV_EVENT_FILE_LOADED, NULL);'
)

LOADFILE_NOTIFY_PATCHED = (
    '    mp_notify(mpctx, MPV_EVENT_FILE_LOADED, NULL);\n'
    '    /* ' + MARKER + ' */\n'
    '    mak_waveform_start(mpctx->stream_open_filename, '
    'get_time_length(mpctx),\n'
    '                       mpctx->demuxer ? mpctx->demuxer->filetype : NULL,\n'
    '                       mpctx->demuxer ? mpctx->demuxer->is_network : false,\n'
    '                       mpctx->demuxer ? mpctx->demuxer->seekable : false);'
)


def patch_loadfile_c(path):
    with open(path) as f:
        text = f.read()
    if LOADFILE_INCLUDE_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (loadfile.c includes) not found in {path}.'
        )
    if LOADFILE_NOTIFY_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (FILE_LOADED notify) not found in {path}.'
        )
    text = text.replace(LOADFILE_INCLUDE_PRISTINE, LOADFILE_INCLUDE_PATCHED, 1)
    text = text.replace(LOADFILE_NOTIFY_PRISTINE, LOADFILE_NOTIFY_PATCHED, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── player/command.c ─────────────────────────────────────────────────

# Anchor for the property table — same neighbour as patch_pcm_tap
# (`audio-bitrate`). Append our two entries just after pcm_tap's.
COMMAND_TABLE_PRISTINE = (
    '    {"audio-bitrate", mp_property_packet_bitrate, '
    '.priv = (void *)&(const int){STREAM_AUDIO}},'
)

COMMAND_TABLE_PATCHED = (
    '    {"audio-bitrate", mp_property_packet_bitrate, '
    '.priv = (void *)&(const int){STREAM_AUDIO}},\n'
    '    /* ' + MARKER + ' */\n'
    '    {"waveform-data", mp_property_waveform_data},\n'
    '    {"waveform-enabled", mp_property_waveform_enabled},'
)

# Insert the getter/setter just before mp_property_audio_params (same
# insertion point as patch_pcm_tap; we just prepend fresh functions).
COMMAND_GETTER_ANCHOR = (
    'static int mp_property_audio_params(void *ctx, struct m_property *prop,'
)

COMMAND_GETTER_INSERT = (
    '/* ' + MARKER + ' ─── read-only property: bulk waveform analyser\n'
    ' * snapshot. Returns a MAP_NODE { state, duration_us, min, max }.\n'
    ' * "min"/"max" are interleaved Float32 byte arrays, one entry per\n'
    ' * bin (empty until state == "ready"). The wrapper polls this on\n'
    ' * its own cadence — we deliberately do NOT call mp_notify_property\n'
    ' * because the coordinator writes the result asynchronously and we\n'
    ' * do not want to fire change events for every transient state\n'
    ' * transition. */\n'
    'static int mp_property_waveform_data(void *ctx, struct m_property *prop,\n'
    '                                     int action, void *arg)\n'
    '{\n'
    '    switch (action) {\n'
    '        case M_PROPERTY_GET_TYPE:\n'
    '            *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_NODE};\n'
    '            return M_PROPERTY_OK;\n'
    '        case M_PROPERTY_GET:\n'
    '        case M_PROPERTY_GET_NODE: {\n'
    '            /* The envelope is grown live — BULK by the coordinator/\n'
    '             * workers, PROGRESSIVE by the af-tap folding pre-DSP frames\n'
    '             * per-bin. The getter snapshots the current state; for a\n'
    '             * ROLLING (live) window it first evicts in lockstep with\n'
    '             * the demuxer seekable cache so only still-seekable bins\n'
    '             * are kept. */\n'
    '            struct MPContext *mpctx = ctx;\n'
    '            double cb = -1.0, ce = -1.0;\n'
    '            if (mpctx && mpctx->demuxer) {\n'
    '                struct demux_reader_state rs;\n'
    '                demux_get_reader_state(mpctx->demuxer, &rs);\n'
    '                for (int i = 0; i < rs.num_seek_ranges; i++) {\n'
    '                    if (cb < 0 || rs.seek_ranges[i].start < cb)\n'
    '                        cb = rs.seek_ranges[i].start;\n'
    '                    if (ce < 0 || rs.seek_ranges[i].end > ce)\n'
    '                        ce = rs.seek_ranges[i].end;\n'
    '                }\n'
    '            }\n'
    '            mak_waveform_update_cache_range(cb, ce);\n'
    '            struct mpv_node n = {0};\n'
    '            if (mak_waveform_read(&n, arg) < 0)\n'
    '                return M_PROPERTY_UNAVAILABLE;\n'
    '            *(struct mpv_node *)arg = n;\n'
    '            return M_PROPERTY_OK;\n'
    '        }\n'
    '    }\n'
    '    return M_PROPERTY_NOT_IMPLEMENTED;\n'
    '}\n'
    '\n'
    '/* ' + MARKER + ' ─── read-write FLAG: gates the bulk waveform\n'
    ' * analyser. OFF by default. Setting it true also kicks the\n'
    ' * analyser for the already-loaded file so enabling mid-track\n'
    ' * works; mak_waveform_start null-checks the url. Setting it false\n'
    ' * cancels any in-flight analysis. */\n'
    'static int mp_property_waveform_enabled(void *ctx, struct m_property *prop,\n'
    '                                        int action, void *arg)\n'
    '{\n'
    '    struct MPContext *mpctx = ctx;\n'
    '    switch (action) {\n'
    '        case M_PROPERTY_GET_TYPE:\n'
    '            *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_FLAG};\n'
    '            return M_PROPERTY_OK;\n'
    '        case M_PROPERTY_GET:\n'
    '            *(int *)arg = mak_waveform_is_enabled() ? 1 : 0;\n'
    '            return M_PROPERTY_OK;\n'
    '        case M_PROPERTY_SET: {\n'
    '            bool on = *(int *)arg != 0;\n'
    '            mak_waveform_set_enabled(on);\n'
    '            if (on)\n'
    '                mak_waveform_start(mpctx->stream_open_filename,\n'
    '                                   get_time_length(mpctx),\n'
    '                                   mpctx->demuxer ? mpctx->demuxer->filetype : NULL,\n'
    '                                   mpctx->demuxer ? mpctx->demuxer->is_network : false,\n'
    '                                   mpctx->demuxer ? mpctx->demuxer->seekable : false);\n'
    '            return M_PROPERTY_OK;\n'
    '        }\n'
    '    }\n'
    '    return M_PROPERTY_NOT_IMPLEMENTED;\n'
    '}\n'
    '\n'
    + COMMAND_GETTER_ANCHOR
)

# Includes anchor — `#include "command.h"`. The getter only needs
# mak_waveform.h (the property reader + start/enable entry points); the
# envelope is grown elsewhere (workers / af-tap), so command.c has no
# dependency on the PCM tap.
COMMAND_INCLUDE_PRISTINE = '#include "command.h"'

COMMAND_INCLUDE_PATCHED = (
    '#include "command.h"\n'
    '/* ' + MARKER + ' */\n'
    '#include "audio/mak_waveform.h"\n'
    '#include "demux/demux.h"'
)


def patch_command_c(path):
    with open(path) as f:
        text = f.read()
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

# Anchor on the same `audio/out/ao.c` line patch_pcm_tap uses, but
# extend further down — adding a NEW file in the audio/ subtree.
# Because patch_pcm_tap appends `audio/out/mak_pcm_tap.c` after
# `audio/out/ao.c`, we anchor on patch_pcm_tap's marker if present,
# falling back to the pristine line. This way the two patches compose
# in any order.
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
    "    'audio/mak_waveform.c',"
)

MESON_PRISTINE = "    'audio/out/ao.c',"

MESON_PATCHED = (
    "    'audio/out/ao.c',\n"
    "    # " + MARKER + "\n"
    "    'audio/mak_waveform.c',"
)


def patch_meson(path):
    with open(path) as f:
        text = f.read()
    # Compose with patch_pcm_tap when it has already run.
    if MESON_AFTER_PCM_TAP in text:
        text = text.replace(
            MESON_AFTER_PCM_TAP, MESON_AFTER_PCM_TAP_PATCHED, 1)
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
    """Write a generated source file, overwriting any existing one. The
    patcher assumes a fresh (git-restored) mpv tree, so the file normally
    does not exist yet; on a re-run it is rewritten with the current patch."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(content)
    print(f'Wrote:    {path}')


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <mpv_src_dir>')
        sys.exit(1)
    src = sys.argv[1]
    write_new_file(os.path.join(src, 'audio', 'mak_wave_fold.h'),
                   WAVE_FOLD_H)
    write_new_file(os.path.join(src, 'audio', 'mak_waveform.h'),
                   WAVEFORM_H)
    write_new_file(os.path.join(src, 'audio', 'mak_waveform.c'),
                   WAVEFORM_C)
    patch_loadfile_c(os.path.join(src, 'player', 'loadfile.c'))
    patch_command_c(os.path.join(src, 'player', 'command.c'))
    patch_meson(os.path.join(src, 'meson.build'))


if __name__ == '__main__':
    main()
