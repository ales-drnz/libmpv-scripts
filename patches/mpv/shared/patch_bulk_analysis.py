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

    audio/mak_waveform.h   NEW — waveform product API + scan-engine interface
    audio/mak_waveform.c   NEW — waveform state, reader, progressive/rolling
    audio/mak_scan.h       NEW — scan engine API
    audio/mak_scan.c       NEW — coordinator + workers + decode + classify
    player/loadfile.c      kicks `mak_scan_start` after FILE_LOADED
    player/command.c       property registration + getter/setter
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

# The real C sources shipped next to this script (see "Layout" above).
SRC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'bulk_analysis')


def read_src(name):
    with open(os.path.join(SRC_DIR, name)) as f:
        return f.read()


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
    '                   mpctx->demuxer ? mpctx->demuxer->seekable : false);'
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
# The spliced block lives in bulk_analysis/command_insert.c and ENDS
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
    text = text.replace(COMMAND_GETTER_ANCHOR,
                        read_src('waveform_command_insert.c'), 1)
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
    "    'audio/mak_waveform.c',\n"
    "    'audio/mak_scan.c',"
)

MESON_PRISTINE = "    'audio/out/ao.c',"

MESON_PATCHED = (
    "    'audio/out/ao.c',\n"
    "    # " + MARKER + "\n"
    "    'audio/mak_waveform.c',\n"
    "    'audio/mak_scan.c',"
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
                   read_src('mak_wave_fold.h'))
    write_new_file(os.path.join(src, 'audio', 'mak_waveform.h'),
                   read_src('mak_waveform.h'))
    write_new_file(os.path.join(src, 'audio', 'mak_waveform.c'),
                   read_src('mak_waveform.c'))
    write_new_file(os.path.join(src, 'audio', 'mak_scan.h'),
                   read_src('mak_scan.h'))
    write_new_file(os.path.join(src, 'audio', 'mak_scan.c'),
                   read_src('mak_scan.c'))
    patch_loadfile_c(os.path.join(src, 'player', 'loadfile.c'))
    patch_command_c(os.path.join(src, 'player', 'command.c'))
    patch_meson(os.path.join(src, 'meson.build'))


if __name__ == '__main__':
    main()
