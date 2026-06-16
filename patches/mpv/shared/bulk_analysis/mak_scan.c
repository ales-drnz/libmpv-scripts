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
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#include "osdep/threads.h"
#include "osdep/timer.h"

#include "audio/mak_scan.h"
#include "audio/mak_waveform.h"

/* Sample budget per worker cancellation check. 4096 samples is
 * ~85 ms at 48 kHz — short enough that a stale worker exits within
 * ~85 ms of the new file landing. */
#define MAK_WAVE_CANCEL_CHECK_INTERVAL 4096

/* ─── live incremental publish ────────────────────────────────────────
 * Cadence of the coordinator's publish loop. 100 ms ≈ 10 Hz: comfortably
 * above the wrapper's poll cadence so every poll sees fresh coverage, far
 * below a spin so the g_wave_lock churn is negligible against a multi-second
 * decode. The loop also breaks as soon as every worker is done, so a short
 * track never waits a full interval. */
#define MAK_WAVE_PUBLISH_INTERVAL_NS (100 * 1000 * 1000LL)

/* One per-worker high-water, on its own cache line so a worker's hot-path
 * release store never false-shares with another worker's line.
 *   hw   = count of LOCAL bins the worker has SEALED (advanced strictly PAST,
 *          so they can no longer widen) — monotone, the bin currently being
 *          widened is never included.
 *   done = set once the worker has exited its decode (covers every exit path),
 *          the race-free liveness signal the coordinator polls instead of the
 *          plain `status` field.
 * The coordinator RELEASE-pairs: it ACQUIRE-loads hw/done, so the worker's
 * plain writes to bins [0, hw) are visible (happens-before) before the
 * coordinator copies that sealed prefix out. _Alignas(64) on the first member
 * forces 64-byte struct alignment AND a 64-byte stride; the static assert
 * makes the one-cache-line layout load-bearing. */
struct mak_wave_hw {
    _Alignas(64) _Atomic int hw;    /* sealed LOCAL bins, monotone        */
    _Atomic int              done;  /* 1 once the worker exits its decode  */
    char _pad[64 - 2 * sizeof(_Atomic int)];
};
_Static_assert(sizeof(struct mak_wave_hw) == 64,
               "mak_wave_hw must occupy exactly one cache line");

/* ─── per-worker slice ────────────────────────────────────────────── */

struct worker_chunk {
    int      my_gen;
    /* Points at the coordinator's per-worker high-water slot (NULL ⇒ the
     * worker does not publish live, e.g. a future caller that omits it). */
    struct mak_wave_hw *hwslot;
    const char *url;             /* shared, owned by coordinator */
    int      audio_idx;
    enum AVCodecID codec_id;
    AVCodecParameters *codecpar; /* shared, used to init each ctx */
    int      sample_rate;
    int64_t  total_samples;
    int64_t  sample_start;       /* inclusive, in source sample-frame units */
    int64_t  sample_end;         /* exclusive */
    int64_t  time_base_num;
    int64_t  time_base_den;
    /* Output slice. total_bins is the global envelope size; the
     * worker writes only [bin_start, bin_end) — disjoint by
     * construction. out_min / out_max point into the coordinator's
     * global arrays. bins_filled has length bin_end - bin_start. */
    int      total_bins;
    int      bin_start;          /* inclusive */
    int      bin_end;            /* exclusive */
    float   *out_min;
    float   *out_max;
    uint8_t *bins_filled;
    int      status;             /* 0 = ok */
};

/* Bin a chunk of [count] mono Float32 samples into the worker's
 * slice of the envelope. Samples that fall outside [bin_start,
 * bin_end) are skipped. */
