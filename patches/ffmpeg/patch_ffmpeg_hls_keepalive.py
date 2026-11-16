#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
The HLS demuxer of FFmpeg 9.0 keeps its persistent connections when the
caller reads the playlist through an AVIOContext of its own.

hls_read_header() of FFmpeg 9.0 turns http_persistent off, and the
autodetection of http_multiple with it, when s->pb has no URLContext,
taking that for a custom io_open: open_url_keepalive() asserts that the
AVIOContext of a segment has one. But s->pb is the playlist only, and
says nothing of how the segments open. mpv reads the playlist through its
own stream (an AVIOContext of mp_read, demux_lavf.c) and opens the
segments with libavformat's default io_open (nested_io_open, without
libcurl), whose AVIOContexts have a URLContext: under mpv every HLS stream
lost its persistent connection, one TCP (and TLS) connection per segment
instead of one for them all, and the next segment was no longer fetched
ahead, with a warning at every open.

This patch takes the test out, and makes open_url_keepalive() check the
AVIOContext it is given instead: one without a URLContext (an io_open
that is really custom, such as mpv's libcurl backend) is closed and
answered with AVERROR_EOF, the answer of a connection the server ended.
Both callers then open a new one, as when ff_http_do_new_request2()
fails: open_url() calls io_open again, and parse_playlist() opens the
playlist again. AVERROR_EOF keeps both from logging a warning at every
segment. The autodetection of http_multiple reads http_version from the
segment's AVIOContext, and keeps its default (-1, no prefetch) where
there is none.

FFmpeg 9.0 only: 8.1 has neither the test nor the need.

MARKER-guarded: MAK_HLS_KEEPALIVE_V1 in every inserted hunk.

Usage:
    python3 patch_ffmpeg_hls_keepalive.py <ffmpeg_src_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402


MARKER = 'MAK_HLS_KEEPALIVE_V1'

HLS = 'libavformat/hls.c'

# open_url_keepalive(): the URLContext of the AVIOContext to reuse.
KEEPALIVE = (
    '    URLContext *uc = ffio_geturlcontext(*pb);\n'
    '    av_assert0(uc);\n'
    '    (*pb)->eof_reached = 0;\n'
)

KEEPALIVE_NEW = (
    '    URLContext *uc = ffio_geturlcontext(*pb);\n'
    '    /* ' + MARKER + ': an AVIOContext of a custom io_open has no\n'
    '     * URLContext to send the next request on. It is closed, and the\n'
    '     * caller opens a new one, as when the server ended the connection\n'
    '     * (AVERROR_EOF, which it does not log). */\n'
    '    if (!uc) {\n'
    '        ff_format_io_close(s, pb);\n'
    '        return AVERROR_EOF;\n'
    '    }\n'
    '    (*pb)->eof_reached = 0;\n'
)

# hls_read_header(): the test on s->pb.
CUSTOM_IO = (
    '    /* http_persistent and http_multiple auto-detection both rely on the\n'
    '     * AVIOContext being backed by the builtin URLContext. Neither works\n'
    '     * when io_open is overridden with a custom callback. */\n'
    '    if (!ffio_geturlcontext(s->pb)) {\n'
    '        if (c->http_persistent) {\n'
    '            av_log(s, AV_LOG_WARNING, "Disabling http_persistent due to custom io_open.\\n");\n'
    '            c->http_persistent = 0;\n'
    '        }\n'
    '        /* Only auto-detection is disabled, enabling http_multiple can still work\n'
    '         * with custom io_open. */\n'
    '        if (c->http_multiple == -1) {\n'
    '            av_log(s, AV_LOG_WARNING, "Disabling http_multiple due to custom io_open.\\n");\n'
    '            c->http_multiple = 0;\n'
    '        }\n'
    '    }\n'
    '\n'
)

CUSTOM_IO_NEW = (
    '    /* ' + MARKER + ': s->pb is the playlist only. The segments\n'
    '     * open through io_open, and open_url_keepalive() opens a new\n'
    '     * connection for an AVIOContext without a URLContext. */\n'
    '\n'
)


def apply(p):
    p.edits(HLS, [
        ('open_url_keepalive URLContext', KEEPALIVE, KEEPALIVE_NEW),
        ('hls_read_header custom io_open', CUSTOM_IO, CUSTOM_IO_NEW),
    ])


anchor.main(apply, 'patch_ffmpeg_hls_keepalive', marker=MARKER,
            usage='<ffmpeg_src_dir>')
