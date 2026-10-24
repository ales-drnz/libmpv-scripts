#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Adds an offline loudness scan (EBU R128 / BS.1770) to libmpv.

Layers ON TOP of patch_bulk_analysis.py — every anchor below is text
that patch emits, so this patch MUST run after it (and is skipped by
the build when bulk_analysis is disabled; see apply_mpv_patches_common).

What it adds
============

The scan rides the bulk-analysis scan ENGINE's existing parallel
decode pass: each bulk worker (in mak_scan.c) also K-weights the
PER-CHANNEL signal (before the waveform's mono downmix) into 100 ms
sub-block energies on a global grid, plus sample/true peak. After the
worker join the coordinator merges the slices and applies the BS.1770
gates — mathematically identical to a single-pass measurement (the
400 ms gating blocks are reassembled from sub-blocks at the merge, so
worker boundaries need no overlap). Design rationale, grid math and
merge formulas live in bulk_analysis/mak_loudness.h.

Surfaced properties (same gated pattern as the waveform):

    loudness-scan-enabled   RW flag, OFF by default. Enabling kicks the
                            scan for the already-loaded file.
    loudness-scan-data      RO map { state, integrated_lufs, lra_lu,
                            sample_peak, true_peak, gated_block_count,
                            progress }.
                            state: idle|scanning|ready|failed|
                            unavailable ("unavailable" = source the bulk
                            path cannot decode up-front: adaptive/live/
                            non-seekable → use live af-chain metering).

The bulk decode now runs when EITHER waveform-enabled or
loudness-scan-enabled is set; each result stays gated by its own flag.

Layout
======

The C sources are REAL files in `bulk_analysis/` next to this script:

    mak_loudness.h            public API + the BS.1770 merge math notes
    mak_loudness.c            K-filters, true-peak FIR, per-worker
                              accumulator, gated merge, property reader
    loudness_command_insert.c property getter/setter block spliced into
                              player/command.c (ends with the bulk
                              patch's getter-comment anchor line)

Files touched in the mpv tree
=============================

    audio/mak_loudness.h     NEW — copied from bulk_analysis/
    audio/mak_loudness.c     NEW — copied from bulk_analysis/
    audio/mak_scan.c         worker feed/finish hooks, decode-end grid
                             extension, coordinator merge + publish,
                             either-flag start gate, start scanning/fail
    audio/mak_waveform.c     arm_progressive / arm_rolling mark unavailable
    player/command.c         property registration + getter/setter
    meson.build              new source file added to the build

Usage
=====

    python3 patch_loudness_scan.py <mpv_source_dir>

Run AFTER patch_bulk_analysis.py (anchors live in its output).
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402


MARKER = 'MAK_LOUDNESS_PATCH'

# Every anchor must be present and unique; a missing one means bulk_analysis
# didn't run first (or its output drifted). A file that already carries
# MARKER is left alone, so a second run changes nothing.


# ─── audio/mak_scan.c (bulk-emitted engine) ──────────────────────────

def patch_mak_scan_c(p):
    edits = [
        ('include', '#include "audio/mak_waveform.h"',
         '#include "audio/mak_waveform.h"\n'
         '/* ' + MARKER + ' */\n'
         '#include "audio/mak_loudness.h"'),

        ('worker_chunk fields',
         '    uint8_t *bins_filled;\n'
         '    int      status;             /* 0 = ok */\n'
         '};',
         '    uint8_t *bins_filled;\n'
         '    /* ' + MARKER + ' ─── per-worker loudness accumulator and its\n'
         '     * finished slice (loud_done set when the slice is valid). */\n'
         '    struct mak_loud_worker *loud;\n'
         '    struct mak_loud_slice   loud_slice;\n'
         '    int      loud_done;\n'
         '    int      status;             /* 0 = ok */\n'
         '};'),

        ('worker create accumulator',
         '    if (swr_init(swr) < 0) goto cleanup;',
         '    if (swr_init(swr) < 0) goto cleanup;\n'
         '\n'
         '    /* ' + MARKER + ' ─── the loudness accumulator rides this\n'
         '     * worker\'s decode; created only while the scan flag is on. It\n'
         '     * converts what the decoder outputs: the probe\'s format can be\n'
         '     * another decoder\'s (MP2 probes as float, decodes as s16). */\n'
         '    a->codecpar->format = dec->sample_fmt;\n'
         '    if (mak_loudness_is_enabled())\n'
         '        a->loud = mak_loud_worker_create(a->codecpar, a->sample_rate,\n'
         '                                         a->sample_start, a->sample_end,\n'
         '                                         a->total_samples);'),

        ('worker decode-end grid extension',
         '    int64_t emitted_samples = 0;\n'
         '    int     stream_pos_initialized = 0;',
         '    int64_t emitted_samples = 0;\n'
         '    int     stream_pos_initialized = 0;\n'
         '    /* ' + MARKER + ' ─── decode up to the slice end rounded to the\n'
         '     * next 100 ms grid boundary so the trailing sub-block completes\n'
         '     * (≤ one hop of extra decode; the bin filter is unaffected), and\n'
         '     * at least to the end of the worker\'s bins. */\n'
         '    int64_t decode_end = a->wave_end;\n'
         '    if (a->loud && mak_loud_worker_decode_end(a->loud) > decode_end)\n'
         '        decode_end = mak_loud_worker_decode_end(a->loud);'),

        ('worker early-stop #1 uses decode_end',
         '            if (frame_seq_pos >= a->wave_end) {',
         '            if (frame_seq_pos >= decode_end) {'),

        ('worker feed before early stop',
         '            /* Stop early once the frame starts past our region. */',
         '            /* ' + MARKER + ' ─── feed the un-downmixed frame; the\n'
         '             * accumulator self-filters to its owned grid and treats\n'
         '             * pre-roll as filter warm-up. It sits where the envelope\n'
         '             * counts it: frame timestamps are rounded by the\n'
         '             * container (1 ms in Matroska), and placing each frame at\n'
         '             * its own left the 100 ms sub-blocks short, so none was\n'
         '             * complete. */\n'
         '            if (a->loud)\n'
         '                mak_loud_worker_feed(a->loud, iframe, frame_seq_pos);\n'
         '\n'
         '            /* Stop early once the frame starts past our region. */'),

        ('worker early-stop #2 uses decode_end',
         '            if (emitted_samples >= a->wave_end) goto done_decode;',
         '            if (emitted_samples >= decode_end) goto done_decode;'),

        ('worker finish slice',
         'done_decode:\n'
         '\n'
         '    a->status = 0;',
         'done_decode:\n'
         '\n'
         '    /* ' + MARKER + ' ─── detach the finished slice for the\n'
         '     * coordinator\'s merge; failure paths destroy it in cleanup. */\n'
         '    if (a->loud) {\n'
         '        a->loud_done = mak_loud_worker_finish(a->loud, &a->loud_slice);\n'
         '        a->loud = NULL;\n'
         '    }\n'
         '\n'
         '    a->status = 0;'),

        ('worker cleanup destroys accumulator',
         'cleanup:\n'
         '    if (out_buf)  av_free(out_buf);',
         'cleanup:\n'
         '    /* ' + MARKER + ' */\n'
         '    if (a->loud) {\n'
         '        mak_loud_worker_destroy(a->loud);\n'
         '        a->loud = NULL;\n'
         '    }\n'
         '    if (out_buf)  av_free(out_buf);'),

        ('coordinator merge + publish',
         '    if (committed) {\n'
         '        bins_min    = NULL;  /* ownership moved into g_wave */\n'
         '        bins_max    = NULL;\n'
         '        bins_sq     = NULL;\n'
         '        bins_n      = NULL;\n'
         '        bins_filled = NULL;\n'
         '    }\n'
         '    goto cleanup;',
         '    if (committed) {\n'
         '        bins_min    = NULL;  /* ownership moved into g_wave */\n'
         '        bins_max    = NULL;\n'
         '        bins_sq     = NULL;\n'
         '        bins_n      = NULL;\n'
         '        bins_filled = NULL;\n'
         '    }\n'
         '\n'
         '    /* ' + MARKER + ' ─── merge the per-worker slices and publish\n'
         '     * the loudness result (generation- and flag-checked inside). */\n'
         '    {\n'
         '        struct mak_loud_slice lslices[MAK_WAVEFORM_WORKERS];\n'
         '        int ln = 0;\n'
         '        for (int w = 0; w < spawned; w++) {\n'
         '            if (chunks[w].loud_done) {\n'
         '                lslices[ln++] = chunks[w].loud_slice;\n'
         '                chunks[w].loud_done = 0;\n'
         '            }\n'
         '        }\n'
         '        if (ln > 0)\n'
         '            mak_loudness_publish(lslices, ln, sample_rate, my_gen);\n'
         '        else if (mak_loudness_is_enabled())\n'
         '            mak_loudness_mark_failed(my_gen);\n'
         '    }\n'
         '    goto cleanup;'),

        ('coordinator fail marks loudness',
         '    mak_waveform_mark_failed(my_gen);',
         '    mak_waveform_mark_failed(my_gen);\n'
         '    /* ' + MARKER + ' */\n'
         '    mak_loudness_mark_failed(my_gen);'),

        ('coordinator cleanup frees slices',
         '    for (int w = 0; w < MAK_WAVEFORM_WORKERS; w++) {\n'
         '        if (chunks[w].bins_filled)\n'
         '            av_free(chunks[w].bins_filled);',
         '    for (int w = 0; w < MAK_WAVEFORM_WORKERS; w++) {\n'
         '        /* ' + MARKER + ' */\n'
         '        if (chunks[w].loud_done)\n'
         '            mak_loud_slice_free(&chunks[w].loud_slice);\n'
         '        if (chunks[w].bins_filled)\n'
         '            av_free(chunks[w].bins_filled);'),

        ('start gate admits either flag',
         '    if (!mak_waveform_is_enabled()) return;',
         '    /* ' + MARKER + ' ─── the scan rides this decode pass: run it\n'
         '     * when EITHER gate is on. */\n'
         '    if (!mak_waveform_is_enabled() && !mak_loudness_is_enabled())\n'
         '        return;'),

        ('start marks loudness scanning',
         '    int new_gen = mak_waveform_begin_generation();',
         '    int new_gen = mak_waveform_begin_generation();\n'
         '    /* ' + MARKER + ' */\n'
         '    mak_loudness_mark_scanning(new_gen);'),

        ('start fail marks loudness',
         '        mak_waveform_mark_failed(new_gen);',
         '        mak_waveform_mark_failed(new_gen);\n'
         '        /* ' + MARKER + ' */\n'
         '        mak_loudness_mark_failed(new_gen);'),
    ]
    p.edits('audio/mak_scan.c', edits)


# ─── audio/mak_waveform.c (bulk-emitted product) ─────────────────────

def patch_mak_waveform_c(p):
    edits = [
        ('arm_progressive marks unavailable',
         'void mak_waveform_arm_progressive(int my_gen, double duration_secs)\n'
         '{\n',
         'void mak_waveform_arm_progressive(int my_gen, double duration_secs)\n'
         '{\n'
         '    /* ' + MARKER + ' ─── playback-grown source: no offline scan. */\n'
         '    mak_loudness_mark_unavailable(my_gen);\n'),

        ('arm_rolling marks unavailable',
         'void mak_waveform_arm_rolling(int my_gen)\n'
         '{\n',
         'void mak_waveform_arm_rolling(int my_gen)\n'
         '{\n'
         '    /* ' + MARKER + ' ─── live source: no offline scan. */\n'
         '    mak_loudness_mark_unavailable(my_gen);\n'),

        ('include', '#include "audio/mak_wave_fold.h"',
         '#include "audio/mak_wave_fold.h"\n'
         '/* ' + MARKER + ' */\n'
         '#include "audio/mak_loudness.h"'),
    ]
    p.edits('audio/mak_waveform.c', edits)


# ─── player/command.c (bulk-emitted anchors) ─────────────────────────

def patch_command_c(p):
    getter_anchor = ('/* MAK_WAVEFORM_PATCH ─── read-only property: '
                     'bulk waveform analyser')
    insert = p.asset('bulk_analysis/loudness_command_insert.c').rstrip('\n')
    if not insert.endswith(getter_anchor):
        p.fail('loudness_command_insert.c must end with the bulk getter-'
               'comment anchor line (it is re-emitted by the splice).')
    edits = [
        ('include',
         '#include "audio/mak_waveform.h"\n'
         '#include "demux/demux.h"',
         '#include "audio/mak_waveform.h"\n'
         '/* ' + MARKER + ' */\n'
         '#include "audio/mak_loudness.h"\n'
         '#include "demux/demux.h"'),

        ('property table',
         '    {"waveform-data", mp_property_waveform_data},\n'
         '    {"waveform-enabled", mp_property_waveform_enabled},',
         '    {"waveform-data", mp_property_waveform_data},\n'
         '    {"waveform-enabled", mp_property_waveform_enabled},\n'
         '    /* ' + MARKER + ' */\n'
         '    {"loudness-scan-data", mp_property_loudness_scan_data},\n'
         '    {"loudness-scan-enabled", mp_property_loudness_scan_enabled},'),

        ('getter/setter splice', getter_anchor, insert),
    ]
    p.edits('player/command.c', edits)


# ─── meson.build (bulk-emitted anchor) ───────────────────────────────

def patch_meson(p):
    edits = [
        ('source list',
         "    # MAK_WAVEFORM_PATCH\n"
         "    'audio/mak_waveform.c',",
         "    # MAK_WAVEFORM_PATCH\n"
         "    'audio/mak_waveform.c',\n"
         "    # " + MARKER + "\n"
         "    'audio/mak_loudness.c',"),
    ]
    p.edits('meson.build', edits)


def apply(p):
    # Sources of the loudness engine, shipped in bulk_analysis/.
    for name in ('mak_loudness.h', 'mak_loudness.c'):
        p.new_file('audio/' + name, p.asset('bulk_analysis/' + name))
    patch_mak_scan_c(p)
    patch_mak_waveform_c(p)
    patch_command_c(p)
    patch_meson(p)


anchor.main(apply, 'patch_loudness_scan', marker=MARKER, usage='<mpv_src_dir>')