static void process_samples(const float *samples, int count,
                            int64_t *emitted, int64_t total_samples,
                            struct worker_chunk *a)
{
    int64_t e = *emitted;
    /* Our own published high-water (only this worker writes it): a relaxed
     * self-read is enough — used solely to skip redundant release stores. */
    int hwm = a->hwslot
            ? atomic_load_explicit(&a->hwslot->hw, memory_order_relaxed) : 0;
    for (int i = 0; i < count; i++) {
        float s = samples[i];
        if (a->total_bins > 0) {
            int64_t bin_idx = e * a->total_bins / total_samples;
            if (bin_idx >= a->bin_start && bin_idx < a->bin_end) {
                int local = (int)(bin_idx - a->bin_start);
                if (!a->bins_filled[local]) {
                    a->out_min[local] = s;
                    a->out_max[local] = s;
                    a->bins_filled[local] = 1;
                } else {
                    if (s < a->out_min[local]) a->out_min[local] = s;
                    if (s > a->out_max[local]) a->out_max[local] = s;
                }
                /* SEAL: bin_idx is monotone in e, so every LOCAL bin strictly
                 * below `local` can no longer widen — publish `local` (NEVER
                 * local+1: the bin being widened must stay private). The
                 * RELEASE carries the plain writes to bins [0, local) as
                 * happens-before to the coordinator's ACQUIRE of this value. */
                if (a->hwslot && local > hwm) {
                    atomic_store_explicit(&a->hwslot->hw, local,
                                          memory_order_release);
                    hwm = local;
                }
            }
        }
        e++;
    }
    *emitted = e;
}

/* Forward decl: the per-worker probe reuses the coordinator's generation-abort
 * callback (defined below, just before coordinator_main). */
static int coord_interrupt_cb(void *opaque);

