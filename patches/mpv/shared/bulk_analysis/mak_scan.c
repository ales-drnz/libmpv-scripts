/* MAK_WAVEFORM_PATCH ─── bulk-analysis scan engine.
 *
 * The decode engine: on mak_scan_start() it spawns a detached coordinator that
 * probes + classifies the source and either BULK-decodes a complete seekable
 * file across MAK_WAVEFORM_WORKERS worker threads (disjoint sample regions, no
 * lock on the decode hot path) or hands a playback-grown source to the waveform
 * product's PROGRESSIVE / ROLLING strategy. The waveform STATE lives in
 * mak_waveform.c; this file calls its scan-engine interface to surface the
 * envelope incrementally and commit the final result. The offline loudness
 * accumulator is woven into the worker/coordinator here by patch_loudness_scan.py
 * (optional — this file compiles and links standalone without it).
 *
 * See patch_bulk_analysis.py for benchmark numbers and the design rationale. */
#include "audio/mak_scan_internal.h"
/* stat() of the file of a URL (scan_file_stamp); osdep/io.h makes it
 * mpv's mp_stat on Windows, with UTF-8 paths. */
#include <sys/stat.h>
#include "osdep/io.h"

/* ─── coordinator ─────────────────────────────────────────────────── */

struct coord_args {
    char  *url;          /* coordinator takes ownership */
    int    my_gen;
    double duration_secs; /* caller's (mpv's) duration — PROGRESSIVE axis */
    AVDictionary *net_opts; /* mpv's network options; coordinator owns */
    struct mak_scan_track track; /* the audio stream the player plays */
    int    fd;           /* duplicate of an fd://N source, or -1; owned */
};

/* Abort a coordinator's blocking probe (avformat_open_input /
 * avformat_find_stream_info) as soon as a newer mak_scan_start()
 * supersedes it: libav polls this callback during in-flight I/O, so a
 * superseded probe drops its (possibly stalled) connection immediately
 * instead of holding the socket open until the network call returns on its
 * own. Without it, rapid track changes against a session-capped server (a
 * Jellyfin/Plex HLS transcode keyed by PlaySessionId) pile up blocked
 * probes that exhaust the server's connection budget, leaving every later
 * track stuck in DECODING with no envelope. Returns nonzero to abort. */
int mak_scan_interrupt_cb(void *opaque)
{
    int my_gen = *(int *)opaque;
    return mak_waveform_current_gen() != my_gen;
}

/* The audio stream of [fmt] the player plays ([t], see scan_track_of): the
 * same stream index when mpv opened the source with lavf, the same track
 * number with mpv's own Matroska demuxer (lavf numbers Matroska streams by
 * it), else the same position among the audio streams. The first audio
 * stream when none matches, or when the player plays none. -1 without
 * audio. */
static int pick_audio_stream(const AVFormatContext *fmt,
                             const struct mak_scan_track *t)
{
    int first = -1, nth = -1, ordinal = 0;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        const AVStream *st = fmt->streams[i];
        if (st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO)
            continue;
        if (t->lavf_index == (int)i)
            return (int)i;
        if (t->mkv_id >= 0 && st->id == t->mkv_id)
            return (int)i;
        if (first < 0)
            first = (int)i;
        if (nth < 0 && ordinal++ == t->ordinal)
            nth = (int)i;
    }
    return nth >= 0 ? nth : first;
}

/* Whether lavf's demuxer [name] (a comma list such as "mov,mp4,m4a,...")
 * seeks to a sample-exact position with sample-exact timestamps. */
static bool mak_exact_seek_format(const char *name)
{
    static const char *const exact[] = {
        "flac", "wav", "w64", "aiff", "mov", "mp4", "ogg", "wv", "tta",
        "ape", "caf",
    };
    while (name && *name) {
        size_t n = strcspn(name, ",");
        for (size_t i = 0; i < sizeof(exact) / sizeof(exact[0]); i++) {
            if (strlen(exact[i]) == n && !strncmp(name, exact[i], n))
                return true;
        }
        name += n + (name[n] == ',');
    }
    return false;
}

/* Whether a later worker decodes [id] like a sequential decode once its
 * pre-roll is behind it, with frames the container indexes one by one. */
static bool mak_exact_seek_codec(enum AVCodecID id)
{
    if (id >= AV_CODEC_ID_PCM_S16LE && id < AV_CODEC_ID_ADPCM_IMA_QT)
        return true;   /* PCM */
    switch (id) {
    case AV_CODEC_ID_FLAC:
    case AV_CODEC_ID_ALAC:
    case AV_CODEC_ID_WAVPACK:
    case AV_CODEC_ID_TTA:
    case AV_CODEC_ID_APE:
    case AV_CODEC_ID_AAC:
    case AV_CODEC_ID_VORBIS:
    case AV_CODEC_ID_OPUS:
        return true;
    default:
        return false;
    }
}

/* Case-insensitive match of a URL's scheme — the text before "://" — against
 * [want]. [sep] is strstr(url, "://") (the caller already computed it to test
 * is_network). Used to tell complete-file network schemes that tolerate
 * concurrent reads (smb/file) from remote schemes that may be a
 * connection-capped transcode (http(s)). */
static bool mak_url_scheme_is(const char *url, const char *sep,
                              const char *want)
{
    size_t n = (size_t)(sep - url);
    if (n != strlen(want)) return false;
    for (size_t i = 0; i < n; i++) {
        char a = url[i];
        if (a >= 'A' && a <= 'Z') a += 32;   /* ASCII tolower */
        if (a != want[i]) return false;
    }
    return true;
}

/* ─── lifetime ───────────────────────────────────────────────────── */

/* Coordinators are detached so a track change never blocks mpv's core on a
 * still-decoding analysis. They must still not outlive the process's libav
 * and TLS state: exit handlers freeing those under a running decode crash
 * the process. Every coordinator is counted; teardown cancels the current
 * generation (the workers stop within one 4096-sample budget) and waits for
 * the count to drain, when the last core is destroyed and, for a process
 * that exits without destroying its cores, from an atexit handler.
 *
 * No atexit on Windows: the OS terminates the other threads before DLL
 * teardown, so a drain there could only time out. */
