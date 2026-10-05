/* MAK_WAVEFORM_PATCH ─── cache-fed analysis of a seekable network file.
 * See mak_feed.h. One detached thread per generation: it pops the demuxer
 * feed, decodes with libavcodec the way mpv's own audio decoder does, folds
 * the mono downmix into the waveform and, with the loudness patch in, feeds
 * the loudness accumulator. It takes one clean pass from the start of the
 * file to its end. Anything else (a packet that does not come from the
 * start, a gap, a timestamp jump, an end of file short of the duration)
 * hands the generation to the re-open of mak_scan.c, as before the feed
 * existed. It also exits when the generation moves on or the demuxer goes
 * away. */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libswresample/swresample.h>

#include "common/av_common.h"
#include "demux/demux.h"
#include "demux/mak_demux_feed.h"
#include "demux/packet.h"
#include "demux/stheader.h"
#include "osdep/threads.h"
#include "osdep/timer.h"
#include "stream/stream.h"

#include "audio/mak_feed.h"
#include "audio/mak_scan.h"
#include "audio/mak_wave_fold.h"
#include "audio/mak_waveform.h"
#if __has_include("audio/mak_loudness.h")
#include "audio/mak_loudness.h"
#define MAK_FEED_LOUDNESS 1
#else
#define MAK_FEED_LOUDNESS 0
#endif

/* How long one wait on the feed lasts before the generation is checked
 * again: a superseded engine exits within this. */
#define MAK_FEED_POLL_NS MP_TIME_MS_TO_NS(100)

/* A packet timestamp further than this from where the last packet ended is a
 * discontinuity the markers did not show (ranges joined, a reused queue). */
#define MAK_FEED_JUMP_SECS 1.0

/* How close to the duration the decode must end for the pass to count as the
 * whole file: an end of file that comes earlier is a cut download. */
#define MAK_FEED_END_SLACK_SECS 1.0

struct feed_args {
    int gen;
    struct mak_demux_feed *feed;
    AVCodecParameters *par;
    AVRational tb;
    double duration_secs;
    char *url;                /* for the re-open */
    AVDictionary *net_opts;   /* mpv's network options, for the re-open */
};

struct feed_dec {
    AVCodecContext *dec;
    AVPacket *pkt;
    AVFrame *frame;
    SwrContext *swr;
    AVChannelLayout swr_layout;
    int swr_format, swr_rate;
    float *buf;        /* interleaved, source layout */
    float *mono;
    int cap;           /* frames */
    int buf_channels;  /* channels [buf] was sized for */
#if MAK_FEED_LOUDNESS
    struct mak_loud_worker *loud;
    AVChannelLayout loud_layout;
    bool loud_on;      /* the scan flag was on when the pass started */
    bool loud_broken;  /* the layout changed: no measurement for this pass */
#endif
    bool from_bof;     /* the pass started at the file's start */
    double next_pts;   /* for frames without a timestamp */
    double pkt_end;    /* where the last packet ended (NOPTS: unknown) */
};

/* (Re)builds the converter when the decoded format changes. */
static bool ensure_swr(struct feed_dec *d, const AVFrame *f)
{
    if (d->swr && d->swr_format == f->format && d->swr_rate == f->sample_rate &&
        !av_channel_layout_compare(&d->swr_layout, &f->ch_layout))
        return true;
    swr_free(&d->swr);
    av_channel_layout_uninit(&d->swr_layout);
    if (swr_alloc_set_opts2(&d->swr, &f->ch_layout, AV_SAMPLE_FMT_FLT,
                            f->sample_rate, &f->ch_layout, f->format,
                            f->sample_rate, 0, NULL) < 0 || !d->swr)
        return false;
    if (swr_init(d->swr) < 0) {
        swr_free(&d->swr);
        return false;
    }
    if (av_channel_layout_copy(&d->swr_layout, &f->ch_layout) < 0)
        return false;
    d->swr_format = f->format;
    d->swr_rate = f->sample_rate;
    return true;
}

#if MAK_FEED_LOUDNESS
/* The accumulator of a run that starts at the file's start, created on its
 * first frame: the decoded format is only certain then. */
static void loud_begin(struct feed_dec *d, const AVFrame *f,
                       const AVCodecParameters *par, double duration_secs)
{
    if (d->loud || !d->loud_on || d->loud_broken)
        return;
    int64_t total = (int64_t)ceil(duration_secs * f->sample_rate);
    if (total <= 0 ||
        av_channel_layout_copy(&d->loud_layout, &f->ch_layout) < 0)
        return;
    AVCodecParameters *p = avcodec_parameters_alloc();
    if (!p)
        return;
    if (avcodec_parameters_copy(p, par) >= 0 &&
        av_channel_layout_copy(&p->ch_layout, &f->ch_layout) >= 0) {
        p->format = f->format;
        p->sample_rate = f->sample_rate;
        d->loud = mak_loud_worker_create(p, f->sample_rate, 0, total, total);
    }
    avcodec_parameters_free(&p);
}