static MP_THREAD_VOID worker_chunk_thread(void *p)
{
    struct worker_chunk *a = p;
    a->status = -1;

    AVFormatContext *fmt = NULL;
    AVCodecContext  *dec = NULL;
    SwrContext      *swr = NULL;
    AVFrame         *iframe = NULL;
    AVPacket        *pkt = NULL;
    float           *out_buf = NULL;
    int              out_buf_capacity = 0;
    int              ret = 0;
    int              samples_since_check = 0;

    /* Same generation-abort + I/O timeout as the coordinator probe, so a
     * superseded or stalled worker drops its (possibly session-capped) network
     * connection instead of blocking on it. &a->my_gen lives for the worker's
     * whole lifetime (the chunk outlives the thread, joined in the coordinator). */
    fmt = avformat_alloc_context();
    if (!fmt) goto cleanup;
    fmt->interrupt_callback.callback = coord_interrupt_cb;
    fmt->interrupt_callback.opaque   = &a->my_gen;
    AVDictionary *open_opts = NULL;
    av_dict_set(&open_opts, "rw_timeout", "5000000", 0);  /* 5 s (microseconds) */
    av_dict_set(&open_opts, "timeout",    "5000000", 0);  /* 5 s (HTTP/TCP) */
    int open_ret = avformat_open_input(&fmt, a->url, NULL, &open_opts);
    av_dict_free(&open_opts);
    if (open_ret < 0) goto cleanup;
    if (avformat_find_stream_info(fmt, NULL) < 0)          goto cleanup;

    const AVCodec *codec = avcodec_find_decoder(a->codec_id);
    if (!codec) goto cleanup;
    dec = avcodec_alloc_context3(codec);
    if (!dec) goto cleanup;
    if (avcodec_parameters_to_context(dec, a->codecpar) < 0) goto cleanup;
    if (avcodec_open2(dec, codec, NULL) < 0) goto cleanup;

    AVChannelLayout out_layout = AV_CHANNEL_LAYOUT_MONO;
    ret = swr_alloc_set_opts2(&swr,
        &out_layout, AV_SAMPLE_FMT_FLT, a->sample_rate,
        &dec->ch_layout, dec->sample_fmt, a->sample_rate,
        0, NULL);
    if (ret < 0 || !swr) goto cleanup;
    if (swr_init(swr) < 0) goto cleanup;

    iframe = av_frame_alloc();
    pkt    = av_packet_alloc();
    if (!iframe || !pkt) goto cleanup;
    out_buf_capacity = 8192;
    out_buf = av_malloc(out_buf_capacity * sizeof(float));
    if (!out_buf) goto cleanup;

    /* Seek to the assigned region (skipped for the first worker
     * which already starts at sample 0). AV_TIME_BASE units; the
     * BACKWARD flag lands us on the nearest preceding keyframe. */
    if (a->sample_start > 0) {
        int64_t seek_us = a->sample_start * 1000000 / a->sample_rate;
        if (av_seek_frame(fmt, -1, seek_us, AVSEEK_FLAG_BACKWARD) < 0)
            goto cleanup;
        avcodec_flush_buffers(dec);
    }

    int64_t emitted_samples = 0;
    int     stream_pos_initialized = 0;

    while (1) {
        if (mak_waveform_current_gen() != a->my_gen) goto cleanup;

        ret = av_read_frame(fmt, pkt);
        if (ret == AVERROR_EOF) break;
        if (ret < 0) goto cleanup;
        if (pkt->stream_index != a->audio_idx) {
            av_packet_unref(pkt);
            continue;
        }
        ret = avcodec_send_packet(dec, pkt);
        av_packet_unref(pkt);
        if (ret < 0) continue;

        while (1) {
            ret = avcodec_receive_frame(dec, iframe);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) goto cleanup;

            /* Compute the absolute source-sample position of this
             * frame from its PTS. After a backward seek the decoder
             * re-emits frames before sample_start; the bin filter
             * inside process_samples drops them. */
            int64_t frame_sample_pos;
            if (iframe->pts != AV_NOPTS_VALUE) {
                frame_sample_pos = av_rescale(iframe->pts,
                    a->sample_rate * a->time_base_num, a->time_base_den);
            } else if (!stream_pos_initialized) {
                frame_sample_pos = a->sample_start;
            } else {
                frame_sample_pos = emitted_samples;
            }
            stream_pos_initialized = 1;

            /* Stop early once the frame starts past our region. */
            if (frame_sample_pos >= a->sample_end) {
                av_frame_unref(iframe);
                goto done_decode;
            }

            int needed = swr_get_out_samples(swr, iframe->nb_samples);
            if (needed > out_buf_capacity) {
                int new_cap = needed + 1024;
                float *grown = av_realloc(out_buf,
                    (size_t)new_cap * sizeof(float));
                if (!grown) { av_frame_unref(iframe); goto cleanup; }
                out_buf = grown;
                out_buf_capacity = new_cap;
            }
            uint8_t *out_data[1] = { (uint8_t *)out_buf };
            int converted = swr_convert(swr, out_data, out_buf_capacity,
                (const uint8_t **)iframe->data, iframe->nb_samples);
            av_frame_unref(iframe);
            if (converted <= 0) continue;

            /* Initialize emitted_samples to the first frame's
             * absolute position after the seek. */
            if (emitted_samples == 0 && frame_sample_pos > 0)
                emitted_samples = frame_sample_pos;

            process_samples(out_buf, converted,
                            &emitted_samples, a->total_samples, a);

            samples_since_check += converted;
            if (samples_since_check >= MAK_WAVE_CANCEL_CHECK_INTERVAL) {
                samples_since_check = 0;
                if (mak_waveform_current_gen() != a->my_gen)
                    goto cleanup;
            }
            if (emitted_samples >= a->sample_end) goto done_decode;
        }
    }
done_decode:

    a->status = 0;

cleanup:
    if (out_buf)  av_free(out_buf);
    if (pkt)      av_packet_free(&pkt);
    if (iframe)   av_frame_free(&iframe);
    if (swr)      swr_free(&swr);
    if (dec)      avcodec_free_context(&dec);
    if (fmt)      avformat_close_input(&fmt);
    /* Liveness for the coordinator's publish loop, on every exit path (normal,
     * EOF, error, cancel). RELEASE so the coordinator's ACQUIRE of `done` also
     * observes this worker's final hw store and all its bin writes. */
    if (a->hwslot)
        atomic_store_explicit(&a->hwslot->done, 1, memory_order_release);
    MP_THREAD_RETURN();
}

/* ─── coordinator ─────────────────────────────────────────────────── */

