/* MAK_WAVEFORM_PATCH ─── read-only property: bulk waveform analyser
 * snapshot. Returns a MAP_NODE { state, duration_us, min, max, filled,
 * range_start_us, range_end_us, coverage_bins, total_bins, progress, rms }.
 * "min"/"max"/"rms" are Float32 byte arrays, one entry per bin
 * (empty until data is present). The wrapper polls this on its own
 * cadence — we deliberately do NOT call mp_notify_property because the
 * coordinator writes the result asynchronously and we do not want to
 * fire change events for every transient state transition. */
static int mp_property_waveform_data(void *ctx, struct m_property *prop,
                                     int action, void *arg)
{
    switch (action) {
        case M_PROPERTY_GET_TYPE:
            *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_NODE};
            return M_PROPERTY_OK;
        case M_PROPERTY_GET:
        case M_PROPERTY_GET_NODE: {
            /* The envelope is grown live — BULK by the scan engine's
             * coordinator/workers, PROGRESSIVE by the af-tap folding pre-DSP
             * frames per-bin. The getter snapshots the current state; for a
             * ROLLING (live) window it first evicts in lockstep with
             * the demuxer seekable cache so only still-seekable bins
             * are kept. */
            struct MPContext *mpctx = ctx;
            double cb = -1.0, ce = -1.0;
            if (mpctx && mpctx->demuxer) {
                struct demux_reader_state rs;
                demux_get_reader_state(mpctx->demuxer, &rs);
                for (int i = 0; i < rs.num_seek_ranges; i++) {
                    if (cb < 0 || rs.seek_ranges[i].start < cb)
                        cb = rs.seek_ranges[i].start;
                    if (ce < 0 || rs.seek_ranges[i].end > ce)
                        ce = rs.seek_ranges[i].end;
                }
            }
            mak_waveform_update_cache_range(cb, ce);
            struct mpv_node n = {0};
            if (mak_waveform_read(&n, arg) < 0)
                return M_PROPERTY_UNAVAILABLE;
            *(struct mpv_node *)arg = n;
            return M_PROPERTY_OK;
        }
    }
    return M_PROPERTY_NOT_IMPLEMENTED;
}

#if __has_include("audio/mak_loudness.h")
#include "audio/mak_loudness.h"
#define MAK_WAVEFORM_SETTER_LOUDNESS 1
#else
#define MAK_WAVEFORM_SETTER_LOUDNESS 0
#endif

/* MAK_WAVEFORM_PATCH ─── read-write FLAG: gates the bulk waveform
 * analyser. OFF by default. Setting it true also kicks the scan
 * engine for the already-loaded file so enabling mid-track works;
 * mak_scan_start null-checks the url. While a file is still opening
 * (before playback_initialized, which mpv sets right before FILE_LOADED)
 * it only sets the flag: there is no demuxer yet to classify the source,
 * so a start here would re-open the URL beside the player's own open (a
 * second GET, and for an HLS transcode a restart that fails the open).
 * The FILE_LOADED kick in loadfile.c starts the scan instead. Setting it
 * false cancels any in-flight analysis. The loudness scan rides the same
 * decode pass, so when it is still scanning the pass restarts for the
 * loudness alone; otherwise it would stay on "scanning" until the next
 * file. */
static int mp_property_waveform_enabled(void *ctx, struct m_property *prop,
                                        int action, void *arg)
{
    struct MPContext *mpctx = ctx;
    switch (action) {
        case M_PROPERTY_GET_TYPE:
            *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_FLAG};
            return M_PROPERTY_OK;
        case M_PROPERTY_GET:
            *(int *)arg = mak_waveform_is_enabled() ? 1 : 0;
            return M_PROPERTY_OK;
        case M_PROPERTY_SET: {
            bool on = *(int *)arg != 0;
            bool was_on = mak_waveform_set_enabled(on);
            bool start = on;
#if MAK_WAVEFORM_SETTER_LOUDNESS
            if (!on && was_on && mak_loudness_is_enabled() &&
                mak_loudness_is_scanning())
                start = true;
#else
            (void)was_on;
#endif
            if (start && mpctx->playback_initialized)
                mak_scan_start(mpctx->stream_open_filename,
                               get_time_length(mpctx),
                               mpctx->opts->mak_waveform_duration_hint,
                               mpctx->demuxer ? mpctx->demuxer->filetype : NULL,
                               mpctx->demuxer ? mpctx->demuxer->is_network : false,
                               mpctx->demuxer ? mpctx->demuxer->seekable : false,
                               mpctx->global, mpctx->log, mpctx->demuxer,
                               mpctx->current_track[0][STREAM_AUDIO]
                                   ? mpctx->current_track[0][STREAM_AUDIO]->stream : NULL);
            return M_PROPERTY_OK;
        }
    }
    return M_PROPERTY_NOT_IMPLEMENTED;
}

static int mp_property_audio_params(void *ctx, struct m_property *prop,
