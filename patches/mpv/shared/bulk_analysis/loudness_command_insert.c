/* MAK_LOUDNESS_PATCH ─── read-only property: offline loudness scan
 * result. Returns a MAP_NODE { state, integrated_lufs, lra_lu,
 * sample_peak, true_peak, gated_block_count }. The wrapper polls this
 * on its own cadence while a scan is pending — no mp_notify_property,
 * same rationale as waveform-data. */
static int mp_property_loudness_scan_data(void *ctx, struct m_property *prop,
                                          int action, void *arg)
{
    switch (action) {
        case M_PROPERTY_GET_TYPE:
            *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_NODE};
            return M_PROPERTY_OK;
        case M_PROPERTY_GET:
        case M_PROPERTY_GET_NODE: {
            struct mpv_node n = {0};
            if (mak_loudness_read(&n) < 0)
                return M_PROPERTY_UNAVAILABLE;
            *(struct mpv_node *)arg = n;
            return M_PROPERTY_OK;
        }
    }
    return M_PROPERTY_NOT_IMPLEMENTED;
}

/* MAK_LOUDNESS_PATCH ─── read-write FLAG: gates the offline loudness
 * scan. OFF by default. The scan rides the bulk-analysis decode pass, so
 * enabling it kicks mak_scan_start for the already-loaded file (the
 * start gate admits either flag) — UNLESS a playback-grown PROGRESSIVE/
 * ROLLING waveform is already accumulating, in which case the source
 * cannot be decoded up-front: the start is skipped so the envelope is not
 * wiped, and the scan is reported "unavailable". Setting it false clears
 * the published result but leaves a concurrent waveform-only scan running. */
static int mp_property_loudness_scan_enabled(void *ctx,
                                             struct m_property *prop,
                                             int action, void *arg)
{
    struct MPContext *mpctx = ctx;
    switch (action) {
        case M_PROPERTY_GET_TYPE:
            *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_FLAG};
            return M_PROPERTY_OK;
        case M_PROPERTY_GET:
            *(int *)arg = mak_loudness_is_enabled() ? 1 : 0;
            return M_PROPERTY_OK;
        case M_PROPERTY_SET: {
            bool on = *(int *)arg != 0;
            mak_loudness_set_enabled(on);
            if (on) {
                if (mak_waveform_is_progressive_live()) {
                    /* A playback-grown PROGRESSIVE/ROLLING waveform is already
                     * accumulating for this source. It cannot be decoded
                     * up-front, so an integrated measurement is impossible and a
                     * restart would only WIPE that envelope. Leave it untouched
                     * and report the scan honestly — the gen + enable gate makes
                     * this land "unavailable" directly (no transient
                     * "scanning"), since mak_loudness_set_enabled already turned
                     * the flag on and the live generation is unchanged. */
                    mak_loudness_mark_unavailable(mak_waveform_current_gen());
                } else {
                    /* No growing envelope (idle / bulk decoding / bulk-ready /
                     * failed / not yet armed): a (re)start drives the bulk
                     * decode pass whose workers — spawned now that the scan flag
                     * is on — create loudness accumulators and reach "ready". A
                     * pass already DECODING was spawned with the scan off and
                     * carries no accumulators, so superseding it with a fresh
                     * generation is the only way to obtain a measurement; for a
                     * local adaptive playlist the fresh coordinator re-probes
                     * and its own arm path settles the scan "unavailable" under
                     * a generation check. */
                    mak_scan_start(mpctx->stream_open_filename,
                                   get_time_length(mpctx),
                                   mpctx->demuxer ? mpctx->demuxer->filetype : NULL,
                                   mpctx->demuxer ? mpctx->demuxer->is_network : false,
                                   mpctx->demuxer ? mpctx->demuxer->seekable : false);
                }
            }
            return M_PROPERTY_OK;
        }
    }
    return M_PROPERTY_NOT_IMPLEMENTED;
}

/* MAK_WAVEFORM_PATCH ─── read-only property: bulk waveform analyser
