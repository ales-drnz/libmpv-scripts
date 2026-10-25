    /**
     * MAK_READ_ERROR_PATCH_V1 ─── an mpv_audio_kit extension
     * (libmpv-scripts patch_read_error.py). A libmpv without it has a
     * shorter struct, which ends at playlist_insert_num_entries: read these
     * two fields only from a libmpv that has the demuxer-read-error
     * property (mpv_get_property() does not answer
     * MPV_ERROR_PROPERTY_NOT_FOUND for it).
     *
     * 1 if the reading of the file stopped on a read error (a connection
     * that dropped, a server that closed before the length it announced)
     * and not at the file's real end, 0 otherwise: the demuxer-read-error
     * property when the file was closed. Set for every reason; with
     * MPV_END_FILE_REASON_EOF it tells a truncated file from a complete
     * one, which the error field cannot (it is 0 for every EOF).
     */
    int mak_read_error;
    /**
     * MAK_READ_ERROR_PATCH_V1 ─── the segments of an HLS or DASH stream
     * lost to an error, in whole or in part: the demuxer-skipped-segments
     * property when the file was closed. 0 for every other format. See
     * mak_read_error for when the field exists.
     */
    int64_t mak_skipped_segments;
