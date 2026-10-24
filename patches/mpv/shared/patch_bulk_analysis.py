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
property `waveform-enabled` is set true. `mak_scan_start()`
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
`g_wave_lock`, only if the generation is still current.

Cancellation
============

Detached coordinator (never joined). Each `start()` bumps a global
generation counter, and so does the close of the file while a scan
runs; coordinator and workers carry their own gen and:
  - exit once it is no longer the current one: a worker within
    MAK_WAVE_CANCEL_CHECK_INTERVAL samples (4096, about 85 ms at
    48 kHz), the coordinator at its next pass of the 100 ms publish
    loop, a blocked open or read through the interrupt callback,
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
    Local files fan out to all workers when their format seeks to an exact
    sample (FLAC, WAV, AIFF, MP4, Ogg, WavPack, TTA, APE, CAF, not ADPCM);
    each later worker decodes a pre-roll before its region and places
    frames where one sequential decode would, so the result is the same.
    Other formats, and an HTTP file, use ONE worker —
    re-opening a signed / connection-capped URL N times can throttle or
    desync, so a single sequential reader is the safe choice.

  * **HTTP file played from its start, with mpv's cache in memory** (the
    default): no re-open. `mak_feed.c` attaches a packet feed to the
    demuxer (`demux/mak_demux_feed.h`, a side consumer like `dump-cache`):
    the cached audio packets are replayed, then every new one is queued as
    mpv downloads it, and a thread of its own decodes them into the same
    bins (read as `decoding` while it fills, with the bins it reached as
    `coverage_bins`; af-tap fold off; `ready` after the pass reaches the
    end). The file is downloaded once. When one
    clean pass is not possible (playback starting further in, any seek the
    cache cannot serve, an audio track switch, a cut download, the cache off
    or on disk, a file larger than the forward cache, a read-ahead that
    stops before the end, a timeline), the generation goes to the
    single-worker re-open above, so the result is never partial.

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
and matches the existing tap's concurrency model. Likewise a Player
that closes its file (stop, the next file) stops an analysis still
running, whichever Player started it.

Files patched
=============

    audio/mak_waveform.h   NEW — waveform product API + scan-engine interface
    audio/mak_waveform.c   NEW — waveform state, reader, progressive/rolling
    audio/mak_scan.h       NEW — scan engine API
    audio/mak_scan.c       NEW — coordinator + workers + decode + classify
    audio/mak_feed.h/.c    NEW — cache-fed engine
    demux/mak_demux_feed.h/.c  NEW — packet feed queue
    demux/demux.c          feed field, push, end of file, release, attach
    player/loadfile.c      kicks `mak_scan_start` after FILE_LOADED, and
                           `mak_scan_file_closed` when the file closes
    player/command.c       property registration + getter/setter
    player/main.c          setup in mp_create, teardown in mp_destroy
    meson.build            new source files added to the build

Layout
======

The C sources are REAL files in `bulk_analysis/` next to this script:

    mak_wave_fold.h     shared min/max-per-bin kernel
    mak_waveform.h      waveform product API + scan-engine interface
                        (MAK_WAVEFORM_BINS / _WORKERS #defines live here —
                        single source of truth)
    mak_waveform.c      waveform state, reader, progressive/rolling fold,
                        and the scan-engine interface (commit/publish/arm)
    mak_scan.h          scan engine API (mak_scan_start)
    mak_scan.c          coordinator + workers + decode + source classify;
                        drives the waveform product, loudness rides woven
    mak_feed.h/.c       cache-fed engine for a seekable network file
    mak_demux_feed.h/.c packet feed queue between demuxer and engine
    demux_feed_insert.c mak_demux_feed_attach, appended to demux/demux.c
    waveform_command_insert.c  property getter/setter block spliced into
                        player/command.c (ends with the pristine
                        anchor line it replaces)

This script is only the applier: it copies the sources into the tree
and performs the anchored edits below. Tuning notes: BINS=2000 sizes
the overview strip of a single-audio player (16 KB/track); WORKERS=4
is near-linear on local files — beyond that I/O contention hurts.

Usage
=====

    python3 patch_bulk_analysis.py <mpv_source_dir>

Composes with `patch_pcm_tap.py`, `patch_audio_output_state.py`,
`patch_embedded_cover_art.py`, `patch_prefetch.py`: disjoint
anchors.
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

# Provenance tag stamped into every patched region and generated file so a
# patched mpv tree is easy to grep. A file that already carries it is left
# alone, so a second run changes nothing; the generated files are refreshed.
MARKER = 'MAK_WAVEFORM_PATCH'


# ─── player/loadfile.c ────────────────────────────────────────────────

LOADFILE_INCLUDE_PRISTINE = '#include "audio/out/ao.h"'