struct coord_args {
    char  *url;          /* coordinator takes ownership */
    int    my_gen;
    double duration_secs; /* caller's (mpv's) duration — PROGRESSIVE axis */
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
static int coord_interrupt_cb(void *opaque)
{
    int my_gen = *(int *)opaque;
    return mak_waveform_current_gen() != my_gen;
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

static MP_THREAD_VOID coordinator_main(void *p)
{
    struct coord_args *args = p;
    int    my_gen   = args->my_gen;
    char  *url      = args->url;
    double dur_secs = args->duration_secs;
    free(args);

    AVFormatContext   *probe_fmt = NULL;
    AVCodecParameters *codecpar_copies[MAK_WAVEFORM_WORKERS] = {0};
    mp_thread          threads[MAK_WAVEFORM_WORKERS];
    struct worker_chunk chunks[MAK_WAVEFORM_WORKERS] = {0};
    /* Per-worker high-waters for the live publish loop; one cache line each. */
    struct mak_wave_hw hw[MAK_WAVEFORM_WORKERS] = {0};
    int                spawned = 0;
    int                bins = 0;
    float             *bins_min = NULL;
    float             *bins_max = NULL;
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
    probe_fmt->interrupt_callback.callback = coord_interrupt_cb;
    probe_fmt->interrupt_callback.opaque   = &my_gen;
    AVDictionary *probe_opts = NULL;
    av_dict_set(&probe_opts, "rw_timeout", "5000000", 0);  /* 5 s (microseconds) */
    av_dict_set(&probe_opts, "timeout",    "5000000", 0);  /* 5 s (HTTP/TCP) */
    int probe_ret = avformat_open_input(&probe_fmt, url, NULL, &probe_opts);
    av_dict_free(&probe_opts);
    if (probe_ret < 0) goto fail;
    if (avformat_find_stream_info(probe_fmt, NULL) < 0)       goto fail;

    for (unsigned i = 0; i < probe_fmt->nb_streams; i++) {
        if (probe_fmt->streams[i]->codecpar->codec_type ==
            AVMEDIA_TYPE_AUDIO) {
            audio_idx = (int)i;
            break;
        }
    }
    if (audio_idx < 0) goto fail;

    AVStream *st = probe_fmt->streams[audio_idx];
    int sample_rate = st->codecpar->sample_rate;
    if (sample_rate <= 0) goto fail;

    /* Track duration in microseconds. Prefer the format-level duration;
     * fall back to the audio stream's own duration, then to the caller's
     * (mpv's) duration hint. */
    int64_t duration_us = 0;
    if (probe_fmt->duration > 0) duration_us = probe_fmt->duration;
    if (duration_us <= 0 && st->duration > 0) {
        duration_us = av_rescale_q(st->duration,
                                   st->time_base, AV_TIME_BASE_Q);
    }
    if (duration_us <= 0 && dur_secs > 0)
        duration_us = (int64_t)(dur_secs * 1e6);

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
    bool is_network  = scheme_sep != NULL;
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
        double eff_dur = dur_secs > 0 ? dur_secs : duration_us / 1e6;
        if (eff_dur > 0)
            mak_waveform_arm_progressive(my_gen, eff_dur);
        else
            mak_waveform_arm_rolling(my_gen);   /* true live: cache-aligned roll */
        goto cleanup;
    }
    if (duration_us <= 0) goto fail;

    int64_t total_samples = (int64_t)duration_us * sample_rate / 1000000;
    if (total_samples <= 0) goto fail;

    /* Seekable complete file. Local paths, SMB shares and file:// URIs fan out
     * to all workers (disjoint regions decoded in parallel); a remote http(s)
     * file uses ONE worker — re-opening a signed / connection-capped URL
     * (Plex/Jellyfin direct-play) N times may throttle or desync, so a single
     * sequential reader is the safe choice. The partition below and both the
     * envelope and loudness merges are worker-count-agnostic (disjoint slices),
     * so the count only trades parallelism for connections. */
    int nworkers = fanout_ok ? MAK_WAVEFORM_WORKERS : 1;

    /* Fixed bin count, clamped down for tracks shorter than the
     * target resolution. Allocate the global min/max arrays. */
    bins = MAK_WAVEFORM_BINS;
    if ((int64_t)bins > total_samples) bins = (int)total_samples;
    if (bins < 1) goto fail;
    bins_min = av_calloc(bins, sizeof(float));
    bins_max = av_calloc(bins, sizeof(float));
    bins_filled = av_calloc(bins, sizeof(uint8_t));
    if (!bins_min || !bins_max || !bins_filled) goto fail;

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

        chunks[w] = (struct worker_chunk){
            .my_gen        = my_gen,
            .hwslot        = &hw[w],
            .url           = url,
            .audio_idx     = audio_idx,
            .codec_id      = st->codecpar->codec_id,
            .codecpar      = codecpar_copies[w],
            .sample_rate   = sample_rate,
            .total_samples = total_samples,
            .sample_start  = ss,
            .sample_end    = se,
            .time_base_num = st->time_base.num,
            .time_base_den = st->time_base.den,
            .total_bins    = bins,
            .bin_start     = bs,
            .bin_end       = be,
            .out_min       = bins_min + bs,
            .out_max       = bins_max + bs,
            .bins_filled   = av_calloc(be - bs > 0 ? be - bs : 1, 1),
            .status        = -1,
        };
        if (!chunks[w].bins_filled) goto fail;

        if (mp_thread_create(&threads[w],
                             worker_chunk_thread, &chunks[w]) != 0) goto fail;
        spawned++;
    }

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
                                     filled_ptrs, coverage);

        if (all_done) break;
        mp_sleep_ns(MAK_WAVE_PUBLISH_INTERVAL_NS);
    }

    /* Join all workers. */
    bool all_ok = true;
    for (int w = 0; w < spawned; w++) {
        mp_thread_join(threads[w]);
        if (chunks[w].status != 0) all_ok = false;
    }
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
                                         bins_min, bins_max, bins_filled,
                                         valid_bins);
    if (committed) {
        bins_min    = NULL;  /* ownership moved into g_wave */
        bins_max    = NULL;
        bins_filled = NULL;
    }
    goto cleanup;

