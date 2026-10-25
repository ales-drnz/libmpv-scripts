#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Count the segments the HLS and DASH demuxers lose to an error.

Both demuxers play on over a segment they cannot read. hls.c skips a
segment that does not open once seg_max_retry is spent (0 by default, so
at the first failure) with a warning, and drops the rest of a segment
whose reading fails without a word: read_data_continuous() goes on to the
next one for any result of read_from_url() but data. dashdec.c does the
same with a fragment that does not open, and with one whose reading fails,
and dash_read_packet() ends with AVERROR_EOF in any case. The stream then
ends as a normal EOF, and its holes are nowhere but in the log.

This patch counts them in a read-only option of each demuxer,
skipped_segments (int64, AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY), which
mpv reads after every packet with av_opt_get_int(..., AV_OPT_SEARCH_CHILDREN)
on the AVFormatContext (patch_read_error.py). An exported option, as http.c
exports mime_type and icy_metadata_packet, needs no new API and no struct
layout on the reader's side: mpv built against an FFmpeg without the patch
finds no option and reads 0. Counted:

  - a segment (HLS) or fragment (DASH) skipped because it did not open;
  - a segment or fragment whose reading ended on an error and not at its
    end (EIO of a body shorter than its Content-Length, a dropped
    connection), once per segment. A new warning says it in hls.c and
    dashdec.c.

Not counted: AVERROR_EXIT (a cancel), the retries of a segment that opens
in the end (seg_max_retry), and the segments a live HLS playlist expired
before they were read (a client that fell behind, not an error).

The count only grows: a seek does not reset it. It is per AVFormatContext,
so per file in mpv.

Applied with patch_ffmpeg_http_reconnect.py under the read_error toggle,
after patch_ffmpeg_dash_keepalive.py, whose anchors in dashdec.c it leaves
alone; it also applies on a dashdec.c without it.

MARKER-guarded: MAK_SEGMENT_SKIPS_V1 in every inserted hunk.

Usage:
    python3 patch_ffmpeg_segment_skips.py <ffmpeg_src_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402


MARKER = 'MAK_SEGMENT_SKIPS_V1'

HLS = 'libavformat/hls.c'
DASH = 'libavformat/dashdec.c'

# The option, the same in both demuxers. FLAGS is the demuxer's
# AV_OPT_FLAG_DECODING_PARAM.
OPTION = (
    '    /* ' + MARKER + ' */\n'
    '    {"skipped_segments", "Segments lost to an error, in whole or in part (exported)",\n'
    '        OFFSET(skipped_segments), AV_OPT_TYPE_INT64, {.i64 = 0}, 0, INT64_MAX,\n'
    '        FLAGS | AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY},\n'
)


# ─── hls.c ─────────────────────────────────────────────────────────────

HLS_CONTEXT = (
    '    HLSCryptoContext  crypto_ctx;\n'
    '} HLSContext;\n'
)

HLS_CONTEXT_NEW = (
    '    HLSCryptoContext  crypto_ctx;\n'
    '    /* ' + MARKER + ': the skipped_segments option. */\n'
    '    int64_t skipped_segments;\n'
    '} HLSContext;\n'
)

HLS_SKIP = (
    'failed too many times, skipping\\n",\n'
    '                       v->cur_seq_no,\n'
    '                       v->index);\n'
    '                v->cur_seq_no++;\n'
)

HLS_SKIP_NEW = HLS_SKIP + (
    '                c->skipped_segments++; /* ' + MARKER + ' */\n'
)

# The end of a segment: whatever read_from_url() returned but data, the
# segment is closed and the next one opened.
HLS_END = (
    '    if (c->http_persistent &&\n'
    '        seg->key_type == KEY_NONE && av_strstart(seg->url, "http", NULL)) {\n'
    '        v->input_read_done = 1;\n'
)

