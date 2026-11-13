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
  - After a read error a seek of the demuxer tries the read again
    (stream->mak_reopen, armed by execute_seek() of demux.c with
    mak_retry, for every demuxer: lavf, mpv's own Matroska and WebM, raw);
    a read without one fails with the error, as before. avio keeps its end
    until a seek that reads, serves a seek into its buffer or a short one
    forward from the old connection, and http.c answers a seek to the
    offset it stands at without a new request. So stream_lavf.c seeks the
    protocol itself (avio direct) until it opened again, and the first
    read after the seek, where the error left it, opens it one byte
    before and drops that byte. Refused again, the reads fail at once,
    with the error, until the next seek.
  - demux_lavf.c remembers that av_read_frame() failed with an error
    (demuxer->mak_read_error), and reads the segments lost so far from the
    skipped_segments option of the HLS and DASH demuxers
    (patch_ffmpeg_segment_skips.py; with another FFmpeg the option is not
    there and the count stays 0).
  - demux.c keeps, with eof, whether the read that ended the file failed
    (demuxer or stream), false again once a read gets on, and the count;
    struct demux_reader_state hands both to the player. It is set before
    the streams are marked at their end, so the analysis feed of
    bulk_analysis takes it with the end (MAK_DEMUX_READ_ERROR in demux.h
    tells that patch it is there). A cached range that ends on a read
    error is no end of the file: a seek past it is a seek of the demuxer,
    and a seek into it resumes the demuxer at its end, as for another
    range, so that the read is tried again there. Nor does it count for
    eof-cached of demuxer-cache-state.
  - Two properties of the current file, unavailable without one:
    demuxer-read-error (flag) and demuxer-skipped-segments (int64). They
    change when the demuxer stops reading, before eof-reached, and are
    notified with the cache properties. With keep-open the last entry
    parks without END_FILE: these properties are how a client reads it
    there.
  - MPV_EVENT_END_FILE gets four fields at the end, mak_read_error and
    mak_skipped_segments, the properties when the file was closed, for
    every reason, and mak_duration and mak_position, the entry's duration
    and time-pos then (-1 when unknown). A client that reads the
    properties from change events gets none for an entry that opens and
    ends in one burst of events (mpv sends the changes only once its event
    queue is empty): these fields carry them with the end. The error field
    keeps its documented meaning (0 unless the reason is
    MPV_END_FILE_REASON_ERROR): a client that tests error or counts errors
    sees no change. The struct grows at the end, so a
    client built against the upstream header reads it as before. A client
    reads the new fields only as far as the mak-end-file-fields property
    says (4); without it, mak_read_error and mak_skipped_segments only
    when the libmpv has the demuxer-read-error property (libmpv-r20). The node form of the event (scripts,
    JSON IPC) gets read_error and skipped_segments, and duration and
    position when known.

Limits. A response with neither Content-Length nor chunked encoding ends
where its connection closes, and no cut can be told from that end: from a
server without Range support http.c reads it as premature (EIO), so such a
file ends with demuxer-read-error yes even when whole, as an internet radio
that stops should. A local file (stream_file.c) and the files of a
timeline (EDL, CUE with files of their own) report no read error.

The C of the properties is in read_error/read_error_command_insert.c, the
fields of client.h in read_error/end_file_fields_insert.h.

Files patched
=============

    stream/stream.h, stream.c     stream->mak_read_error
    stream/stream_lavf.c          set on a read error, avio error cleared
                                  on a seek, the protocol opened again
    demux/demux.h                 struct demuxer and demux_reader_state
    demux/demux.c                 kept with eof, read by the reader state,
                                  the cached range of a read error, a seek
                                  arms the retry of the stream
    demux/demux_lavf.c            av_read_frame() errors, skipped_segments
    player/loadfile.c             the END_FILE fields
    player/command.c              the notification
    player/mak_property_getters.inc  the getters of the three properties
    player/mak_property_table.inc    their entries (the seam of
                                  patch_property_seam.py, which runs first)
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
import property_seam as seam  # noqa: E402

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
    '    // ' + MARKER + ': mak_reopen, a read of the protocol failed with an\n'
    '    // error and it has not opened again since: stream_lavf.c seeks the\n'
    '    // protocol itself, and fails every read. mak_retry, a seek of the\n'
    '    // demuxer since (execute_seek of demux.c): the next read opens it\n'
    '    // again first.\n'
    '    bool mak_reopen, mak_retry;\n'
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
    'static int fill_buffer(stream_t *s, void *buffer, int max_len)\n'
    '{\n'
    '    AVIOContext *avio = s->priv;\n'
    '    int r = avio_read_partial(avio, buffer, max_len);\n'
    '    return (r <= 0) ? -1 : r;\n'
)

