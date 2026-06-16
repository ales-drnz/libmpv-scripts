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
import os
import sys


MARKER = 'MAK_LOUDNESS_PATCH'

SRC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       'bulk_analysis')


def read_src(name):
    with open(os.path.join(SRC_DIR, name)) as f:
        return f.read()


def apply_edits(path, edits):
    """[(label, anchor, replacement)] — every anchor must be present and
    unique; a missing anchor means bulk_analysis didn't run first (or
    its output drifted) and is a hard error."""
    with open(path) as f:
        text = f.read()
    for label, anchor, replacement in edits:
        n = text.count(anchor)
        if n != 1:
            raise RuntimeError(
                f'{label}: anchor found {n} times (expected 1) in {path}. '
                f'Run patch_bulk_analysis.py first / check for drift.'
            )
        text = text.replace(anchor, replacement, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── audio/mak_scan.c (bulk-emitted engine) ──────────────────────────

def patch_mak_scan_c(path):
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
         '     * worker\'s decode; created only while the scan flag is on. */\n'
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
         '     * (≤ one hop of extra decode; the bin filter is unaffected). */\n'
         '    int64_t decode_end = a->loud\n'
         '        ? mak_loud_worker_decode_end(a->loud) : a->sample_end;'),

        ('worker early-stop #1 uses decode_end',
         '            if (frame_sample_pos >= a->sample_end) {',
         '            if (frame_sample_pos >= decode_end) {'),

        ('worker feed before early stop',
         '            /* Stop early once the frame starts past our region. */',
         '            /* ' + MARKER + ' ─── feed the un-downmixed frame; the\n'
         '             * accumulator self-filters to its owned grid and treats\n'
         '             * pre-roll as filter warm-up. */\n'
         '            if (a->loud)\n'
         '                mak_loud_worker_feed(a->loud, iframe, frame_sample_pos);\n'
         '\n'
         '            /* Stop early once the frame starts past our region. */'),

        ('worker early-stop #2 uses decode_end',
         '            if (emitted_samples >= a->sample_end) goto done_decode;',
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
         '        bins_filled = NULL;\n'
         '    }\n'
         '    goto cleanup;',
         '    if (committed) {\n'
         '        bins_min    = NULL;  /* ownership moved into g_wave */\n'
         '        bins_max    = NULL;\n'
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
    apply_edits(path, edits)


# ─── audio/mak_waveform.c (bulk-emitted product) ─────────────────────

def patch_mak_waveform_c(path):
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
    apply_edits(path, edits)


# ─── player/command.c (bulk-emitted anchors) ─────────────────────────

def patch_command_c(path):
    getter_anchor = ('/* MAK_WAVEFORM_PATCH ─── read-only property: '
                     'bulk waveform analyser')
    insert = read_src('loudness_command_insert.c').rstrip('\n')
    if not insert.endswith(getter_anchor):
        raise RuntimeError(
            'loudness_command_insert.c must end with the bulk getter-'
            'comment anchor line (it is re-emitted by the splice).'
        )
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
    apply_edits(path, edits)


# ─── meson.build (bulk-emitted anchor) ───────────────────────────────

def patch_meson(path):
    edits = [
        ('source list',
         "    # MAK_WAVEFORM_PATCH\n"
         "    'audio/mak_waveform.c',",
         "    # MAK_WAVEFORM_PATCH\n"
         "    'audio/mak_waveform.c',\n"
         "    # " + MARKER + "\n"
         "    'audio/mak_loudness.c',"),
    ]
    apply_edits(path, edits)


# ─── new files ────────────────────────────────────────────────────────

def write_new_file(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write(content)
    print(f'Wrote:    {path}')


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <mpv_src_dir>')
        sys.exit(1)
    src = sys.argv[1]
    write_new_file(os.path.join(src, 'audio', 'mak_loudness.h'),
                   read_src('mak_loudness.h'))
    write_new_file(os.path.join(src, 'audio', 'mak_loudness.c'),
                   read_src('mak_loudness.c'))
    patch_mak_scan_c(os.path.join(src, 'audio', 'mak_scan.c'))
    patch_mak_waveform_c(os.path.join(src, 'audio', 'mak_waveform.c'))
    patch_command_c(os.path.join(src, 'player', 'command.c'))
    patch_meson(os.path.join(src, 'meson.build'))


if __name__ == '__main__':
    main()