static void loud_drop(struct feed_dec *d)
{
    if (d->loud)
        mak_loud_worker_destroy(d->loud);
    d->loud = NULL;
    av_channel_layout_uninit(&d->loud_layout);
}
#endif

/* Folds one decoded frame. Returns false on a conversion failure. */
static bool fold_frame(struct feed_dec *d, struct feed_args *a, AVFrame *f)
{
    int rate = f->sample_rate > 0 ? f->sample_rate : a->par->sample_rate;
    int channels = f->ch_layout.nb_channels;
    if (rate <= 0 || channels <= 0 || f->nb_samples <= 0)
        return true;

    double pts = mp_pts_from_av(f->pts, &a->tb);
    if (pts == MP_NOPTS_VALUE)
        pts = d->next_pts;
    if (pts == MP_NOPTS_VALUE)
        return true;
    d->next_pts = pts + (double)f->nb_samples / rate;

#if MAK_FEED_LOUDNESS
    {
        /* The accumulator converts with the layout it was made for. */
        if (d->loud && av_channel_layout_compare(&d->loud_layout,
                                                 &f->ch_layout)) {
            loud_drop(d);
            d->loud_broken = true;
        }
        loud_begin(d, f, a->par, a->duration_secs);
        if (d->loud)
            mak_loud_worker_feed(d->loud, f, llround(pts * rate));
    }
#endif

    if (!ensure_swr(d, f))
        return false;
    int needed = swr_get_out_samples(d->swr, f->nb_samples);
    if (needed > d->cap || channels > d->buf_channels) {
        int cap = needed > d->cap ? needed + 1024 : d->cap;
        float *buf = av_realloc(d->buf, (size_t)cap * channels * sizeof(float));
        if (!buf)
            return false;
        d->buf = buf;
        float *mono = av_realloc(d->mono, (size_t)cap * sizeof(float));
        if (!mono)
            return false;
        d->mono = mono;
        d->cap = cap;
        d->buf_channels = channels;
    }
    uint8_t *out[1] = { (uint8_t *)d->buf };
    int n = swr_convert(d->swr, out, d->cap, (const uint8_t **)f->data,
                        f->nb_samples);
    if (n <= 0)
        return n == 0;
    mak_downmix_mono(d->buf, n, channels, d->mono);
    mak_waveform_fold_samples(d->mono, n, pts, rate, a->gen);
    return true;
}