static atomic_int g_live_coordinators;
static atomic_int g_live_cores;

#define MAK_SCAN_DRAIN_TIMEOUT_NS MP_TIME_S_TO_NS(2)

static void drain_coordinators(void)
{
    if (atomic_load(&g_live_coordinators) == 0)
        return;
    mak_waveform_stop();
    int64_t deadline = mp_time_ns() + MAK_SCAN_DRAIN_TIMEOUT_NS;
    while (atomic_load(&g_live_coordinators) > 0 && mp_time_ns() < deadline)
        mp_sleep_ns(MP_TIME_MS_TO_NS(1));
}

#if !defined(_WIN32)
static void drain_at_exit(void)
{
    drain_coordinators();
}
#endif

void mak_scan_core_acquire(void)
{
    atomic_fetch_add(&g_live_cores, 1);
#if !defined(_WIN32)
    static atomic_bool registered;
    if (!atomic_exchange(&registered, true))
        atexit(drain_at_exit);
#endif
}

void mak_scan_core_release(void)
{
    if (atomic_fetch_sub(&g_live_cores, 1) == 1)
        drain_coordinators();
}

void mak_scan_thread_enter(void)
{
    atomic_fetch_add(&g_live_coordinators, 1);
}

void mak_scan_thread_leave(void)
{
    atomic_fetch_sub(&g_live_coordinators, 1);
}

