/* MAK_WAVEFORM_PATCH ─── cache-fed analysis of an HTTP file.
 * See mak_feed.h. One detached thread per generation: it pops the demuxer
 * feed, decodes with libavcodec the way mpv's own audio decoder does, folds
 * the mono downmix into the waveform and, with the loudness patch in, feeds
 * the loudness accumulator. It takes one clean pass from the start of the
 * file to its end. Anything else (a packet that does not come from the
 * start, a gap, a timestamp jump, an end of file short of the duration)
 * hands the generation to the re-open of mak_scan.c, as before the feed
 * existed, or for a stream on a hinted length to the waveform grown from
 * playback. It also exits when the generation moves on or the demuxer goes
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

/* Packets copied from the cache per batch, each under the demuxer's lock
 * for a few tens of microseconds. */
#define MAK_FEED_REPLAY_BATCH 64

/* A packet timestamp further than this from where the last packet ended is a
 * discontinuity the markers did not show (ranges joined, a reused queue). */
#define MAK_FEED_JUMP_SECS 1.0

/* How close to the duration the samples decoded must come for the pass to
 * count as the whole file: an end of file that comes earlier is a cut
 * download. A duration read from a header is within tens of milliseconds of
 * the samples, but one estimated from the bitrate (raw AAC, an MP3 without
 * a Xing header) can be off by more, and a tighter bound would send such a
 * file to the re-open, downloading it twice. */
#define MAK_FEED_END_SLACK_SECS 1.0

/* What a complete file can still hold after its last audio packet: an
 * ID3v1 tag (128 bytes), a small APE tag. A pass whose last packet ends
 * this close to the end of the file reached it, whatever the duration
 * says. A longer tail goes to the re-open, as before. */
#define MAK_FEED_TAIL_BYTES 4096