LAVF_FILL_NEW = (
    '// ' + MARKER + ': seeks the protocol itself. direct keeps avio_seek()\n'
    '// from serving the seek from its buffer or reading on to it; the buffer\n'
    '// is dropped because the seek back by half a buffer (and refill) does\n'
    '// not look at direct (libavformat/aviobuf.c, FFmpeg 8.1).\n'
    '// These are fields of AVIOContext that aviobuf.c owns, and no anchor\n'
    '// watches FFmpeg from here: the check below stops the build on a\n'
    '// libavformat this was not read against (60, FFmpeg 6.1, to 62, FFmpeg\n'
    '// 8.1). For a new one read avio_seek() and fill_buffer() again, then\n'
    '// raise the bound.\n'
    '#if (LIBAVFORMAT_VERSION_MAJOR < 60 || LIBAVFORMAT_VERSION_MAJOR > 62) && \\\n'
    '    !defined(MAK_PROTOCOL_SEEK_UNCHECKED)\n'
    '#error "mak_protocol_seek writes AVIOContext fields as aviobuf.c of ' \
    'libavformat 60 to 62 reads them: check it against this libavformat ' \
    '(or define MAK_PROTOCOL_SEEK_UNCHECKED)"\n'
    '#endif\n'
    'static int64_t mak_protocol_seek(AVIOContext *avio, int64_t pos)\n'
    '{\n'
    '    int direct = avio->direct;\n'
    '    avio->direct = 1;\n'
    '    avio->buf_ptr = avio->buf_end = avio->buffer;\n'
    '    int64_t r = avio_seek(avio, pos, SEEK_SET);\n'
    '    avio->direct = direct;\n'
    '    avio->error = 0;\n'
    '    return r;\n'
    '}\n'
    '\n'
    '// ' + MARKER + ': opens the protocol again where the stream reads on\n'
    '// (s->pos), after a read error. http.c answers a seek to the offset it\n'
    '// stands at without a new request, so the seek is to the byte before,\n'
    '// which is read and dropped.\n'
    'static bool mak_open_again(stream_t *s, AVIOContext *avio)\n'
    '{\n'
    '    int64_t pos = s->pos;\n'
    '    if (mak_protocol_seek(avio, pos > 0 ? pos - 1 : 0) < 0)\n'
    '        return false;\n'
    '    if (pos > 0)\n'
    '        avio_r8(avio);\n'
    '    if (avio_tell(avio) != pos)\n'
    '        return false;\n'
    '    s->mak_reopen = false;\n'
    '    return true;\n'
    '}\n'
    '\n'
    'static int fill_buffer(stream_t *s, void *buffer, int max_len)\n'
    '{\n'
    '    AVIOContext *avio = s->priv;\n'
    '    // ' + MARKER + ': after a read error every read fails with it, but\n'
    '    // the first one after a seek of the demuxer opens the protocol again\n'
    '    // first, and reads on if it did.\n'
    '    if (s->mak_reopen) {\n'
    '        bool retry = s->mak_retry;\n'
    '        s->mak_retry = false;\n'
    '        if (!retry || !mak_open_again(s, avio)) {\n'
    '            s->mak_read_error = true;\n'
    '            return -1;\n'
    '        }\n'
    '    }\n'
    '    int r = avio_read_partial(avio, buffer, max_len);\n'
    '    // ' + MARKER + ': an error and not the end of the stream, such as\n'
    '    // the EIO of http.c for a body shorter than its Content-Length.\n'
    '    // AVERROR_EXIT is a cancel (stop, quit), not a read error.\n'
    '    if (r < 0 && r != AVERROR_EOF && r != AVERROR_EXIT) {\n'
    '        s->mak_read_error = true;\n'
    '        s->mak_reopen = s->seekable;\n'
    '    }\n'
    '    return (r <= 0) ? -1 : r;\n'
)

LAVF_SEEK = (
    '    if (avio_seek(avio, newpos, SEEK_SET) < 0) {\n'
    '        return 0;\n'
    '    }\n'
    '    return 1;\n'
)

