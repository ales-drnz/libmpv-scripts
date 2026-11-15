#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
The read errors http.c hides: a body cut short ends with EIO, not as if it
were complete, and a chunked body read to its end ends as complete, not
with EIO.

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

The same happens to a chunked body from a server that says Accept-Ranges
(a transcode or a live stream of a media server): the reconnect asks for a
range, and the failed reply leaves filesize 0 and chunksize unset.

From FFmpeg 8.1.3 http_seek_internal() goes on with the old connection
only if it kept one: a short seek near the end of a range drains the old
connection and keeps none, and with no connection http_buf_read() answers
EIO, which needs no state put back. The same state is put back in both
forms, inside the block that restores the old connection (8.1.3, 9.0) or
after it (8.1.1).

The patch saves that state with the old buffer, and puts it back with it
when the new request fails, if the old response announced its size or was
chunked and had not reached its last chunk: then the cut body stays short
whatever the failed reply said, the loop tries again as
reconnect_delay_max allows, and returns AVERROR(EIO), which mpv reports as
a read error (patch_read_error.py). A user seek whose request fails goes on
with the old connection, which the restored state reads as it was (upstream
read the chunk sizes of a chunked body as data, or ended it).

A response of unknown size (no Content-Length, not chunked) ends where its
connection closes, and no cut can be told from its end: http.c reads every
such end as premature, and on a server with Range support its reconnect
past the end gets 416, whose reply then ends the file. That stays as
upstream has it; putting the state back there would retry a complete body
for seconds and end it with EIO. The same holds for a chunked body read
with multiple_requests, which keeps its connection after the last chunk
(chunkend): it is complete, and its state is not put back either.

===== A chunked body without its last chunk =====

Chunked encoding ends a body with a chunk of size 0, so a body that stops
before it is cut short, wherever the connection closes. Upstream sees two
of the three places: a close inside a chunk is EIO only without
Connection: close (the willclose test of http_buf_read() is for bodies
delimited by the close, not for chunked ones), and a close between two
chunks, where http_get_line() reads the size of the next one, comes back
as AVERROR_EOF. FFmpeg 9.0 sets willclose for every request that asks for
Connection: close, every one without multiple_requests, so there a close
inside a chunk is never EIO upstream. A live stream sent chunked (an internet radio, a transcode)
that drops ended as a normal end. The patch answers both with EIO and an
error in the log; a body closed by its last chunk ends as before.

===== A chunked body read to its last chunk =====

FFmpeg 9.0 answers a read with no connection left by the size of the body:
http_read_stream() returns EIO while the offset is short of filesize, and
AVERROR_EOF past it. A chunked body has no size (filesize stays UINT64_MAX),
and after its last chunk http_buf_read() closes the connection (without
multiple_requests): the next read then took every complete chunked body,
a finished transcode for one, for one cut short, and ended it with EIO.
The patch sets filesize to the offset at the last chunk, the size the body
turned out to have, so the end of the body ends with AVERROR_EOF on every
version. FFmpeg 8.1 ended it so already, and its size is only read there
by a seek, which past the end now stays where it is.

Whether the reconnect loop of http_read_stream() runs does not change: a
chunked body has no known size, so the loop takes any failed read for
premature, and a live stream without Range support is not resumed unless
reconnect_streamed is set (off by default, and then from the start).

Applied with patch_ffmpeg_segment_skips.py under the read_error toggle,
the FFmpeg side of patch_read_error.py: with the toggle off the build keeps
upstream's http.c.

MARKER-guarded: MAK_HTTP_READ_ERRORS_V2 in every inserted hunk.

Usage:
    python3 patch_ffmpeg_http_read_errors.py <ffmpeg_src_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402


MARKER = 'MAK_HTTP_READ_ERRORS_V2'

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

# The state goes back with the old connection. FFmpeg 8.1.3 puts the old
# connection back only when there was one (the soft seek of a short seek
# drains it and keeps no old one), in a block of its own; 8.1.1 put it back
# in any case.
RESTORE_STATE = (
    '/* ' + MARKER + ': a body of known size, or chunked and before\n'
    ' * its last chunk, can be cut short. */\n'
    'if (old_filesize != UINT64_MAX ||\n'
    '    (old_chunksize != UINT64_MAX && !s->chunkend)) {\n'
    '    s->filesize         = old_filesize;\n'
    '    s->chunksize        = old_chunksize;\n'
    '    s->icy_data_read    = old_icy_data_read;\n'
    '    s->willclose        = old_willclose;\n'
    '    s->end_header       = old_end_header;\n'
    '    s->end_chunked_post = old_end_chunked_post;\n'
    '#if CONFIG_ZLIB\n'
    '    s->compressed       = old_compressed;\n'
    '#endif\n'
    '}\n'
)


def indent(text, n):
    return ''.join((' ' * n + line if line and not line.startswith('#') else line)
                   for line in text.splitlines(True))


RESTORE = (
    '            s->hd      = old_hd;\n'
    '            s->off     = old_off;\n'
    '        }\n'
)

RESTORE_NEW = (
    '            s->hd      = old_hd;\n'
    '            s->off     = old_off;\n'
    + indent(RESTORE_STATE, 12) +
    '        }\n'
)

RESTORE_811 = (
    '        s->hd      = old_hd;\n'
    '        s->off     = old_off;\n'
    '        return ret;\n'
)

RESTORE_811_NEW = (
    '        s->hd      = old_hd;\n'
    '        s->off     = old_off;\n'
    + indent(RESTORE_STATE, 8) +
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

# http_buf_read(): the last chunk of a body read without multiple_requests,
# which closes the connection.
LAST_CHUNK = (
    '            else if (!s->chunksize) {\n'
    '                av_log(h, AV_LOG_DEBUG, "Last chunk received, closing conn\\n");\n'
    '                ffurl_closep(&s->hd);\n'
)

LAST_CHUNK_NEW = (
    '            else if (!s->chunksize) {\n'
    '                av_log(h, AV_LOG_DEBUG, "Last chunk received, closing conn\\n");\n'
    '                /* ' + MARKER + ': the body is complete and its size known:\n'
    '                 * with no connection left, a read short of filesize is\n'
    '                 * EIO (FFmpeg 9.0), and a chunked body has none. */\n'
    '                s->filesize = s->off;\n'
    '                ffurl_closep(&s->hd);\n'
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
    if p.edits(HTTP, [
        ('http_seek_internal saves the old context', SAVE, SAVE_NEW),
        ('http_buf_read size line of a chunk', CHUNK_SIZE_LINE, CHUNK_SIZE_LINE_NEW),
        ('http_buf_read last chunk', LAST_CHUNK, LAST_CHUNK_NEW),
        ('http_buf_read read of the body', BODY_READ, BODY_READ_NEW),
    ]):
        p.optional(HTTP, [(RESTORE, RESTORE_NEW), (RESTORE_811, RESTORE_811_NEW)],
                   'http_seek_internal failed request')


anchor.main(apply, 'patch_ffmpeg_http_read_errors', marker=MARKER,
            usage='<ffmpeg_src_dir>')
