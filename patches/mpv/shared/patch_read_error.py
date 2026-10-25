# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Tell a file that ended from a file whose reading stopped on an error.

Upstream mpv ends both the same way: MPV_EVENT_END_FILE with reason EOF and
error 0. An HTTP body shorter than its Content-Length makes FFmpeg's http.c
return EIO ("Stream ends prematurely"), but stream_lavf.c turns every
failed read into -1 and the stream layer into its end of stream, so the
demuxer sees a plain EOF. A read error of FFmpeg's own demuxers (HLS and
DASH open their URLs themselves) ends as EOF too, after ten tries
(demux_lavf.c). And the HLS and DASH demuxers skip a segment that does not
open, or whose reading fails, with a warning at most: the stream plays on
with a hole and ends as a normal EOF.

This patch carries both to the client, without changing the playback: the
same end, the same playlist advance, the same keep-open park.

  - The stream layer remembers that its last read failed with an error and
    not at the end (stream->mak_read_error, set by stream_lavf.c), cleared
    by every read and seek as eof is. A seek also clears the error avio
    keeps, so a read that resumes and reaches the real end is not taken
    for the old error.
  - demux_lavf.c remembers that av_read_frame() failed with an error
    (demuxer->mak_read_error), and reads the segments lost so far from the
    skipped_segments option of the HLS and DASH demuxers
    (patch_ffmpeg_segment_skips.py; with another FFmpeg the option is not
    there and the count stays 0).
  - demux.c keeps, with eof, whether the read that ended the file failed
    (demuxer or stream), false again once a read gets on, and the count;
    struct demux_reader_state hands both to the player.
  - Two properties of the current file, unavailable without one:
    demuxer-read-error (flag) and demuxer-skipped-segments (int64). They
    change when the demuxer stops reading, before eof-reached, and are
    notified with the cache properties. With keep-open the last entry
    parks without END_FILE: these properties are how a client reads it
    there.
  - MPV_EVENT_END_FILE gets two fields at the end, mak_read_error and
    mak_skipped_segments: the properties when the file was closed, for
    every reason. The error field keeps its documented meaning (0 unless
    the reason is MPV_END_FILE_REASON_ERROR): a client that tests error
    or counts errors sees no change. The struct grows at the end, so a
    client built against the upstream header reads it as before; a client
    that reads the new fields checks first that the libmpv has the
    demuxer-read-error property. The node form of the event (scripts,
    JSON IPC) gets read_error and skipped_segments.

The C of the properties is in read_error/read_error_command_insert.c, the
fields of client.h in read_error/end_file_fields_insert.h.

Files patched
=============

    stream/stream.h, stream.c     stream->mak_read_error
    stream/stream_lavf.c          set on a read error, avio error cleared
                                  on a seek
    demux/demux.h                 struct demuxer and demux_reader_state
    demux/demux.c                 kept with eof, read by the reader state
    demux/demux_lavf.c            av_read_frame() errors, skipped_segments
    player/loadfile.c             the END_FILE fields
    player/command.c              the two properties and their notification
    player/client.c               the node form of END_FILE
    include/mpv/client.h          the END_FILE fields

Usage: patch_read_error.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = 'MAK_READ_ERROR_PATCH_V1'

STREAM_H = 'stream/stream.h'
STREAM_C = 'stream/stream.c'
STREAM_LAVF = 'stream/stream_lavf.c'
DEMUX_H = 'demux/demux.h'
DEMUX_C = 'demux/demux.c'
DEMUX_LAVF = 'demux/demux_lavf.c'
LOADFILE = 'player/loadfile.c'
COMMAND = 'player/command.c'
CLIENT_C = 'player/client.c'
CLIENT_H = 'include/mpv/client.h'


# ─── stream ────────────────────────────────────────────────────────────

STREAM_FIELD = (
    '    int eof; // valid only after read calls that returned a short result\n'
)