/* Sends [dp] (NULL drains) and folds every frame it yields. */
static bool decode(struct feed_dec *d, struct feed_args *a,
                   struct demux_packet *dp)
{
    if (dp)
        mp_set_av_packet(d->pkt, dp, &a->tb);
    int ret = avcodec_send_packet(d->dec, dp ? d->pkt : NULL);
    if (ret < 0 && ret != AVERROR(EAGAIN) && ret != AVERROR_EOF)
        return true;   /* a broken packet: skip it, as playback does */
    while (1) {
        ret = avcodec_receive_frame(d->dec, d->frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
            return true;
        if (ret < 0)
            return true;
        bool ok = fold_frame(d, a, d->frame);
        av_frame_unref(d->frame);
        if (!ok)
            return false;
    }
}


static MP_THREAD_VOID feed_main(void *p)
{
    struct feed_args *a = p;
    struct feed_dec d = { .next_pts = MP_NOPTS_VALUE,
                          .pkt_end = MP_NOPTS_VALUE };
#if MAK_FEED_LOUDNESS
    d.loud_on = mak_loudness_is_enabled();
#endif
    bool complete = false;
    bool reopen = false;

    const AVCodec *codec = avcodec_find_decoder(a->par->codec_id);
    d.dec = codec ? avcodec_alloc_context3(codec) : NULL;
    d.pkt = av_packet_alloc();
    d.frame = av_frame_alloc();
    if (!d.dec || !d.pkt || !d.frame ||
        avcodec_parameters_to_context(d.dec, a->par) < 0)
        goto fail;
    d.dec->pkt_timebase = a->tb;
    d.dec->thread_count = 1;
    if (avcodec_open2(d.dec, codec, NULL) < 0)
        goto fail;

    while (mak_waveform_current_gen() == a->gen) {
        struct demux_packet *dp = NULL;
        enum mak_feed_item item = mak_demux_feed_pop(a->feed, &dp,
                                                     MAK_FEED_POLL_NS);
        if (item == MAK_FEED_TIMEOUT)
            continue;
        if (item == MAK_FEED_CLOSED)
            break;
        if (item == MAK_FEED_BOF && !d.from_bof) {
            d.from_bof = true;
            continue;
        }
        if (item != MAK_FEED_PACKET && item != MAK_FEED_EOF) {
            reopen = true;   /* a gap, or a second start */
            break;
        }
        if (item == MAK_FEED_EOF) {
            if (!decode(&d, a, NULL))
                goto fail;
            /* Complete only if the decode reached the duration: a download
             * cut short also ends with an end of file. */
            complete = d.from_bof && d.next_pts != MP_NOPTS_VALUE &&
                d.next_pts >= a->duration_secs - MAK_FEED_END_SLACK_SECS;
            reopen = !complete;
            break;
        }
        bool jump = false;
        if (dp->pts != MP_NOPTS_VALUE) {
            jump = d.pkt_end != MP_NOPTS_VALUE &&
                   fabs(dp->pts - d.pkt_end) > MAK_FEED_JUMP_SECS;
            d.pkt_end = dp->duration > 0 ? dp->pts + dp->duration
                                         : MP_NOPTS_VALUE;
        }
        if (!d.from_bof || jump) {
            free_demux_packet(dp);
            reopen = true;   /* not a pass from the start, or not contiguous */
            break;
        }
        bool ok = decode(&d, a, dp);
        free_demux_packet(dp);
        if (!ok)
            goto fail;
    }

    if (complete && mak_waveform_fed_complete(a->gen)) {
#if MAK_FEED_LOUDNESS
        struct mak_loud_slice slice;
        int rate = d.swr_rate > 0 ? d.swr_rate : a->par->sample_rate;
        if (d.loud && mak_loud_worker_finish(d.loud, &slice)) {
            d.loud = NULL;
            mak_loudness_publish(&slice, 1, rate, a->gen);
        } else if (d.loud_broken) {
            mak_loudness_mark_unavailable(a->gen);
        } else if (d.loud_on) {
            d.loud = NULL;
            mak_loudness_mark_failed(a->gen);
        }
#endif
    }
    /* The pass cannot cover the file: the re-open takes the generation over,
     * from a clean state, as it would have without the feed. */
    if (reopen && mak_waveform_fed_abandon(a->gen))
        mak_scan_reopen(a->gen, a->url, a->duration_secs, a->net_opts);
    goto done;

fail:
    mak_waveform_mark_failed(a->gen);
#if MAK_FEED_LOUDNESS
    mak_loudness_mark_failed(a->gen);
#endif

done:
#if MAK_FEED_LOUDNESS
    loud_drop(&d);
#endif
    mak_demux_feed_close(a->feed);
    swr_free(&d.swr);
    av_channel_layout_uninit(&d.swr_layout);
    av_free(d.buf);
    av_free(d.mono);
    av_frame_free(&d.frame);
    mp_free_av_packet(&d.pkt);
    avcodec_free_context(&d.dec);
    avcodec_parameters_free(&a->par);
    av_dict_free(&a->net_opts);
    free(a->url);
    free(a);
    /* Last touch of shared state, as for the coordinators. */
    mak_scan_thread_leave();
    MP_THREAD_RETURN();
}

bool mak_feed_start(int gen, struct demuxer *demuxer, struct sh_stream *audio,
                    double duration_secs, const char *url,
                    struct mpv_global *global, struct mp_log *log)
{
    if (!demuxer || !audio || !audio->codec || duration_secs <= 0 || !url)
        return false;
    AVCodecParameters *par = mp_codec_params_to_av(audio->codec);
    if (!par || par->sample_rate <= 0 || !avcodec_find_decoder(par->codec_id)) {
        avcodec_parameters_free(&par);
        return false;
    }
    struct feed_args *a = calloc(1, sizeof(*a));
    if (!a) {
        avcodec_parameters_free(&par);
        return false;
    }
    a->gen = gen;
    a->par = par;
    a->url = strdup(url);
    if (!a->url) {
        avcodec_parameters_free(&a->par);
        free(a);
        return false;
    }
    /* Snapshot now, on the core thread, as mak_scan_start does for its own
     * re-open: the file-local headers of this track ride along. */
    if (global)
        mp_setup_av_network_options(&a->net_opts, NULL, global, log);
    a->tb = mp_get_codec_timebase(audio->codec);
    a->duration_secs = duration_secs;
    a->feed = mak_demux_feed_attach(demuxer, audio);
    if (!a->feed || !mak_waveform_arm_fed(gen, duration_secs, par->sample_rate)) {
        if (a->feed)
            mak_demux_feed_close(a->feed);
        avcodec_parameters_free(&a->par);
        av_dict_free(&a->net_opts);
        free(a->url);
        free(a);
        return false;
    }

    mp_thread t;
    mak_scan_thread_enter();
    if (mp_thread_create(&t, feed_main, a) != 0) {
        mak_scan_thread_leave();
        mak_demux_feed_close(a->feed);
        avcodec_parameters_free(&a->par);
        av_dict_free(&a->net_opts);
        free(a->url);
        free(a);
        mak_waveform_mark_failed(gen);
#if MAK_FEED_LOUDNESS
        mak_loudness_mark_failed(gen);
#endif
        return true;   /* the generation is settled; no second attempt */
    }
    mp_thread_detach(t);
    return true;
}