HLS_END_NEW = (
    '    /* ' + MARKER + ': the reading ended on an error and not at the end\n'
    '     * of the segment, whose rest is lost. */\n'
    '    if (ret < 0 && ret != AVERROR_EOF && ret != AVERROR_EXIT) {\n'
    '        av_log(v->parent, AV_LOG_WARNING,\n'
    '               "Segment %"PRId64" of playlist %d ended on a read error: %s\\n",\n'
    '               v->cur_seq_no, v->index, av_err2str(ret));\n'
    '        c->skipped_segments++;\n'
    '    }\n'
    + HLS_END
)

HLS_OPTIONS_END = (
    '    {NULL}\n'
    '};\n'
    '\n'
    'static const AVClass hls_class = {\n'
)


# ─── dashdec.c ─────────────────────────────────────────────────────────

DASH_CONTEXT = '} DASHContext;\n'

DASH_CONTEXT_NEW = (
    '    /* ' + MARKER + ': the skipped_segments option. */\n'
    '    int64_t skipped_segments;\n'
    + DASH_CONTEXT
)

# The flag that counts a fragment once: after a read error read_data() can
# be called again on the same input (avio_feof() retries the read).
DASH_REP = '    int is_restart_needed;\n'

DASH_REP_NEW = DASH_REP + (
    '    int read_error_counted;  /* ' + MARKER + ' */\n'
)

# The opening of the next fragment, in both forms of read_data() (with and
# without patch_ffmpeg_dash_keepalive.py).
DASH_OPEN = (
    '        free_fragment(&v->cur_seg);\n'
    '        v->cur_seg = get_current_fragment(v);\n'
)

DASH_OPEN_NEW = (
    '        v->read_error_counted = 0; /* ' + MARKER + ' */\n'
    + DASH_OPEN
)

DASH_SKIP = (
    '            av_log(v->parent, AV_LOG_WARNING, "Failed to open fragment of playlist\\n");\n'
    '            v->cur_seq_no++;\n'
)

DASH_SKIP_NEW = DASH_SKIP + (
    '            c->skipped_segments++; /* ' + MARKER + ' */\n'
)

DASH_READ = (
    '    ret = read_from_url(v, v->cur_seg, buf, buf_size);\n'
    '    if (ret > 0)\n'
    '        goto end;\n'
)

DASH_READ_NEW = DASH_READ + (
    '\n'
    '    /* ' + MARKER + ': the reading ended on an error and not at the end\n'
    '     * of the fragment, whose rest is lost. */\n'
    '    if (ret < 0 && ret != AVERROR_EOF && ret != AVERROR_EXIT &&\n'
    '        !v->read_error_counted) {\n'
    '        av_log(v->parent, AV_LOG_WARNING,\n'
    '               "Fragment %"PRId64" of playlist ended on a read error: %s\\n",\n'
    '               v->cur_seq_no, av_err2str(ret));\n'
    '        v->read_error_counted = 1;\n'
    '        c->skipped_segments++;\n'
    '    }\n'
)

DASH_OPTIONS_END = (
    '    {NULL}\n'
    '};\n'
    '\n'
    'static const AVClass dash_class = {\n'
)


def apply(p):
    p.edits(HLS, [
        ('HLSContext end', HLS_CONTEXT, HLS_CONTEXT_NEW),
        ('segment skipped after seg_max_retry', HLS_SKIP, HLS_SKIP_NEW),
        ('end of a segment', HLS_END, HLS_END_NEW),
        ('hls_options end', HLS_OPTIONS_END, OPTION + HLS_OPTIONS_END),
    ])
    p.edits(DASH, [
        ('DASHContext end', DASH_CONTEXT, DASH_CONTEXT_NEW),
        ('struct representation', DASH_REP, DASH_REP_NEW),
        ('opening of a fragment', DASH_OPEN, DASH_OPEN_NEW),
        ('fragment that does not open', DASH_SKIP, DASH_SKIP_NEW),
        ('end of a fragment', DASH_READ, DASH_READ_NEW),
        ('dash_options end', DASH_OPTIONS_END, OPTION + DASH_OPTIONS_END),
    ])


anchor.main(apply, 'patch_ffmpeg_segment_skips', marker=MARKER,
            usage='<ffmpeg_src_dir>')