LOADFILE_INCLUDE_PATCHED = (
    '#include "audio/out/ao.h"\n'
    '/* ' + MARKER + ' */\n'
    '#include "audio/mak_scan.h"'
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
    '    mak_scan_start(mpctx->stream_open_filename, '
    'get_time_length(mpctx),\n'
    '                   mpctx->demuxer ? mpctx->demuxer->filetype : NULL,\n'
    '                   mpctx->demuxer ? mpctx->demuxer->is_network : false,\n'
    '                   mpctx->demuxer ? mpctx->demuxer->seekable : false,\n'
    '                   mpctx->global, mpctx->log, mpctx->demuxer,\n'
    '                   mpctx->current_track[0][STREAM_AUDIO]\n'
    '                       ? mpctx->current_track[0][STREAM_AUDIO]->stream\n'
    '                       : NULL);'
)


# Anchor: the close of the file in play_current_file, which every end goes
# through (stop, the next file, an error, the end of the playlist), right
# before the demuxer goes. An analysis still running for the file stops
# there, instead of downloading and decoding it for nobody. With keep-open
# the file stays loaded at its end and the analysis goes on. Pristine lines
# lifted from mpv 0.41.0.
LOADFILE_CLOSE_PRISTINE = (
    '    mpctx->playback_initialized = false;\n'
    '\n'
    '    uninit_demuxer(mpctx);\n'
)

LOADFILE_CLOSE_PATCHED = (
    '    mpctx->playback_initialized = false;\n'
    '\n'
    '    /* ' + MARKER + ' */\n'
    '    mak_scan_file_closed();\n'
    '    uninit_demuxer(mpctx);\n'
)


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
# The spliced block lives in bulk_analysis/waveform_command_insert.c and ENDS
# with this anchor line, so the replace re-emits it.
COMMAND_GETTER_ANCHOR = (
    'static int mp_property_audio_params(void *ctx, struct m_property *prop,'
)

COMMAND_INCLUDE_PRISTINE = '#include "command.h"'

COMMAND_INCLUDE_PATCHED = (
    '#include "command.h"\n'
    '/* ' + MARKER + ' */\n'
    '#include "audio/mak_scan.h"\n'
    '#include "audio/mak_waveform.h"\n'
    '#include "demux/demux.h"'
)


# ─── player/main.c ────────────────────────────────────────────────────

# Bracket every core's lifetime so the last mp_destroy drains the detached
# analysis threads (see "lifetime" in mak_scan.c). Pristine lines lifted from
# mpv 0.41.0.
MAIN_INCLUDE_PRISTINE = '#include "screenshot.h"'

MAIN_INCLUDE_PATCHED = (
    '#include "screenshot.h"\n'
    '/* ' + MARKER + ' */\n'
    '#include "audio/mak_scan.h"'
)

MAIN_DESTROY_PRISTINE = (
    'void mp_destroy(struct MPContext *mpctx)\n'
    '{\n'
    '    mp_shutdown_clients(mpctx);'
)

MAIN_DESTROY_PATCHED = (
    'void mp_destroy(struct MPContext *mpctx)\n'
    '{\n'
    '    mp_shutdown_clients(mpctx);\n'
    '    /* ' + MARKER + ' */\n'
    '    mak_scan_core_release();'
)

MAIN_CREATE_PRISTINE = '    mp_time_init();\n'

MAIN_CREATE_PATCHED = (
    '    mp_time_init();\n'
    '    /* ' + MARKER + ' */\n'
    '    mak_scan_core_acquire();\n'
)


# ─── demux/demux.c ────────────────────────────────────────────────────

