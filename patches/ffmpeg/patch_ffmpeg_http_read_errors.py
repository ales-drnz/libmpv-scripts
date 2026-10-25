#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
The read errors http.c hides: a body cut short ends with EIO, not as if it
were complete.

===== A reconnect that fails =====

With reconnect=1 (mpv sets it, with reconnect_delay_max=7) http.c answers a
body shorter than its Content-Length by reconnecting at the offset it
reached: http_read_stream() calls http_seek_internal(), which opens a new
request and, if that fails, goes on with the old connection. But
http_open_cnx() resets the state of the response the old connection carries
(http_connect(): filesize, willclose, chunksize, ...), and the reply to the
failed request leaves its own: a 503 or a 403 (an expired signed URL) with
Content-Length: 0 sets filesize to 0. The old connection is then read as a
body that has nothing left: http_buf_read() returns AVERROR_EOF, the loop
sees nothing premature and stops, and the file ends as if it were complete.
A reconnect that fails before a reply (no network) keeps filesize, so the
same cut ends with EIO after the retries.

The patch saves that state with the old buffer, and puts it back with it
when the new request fails, if the old response announced its size: then
the cut body stays short whatever the failed reply said, the loop tries
again as reconnect_delay_max allows, and returns AVERROR(EIO), which mpv
reports as a read error (patch_read_error.py). A user seek whose request
fails goes on with the old connection as it is, as upstream intended.

A response of unknown size (no Content-Length) ends where its connection
closes, and no cut can be told from its end: http.c reads every such end as
premature, and on a server with Range support its reconnect past the end
gets 416, whose reply then ends the file. That stays as upstream has it;
putting the state back there would retry a complete body for seconds and
end it with EIO.

===== A chunked body without its last chunk =====

Chunked encoding ends a body with a chunk of size 0, so a body that stops
before it is cut short, wherever the connection closes. Upstream sees two
of the three places: a close inside a chunk is EIO only without
Connection: close (the willclose test of http_buf_read() is for bodies
delimited by the close, not for chunked ones), and a close between two
chunks, where http_get_line() reads the size of the next one, comes back
as AVERROR_EOF. A live stream sent chunked (an internet radio, a transcode)
that drops ended as a normal end. The patch answers both with EIO and an
error in the log; a body closed by its last chunk ends as before.

Whether the reconnect loop of http_read_stream() runs does not change: a
chunked body has no known size, so the loop takes any failed read for
premature, and a live stream without Range support is not resumed unless
reconnect_streamed is set (off by default, and then from the start).

Applied with patch_ffmpeg_segment_skips.py under the read_error toggle,
the FFmpeg side of patch_read_error.py: with the toggle off the build keeps
upstream's http.c.

MARKER-guarded: MAK_HTTP_READ_ERRORS_V1 in every inserted hunk.

Usage:
    python3 patch_ffmpeg_http_read_errors.py <ffmpeg_src_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402


MARKER = 'MAK_HTTP_READ_ERRORS_V1'

HTTP = 'libavformat/http.c'

SAVE = (
    '    /* we save the old context in case the seek fails */\n'
    '    old_buf_size = s->buf_end - s->buf_ptr;\n'
    '    memcpy(old_buf, s->buf_ptr, old_buf_size);\n'
)

SAVE_NEW = SAVE + (
    '    /* ' + MARKER + ': and the state of the response the old connection\n'
    '     * carries, which http_connect() resets and the reply to a failed\n'
    '     * request overwrites (a Content-Length: 0 made the cut body look\n'
    '     * complete). */\n'
    '    uint64_t old_filesize = s->filesize, old_chunksize = s->chunksize;\n'
    '    uint64_t old_icy_data_read = s->icy_data_read;\n'
    '    int old_willclose = s->willclose, old_end_header = s->end_header;\n'
    '    int old_end_chunked_post = s->end_chunked_post;\n'
    '#if CONFIG_ZLIB\n'
    '    int old_compressed = s->compressed;\n'
    '#endif\n'
)

RESTORE = (
    '        s->hd      = old_hd;\n'
    '        s->off     = old_off;\n'
    '        return ret;\n'
)

RESTORE_NEW = (
    '        s->hd      = old_hd;\n'
    '        s->off     = old_off;\n'
    '        /* ' + MARKER + ': only a body of known size can be cut short. */\n'
    '        if (old_filesize != UINT64_MAX) {\n'
    '            s->filesize         = old_filesize;\n'
    '            s->chunksize        = old_chunksize;\n'
    '            s->icy_data_read    = old_icy_data_read;\n'
    '            s->willclose        = old_willclose;\n'
    '            s->end_header       = old_end_header;\n'
    '            s->end_chunked_post = old_end_chunked_post;\n'
    '#if CONFIG_ZLIB\n'
    '            s->compressed       = old_compressed;\n'
    '#endif\n'
    '        }\n'
    '        return ret;\n'
)


# http_buf_read(): the size line of the next chunk.
CHUNK_SIZE_LINE = (
    '            do {\n'
    '                if ((err = http_get_line(s, line, sizeof(line))) < 0)\n'
    '                    return err;\n'
    '            } while (!*line);    /* skip CR LF from last chunk */\n'
)

CHUNK_SIZE_LINE_NEW = (
    '            do {\n'
    '                if ((err = http_get_line(s, line, sizeof(line))) < 0) {\n'
    '                    /* ' + MARKER + ': closed before the last chunk. */\n'
    '                    if (err == AVERROR_EOF) {\n'
    '                        av_log(h, AV_LOG_ERROR,\n'
    '                               "Chunked stream ends without its last chunk at %"PRIu64"\\n",\n'
    '                               s->off);\n'
    '                        return AVERROR(EIO);\n'
    '                    }\n'
    '                    return err;\n'
    '                }\n'
    '            } while (!*line);    /* skip CR LF from last chunk */\n'
)

# http_buf_read(): the read of the body, here inside a chunk when chunked.
BODY_READ = (
    '        len = ffurl_read(s->hd, buf, size);\n'
    '        if ((!len || len == AVERROR_EOF) &&\n'
)

BODY_READ_NEW = (
    '        len = ffurl_read(s->hd, buf, size);\n'
    '        /* ' + MARKER + ': a close inside a chunk cuts the body short,\n'
    '         * Connection: close or not. */\n'
    '        if ((!len || len == AVERROR_EOF) && s->chunksize != UINT64_MAX) {\n'
    '            av_log(h, AV_LOG_ERROR,\n'
    '                   "Chunked stream ends prematurely at %"PRIu64", %"PRIu64" bytes before the end of a chunk\\n",\n'
    '                   s->off, s->chunksize);\n'
    '            return AVERROR(EIO);\n'
    '        }\n'
    '        if ((!len || len == AVERROR_EOF) &&\n'
)


def apply(p):
    p.edits(HTTP, [
        ('http_seek_internal saves the old context', SAVE, SAVE_NEW),
        ('http_seek_internal failed request', RESTORE, RESTORE_NEW),
        ('http_buf_read size line of a chunk', CHUNK_SIZE_LINE, CHUNK_SIZE_LINE_NEW),
        ('http_buf_read read of the body', BODY_READ, BODY_READ_NEW),
    ])


anchor.main(apply, 'patch_ffmpeg_http_read_errors', marker=MARKER,
            usage='<ffmpeg_src_dir>')