STREAM_FIELD_NEW = STREAM_FIELD + (
    '    // ' + MARKER + ': the last read stopped on an error and not at the\n'
    '    // end of the stream. fill_buffer sets it; each read and each seek\n'
    '    // clears it first, as eof.\n'
    '    bool mak_read_error;\n'
)

STREAM_READ = (
    '    int res = 0;\n'
    '    // we will retry even if we already reached EOF previously.\n'
)

STREAM_READ_NEW = (
    '    int res = 0;\n'
    '    s->mak_read_error = false; // ' + MARKER + '\n'
    '    // we will retry even if we already reached EOF previously.\n'
)

STREAM_SEEK = (
    '    s->eof = 0; // eof should be set only on read; seeking always clears it\n'
)

STREAM_SEEK_NEW = STREAM_SEEK + (
    '    s->mak_read_error = false; // ' + MARKER + '\n'
)

LAVF_FILL = (
    '    int r = avio_read_partial(avio, buffer, max_len);\n'
    '    return (r <= 0) ? -1 : r;\n'
)

LAVF_FILL_NEW = (
    '    int r = avio_read_partial(avio, buffer, max_len);\n'
    '    // ' + MARKER + ': an error and not the end of the stream, such as\n'
    '    // the EIO of http.c for a body shorter than its Content-Length.\n'
    '    // AVERROR_EXIT is a cancel (stop, quit), not a read error.\n'
    '    if (r < 0 && r != AVERROR_EOF && r != AVERROR_EXIT)\n'
    '        s->mak_read_error = true;\n'
    '    return (r <= 0) ? -1 : r;\n'
)

LAVF_SEEK = (
    '    if (avio_seek(avio, newpos, SEEK_SET) < 0) {\n'
    '        return 0;\n'
    '    }\n'
    '    return 1;\n'
)

LAVF_SEEK_NEW = (
    '    if (avio_seek(avio, newpos, SEEK_SET) < 0) {\n'
    '        return 0;\n'
    '    }\n'
    '    // ' + MARKER + ': avio keeps the error of a failed read until it is\n'
    '    // closed, and avio_read_partial() would answer it again at the real\n'
    '    // end of the stream once this seek reads on.\n'
    '    avio->error = 0;\n'
    '    return 1;\n'
)


# ─── demux ─────────────────────────────────────────────────────────────

READER_STATE = '    uint64_t bytes_per_second; // low level statistics\n'

READER_STATE_NEW = READER_STATE + (
    '    // ' + MARKER + ': the reading stopped on a read error, and the HLS\n'
    '    // or DASH segments lost to errors (struct demuxer).\n'
    '    bool mak_read_error;\n'
    '    int64_t mak_skipped_segments;\n'
)

DEMUXER_END = (
    '    struct stream *stream;\n'
    '} demuxer_t;\n'
)

DEMUXER_END_NEW = (
    '    struct stream *stream;\n'
    '\n'
    '    // ' + MARKER + ': set by the demuxer implementation, on the thread\n'
    '    // side. mak_read_error: its last read failed with an error and not\n'
    '    // at the end of the file (demux.c also checks the stream).\n'
    '    // mak_skipped_segments: the HLS or DASH segments lost so far.\n'
    '    bool mak_read_error;\n'
    '    int64_t mak_skipped_segments;\n'
    '} demuxer_t;\n'
)

INTERNAL_EOF = '    bool eof;                   // whether we\'re in EOF state\n'

INTERNAL_EOF_NEW = INTERNAL_EOF + (
    '    // ' + MARKER + ': the read that set eof failed with an error, of the\n'
    '    // demuxer or of its stream; the segments the demuxer lost so far.\n'
    '    bool mak_read_error;\n'
    '    int64_t mak_skipped_segments;\n'
)

READ_PACKET_END = (
    '        in->eof = eof;\n'
    '        in->reading = !eof;\n'
    '    }\n'
    '    return true;\n'
    '}\n'
)

