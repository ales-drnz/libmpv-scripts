#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Keep a body cut short when the reconnect to resume it fails.

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

This patch saves that state with the old buffer, and puts it back with it
when the new request fails. The cut body stays short whatever the failed
reply said: the loop tries again as reconnect_delay_max allows, and then
returns AVERROR(EIO), which mpv reports as a read error
(patch_read_error.py). A user seek whose request fails goes on with the
old connection as it is, as upstream intended.

Applied with patch_ffmpeg_segment_skips.py under the read_error toggle,
the FFmpeg side of patch_read_error.py: with the toggle off the build keeps
upstream's http.c.

MARKER-guarded: MAK_HTTP_RECONNECT_V1 in every inserted hunk.

Usage:
    python3 patch_ffmpeg_http_reconnect.py <ffmpeg_src_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402


MARKER = 'MAK_HTTP_RECONNECT_V1'

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
    '        /* ' + MARKER + ' */\n'
    '        s->filesize         = old_filesize;\n'
    '        s->chunksize        = old_chunksize;\n'
    '        s->icy_data_read    = old_icy_data_read;\n'
    '        s->willclose        = old_willclose;\n'
    '        s->end_header       = old_end_header;\n'
    '        s->end_chunked_post = old_end_chunked_post;\n'
    '#if CONFIG_ZLIB\n'
    '        s->compressed       = old_compressed;\n'
    '#endif\n'
    '        return ret;\n'
)


def apply(p):
    p.edits(HTTP, [
        ('http_seek_internal saves the old context', SAVE, SAVE_NEW),
        ('http_seek_internal failed request', RESTORE, RESTORE_NEW),
    ])


anchor.main(apply, 'patch_ffmpeg_http_reconnect', marker=MARKER,
            usage='<ffmpeg_src_dir>')