LAVF_SEEK_NEW = (
    '    // ' + MARKER + ': after a read error, a seek of the protocol itself.\n'
    '    // To another offset than the one it stands at, it opens it again.\n'
    '    // Refused, the reads after it fail at once.\n'
    '    if (s->mak_reopen) {\n'
    '        int64_t at = avio->pos;\n'
    '        if (mak_protocol_seek(avio, newpos) < 0) {\n'
    '            s->mak_retry = false;\n'
    '            return 0;\n'
    '        }\n'
    '        if (newpos != at)\n'
    '            s->mak_reopen = s->mak_retry = false;\n'
    '        return 1;\n'
    '    }\n'
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
    '\n'
    '// ' + MARKER + ': demux.c keeps the read error with eof\n'
    '// (demux_internal.mak_read_error), set before the streams are marked at\n'
    '// their end. The analysis feed of bulk_analysis reads it there.\n'
    '#define MAK_DEMUX_READ_ERROR 1\n'
)

RANGE_EOF = '    bool is_eof;            // set if the file ends with this range\n'

RANGE_EOF_NEW = RANGE_EOF + (
    '    // ' + MARKER + ': the range ends where the reading stopped on a read\n'
    '    // error, which is no end of the file (is_eof is set as well).\n'
    '    bool mak_read_error;\n'
)

INTERNAL_EOF = '    bool eof;                   // whether we\'re in EOF state\n'

INTERNAL_EOF_NEW = INTERNAL_EOF + (
    '    // ' + MARKER + ': the read that set eof failed with an error, of the\n'
    '    // demuxer or of its stream; the segments the demuxer lost so far.\n'
    '    bool mak_read_error;\n'
    '    int64_t mak_skipped_segments;\n'
)

READ_PACKET_EOF = (
    '    if (!in->seeking) {\n'
    '        if (eof) {\n'
)

READ_PACKET_EOF_NEW = (
    '    if (!in->seeking) {\n'
    '        // ' + MARKER + ': false again as soon as a read gets on. Set\n'
    '        // before the streams are marked at their end, which the analysis\n'
    '        // feed (bulk_analysis) reads with it.\n'
    '        in->mak_read_error = eof && (demux->mak_read_error ||\n'
    '                             (demux->stream && demux->stream->mak_read_error));\n'
    '        in->current_range->mak_read_error = in->mak_read_error;\n'
    '        if (eof) {\n'
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
    '    }\n'
    '    in->mak_skipped_segments = demux->mak_skipped_segments; // ' + MARKER + '\n'
    '    return true;\n'
    '}\n'
)

RANGE_JOIN = (
    '    update_seek_ranges(current);\n'
    '\n'
    '    // Move demuxing position to after the current range.\n'
)

RANGE_JOIN_NEW = (
    '    current->mak_read_error = next->mak_read_error; // ' + MARKER + '\n'
    + RANGE_JOIN
)

CACHE_RANGE = (
    '            if ((pts >= r->seek_start || r->is_bof) &&\n'
    '                (pts <= r->seek_end || r->is_eof))\n'
)

CACHE_RANGE_NEW = (
    '            // ' + MARKER + ': past a range that ends on a read error is\n'
    '            // no seek into it.\n'
    '            if ((pts >= r->seek_start || r->is_bof) &&\n'
    '                (pts <= r->seek_end || (r->is_eof && !r->mak_read_error)))\n'
)

CACHE_RESUME = (
    '    if (in->current_range != range) {\n'
    '        switch_current_range(in, range);\n'
)

CACHE_RESUME_NEW = (
    '    // ' + MARKER + ': into a range that ends on a read error, the low\n'
    '    // level demuxer resumes at its end as well, even in the current\n'
    '    // range, so that the read is tried again there.\n'
    '    if (in->current_range != range || range->mak_read_error) {\n'
    '        if (in->current_range != range)\n'
    '            switch_current_range(in, range);\n'
)

EXECUTE_SEEK = (
    '    if (in->d_thread->desc->seek)\n'
    '        in->d_thread->desc->seek(in->d_thread, pts, flags);\n'
)

EXECUTE_SEEK_NEW = (
    '    // ' + MARKER + ': after a read error of the stream, a seek of the\n'
    '    // demuxer tries the read again, whatever the demuxer (lavf, mkv,\n'
    '    // raw) and whatever asked for it (the user, a cache range resumed):\n'
    '    // the stream opens the protocol again at its next read. The demuxer\n'
    '    // may not move the stream at all, when the target is in its buffer.\n'
    '    if (in->d_thread->stream && in->d_thread->stream->mak_reopen)\n'
    '        in->d_thread->stream->mak_retry = true;\n'
    '\n'
    + EXECUTE_SEEK
)

EOF_CACHED = '            r->eof_cached |= range->is_eof;\n'