static MP_THREAD_VOID coordinator_main(void *p)
{
    struct coord_args *args = p;
    int    my_gen   = args->my_gen;
    char  *url      = args->url;
    double dur_secs = args->duration_secs;
    /* Shared read-only with the workers, freed in cleanup after they join. */
    AVDictionary *net_opts = args->net_opts;
    struct mak_scan_track track = args->track;
    /* Shared with the workers like [url], closed in cleanup. */
    int fd = args->fd;
    free(args);

    AVFormatContext   *probe_fmt = NULL;
    AVCodecParameters *codecpar_copies[MAK_WAVEFORM_WORKERS] = {0};
    mp_thread          threads[MAK_WAVEFORM_WORKERS];
    struct worker_chunk chunks[MAK_WAVEFORM_WORKERS] = {0};
    /* Per-worker high-waters for the live publish loop; one cache line each. */
    struct mak_wave_hw hw[MAK_WAVEFORM_WORKERS] = {0};
    int                spawned = 0;
    /* Workers [0, joined) are already joined. The fail path joins only the
     * rest: a second join of a finished thread reads its freed descriptor
     * and crashes, which a single cancelled worker used to trigger. */
    int                joined = 0;
    /* Set by the fail path so the spawned workers stop within one check
     * budget instead of decoding their whole region before the join. */
    atomic_bool        abort_workers = false;
    int                bins = 0;
    float             *bins_min = NULL;
    float             *bins_max = NULL;
    double            *bins_sq = NULL;
    uint32_t          *bins_n = NULL;
    uint8_t           *bins_filled = NULL;
    int                audio_idx = -1;

    mak_waveform_mark_decoding(my_gen);
    if (mak_waveform_current_gen() != my_gen) goto cleanup;

    /* Pre-allocate the probe context so we can install the interrupt
     * callback + an I/O timeout BEFORE the (blocking) open. The callback
     * aborts this probe if a newer start() bumps the generation; the
     * timeout bounds a single stalled connection. Together they stop blocked
     * probes from piling up on a session-capped transcode server (the cause
     * of the "no waveform + no artwork until restart" stall). */
    probe_fmt = avformat_alloc_context();
    if (!probe_fmt) goto fail;
    probe_fmt->interrupt_callback.callback = mak_scan_interrupt_cb;
    probe_fmt->interrupt_callback.opaque   = &my_gen;
    int open_ret = mak_scan_open_source(&probe_fmt, url, fd, net_opts);
    if (open_ret < 0) {
        /* Logged through FFmpeg's log, which mpv routes from any thread:
         * this detached thread may outlive the core and its log. Not for a
         * probe a newer generation interrupted. */
        if (mak_waveform_current_gen() == my_gen)
            av_log(NULL, AV_LOG_WARNING, "analysis: cannot open the source "
                   "(%s), the waveform and loudness scan fail\n",
                   av_err2str(open_ret));
        goto fail;
    }
    if (avformat_find_stream_info(probe_fmt, NULL) < 0)       goto fail;

    audio_idx = pick_audio_stream(probe_fmt, &track);
    if (audio_idx < 0) goto fail;

    AVStream *st = probe_fmt->streams[audio_idx];
    int sample_rate = st->codecpar->sample_rate;
    /* The bounds of the cache-fed engine (mak_feed_start) hold here too:
     * the rate and the duration are the file's word, and their product,
     * the axis in samples, must stay inside an int64. A rate past
     * MAK_WAVEFORM_FED_MAX_RATE is no audio this decodes. */
    if (sample_rate <= 0 || sample_rate > MAK_WAVEFORM_FED_MAX_RATE)
        goto fail;
    /* Checked in double, before any conversion to an integer. */
    bool too_long = dur_secs > MAK_WAVEFORM_FED_MAX_SECS;
    const int64_t max_us = (int64_t)MAK_WAVEFORM_FED_MAX_SECS * 1000000;

    /* Track duration in microseconds. Prefer the caller's (mpv's), the one
     * the cache-fed engine builds its axis from (mak_feed.c), so both paths
     * lay the same bins; mpv takes a stream's duration over the format's,
     * which can differ. Fall back to the format-level duration, then to the
     * audio stream's own. */
    int64_t duration_us = 0;
    if (dur_secs > 0 && !too_long) duration_us = llround(dur_secs * 1e6);
    if (duration_us <= 0 && !too_long && probe_fmt->duration > 0)
        duration_us = probe_fmt->duration;
    if (duration_us <= 0 && !too_long && st->duration > 0) {
        duration_us = av_rescale_q(st->duration,
                                   st->time_base, AV_TIME_BASE_Q);
    }
    /* av_rescale_q answers INT64_MIN for what does not fit. */
    if (duration_us < 0) duration_us = 0;
    if (duration_us > max_us) too_long = true;

    /* ── Classify the source (fully automatic, no caller hint) ──────────
     * Bulk parallel decode needs a complete, randomly seekable file. An
     * adaptive/segmented stream (DASH/HLS — a Plex/Jellyfin transcode), a
     * live source, or a non-seekable input cannot be bulk-decoded. mpv's
     * libav probe gives us everything:
     *   - the demuxer NAME is the reliable DASH/HLS discriminator (those
     *     report "seekable" within segments, so seekability alone is not
     *     enough; a live DASH doesn't even set AVFMTCTX_UNSEEKABLE);
     *   - AVFMTCTX_UNSEEKABLE / a non-seekable AVIO catches live / pipe.
     * Those go PROGRESSIVE — grown from playback by the af-tap — using
     * mpv's duration as the axis (no duration ⇒ FAILED, no axis). */
    const char *fmt_name = (probe_fmt->iformat && probe_fmt->iformat->name)
                           ? probe_fmt->iformat->name : "";
    bool is_adaptive = strstr(fmt_name, "dash") ||
                       strstr(fmt_name, "hls")  ||
                       strstr(fmt_name, "applehttp");
    bool unseekable  = (probe_fmt->ctx_flags & AVFMTCTX_UNSEEKABLE) ||
                       (probe_fmt->pb &&
                        !(probe_fmt->pb->seekable & AVIO_SEEKABLE_NORMAL));
    const char *scheme_sep = strstr(url, "://");
    /* A descriptor source reads a local file, like a path. */
    bool is_network  = scheme_sep != NULL && fd < 0;
    /* A complete seekable file fans out to all workers unless re-opening it N
     * times is unsafe. SMB shares (smb:// and libsmb2's smb2://) and file://
     * URIs are plain files that serve concurrent reads at disjoint offsets just
     * like a local path, so they fan out. Other remote schemes (http(s)) stay
     * single-worker: one may be a signed / connection-capped direct-play
     * (Plex/Jellyfin) that throttles or desyncs when re-opened. Adaptive /
     * non-seekable transcodes never reach here — diverted to PROGRESSIVE above. */
    bool fanout_ok   = !is_network ||
                       mak_url_scheme_is(url, scheme_sep, "smb")  ||
                       mak_url_scheme_is(url, scheme_sep, "smb2") ||
                       mak_url_scheme_is(url, scheme_sep, "file");

    if (is_adaptive || unseekable) {
        /* A length past the bound has no axis: arm_progressive fails it. */
        double eff_dur = dur_secs > 0 ? dur_secs
                       : too_long ? 2.0 * MAK_WAVEFORM_FED_MAX_SECS
                       : duration_us / 1e6;
        if (eff_dur > 0)
            mak_waveform_arm_progressive(my_gen, eff_dur);
        else
            mak_waveform_arm_rolling(my_gen);   /* true live: cache-aligned roll */
        goto cleanup;
    }
    if (duration_us <= 0 || too_long) goto fail;
    /* The start time becomes samples as well. */
    if (!(fabs(track.start_secs) <= MAK_WAVEFORM_FED_MAX_SECS)) goto fail;

    /* At most 5e12 us times 1e6 Hz, inside an int64. */
    int64_t total_samples = (int64_t)duration_us * sample_rate / 1000000;
    if (total_samples <= 0) goto fail;
    /* A source whose timestamps start later (an MPEG-TS at 1.4 s or hours
     * in, an Ogg cut from a stream) plays from time 0: the bins follow
     * playback time, not the raw timestamps, or the envelope would sit
     * late by the start time and lose its end past the axis. */
    int64_t start_samples = llround(track.start_secs * sample_rate);

    /* Seekable complete file. Local paths, SMB shares and file:// URIs fan out
     * to all workers (disjoint regions decoded in parallel); a remote http(s)
     * file uses ONE worker — re-opening a signed / connection-capped URL
     * (Plex/Jellyfin direct-play) N times may throttle or desync, so a single
     * sequential reader is the safe choice. The partition below and both the
     * envelope and loudness merges are worker-count-agnostic (disjoint slices),
     * so the count only trades parallelism for connections. */
    /* Workers past the first place their frames by timestamp after a seek,
     * which only lands sample by sample where a seek and its timestamps are
     * exact: formats indexed by sample (FLAC, WAV, AIFF, MP4, Ogg, WavPack,
     * TTA, APE, CAF) whose time base resolves a sample. MP3, raw AAC, AC-3
     * and DTS seek by an estimated byte position, Matroska and ASF round
     * their timestamps to 1 ms: one sequential worker decodes them, so a
     * local file gives the same result as one decode of it. The codec
     * counts too: those containers can carry MP3, AC-3 or DTS (a DTS WAV
     * seeks by byte), and ADPCM keeps a predictor from the blocks before
     * (IMA in QuickTime only resets it on a large jump), so no pre-roll
     * makes a later worker decode the same samples. */
    bool exact_seek = mak_exact_seek_format(fmt_name) &&
                      mak_exact_seek_codec(st->codecpar->codec_id) &&
                      st->time_base.num > 0 &&
                      (int64_t)st->time_base.num * sample_rate <=
                          (int64_t)st->time_base.den;
    int nworkers = fanout_ok && exact_seek ? MAK_WAVEFORM_WORKERS : 1;

    /* Fixed bin count, clamped down for tracks shorter than the
     * target resolution. Allocate the global min/max/energy arrays. */
    bins = MAK_WAVEFORM_BINS;
    if ((int64_t)bins > total_samples) bins = (int)total_samples;
    if (bins < 1) goto fail;
    bins_min = av_calloc(bins, sizeof(float));
    bins_max = av_calloc(bins, sizeof(float));
    bins_sq  = av_calloc(bins, sizeof(double));
    bins_n   = av_calloc(bins, sizeof(uint32_t));
    bins_filled = av_calloc(bins, sizeof(uint8_t));
    if (!bins_min || !bins_max || !bins_sq || !bins_n || !bins_filled)
        goto fail;

    /* Spawn the workers (nworkers: all for local/SMB/file, 1 for remote
     * http(s)). Each worker covers a disjoint sample range and a disjoint bin
     * slice. */
    for (int w = 0; w < nworkers; w++) {
        int64_t ss = total_samples * w / nworkers;
        int64_t se = total_samples * (w + 1) / nworkers;

        codecpar_copies[w] = avcodec_parameters_alloc();
        if (!codecpar_copies[w]) goto fail;
        if (avcodec_parameters_copy(codecpar_copies[w],
                                    st->codecpar) < 0) goto fail;

        int bs = (int)((int64_t)bins * w / nworkers);
        int be = (int)((int64_t)bins * (w + 1) / nworkers);
        /* First sample of bin bs and of bin be (the bin of sample e is
         * e * bins / total_samples, rounded down). */
        int64_t bin_first = ((int64_t)bs * total_samples + bins - 1) / bins;
        int64_t bin_next  = ((int64_t)be * total_samples + bins - 1) / bins;

        chunks[w] = (struct worker_chunk){
            .my_gen        = my_gen,
            .abort         = &abort_workers,
            .hwslot        = &hw[w],
            .url           = url,
            .fd            = fd,
            .net_opts      = net_opts,
            .audio_idx     = audio_idx,
            .codec_id      = st->codecpar->codec_id,
            .codecpar      = codecpar_copies[w],
            .sample_rate   = sample_rate,
            .total_samples = total_samples,
            .sample_start  = ss,
            .sample_end    = se,
            .need_start    = ss < bin_first ? ss : bin_first,
            .wave_end      = w + 1 == nworkers ? total_samples : bin_next,
            .time_base_num = st->time_base.num,
            .time_base_den = st->time_base.den,
            .start_samples = start_samples,
            .total_bins    = bins,
            .bin_start     = bs,
            .bin_end       = be,
            .out_min       = bins_min + bs,
            .out_max       = bins_max + bs,
            .out_sq        = bins_sq + bs,
            .out_n         = bins_n + bs,
            .bins_filled   = av_calloc(be - bs > 0 ? be - bs : 1, 1),
            .status        = -1,
        };
        if (!chunks[w].bins_filled) goto fail;

        if (mp_thread_create(&threads[w],
                             mak_scan_worker_thread, &chunks[w]) != 0) goto fail;
        spawned++;
    }

    /* The workers have their own copies of what the probe found: close it
     * now instead of holding a connection (or an SMB handle) idle for the
     * whole decode, beside the player's and the worker's. st points into
     * it. */
    st = NULL;
    mak_scan_close_source(&probe_fmt);

    /* ── LIVE INCREMENTAL PUBLISH ──────────────────────────────────────────
     * Surface the envelope as the workers fill it, instead of one commit at
     * join. Each worker release-stores a monotone high-water of its SEALED
     * bins; here we ACQUIRE those high-waters (and the done flags) and hand the
     * sealed prefixes to the waveform product, which copies them into a
     * SEPARATE g_wave-owned buffer under its lock. We never alias the workers'
     * live arrays into g_wave, so a core-thread reset can free the published
     * buffer without racing a still-writing worker, and the post-join commit
     * stays the byte-for-byte authoritative final write. The ACQUIRE here
     * happens-before the product's copy (same thread), so [0,cnt) is visible. */
    for (;;) {
        if (mak_waveform_current_gen() != my_gen) break;  /* superseded */

        int  coverage = 0;
        bool all_done = true;
        int  bin_start[MAK_WAVEFORM_WORKERS];
        int  cnt[MAK_WAVEFORM_WORKERS];
        const uint8_t *filled_ptrs[MAK_WAVEFORM_WORKERS];
        for (int w = 0; w < spawned; w++) {
            int slice = chunks[w].bin_end - chunks[w].bin_start;
            if (slice < 0) slice = 0;
            /* A finished worker has sealed its WHOLE region (its done-release
             * makes every bin visible); an in-flight worker exposes [0, hw). */
            bool wdone = atomic_load_explicit(&hw[w].done,
                                              memory_order_acquire);
            /* A worker that ended in error fails the scan now: its region
             * is not sealed, so counting it would jump the progress ahead,
             * and the others would decode theirs for a result that is
             * dropped. fail stops them at their next check. The status was
             * written before the done release this acquire pairs with. */
            if (wdone && chunks[w].status != 0)
                goto fail;
            int h = wdone ? slice
                          : atomic_load_explicit(&hw[w].hw,
                                                 memory_order_acquire);
            if (h < 0)     h = 0;
            if (h > slice) h = slice;
            bin_start[w]   = chunks[w].bin_start;
            cnt[w]         = h;
            filled_ptrs[w] = chunks[w].bins_filled;
            coverage      += h;
            if (!wdone) all_done = false;
        }

        mak_waveform_publish_partial(my_gen, bins, duration_us, spawned,
                                     bin_start, cnt, bins_min, bins_max,
                                     bins_sq, bins_n, filled_ptrs, coverage);

        if (all_done) break;
        mp_sleep_ns(MAK_WAVE_PUBLISH_INTERVAL_NS);
    }

    /* Join all workers. */
    bool all_ok = true;
    for (int w = 0; w < spawned; w++) {
        mp_thread_join(threads[w]);
        if (chunks[w].status != 0) all_ok = false;
    }
    joined = spawned;
    if (!all_ok) goto fail;

    /* High-water mark of bins any worker actually filled. bins_filled is
     * still alive here (freed in cleanup); ranges are disjoint, so the
     * global max is the answer. valid_bins stays 0 if nothing filled, and
     * the reader then falls back to the full bin count. */
    int valid_bins = 0;
    for (int w = 0; w < spawned; w++) {
        struct worker_chunk *c = &chunks[w];
        if (!c->bins_filled)
            continue;
        for (int local = c->bin_end - c->bin_start - 1; local >= 0; local--) {
            if (c->bins_filled[local]) {
                int gb = c->bin_start + local + 1;
                if (gb > valid_bins) valid_bins = gb;
                break;
            }
        }
    }

    /* Merge the disjoint per-worker fill flags into one global mask. Without
     * it the bulk path leaves g_wave.bins_filled NULL and the reader
     * fabricates "all filled", so a bin no worker ever touched (a decode gap
     * or failed sub-range that still sits inside the valid_bins high-water)
     * would render as a real silent sample instead of an unloaded baseline.
     * The per-worker slices are disjoint by construction. */
    for (int w = 0; w < spawned; w++) {
        struct worker_chunk *c = &chunks[w];
        if (!c->bins_filled) continue;
        int slice = c->bin_end - c->bin_start;
        if (slice > 0)
            memcpy(bins_filled + c->bin_start, c->bins_filled, (size_t)slice);
    }

    /* Commit the final envelope through the product (installs under its lock,
     * only if we are still the current generation; takes ownership of the
     * arrays on success). */
    bool committed = mak_waveform_commit(my_gen, bins, duration_us,
                                         bins_min, bins_max, bins_sq, bins_n,
                                         bins_filled, valid_bins);
    if (committed) {
        bins_min    = NULL;  /* ownership moved into g_wave */
        bins_max    = NULL;
        bins_sq     = NULL;
        bins_n      = NULL;
        bins_filled = NULL;
    }
    goto cleanup;

fail:
    /* Tear down any workers already spawned before declaring failure
     * (otherwise we'd leak threads and their open AVFormatContexts). */
    atomic_store_explicit(&abort_workers, true, memory_order_relaxed);
    for (int w = joined; w < spawned; w++) mp_thread_join(threads[w]);
    spawned = 0;
    /* Drop any partial envelope the live publish loop attached, then mark
     * FAILED (the partial is g_wave-owned, so the product frees it). */
    mak_waveform_drop_partial(my_gen);
    mak_waveform_mark_failed(my_gen);

cleanup:
    for (int w = 0; w < MAK_WAVEFORM_WORKERS; w++) {
        if (chunks[w].bins_filled)
            av_free(chunks[w].bins_filled);
        if (codecpar_copies[w]) avcodec_parameters_free(&codecpar_copies[w]);
    }
    if (bins_min) av_free(bins_min);
    if (bins_max) av_free(bins_max);
    if (bins_sq) av_free(bins_sq);
    if (bins_n) av_free(bins_n);
    if (bins_filled) av_free(bins_filled);
    if (probe_fmt) mak_scan_close_source(&probe_fmt);
    mak_scan_close_fd(fd);
    av_dict_free(&net_opts);
    free(url);
    /* Last touch of shared state: a drain waiting on this count may let the
     * process tear libav down as soon as it reads zero. */
    atomic_fetch_sub(&g_live_coordinators, 1);
    MP_THREAD_RETURN();
}