READ_PACKET_END_NEW = (
    '        in->eof = eof;\n'
    '        in->reading = !eof;\n'
    '        // ' + MARKER + ': false again as soon as a read gets on.\n'
    '        in->mak_read_error = eof && (demux->mak_read_error ||\n'
    '                             (demux->stream && demux->stream->mak_read_error));\n'
    '    }\n'
    '    in->mak_skipped_segments = demux->mak_skipped_segments; // ' + MARKER + '\n'
    '    return true;\n'
    '}\n'
)

READER_STATE_INIT = (
    '        .file_cache_bytes = in->cache ? demux_cache_get_size(in->cache) : -1,\n'
)

READER_STATE_INIT_NEW = READER_STATE_INIT + (
    '        .mak_read_error = in->mak_read_error, // ' + MARKER + '\n'
    '        .mak_skipped_segments = in->mak_skipped_segments,\n'
)

LAVF_PRIV = '    int retry_counter;\n'

LAVF_PRIV_NEW = LAVF_PRIV + (
    '\n'
    '    // ' + MARKER + ': the demuxer exports skipped_segments.\n'
    '    bool mak_skips;\n'
)

LAVF_OPEN = '    priv->avfc = avfc;\n'

LAVF_OPEN_NEW = LAVF_OPEN + (
    '\n'
    '    // ' + MARKER + ': the HLS and DASH demuxers of libmpv-scripts export\n'
    '    // the segments they lost (patch_ffmpeg_segment_skips.py); another\n'
    '    // FFmpeg has no such option.\n'
    '    int64_t mak_skipped = 0;\n'
    '    priv->mak_skips = av_opt_get_int(avfc, "skipped_segments",\n'
    '                                     AV_OPT_SEARCH_CHILDREN, &mak_skipped) >= 0;\n'
)

LAVF_READ = (
    '    int r = av_read_frame(priv->avfc, pkt);\n'
    '    update_read_stats(demux);\n'
)

LAVF_READ_NEW = LAVF_READ + (
    '    // ' + MARKER + ': whether this read failed with an error and not at\n'
    '    // the end (the tenth in a row stops the reading for good, below),\n'
    '    // and the segments lost so far.\n'
    '    demux->mak_read_error = r < 0 && r != AVERROR_EOF && r != AVERROR_EXIT;\n'
    '    if (priv->mak_skips) {\n'
    '        int64_t skipped = 0;\n'
    '        if (av_opt_get_int(priv->avfc, "skipped_segments",\n'
    '                           AV_OPT_SEARCH_CHILDREN, &skipped) >= 0)\n'
    '            demux->mak_skipped_segments = skipped;\n'
    '    }\n'
)


# ─── player ────────────────────────────────────────────────────────────

# bulk_analysis puts mak_scan_file_closed() before uninit_demuxer.
UNINIT_DEMUXER = (
    '    uninit_demuxer(mpctx);\n'
    '\n'
    '    // Possibly stop ongoing async commands.\n'
)

UNINIT_DEMUXER_NEW = (
    '    // ' + MARKER + ': how the reading of the file ended, for\n'
    '    // MPV_EVENT_END_FILE (demuxer-read-error, demuxer-skipped-segments).\n'
    '    if (mpctx->demuxer) {\n'
    '        struct demux_reader_state mak_rs;\n'
    '        demux_get_reader_state(mpctx->demuxer, &mak_rs);\n'
    '        end_event.mak_read_error = mak_rs.mak_read_error;\n'
    '        end_event.mak_skipped_segments = mak_rs.mak_skipped_segments;\n'
    '    }\n'
    + UNINIT_DEMUXER
)

COMMAND_GETTERS = (
    'static int mp_property_demuxer_is_network(void *ctx, struct m_property *prop,\n'
)

COMMAND_TABLE = '    {"demuxer-via-network", mp_property_demuxer_is_network},\n'

COMMAND_TABLE_NEW = COMMAND_TABLE + (
    '    /* ' + MARKER + ' */\n'
    '    {"demuxer-read-error", mp_property_demuxer_read_error},\n'
    '    {"demuxer-skipped-segments", mp_property_demuxer_skipped_segments},\n'
)