# The packet feed of the cache-fed analysis (mak_demux_feed.h): the demuxer
# owns one reference, pushes each new packet of the fed stream and its end of
# file, and lets go when it is freed. Pristine lines lifted from mpv 0.41.0.
DEMUX_EDITS = [
    ('includes',
     '#include "packet_pool.h"',
     '#include "packet_pool.h"\n'
     '/* ' + MARKER + ' */\n'
     '#include "mak_demux_feed.h"'),
    ('demux_internal field',
     '    struct mp_recorder *dumper;\n'
     '    int dumper_status;\n',
     '    struct mp_recorder *dumper;\n'
     '    int dumper_status;\n'
     '\n'
     '    /* ' + MARKER + ' ─── the bulk analysis packet feed, if attached,\n'
     '     * and the guard its consumer reaches the cache through. */\n'
     '    struct mak_demux_feed *mak_feed;\n'
     '    struct mak_feed_guard *mak_guard;\n'),
    ('add_packet_locked push',
     '    record_packet(in, dp);\n',
     '    record_packet(in, dp);\n'
     '\n'
     '    /* ' + MARKER + ' ─── queue a reference for the analysis. */\n'
     '    if (in->mak_feed && dp->stream == mak_demux_feed_stream(in->mak_feed) &&\n'
     '        !mak_demux_feed_push(in->mak_feed, dp, queue,\n'
     '                             queue->is_bof && !queue->head))\n'
     '    {\n'
     '        mak_demux_feed_owner_release(in->mak_feed);\n'
     '        in->mak_feed = NULL;\n'
     '    }\n'),
    ('read_packet cache full',
     '    if (total_fw_bytes >= in->max_bytes) {\n',
     '    if (total_fw_bytes >= in->max_bytes) {\n'
     '        /* ' + MARKER + ' ─── the cache of a file of unknown size is\n'
     '         * full before its end: the file may be far larger than the\n'
     '         * cache, and the rest would come at the playback pace. The\n'
     '         * re-open takes over, as for a file known to be that large. */\n'
     '        if (in->mak_feed && !in->eof && in->stream_size <= 0)\n'
     '            mak_demux_feed_cut(in->mak_feed);\n'),
    ('read_packet read-ahead reached',
     '    if (!read_more && !prefetch_more && !refresh_more) {\n'
     '        in->hyst_active = !!in->hyst_secs;\n',
     '    if (!read_more && !prefetch_more && !refresh_more) {\n'
     '        /* ' + MARKER + ' ─── the read-ahead (cache-secs) is reached\n'
     '         * before the end of the file: from now on the demuxer reads at\n'
     '         * the playback pace, a few seconds ahead of it, and the analysis\n'
     '         * would trail playback. The re-open takes over. */\n'
     '        if (in->mak_feed && !in->eof)\n'
     '            mak_demux_feed_cut(in->mak_feed);\n'
     '        in->hyst_active = !!in->hyst_secs;\n'),
    ('mark_stream_eof',
     'static void mark_stream_eof(struct demux_stream *ds)\n'
     '{\n'
     '    if (!ds->eof) {\n'
     '        ds->eof = true;\n',
     'static void mark_stream_eof(struct demux_stream *ds)\n'
     '{\n'
     '    if (!ds->eof) {\n'
     '        ds->eof = true;\n'
     '        /* ' + MARKER + ' ─── a cancelled read also ends here: not an\n'
     '         * end of file for the analysis. */\n'
     '        if (ds->in->mak_feed && !demux_cancel_test(ds->in->d_thread) &&\n'
     '            ds->index == mak_demux_feed_stream(ds->in->mak_feed))\n'
     '            mak_demux_feed_mark(ds->in->mak_feed, MAK_FEED_EOF);\n'),
    ('execute_seek',
     'static void execute_seek(struct demux_internal *in)\n'
     '{\n'
     '    int flags = in->seek_flags;\n'
     '    double pts = in->seek_pts;\n',
     'static void execute_seek(struct demux_internal *in)\n'
     '{\n'
     '    int flags = in->seek_flags;\n'
     '    double pts = in->seek_pts;\n'
     '    /* ' + MARKER + ' ─── every low-level seek, whatever asked for it\n'
     '     * (the user, a cache range resumed or joined, a track refresh),\n'
     '     * breaks the continuity the analysis feed relies on. */\n'
     '    if (in->mak_feed)\n'
     '        mak_demux_feed_seek(in->mak_feed);\n'),
    ('switch_current_range',
     'static void switch_current_range(struct demux_internal *in,\n'
     '                                 struct demux_cached_range *range)\n'
     '{\n',
     'static void switch_current_range(struct demux_internal *in,\n'
     '                                 struct demux_cached_range *range)\n'
     '{\n'
     '    /* ' + MARKER + ' ─── the range the feed follows is left, and may\n'
     '     * be freed below: cut before a replay could reach its queue. */\n'
     '    if (in->mak_feed)\n'
     '        mak_demux_feed_seek(in->mak_feed);\n'),
    ('demuxer_select_track',
     '        ds->selected = selected;\n'
     '        update_stream_selection_state(in, ds);\n',
     '        ds->selected = selected;\n'
     '        /* ' + MARKER + ' ─── a deselected fed stream gets no more\n'
     '         * packets and loses its cache: the pass cannot go on. */\n'
     '        if (!selected && in->mak_feed &&\n'
     '            stream->index == mak_demux_feed_stream(in->mak_feed))\n'
     '            mak_demux_feed_cut(in->mak_feed);\n'
     '        update_stream_selection_state(in, ds);\n'),
    ('demux_shutdown',
     'static void demux_shutdown(struct demux_internal *in)\n'
     '{\n'
     '    struct demuxer *demuxer = in->d_user;\n',
     'static void demux_shutdown(struct demux_internal *in)\n'
     '{\n'
     '    struct demuxer *demuxer = in->d_user;\n'
     '\n'
     '    /* ' + MARKER + ' ─── the flush below frees the cache ranges and\n'
     '     * their queues, without the lock, and on the demux thread when the\n'
     '     * demuxer is freed asynchronously (stop, playlist advance), long\n'
     '     * before demux_dealloc(). Let go of the feed first: killing the\n'
     '     * guard waits for a replay batch in progress, and the next one\n'
     '     * finds the demuxer gone. Not under the lock: the guard comes\n'
     '     * first in the lock order. */\n'
     '    if (in->mak_guard)\n'
     '        mak_feed_guard_kill(in->mak_guard);\n'
     '    in->mak_guard = NULL;\n'
     '    if (in->mak_feed)\n'
     '        mak_demux_feed_owner_release(in->mak_feed);\n'
     '    in->mak_feed = NULL;\n'),
    ('demux_dealloc',
     'static void demux_dealloc(struct demux_internal *in)\n'
     '{\n',
     'static void demux_dealloc(struct demux_internal *in)\n'
     '{\n'
     '    /* ' + MARKER + ' ─── the demux thread is stopped: no more pushes.\n'
     '     * demux_shutdown() already let go of the feed; this covers a\n'
     '     * demuxer freed without it. */\n'
     '    if (in->mak_guard)\n'
     '        mak_feed_guard_kill(in->mak_guard);\n'
     '    in->mak_guard = NULL;\n'
     '    if (in->mak_feed)\n'
     '        mak_demux_feed_owner_release(in->mak_feed);\n'
     '    in->mak_feed = NULL;\n'),
]


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
    "    'audio/mak_waveform.c',\n"
    "    'audio/mak_scan.c',\n"
    "    'audio/mak_feed.c',\n"
    "    'demux/mak_demux_feed.c',"
)