/* Settles generation [gen] as failed, the loudness scan with it: for the
 * failure paths of the start and the re-open, which would otherwise leave
 * the waveform on decoding and the loudness on scanning until the next
 * file. The loudness patch weaves its include in after this point, so this
 * holds with or without it. */
static void scan_failed(int gen)
{
    mak_waveform_mark_failed(gen);
#if __has_include("audio/mak_loudness.h")
    mak_loudness_mark_failed(gen);
#endif
}

#if MAK_SCAN_FD_IO
/* The duplicate of N that a loaded fd://N or fdclose://N file keeps, by
 * its demuxer: taken by the first start of the file (the FILE_LOADED kick,
 * whatever the flags) and closed with the file. A later start, when the
 * waveform or the loudness is turned on, duplicates this one and not N:
 * the app may have closed N and reused the number by then. [why] says why
 * there is none. One entry per loaded file of every player of the process,
 * in a list under g_held_lock, as each player has a core thread of its
 * own. */
struct scan_held {
    struct scan_held *next;
    struct demuxer *demuxer;
    int fd;
    const char *why;
};
static struct scan_held *g_held;
static mp_mutex g_held_lock = MP_STATIC_MUTEX_INITIALIZER;

/* The link to the entry of [demuxer], or to the end of the list. Under
 * g_held_lock. */