fail:
    /* Tear down any workers already spawned before declaring failure
     * (otherwise we'd leak threads and their open AVFormatContexts). */
    for (int w = 0; w < spawned; w++) mp_thread_join(threads[w]);
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
    if (bins_filled) av_free(bins_filled);
    if (probe_fmt) avformat_close_input(&probe_fmt);
    free(url);
    MP_THREAD_RETURN();
}

/* ─── public entry point ─────────────────────────────────────────── */

void mak_scan_start(const char *url, double duration_secs,
                    const char *format_name, bool is_network,
                    bool seekable)
{
    if (!mak_waveform_is_enabled()) return;
    if (!url || !*url) return;

    /* Bump the generation up front so any in-flight coordinator/workers and
     * af-tap folds from the previous track self-cancel, and reset the visible
     * state to "decoding". */
    int new_gen = mak_waveform_begin_generation();

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
    if (is_network && (name_adaptive || !seekable)) {
        if (duration_secs > 0)
            mak_waveform_arm_progressive(new_gen, duration_secs);
        else
            mak_waveform_arm_rolling(new_gen);   /* unknown duration → roll */
        return;
    }

    /* Local file, or a seekable HTTP byte-range part (direct-play): hand to the
     * coordinator. It probes [url] with libav and BULK-decodes a complete
     * seekable file; a *local* adaptive source still routes to progressive via
     * the coordinator's own classification. Re-opening here is safe — a local
     * or static file has no transcode to kill. */
    struct coord_args *args = calloc(1, sizeof(*args));
    if (!args) return;
    args->url           = strdup(url);
    args->my_gen        = new_gen;
    args->duration_secs = duration_secs;
    if (!args->url) { free(args); return; }

    mp_thread t;
    if (mp_thread_create(&t, coordinator_main, args) != 0) {
        free(args->url);
        free(args);
        mak_waveform_mark_failed(new_gen);
        return;
    }
    mp_thread_detach(t);
}