# The properties change when the demuxer stops reading, which the playloop
# follows with one more cache update (handle_update_cache).
COMMAND_NOTIFY = (
    '      "demuxer-cache-time", "cache-buffering-state", "cache-speed",\n'
    '      "demuxer-cache-state"),\n'
)

COMMAND_NOTIFY_NEW = (
    '      "demuxer-cache-time", "cache-buffering-state", "cache-speed",\n'
    '      "demuxer-cache-state",\n'
    '      /* ' + MARKER + ' */ "demuxer-read-error", "demuxer-skipped-segments"),\n'
)

CLIENT_NODE = (
    '        if (eef->playlist_insert_id) {\n'
    '            node_map_add_int64(dst, "playlist_insert_id", eef->playlist_insert_id);\n'
    '            node_map_add_int64(dst, "playlist_insert_num_entries",\n'
    '                               eef->playlist_insert_num_entries);\n'
    '        }\n'
)

CLIENT_NODE_NEW = CLIENT_NODE + (
    '\n'
    '        // ' + MARKER + '\n'
    '        node_map_add_flag(dst, "read_error", eef->mak_read_error);\n'
    '        node_map_add_int64(dst, "skipped_segments", eef->mak_skipped_segments);\n'
)

END_FILE_STRUCT = (
    '    int playlist_insert_num_entries;\n'
    '} mpv_event_end_file;\n'
)


def apply(p):
    p.edits(STREAM_H, [('struct stream eof', STREAM_FIELD, STREAM_FIELD_NEW)])
    p.edits(STREAM_C, [
        ('stream_read_unbuffered', STREAM_READ, STREAM_READ_NEW),
        ('stream_seek', STREAM_SEEK, STREAM_SEEK_NEW),
    ])
    p.edits(STREAM_LAVF, [
        ('fill_buffer', LAVF_FILL, LAVF_FILL_NEW),
        ('seek', LAVF_SEEK, LAVF_SEEK_NEW),
    ])
    p.edits(DEMUX_H, [
        ('struct demux_reader_state', READER_STATE, READER_STATE_NEW),
        ('struct demuxer end', DEMUXER_END, DEMUXER_END_NEW),
    ])
    p.edits(DEMUX_C, [
        ('struct demux_internal eof', INTERNAL_EOF, INTERNAL_EOF_NEW),
        ('read_packet end', READ_PACKET_END, READ_PACKET_END_NEW),
        ('demux_get_reader_state', READER_STATE_INIT, READER_STATE_INIT_NEW),
    ])
    p.edits(DEMUX_LAVF, [
        ('lavf_priv_t', LAVF_PRIV, LAVF_PRIV_NEW),
        ('demux_open_lavf', LAVF_OPEN, LAVF_OPEN_NEW),
        ('demux_lavf_read_packet', LAVF_READ, LAVF_READ_NEW),
    ])
    p.edits(LOADFILE, [('play_current_file end', UNINIT_DEMUXER, UNINIT_DEMUXER_NEW)])
    p.edits(COMMAND, [
        ('property getters', COMMAND_GETTERS,
         p.asset('read_error/read_error_command_insert.c') + COMMAND_GETTERS),
        ('property table', COMMAND_TABLE, COMMAND_TABLE_NEW),
        ('cache update notification', COMMAND_NOTIFY, COMMAND_NOTIFY_NEW),
    ])
    p.edits(CLIENT_C, [('END_FILE node', CLIENT_NODE, CLIENT_NODE_NEW)])
    p.edits(CLIENT_H, [(
        'mpv_event_end_file end', END_FILE_STRUCT,
        '    int playlist_insert_num_entries;\n'
        + p.asset('read_error/end_file_fields_insert.h')
        + '} mpv_event_end_file;\n',
    )])


anchor.main(apply, 'patch_read_error', marker=MARKER)