static struct scan_held **scan_held_of(struct demuxer *demuxer)
{
    struct scan_held **e = &g_held;
    while (*e && (*e)->demuxer != demuxer)
        e = &(*e)->next;
    return e;
}
#endif

void mak_scan_file_closed(struct demuxer *demuxer)
{
#if MAK_SCAN_FD_IO
    mp_mutex_lock(&g_held_lock);
    struct scan_held **link = scan_held_of(demuxer), *e = *link;
    if (demuxer && e) {
        *link = e->next;
        if (e->fd >= 0)
            mak_scan_close_fd(e->fd);
        free(e);
    }
    mp_mutex_unlock(&g_held_lock);
#else
    (void)demuxer;
#endif
    int gen = mak_waveform_cancel_running();
#if __has_include("audio/mak_loudness.h")
    /* Under the new generation, as the core marks a new file's scan. */
    if (gen)
        mak_loudness_mark_failed(gen);
#else
    (void)gen;
#endif
}

void mak_scan_reopen(int gen, const char *url, double duration_secs,
                     const AVDictionary *net_opts,
                     const struct mak_scan_track *track)
{
    if (mak_waveform_current_gen() != gen)
        return;
    struct coord_args *args = calloc(1, sizeof(*args));
    if (!args) {
        scan_failed(gen);
        return;
    }
    args->url           = strdup(url);
    args->my_gen        = gen;
    args->duration_secs = duration_secs;
    args->track         = *track;
    args->fd            = -1;   /* the cache feed takes network files only */
    if (!args->url || (net_opts && av_dict_copy(&args->net_opts, net_opts, 0) < 0)) {
        av_dict_free(&args->net_opts);
        free(args->url);
        free(args);
        scan_failed(gen);
        return;
    }
    mp_thread t;
    atomic_fetch_add(&g_live_coordinators, 1);
    if (mp_thread_create(&t, coordinator_main, args) != 0) {
        atomic_fetch_sub(&g_live_coordinators, 1);
        av_dict_free(&args->net_opts);
        free(args->url);
        free(args);
        scan_failed(gen);
        return;
    }
    mp_thread_detach(t);
}

