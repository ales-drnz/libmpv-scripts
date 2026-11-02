#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Keeps the edit list of fragmented MP4 in the segments of a DASH stream.

Upstream mov.c turns advanced_editlist off for a fragmented MP4 (no stts
entries in the moov, the timing comes in the trun atoms):

    if (!sc->stts_count && c->advanced_editlist) {
        av_log(c->fc, AV_LOG_VERBOSE, "advanced_editlist does not work with fragmented "
                                      "MP4. disabling.\\n");
        c->advanced_editlist = 0;
        c->advanced_editlist_autodisabled = 1;
    }

Then the edit list of the moov sets start_pad, and the AAC priming it
declares (1024 samples from FFmpeg's encoder, 2112 from Apple's) is
skipped once, on the first packet. That is right for a file and for HLS,
where one mov demuxer reads the whole stream.

dashdec.c opens a new mov demuxer for every segment (reopen_demux_for_
component, when a segment ends) and reads the init section again: the
priming is skipped again at the start of each segment, so real audio is
cut out at every boundary, a click every few seconds.

This patch adds a private option to the mov demuxer, mak_frag_editlist
(default 0). At 0 the upstream autodisable runs as before. At 1 it is
skipped: start_pad is not set and nothing is cut, at the price of the
priming of the first segment, which stays at the start of the stream.
dashdec.c sets it to 1 in reopen_demux_for_component, next to the
decryption keys it passes the same way.

verify_binaries.sh finds the option name in the native binaries.

Usage:
    python3 patch_ffmpeg_advanced_editlist.py <ffmpeg_source_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402


MARKER = 'MAK_FRAG_EDITLIST_PATCH_V2'

ISOM_FIELD = (
    '    int advanced_editlist_autodisabled;\n',
    '    int advanced_editlist_autodisabled;\n'
    '    int mak_frag_editlist; /* ' + MARKER + ' */\n',
)

MOV_AUTODISABLE = (
    '    if (!sc->stts_count && c->advanced_editlist) {\n',
    '    /* ' + MARKER + ': kept on with mak_frag_editlist,\n'
    '     * which the DASH demuxer sets: it reopens the demuxer at every\n'
    '     * segment, and the priming the edit list skips would be cut\n'
    '     * again each time. */\n'
    '    if (!sc->stts_count && c->advanced_editlist && !c->mak_frag_editlist) {\n',
)

MOV_OPTION = (
    '    {"ignore_chapters", "", OFFSET(ignore_chapters), AV_OPT_TYPE_BOOL, {.i64 = 0},\n',
    '    {"mak_frag_editlist",\n'
    '        "keep advanced_editlist on fragmented MP4 (set by the DASH demuxer)",\n'
    '        OFFSET(mak_frag_editlist), AV_OPT_TYPE_BOOL, {.i64 = 0},\n'
    '        0, 1, FLAGS},\n'
    '    {"ignore_chapters", "", OFFSET(ignore_chapters), AV_OPT_TYPE_BOOL, {.i64 = 0},\n',
)

DASH_REOPEN = (
    '    if (c->cenc_decryption_keys)\n'
    '        av_dict_set(&in_fmt_opts, "decryption_keys", c->cenc_decryption_keys, 0);\n',
    '    if (c->cenc_decryption_keys)\n'
    '        av_dict_set(&in_fmt_opts, "decryption_keys", c->cenc_decryption_keys, 0);\n'
    '    /* ' + MARKER + ': each segment opens a new demuxer, which\n'
    '     * would skip the priming of the edit list again. */\n'
    '    av_dict_set(&in_fmt_opts, "mak_frag_editlist", "1", 0);\n',
)


def apply(p):
    # A missing anchor: the upstream layout changed. Review the patch
    # against mov.c around "advanced_editlist does not work with fragmented
    # MP4", MOVContext in isom.h and reopen_demux_for_component in dashdec.c.
    p.edits('libavformat/isom.h', [ISOM_FIELD])
    p.edits('libavformat/mov.c', [MOV_AUTODISABLE, MOV_OPTION])
    p.edits('libavformat/dashdec.c', [DASH_REOPEN])


anchor.main(apply, 'patch_ffmpeg_advanced_editlist', marker=MARKER,
            usage='<ffmpeg_src_dir>')