struct feed_args {
    int gen;
    struct mak_demux_feed *feed;
    AVCodecParameters *par;
    AVRational tb;
    int rate;                 /* source sample rate */
    int64_t start;            /* timestamp of playback time 0, in samples */
    double duration_secs;
    int64_t total_samples;    /* the axis, as the bulk coordinator builds it */
    /* The axis is a length the client gave for a stream that cannot seek
     * and tells none (waveform-duration-hint): see mak_feed.h. */
    bool hinted;
    char *url;                /* for the re-open */
    AVDictionary *net_opts;   /* mpv's network options, for the re-open */
    struct mak_scan_track track; /* the stream of [url] to re-open */
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
    bool pos_init;     /* a frame was seen */
    bool anchored;     /* a frame was placed: the next go right after */
    int64_t emitted;   /* sequential source sample of the next frame */
    int64_t first_pos; /* where the first frame was placed */
    double pkt_end;    /* where the last packet ended (NOPTS: unknown) */
    int64_t byte_end;  /* the file byte after the last packet (-1: unknown) */
    /* The batch of the cache replay being decoded. */
    struct demux_packet *batch[MAK_FEED_REPLAY_BATCH];
    int batch_n, batch_i;
    bool replayed;     /* the replay is over: pop the feed */
    bool rate_changed; /* decoded at another rate than the axis counts */
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
                       const AVCodecParameters *par, int64_t total)
{
    if (d->loud || !d->loud_on || d->loud_broken)
        return;
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
    int channels = f->ch_layout.nb_channels;
    if (channels <= 0 || f->nb_samples <= 0)
        return true;
    /* The axis counts samples at the demuxer's rate: frames decoded at
     * another one (implicit SBR in Matroska) would stretch the envelope.
     * The re-open takes the generation over. */
    if (f->sample_rate != a->rate) {
        d->rate_changed = true;
        return true;
    }

    /* Placed the way the bulk worker places it: the first frame at its
     * timestamp, every later one right after the samples before it. Frame
     * timestamps are rounded by the container (to 1 ms in Matroska), so
     * placing each at its own would shift it by a few samples. */
    int64_t frame_pos;
    if (f->pts != AV_NOPTS_VALUE && a->tb.num > 0 && a->tb.den > 0)
        /* The cached packets carry the file's own timestamps: the axis is
         * playback time, which starts at the start time. */
        frame_pos = av_rescale(f->pts, (int64_t)a->rate * a->tb.num,
                               a->tb.den) - a->start;
    else
        frame_pos = d->pos_init ? d->emitted : 0;
    d->pos_init = true;
    /* A first timestamp past the end (a broken or crafted file) is placed
     * at the end: nothing folds, and the pass is not complete. */
    if (frame_pos > a->total_samples)
        frame_pos = a->total_samples;
    int64_t pos = d->anchored ? d->emitted
        : (frame_pos > 0 ? frame_pos : 0);

#if MAK_FEED_LOUDNESS
    {
        /* The accumulator converts with the layout it was made for. */
        if (d->loud && av_channel_layout_compare(&d->loud_layout,
                                                 &f->ch_layout)) {
            loud_drop(d);
            d->loud_broken = true;
        }
        loud_begin(d, f, a->par, a->total_samples);
        if (d->loud)
            mak_loud_worker_feed(d->loud, f, pos);
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
    /* extended_data: data[] holds the first 8 planes only. */
    uint8_t *out[1] = { (uint8_t *)d->buf };
    int n = swr_convert(d->swr, out, d->cap,
                        (const uint8_t **)f->extended_data, f->nb_samples);
    if (n <= 0)
        return n == 0;
    d->emitted = pos;
    if (!d->anchored)
        d->first_pos = pos;
    d->anchored = true;
    mak_downmix_mono(d->buf, n, channels, d->mono);
    mak_waveform_fold_fed(d->mono, n, d->emitted, a->gen);
    d->emitted += n;
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
    struct feed_dec d = { .pkt_end = MP_NOPTS_VALUE, .byte_end = -1 };
#if MAK_FEED_LOUDNESS
    d.loud_on = mak_loudness_is_enabled();
#endif
    bool complete = false;
    bool reopen = false;
    bool closed = false;

    const AVCodec *codec = avcodec_find_decoder(a->par->codec_id);
    d.dec = codec ? avcodec_alloc_context3(codec) : NULL;
    d.pkt = av_packet_alloc();
    d.frame = av_frame_alloc();
    if (!d.dec || !d.pkt || !d.frame ||
        avcodec_parameters_to_context(d.dec, a->par) < 0)
        goto fail;
    /* No pkt_timebase, as in the bulk worker: with it libavcodec moves the
     * first frame's timestamp past the samples it skips (an MP3's encoder
     * delay), and the envelope would start that much later than the
     * re-open's. */
    d.dec->thread_count = 1;
    if (avcodec_open2(d.dec, codec, NULL) < 0)
        goto fail;

    while (mak_waveform_current_gen() == a->gen) {
        struct demux_packet *dp = NULL;
        enum mak_feed_item item;
        if (d.batch_i < d.batch_n) {
            /* The packets the cache held at the attach come first. */
            item = MAK_FEED_PACKET;
            dp = d.batch[d.batch_i++];
        } else if (!d.replayed) {
            d.batch_i = 0;
            item = mak_demux_feed_replay(a->feed, d.batch,
                                         MAK_FEED_REPLAY_BATCH, &d.batch_n);
            if (item == MAK_FEED_PACKET)
                continue;
            if (item == MAK_FEED_REPLAYED) {
                d.replayed = true;
                continue;
            }
        } else {
            item = mak_demux_feed_pop(a->feed, &dp, MAK_FEED_POLL_NS);
        }
        if (item == MAK_FEED_TIMEOUT)
            continue;
        if (item == MAK_FEED_CLOSED) {
            closed = true;
            break;
        }
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
            /* Complete only if the decode reached the end of the stream: a
             * download cut short also ends with an end of file. The end is
             * where the duration puts it, or the end of the file: a
             * duration estimated from the bitrate of the first frames (raw
             * AAC, an MP3 without a Xing header) can lie far past it, and
             * the re-open would download the file again for the same
             * envelope, trimmed to the bins filled. */
            int64_t size = mak_demux_feed_replay_state(a->feed)->stream_size;
            bool at_duration = d.emitted - d.first_pos >= a->total_samples -
                (int64_t)(MAK_FEED_END_SLACK_SECS * a->rate);
            bool at_size = size > 0 && d.byte_end > 0 &&
                d.byte_end >= size - MAK_FEED_TAIL_BYTES;
            /* A stream on a hinted length ends where it ends: the length is
             * the client's, and a re-open could only download it again. A
             * hint past the end leaves the bins after the last one filled,
             * which the completion trims as for a duration that overshoots. */
            complete = d.from_bof && d.anchored && !d.rate_changed &&
                (a->hinted || at_duration || at_size);
            reopen = !complete;
            break;
        }
        d.byte_end = dp->pos >= 0 && dp->len > 0 ? dp->pos + dp->len : -1;
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
        if (d.rate_changed) {
            reopen = true;
            break;
        }
        /* A hinted length shorter than the stream ends the pass there:
         * nothing past the axis folds. */
        if (a->hinted && d.anchored && d.emitted >= a->total_samples) {
            complete = true;
            break;
        }
    }

    if (complete && mak_waveform_fed_complete(a->gen)) {
#if MAK_FEED_LOUDNESS
        struct mak_loud_slice slice;
        int rate = a->rate;
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
    /* A stream on a hinted length is not opened again (a second request
     * would start a second transcode): it grows from playback on the same
     * axis, as when the cache cannot be fed at all. */
    if (reopen && mak_waveform_fed_abandon(a->gen)) {
        if (a->hinted)
            mak_waveform_arm_progressive(a->gen, a->duration_secs);
        else
            mak_scan_reopen(a->gen, a->url, a->duration_secs, a->net_opts,
                            &a->track);
    }
    /* The demuxer went away before the end (stop, next file): nothing will
     * finish this generation, so close it instead of leaving a partial
     * envelope on "decoding" and the loudness on "scanning". */
    if (closed && !complete && mak_waveform_fed_abandon(a->gen))
        goto fail;
    goto done;

fail:
    mak_waveform_mark_failed(a->gen);
#if MAK_FEED_LOUDNESS
    mak_loudness_mark_failed(a->gen);
#endif

done:
    for (int i = d.batch_i; i < d.batch_n; i++)
        free_demux_packet(d.batch[i]);
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
                    double duration_secs, bool hinted, const char *url,
                    const struct mak_scan_track *track,
                    struct mpv_global *global, struct mp_log *log)
{
    if (!demuxer || !audio || !audio->codec || !url ||
        !(duration_secs > 0 && duration_secs <= MAK_WAVEFORM_FED_MAX_SECS))
        return false;
    AVCodecParameters *par = mp_codec_params_to_av(audio->codec);
    if (!par || par->sample_rate <= 0 ||
        par->sample_rate > MAK_WAVEFORM_FED_MAX_RATE ||
        !avcodec_find_decoder(par->codec_id)) {
        avcodec_parameters_free(&par);
        return false;
    }
    struct feed_args *a = calloc(1, sizeof(*a));
    if (!a) {
        avcodec_parameters_free(&par);
        return false;
    }
    a->gen = gen;
    a->hinted = hinted;
    a->par = par;
    a->track = *track;
    a->url = strdup(url);
    if (!a->url) {
        avcodec_parameters_free(&a->par);
        free(a);
        return false;
    }
    /* Snapshot now, on the core thread, as mak_scan_start does for its own
     * re-open: the file-local headers of this track ride along. A hinted
     * stream is never re-opened. */
    if (global && !hinted)
        mp_setup_av_network_options(&a->net_opts, NULL, global, log);
    a->tb = mp_get_codec_timebase(audio->codec);
    a->rate = par->sample_rate;
    a->start = llround(track->start_secs * a->rate);
    a->duration_secs = duration_secs;
    a->total_samples = llround(duration_secs * 1e6) * a->rate / 1000000;
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