/* ─── public entry point ─────────────────────────────────────────── */

/* Fills [t] with what identifies [audio] among the streams of [demuxer]
 * (see struct mak_scan_track). Returns false when [audio] is not one of
 * them: a track of another source, an external audio file, that a re-open
 * of the main URL does not carry. Core thread. */
static bool scan_track_of(struct demuxer *demuxer, struct sh_stream *audio,
                          struct mak_scan_track *t)
{
    *t = (struct mak_scan_track){
        .lavf_index = -1, .mkv_id = -1, .ordinal = -1,
        .start_secs = demuxer && isfinite(demuxer->start_time)
                    ? demuxer->start_time : 0,
    };
    if (!demuxer || !audio)
        return true;   /* nothing selected: the first audio stream */
    int ordinal = 0;
    for (int i = 0; i < demux_get_num_stream(demuxer); i++) {
        struct sh_stream *sh = demux_get_stream(demuxer, i);
        if (sh == audio) {
            const char *name = demuxer->desc ? demuxer->desc->name : "";
            t->ordinal = ordinal;
            if (!strcmp(name, "lavf"))
                t->lavf_index = audio->ff_index;
            else if (!strcmp(name, "mkv"))
                t->mkv_id = audio->demuxer_id;
            return true;
        }
        if (sh->type == STREAM_AUDIO)
            ordinal++;
    }
    return false;
}

/* The text after "://" of an fd://N or fdclose://N URL, NULL for others. */
static const char *scan_fd_num(const char *url)
{
    const char *sep = strstr(url, "://");
    if (sep && (mak_url_scheme_is(url, sep, "fd") ||
                mak_url_scheme_is(url, sep, "fdclose")))
        return sep + 3;
    return NULL;
}

#if MAK_SCAN_FD_IO
/* A duplicate of the descriptor N names ([num] is the text after "://"),
 * taken on the core thread while N is the player's file. -1, with the
 * reason in [why], when the source cannot be read ahead of time: N is not
 * an open descriptor, or not a regular file (a pipe from a cloud
 * provider). */
static int scan_dup_fd(const char *num, const char **why_out)
{
    char *end = NULL;
    errno = 0;
    long n = strtol(num, &end, 0);   /* as mpv's stream_file parses it */
    struct stat st;
    const char *why = NULL;
    if (errno || !end || end == num || *end || n < 0 || n > INT_MAX)
        why = "not a descriptor number";
    else if (fstat((int)n, &st) < 0)
        why = "not an open descriptor";
    else if (!S_ISREG(st.st_mode))
        why = "not a regular file";
    int fd = why ? -1 : fcntl((int)n, F_DUPFD_CLOEXEC, 0);
    if (!why && fd < 0)
        why = "cannot be duplicated";
    *why_out = why;
    return fd;
}

/* Takes the duplicate the file of [demuxer] keeps, once per file. Out of
 * memory nothing is held, and a pass duplicates N itself. */
static void scan_hold_fd(const char *url, struct demuxer *demuxer)
{
    const char *num = scan_fd_num(url);
    if (!num || !demuxer)
        return;
    mp_mutex_lock(&g_held_lock);
    struct scan_held **link = scan_held_of(demuxer);
    if (!*link) {
        struct scan_held *e = calloc(1, sizeof(*e));
        if (e) {
            e->demuxer = demuxer;
            e->fd = scan_dup_fd(num, &e->why);
            *link = e;
        }
    }
    mp_mutex_unlock(&g_held_lock);
}

/* A duplicate of the file's own for one pass, of N when the file holds
 * none. -1, with a warning, when the source cannot be read ahead of time. */
static int scan_file_fd(const char *url, struct demuxer *demuxer,
                        struct mp_log *log)
{
    const char *why = NULL;
    int fd = -1;
    mp_mutex_lock(&g_held_lock);
    struct scan_held *e = demuxer ? *scan_held_of(demuxer) : NULL;
    if (e) {
        why = e->why;
        if (e->fd >= 0) {
            fd = fcntl(e->fd, F_DUPFD_CLOEXEC, 0);
            if (fd < 0)
                why = "cannot be duplicated";
        }
    }
    mp_mutex_unlock(&g_held_lock);
    if (!e)
        fd = scan_dup_fd(scan_fd_num(url), &why);
    if (fd < 0 && log)
        mp_warn(log, "analysis: the descriptor source is %s, the waveform "
                "grows from playback and the loudness scan is unavailable\n",
                why ? why : "not open");
    return fd;
}
#endif

/* The last scan started, to keep its result when the same file is loaded
 * again (F166): a playlist of one entry with loop-playlist wraps by
 * loading it again, and each FILE_LOADED decoded the whole file once
 * more (over SMB, a new download) for the result the client already
 * holds. Each player's core thread calls mak_scan_start, hence the lock. */
/* What tells the scanned source apart besides its URL: the track the
 * player plays, and for a local file its size and modification time. */
struct scan_key {
    char  *url;
    double duration, hint;
    int    lavf_index, mkv_id, ordinal;
    int64_t size, mtime_s, mtime_ns;
};

static struct scan_key g_last;
static int    g_last_gen;
static mp_mutex g_last_lock = MP_STATIC_MUTEX_INITIALIZER;

/* Size and modification time of [url] when it is a local file, -1
 * otherwise: a file written again under the same path is another file.
 * [url] is a path here, never a file:// URL (see mak_scan_start). Returns
 * false for a local file that has no stamp: nothing then tells a rewrite
 * of it apart, so its result is not kept. */
