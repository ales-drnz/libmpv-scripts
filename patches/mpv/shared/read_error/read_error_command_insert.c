/* MAK_READ_ERROR_PATCH_V1 ─── read-only flag: the reading of the current
 * file stopped on a read error (a connection that dropped, a server that
 * closed before the length it announced) and not at the file's real end.
 * It turns yes when the demuxer stops reading, ahead of eof-reached. A
 * seek after it tries the read again: back to no when the reading resumes,
 * yes again when it fails again. Unavailable without a file.
 * MPV_EVENT_END_FILE carries the same value in mak_read_error. */
static int mp_property_demuxer_read_error(void *ctx, struct m_property *prop,
                                          int action, void *arg)
{
    MPContext *mpctx = ctx;
    if (!mpctx->demuxer)
        return M_PROPERTY_UNAVAILABLE;

    struct demux_reader_state s;
    demux_get_reader_state(mpctx->demuxer, &s);

    return m_property_bool_ro(action, arg, s.mak_read_error);
}

/* MAK_READ_ERROR_PATCH_V1 ─── read-only int64: the segments of an HLS or
 * DASH stream that were lost to an error since the file was opened, in
 * whole (the segment did not open and was skipped) or in part (its reading
 * ended on a read error). 0 for every other format, and always 0 with an
 * FFmpeg without patch_ffmpeg_segment_skips.py. Unavailable without a file.
 * MPV_EVENT_END_FILE carries the same value in mak_skipped_segments. */
static int mp_property_demuxer_skipped_segments(void *ctx,
                                                struct m_property *prop,
                                                int action, void *arg)
{
    MPContext *mpctx = ctx;
    if (!mpctx->demuxer)
        return M_PROPERTY_UNAVAILABLE;

    struct demux_reader_state s;
    demux_get_reader_state(mpctx->demuxer, &s);

    return m_property_int64_ro(action, arg, s.mak_skipped_segments);
}