EOF_CACHED_NEW = (
    '            // ' + MARKER + ': a range that ends on a read error does not\n'
    '            // hold the end of the file.\n'
    '            r->eof_cached |= range->is_eof && !range->mak_read_error;\n'
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

# bulk_analysis puts mak_scan_file_closed(mpctx->demuxer) before uninit_demuxer.
UNINIT_DEMUXER = (
    '    uninit_demuxer(mpctx);\n'
    '\n'
    '    // Possibly stop ongoing async commands.\n'
)

UNINIT_DEMUXER_NEW = (
    '    // ' + MARKER + ': how the reading of the file ended, for\n'
    '    // MPV_EVENT_END_FILE (demuxer-read-error, demuxer-skipped-segments),\n'
    '    // and the duration and time-pos of the entry then (-1 unknown, a\n'
    '    // known position is never negative).\n'
    '    if (mpctx->demuxer) {\n'
    '        struct demux_reader_state mak_rs;\n'
    '        demux_get_reader_state(mpctx->demuxer, &mak_rs);\n'
    '        end_event.mak_read_error = mak_rs.mak_read_error;\n'
    '        end_event.mak_skipped_segments = mak_rs.mak_skipped_segments;\n'
    '        double mak_len = get_time_length(mpctx);\n'
    '        double mak_pos = get_current_time(mpctx);\n'
    '        end_event.mak_duration = mak_len >= 0 ? mak_len : -1;\n'
    '        end_event.mak_position = mak_pos != MP_NOPTS_VALUE ? MPMAX(mak_pos, 0) : -1;\n'
    '    }\n'
    + UNINIT_DEMUXER
)

END_EVENT_INIT = (
    '    mpv_event_end_file end_event = {\n'
    '        .playlist_entry_id = start_event.playlist_entry_id,\n'
    '    };\n'
)

END_EVENT_INIT_NEW = (
    '    mpv_event_end_file end_event = {\n'
    '        .playlist_entry_id = start_event.playlist_entry_id,\n'
    '        .mak_duration = -1, // ' + MARKER + ': unknown until set\n'
    '        .mak_position = -1,\n'
    '    };\n'
)

# The entries, in player/mak_property_table.inc; the getters,
# read_error/read_error_command_insert.c, in player/mak_property_getters.inc.
COMMAND_TABLE = (
    '    /* ' + MARKER + ' */\n'
    '    {"demuxer-read-error", mp_property_demuxer_read_error},\n'
    '    {"demuxer-skipped-segments", mp_property_demuxer_skipped_segments},\n'
    '    {"mak-end-file-fields", mp_property_mak_end_file_fields},\n'
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
    '        if (eef->mak_duration >= 0)\n'
    '            node_map_add_double(dst, "duration", eef->mak_duration);\n'
    '        if (eef->mak_position >= 0)\n'
    '            node_map_add_double(dst, "position", eef->mak_position);\n'
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
        ('struct demux_cached_range is_eof', RANGE_EOF, RANGE_EOF_NEW),
        ('struct demux_internal eof', INTERNAL_EOF, INTERNAL_EOF_NEW),
        ('attempt_range_joining', RANGE_JOIN, RANGE_JOIN_NEW),
        ('read_packet eof', READ_PACKET_EOF, READ_PACKET_EOF_NEW),
        ('read_packet end', READ_PACKET_END, READ_PACKET_END_NEW),
        ('find_cache_seek_range', CACHE_RANGE, CACHE_RANGE_NEW),
        ('execute_cache_seek', CACHE_RESUME, CACHE_RESUME_NEW),
        ('execute_seek', EXECUTE_SEEK, EXECUTE_SEEK_NEW),
        ('demux_get_reader_state', READER_STATE_INIT, READER_STATE_INIT_NEW),
        ('demux_get_reader_state eof_cached', EOF_CACHED, EOF_CACHED_NEW),
    ])
    p.edits(DEMUX_LAVF, [
        ('lavf_priv_t', LAVF_PRIV, LAVF_PRIV_NEW),
        ('demux_open_lavf', LAVF_OPEN, LAVF_OPEN_NEW),
        ('demux_lavf_read_packet', LAVF_READ, LAVF_READ_NEW),
    ])
    p.edits(LOADFILE, [
        ('play_current_file end_event', END_EVENT_INIT, END_EVENT_INIT_NEW),
        ('play_current_file end', UNINIT_DEMUXER, UNINIT_DEMUXER_NEW),
    ])
    seam.getters(p, p.asset('read_error/read_error_command_insert.c') + '\n')
    seam.table(p, COMMAND_TABLE)
    p.edits(COMMAND, [
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