static bool scan_file_stamp(const char *url, struct scan_key *k)
{
    k->size = k->mtime_s = k->mtime_ns = -1;
    if (strstr(url, "://"))
        return true;
    struct stat st;
    if (stat(url, &st) != 0)
        return false;
    k->size = (int64_t)st.st_size;
    k->mtime_s = (int64_t)st.st_mtime;
#if defined(__APPLE__)
    k->mtime_ns = (int64_t)st.st_mtimespec.tv_nsec;
#elif defined(__linux__) || defined(__ANDROID__)
    k->mtime_ns = (int64_t)st.st_mtim.tv_nsec;
#else
    k->mtime_ns = 0;
#endif
    return true;
}

/* Whether [k] is the last scan's source, its analysis complete: the same
 * URL, duration, hint, track and file stamp, its envelope READY in the
 * generation it started (no scan or stop came since), and the loudness
 * READY when it is on (one turned on since then has no result yet). A
 * live, progressive or rolling source never turns READY in its own pass,
 * so it starts again. */
static bool scan_still_ready(const struct scan_key *k)
{
    mp_mutex_lock(&g_last_lock);
    bool same = g_last.url && !strcmp(g_last.url, k->url) &&
                fabs(g_last.duration - k->duration) < 0.5 &&
                fabs(g_last.hint - k->hint) < 0.5 &&
                g_last.lavf_index == k->lavf_index &&
                g_last.mkv_id == k->mkv_id &&
                g_last.ordinal == k->ordinal &&
                g_last.size == k->size &&
                g_last.mtime_s == k->mtime_s &&
                g_last.mtime_ns == k->mtime_ns &&
                g_last_gen != 0 && mak_waveform_ready_gen() == g_last_gen;
    mp_mutex_unlock(&g_last_lock);
#if __has_include("audio/mak_loudness.h")
    if (same && mak_loudness_is_enabled() && !mak_loudness_is_ready())
        same = false;
#endif
    return same;
}

/* Remembers [k] for generation [gen]; NULL forgets: the next start scans. */
static void scan_remember(const struct scan_key *k, int gen)
{
    mp_mutex_lock(&g_last_lock);
    free(g_last.url);
    g_last = k ? *k : (struct scan_key){0};
    g_last.url = k ? strdup(k->url) : NULL;
    g_last_gen = g_last.url ? gen : 0;
    mp_mutex_unlock(&g_last_lock);
}

static void scan_start(const char *url, double duration_secs,
                       double duration_hint,
                       const char *format_name, bool is_network,
                       bool seekable, struct mpv_global *global,
                       struct mp_log *log, struct demuxer *demuxer,
                       struct sh_stream *audio);

void mak_scan_start(const char *url, double duration_secs,
                    double duration_hint,
                    const char *format_name, bool is_network,
                    bool seekable, struct mpv_global *global,
                    struct mp_log *log, struct demuxer *demuxer,
                    struct sh_stream *audio)
{
    if (!url || !*url) return;
    /* A file:// URL becomes the path it names, as mpv's own stream reads
     * it (escapes decoded, the slash before a drive letter dropped). mpv
     * turns the ones of a playlist into paths itself, but one a hook
     * writes to stream-open-filename arrives as it is, and FFmpeg's file
     * protocol takes the text after the scheme for the path: with "%20"
     * in it the re-open found no file, and stat() no stamp. */
    char *local = mp_file_url_to_filename(NULL, bstr0(url));
    scan_start(local ? local : url, duration_secs, duration_hint, format_name,
               is_network, seekable, global, log, demuxer, audio);
    talloc_free(local);
}

static void scan_start(const char *url, double duration_secs,
                       double duration_hint,
                       const char *format_name, bool is_network,
                       bool seekable, struct mpv_global *global,
                       struct mp_log *log, struct demuxer *demuxer,
                       struct sh_stream *audio)
{
#if MAK_SCAN_FD_IO
    /* Before the gate: the file keeps its descriptor for a later start. */
    scan_hold_fd(url, demuxer);
#endif
    if (!mak_waveform_is_enabled()) return;

    /* The same file again, its analysis complete: the result stays. Never
     * for an external track (the result of another source) nor a
     * descriptor (its number names whatever file it holds now). */
    struct mak_scan_track key_track;
    bool reusable = scan_track_of(demuxer, audio, &key_track) &&
                    !scan_fd_num(url);
    struct scan_key key = {
        .url = (char *)url, .duration = duration_secs, .hint = duration_hint,
        .lavf_index = key_track.lavf_index, .mkv_id = key_track.mkv_id,
        .ordinal = key_track.ordinal,
    };
    if (!scan_file_stamp(url, &key))
        reusable = false;
    if (reusable && scan_still_ready(&key)) {
        if (log)
            mp_verbose(log, "analysis: same file, the result stays\n");
        return;
    }

    /* Bump the generation up front so any in-flight coordinator/workers and
     * af-tap folds from the previous track self-cancel, and reset the visible
     * state to "decoding". */
    int new_gen = mak_waveform_begin_generation();
    scan_remember(reusable ? &key : NULL, new_gen);

    /* ── LIVE PCM (mak-pcm://<id>): roll, never re-open ─────────────────
     * The source is read once, by the player: a second open is refused and
     * would leave the analysis failed. It has no duration, so the waveform
     * rolls from the af-tap and the loudness scan reports unavailable.
     * Matched by scheme, whatever flags the stream sets. */
    const char *pcm_sep = strstr(url, "://");
    if (pcm_sep && mak_url_scheme_is(url, pcm_sep, "mak-pcm")) {
        mak_waveform_arm_rolling(new_gen);
        return;
    }

    /* ── EXTERNAL audio track: grown from playback, never re-opened ───────
     * The player plays a track of another source (--audio-file): a re-open
     * of [url] would analyze the main file's audio, and the cache feed
     * refuses a stream of another demuxer. The waveform grows from playback
     * like a stream's, and the loudness scan reports unavailable. */
    struct mak_scan_track track;
    if (!scan_track_of(demuxer, audio, &track)) {
        if (log)
            mp_verbose(log, "analysis: external audio track, the waveform "
                       "grows from playback\n");
        if (duration_secs > 0)
            mak_waveform_arm_progressive(new_gen, duration_secs);
        else
            mak_waveform_arm_rolling(new_gen);
        return;
    }

