    /**
     * MAK_READ_ERROR_PATCH_V2 ─── an mpv_audio_kit extension
     * (libmpv-scripts patch_read_error.py). A libmpv without it has a
     * shorter struct, which ends at playlist_insert_num_entries. Read
     * these fields as far as the int64 property mak-end-file-fields says:
     * 4 here. A libmpv without that property (libmpv-r20) has only
     * mak_read_error and mak_skipped_segments when it has the
     * demuxer-read-error property, else none of them.
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
     * MAK_READ_ERROR_PATCH_V2 ─── the segments of an HLS or DASH stream
     * lost to an error, in whole or in part: the demuxer-skipped-segments
     * property when the file was closed. 0 for every other format. See
     * mak_read_error for when the field exists.
     */
    int64_t mak_skipped_segments;
    /**
     * MAK_READ_ERROR_PATCH_V2 ─── the duration of the entry when the file
     * was closed, in seconds (the duration property then), or -1 when mpv
     * knew none: a live stream, a file that never opened. See
     * mak_read_error for when the field exists.
     *
     * With the position below, it reaches a client even for an entry that
     * opened and ended within one burst of events, which gets no change of
     * the duration or time-pos property (mpv sends property changes only
     * once its event queue is empty).
     */
    double mak_duration;
    /**
     * MAK_READ_ERROR_PATCH_V2 ─── the playback position of the entry when
     * the file was closed, in seconds (the time-pos property then, never
     * negative), or -1 when mpv knew none (a file that never opened). With
     * MPV_END_FILE_REASON_EOF it is where playback stopped, the end for a
     * whole file. See mak_read_error for when the field exists.
     */
    double mak_position;