MESON_PRISTINE = "    'audio/out/ao.c',"

MESON_PATCHED = (
    "    'audio/out/ao.c',\n"
    "    # " + MARKER + "\n"
    "    'audio/mak_waveform.c',\n"
    "    'audio/mak_scan.c',\n"
    "    'audio/mak_feed.c',\n"
    "    'demux/mak_demux_feed.c',"
)



# The generated sources and where they go in the tree.
NEW_FILES = [
    ('audio', 'mak_wave_fold.h'),
    ('audio', 'mak_waveform.h'),
    ('audio', 'mak_waveform.c'),
    ('audio', 'mak_scan.h'),
    ('audio', 'mak_scan.c'),
    ('audio', 'mak_feed.h'),
    ('audio', 'mak_feed.c'),
    ('demux', 'mak_demux_feed.h'),
    ('demux', 'mak_demux_feed.c'),
]


def apply(p):
    # The real C sources ship next to this script (see "Layout" above). A
    # second run refreshes them: patch_loudness_scan.py edits two of them
    # after this patch, and redoes its edits on the fresh copies.
    for d, name in NEW_FILES:
        p.new_file(f'{d}/{name}', p.asset(f'bulk_analysis/{name}'))
    if p.edits('demux/demux.c', DEMUX_EDITS):
        p.write('demux/demux.c', p.text('demux/demux.c').rstrip('\n') + '\n'
                + p.asset('bulk_analysis/demux_feed_insert.c'))
    p.edits('player/loadfile.c', [
        ('loadfile.c includes', LOADFILE_INCLUDE_PRISTINE, LOADFILE_INCLUDE_PATCHED),
        ('FILE_LOADED notify', LOADFILE_NOTIFY_PRISTINE, LOADFILE_NOTIFY_PATCHED),
        ('file close', LOADFILE_CLOSE_PRISTINE, LOADFILE_CLOSE_PATCHED),
    ])
    p.edits('player/command.c', [
        ('command.c includes', COMMAND_INCLUDE_PRISTINE, COMMAND_INCLUDE_PATCHED),
        ('audio-bitrate property entry', COMMAND_TABLE_PRISTINE,
         COMMAND_TABLE_PATCHED),
        ('mp_property_audio_params getter', COMMAND_GETTER_ANCHOR,
         p.asset('bulk_analysis/waveform_command_insert.c')),
    ])
    p.edits('player/main.c', [
        ('main.c includes', MAIN_INCLUDE_PRISTINE, MAIN_INCLUDE_PATCHED),
        ('main.c mp_destroy', MAIN_DESTROY_PRISTINE, MAIN_DESTROY_PATCHED),
        ('main.c mp_create', MAIN_CREATE_PRISTINE, MAIN_CREATE_PATCHED),
    ])
    if p.marked('meson.build'):
        print('Already patched: meson.build')
    else:
        # Composes with patch_pcm_tap when it has already run.
        p.optional('meson.build', [
            (MESON_AFTER_PCM_TAP, MESON_AFTER_PCM_TAP_PATCHED),
            (MESON_PRISTINE, MESON_PATCHED),
        ], 'audio/out/ao.c entry')


anchor.main(apply, 'patch_bulk_analysis', marker=MARKER, usage='<mpv_src_dir>')