    /* ── DESCRIPTOR (fd://N, fdclose://N: an Android content:// URI) ──────
     * FFmpeg cannot open these URLs. The coordinator and its workers read a
     * duplicate of the one the file keeps (g_held), with pread (see
     * mak_scan_open_source). A source that cannot be read ahead of time (a
     * pipe, or a platform without pread) grows from playback, and the
     * loudness scan reports unavailable. */
    int fd = -1;
    if (scan_fd_num(url)) {
#if MAK_SCAN_FD_IO
        fd = scan_file_fd(url, demuxer, log);
#else
        if (log)
            mp_warn(log, "analysis: a descriptor source is not decoded ahead "
                    "of time here, the waveform grows from playback\n");
#endif
        if (fd < 0) {
            if (duration_secs > 0)
                mak_waveform_arm_progressive(new_gen, duration_secs);
            else
                mak_waveform_arm_rolling(new_gen);
            return;
        }
    }

    /* ── NETWORK adaptive / non-seekable: arm DIRECTLY, never re-open ──────
     * mpv already classified the source (format name + is_network + seekable),
     * so do NOT spawn the coordinator probe for a network HLS/DASH transcode or
     * a non-seekable network stream. A probe would be a SECOND concurrent open
     * of the same live transcode: Jellyfin's DynamicHls kills+restarts the
     * transcode on each init-segment request, so the probe and the player's own
     * open kill each other → HTTP 500 → no waveform + playback desync.
     * arm_progressive/arm_rolling need nothing from a probe (the af-tap supplies
     * the sample rate per frame), only the duration axis mpv hands us. Keyed on
     * the lavf NAME, not is_network alone: a seekable network DIRECT-PLAY file
     * ("flac"/"mov"…) must still bulk-decode, so it falls through below. */
    const char *fn = format_name ? format_name : "";
    bool name_adaptive = strstr(fn, "dash") ||
                         strstr(fn, "hls")  ||
                         strstr(fn, "applehttp");
    const char *sep = strstr(url, "://");
    bool is_http = is_network && sep && (mak_url_scheme_is(url, sep, "http") ||
                                         mak_url_scheme_is(url, sep, "https"));

    /* ── HTTP stream with a length hint: decode it from the cache ─────────
     * A transcode a music server sends chunked, without byte ranges or a
     * length, cannot seek and has no duration at FILE_LOADED, although mpv
     * caches the whole of it in seconds (mpv_audio_kit #29). With the length
     * the client knows (the per-file option waveform-duration-hint), the
     * cache feed decodes it on that axis, as for a seekable HTTP file below,
     * instead of growing it from playback. Never re-opened: a second request
     * would start a second transcode. When the cache cannot be fed, the
     * waveform grows from playback on the same axis. mpv's own duration,
     * when it has one (a body with Content-Length from a server without
     * byte ranges), wins over the hint: the hint stands in for a length
     * mpv does not know, and the axis follows the stream. Not one lavf
     * estimated from the bitrate (an MP3 without a Xing header, a length
     * the server guessed, as Subsonic's estimateContentLength does): it
     * can be far off, and a short one cut the waveform. [seekable] is
     * the stream's own: a stream that only seeks with force-seekable
     * still takes this branch. */
    if (is_http && !name_adaptive && !seekable && duration_hint > 0) {
        bool estimated = demuxer && demuxer->mak_duration_estimated;
        double axis = duration_secs > 0 && !estimated ? duration_secs
                                                      : duration_hint;
        if (!mak_feed_start(new_gen, demuxer, audio, axis, true, url,
                            &track, global, log))
            mak_waveform_arm_progressive(new_gen, axis);
        return;
    }

    if (is_network && (name_adaptive || !seekable)) {
        if (duration_secs > 0)
            mak_waveform_arm_progressive(new_gen, duration_secs);
        else
            mak_waveform_arm_rolling(new_gen);   /* unknown duration → roll */
        return;
    }

    /* Seekable HTTP file (a direct-play original): decode it from mpv's own
     * demuxer cache instead of downloading it a second time. Falls through
     * to the re-open when the cache cannot cover the whole file (see
     * mak_demux_feed_attach). SMB and other file-like schemes keep the
     * parallel decode, which is faster than their download. */
    if (is_http &&
        mak_feed_start(new_gen, demuxer, audio, duration_secs, false, url,
                       &track, global, log))
        return;

    /* Local file, or a seekable HTTP byte-range part (direct-play): hand to the
     * coordinator. It probes [url] with libav and BULK-decodes a complete
     * seekable file; a *local* adaptive source still routes to progressive via
     * the coordinator's own classification. Re-opening here is safe — a local
     * or static file has no transcode to kill. */
    struct coord_args *args = calloc(1, sizeof(*args));
    if (!args) {
        mak_scan_close_fd(fd);
        scan_failed(new_gen);
        return;
    }
    args->url           = strdup(url);
    args->my_gen        = new_gen;
    args->duration_secs = duration_secs;
    args->track         = track;
    args->fd            = fd;
    if (!args->url) {
        mak_scan_close_fd(fd);
        free(args);
        scan_failed(new_gen);
        return;
    }
    /* Snapshot mpv's network options now, on the core thread: the current
     * values include this file's file-local ones (Media headers), and the
     * detached coordinator must not read the core's config later. Keyed on
     * the URL scheme like the coordinator's own is_network, so a URL with no
     * demuxer yet still gets them; a local path and a descriptor need none. */
    if (global && fd < 0 && strstr(url, "://"))
        mp_setup_av_network_options(&args->net_opts, NULL, global, log);

    mp_thread t;
    atomic_fetch_add(&g_live_coordinators, 1);
    if (mp_thread_create(&t, coordinator_main, args) != 0) {
        atomic_fetch_sub(&g_live_coordinators, 1);
        mak_scan_close_fd(fd);
        av_dict_free(&args->net_opts);
        free(args->url);
        free(args);
        mak_waveform_mark_failed(new_gen);
        return;
    }
    mp_thread_detach(t);
}
