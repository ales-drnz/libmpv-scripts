/* MAK_WAVEFORM_PATCH ─── bulk-analysis scan engine: one worker.
 *
 * Decodes the worker's sample region of the source and bins it into its
 * disjoint slice of the envelope, publishing sealed bins through its
 * high-water slot (see mak_scan_internal.h). The offline loudness accumulator
 * is woven in here by patch_loudness_scan.py. See mak_scan.c. */
#include "audio/mak_scan_internal.h"

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
                a->out_sq[local] += (double)s * s;
                a->out_n[local]++;
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

/* The offset between a frame's timestamp and its place in a sequential
 * decode of the file, in samples. The two differ by what the decoder drops
 * at the start (an MP3's encoder delay, an AAC priming): worker 0 counts
 * samples from the first frame, so its positions trail the timestamps by
 * that much. Decodes the first frames of the freshly opened [fmt] the way
 * worker 0 places them and returns the offset once two frames agree. */
static bool measure_pts_offset(AVFormatContext *fmt, AVCodecContext *dec,
                               AVPacket *pkt, AVFrame *frame,
                               const struct worker_chunk *a, int64_t *out)
{
    int64_t emitted = 0;
    int64_t prev = 0;
    int frames = 0;
    /* Bounded by packets too: a decoder that never yields a frame, or a
     * file whose other streams come first, must not be read whole here. */
    for (int packets = 0, reads = 0;
         frames < 16 && packets < 64 && reads < 1024; reads++) {
        if (mak_waveform_current_gen() != a->my_gen)
            return false;
        int ret = av_read_frame(fmt, pkt);
        if (ret < 0)
            return false;
        if (pkt->stream_index != a->audio_idx) {
            av_packet_unref(pkt);
            continue;
        }
        packets++;
        ret = avcodec_send_packet(dec, pkt);
        av_packet_unref(pkt);
        if (ret < 0)
            continue;
        while (avcodec_receive_frame(dec, frame) >= 0) {
            bool ok = frame->pts != AV_NOPTS_VALUE && frame->nb_samples > 0;
            int64_t pos = ok ? av_rescale(frame->pts,
                a->sample_rate * a->time_base_num, a->time_base_den) -
                a->start_samples : 0;
            int n = frame->nb_samples;
            av_frame_unref(frame);
            if (!ok)
                return false;
            int64_t seq = frames ? emitted : (pos > 0 ? pos : 0);
            int64_t d = pos - seq;
            emitted = seq + n;
            if (++frames >= 3 && d == prev) {
                *out = d;
                return true;
            }
            prev = d;
        }
    }
    return false;
}

/* Rebuilds [*swr] for [f] when the frame's sample format or channel layout
 * differs from the ones [*swr] converts from ([layout], [format]). A stream
 * can change its layout mid-file (two MP3s joined, stereo then mono), and
 * swresample reads every plane of the layout it was built for, past the end
 * of a frame with fewer. The rate stays the probe's: the axis counts
 * samples at that rate, and a frame at another one is converted as before,
 * without resampling. Returns false when the converter cannot be built. */
static bool worker_swr_for(SwrContext **swr, AVChannelLayout *layout,
                           int *format, const AVFrame *f, int rate)
{
    if (*swr && *format == f->format &&
        !av_channel_layout_compare(layout, &f->ch_layout))
        return true;
    swr_free(swr);
    av_channel_layout_uninit(layout);
    if (swr_alloc_set_opts2(swr, &f->ch_layout, AV_SAMPLE_FMT_FLT, rate,
                            &f->ch_layout, f->format, rate, 0, NULL) < 0 ||
        !*swr || swr_init(*swr) < 0 ||
        av_channel_layout_copy(layout, &f->ch_layout) < 0) {
        swr_free(swr);
        return false;
    }
    *format = f->format;
    return true;
}

MP_THREAD_VOID mak_scan_worker_thread(void *p)
{
    struct worker_chunk *a = p;
    a->status = -1;

    AVFormatContext *fmt = NULL;
    AVCodecContext  *dec = NULL;
    SwrContext      *swr = NULL;
    AVChannelLayout  swr_layout = {0};   /* what [swr] converts from */
    int              swr_format = -1;
    AVFrame         *iframe = NULL;
    AVPacket        *pkt = NULL;
    float           *out_buf = NULL;     /* interleaved, all channels */
    int              out_buf_capacity = 0;   /* in frames */
    float           *mono_buf = NULL;    /* out_buf downmixed */
    int              channels = 0;
    int              buf_channels = 0;   /* channels out_buf was sized for */
    int              ret = 0;
    int              samples_since_check = 0;

    /* Same generation-abort + I/O timeout as the coordinator probe, so a
     * superseded or stalled worker drops its (possibly session-capped) network
     * connection instead of blocking on it. &a->my_gen lives for the worker's
     * whole lifetime (the chunk outlives the thread, joined in the coordinator). */
    fmt = avformat_alloc_context();
    if (!fmt) goto cleanup;
    fmt->interrupt_callback.callback = mak_scan_interrupt_cb;
    fmt->interrupt_callback.opaque   = &a->my_gen;
    if (mak_scan_open_source(&fmt, a->url, a->fd, a->net_opts) < 0) goto cleanup;
    if (avformat_find_stream_info(fmt, NULL) < 0)          goto cleanup;

    const AVCodec *codec = avcodec_find_decoder(a->codec_id);
    if (!codec) goto cleanup;
    dec = avcodec_alloc_context3(codec);
    if (!dec) goto cleanup;
    if (avcodec_parameters_to_context(dec, a->codecpar) < 0) goto cleanup;
    if (avcodec_open2(dec, codec, NULL) < 0) goto cleanup;

    /* Convert to interleaved float in the SOURCE layout, then fold to mono
     * with mak_downmix_mono: the same average the progressive af-tap path
     * uses, so both envelopes agree and a full-scale stereo track peaks at
     * 1.0. (A MONO swr target would apply swresample's 1/sqrt(2) per channel
     * matrix, which sums a correlated stereo pair to sqrt(2).) */
    channels = dec->ch_layout.nb_channels;
    if (channels <= 0) goto cleanup;
    ret = swr_alloc_set_opts2(&swr,
        &dec->ch_layout, AV_SAMPLE_FMT_FLT, a->sample_rate,
        &dec->ch_layout, dec->sample_fmt, a->sample_rate,
        0, NULL);
    if (ret < 0 || !swr) goto cleanup;
    if (swr_init(swr) < 0) goto cleanup;

    iframe = av_frame_alloc();
    pkt    = av_packet_alloc();
    if (!iframe || !pkt) goto cleanup;
    out_buf_capacity = 8192;
    out_buf  = av_malloc((size_t)out_buf_capacity * channels * sizeof(float));
    mono_buf = av_malloc((size_t)out_buf_capacity * sizeof(float));
    if (!out_buf || !mono_buf) goto cleanup;
    buf_channels = channels;
    if (av_channel_layout_copy(&swr_layout, &dec->ch_layout) < 0) goto cleanup;
    swr_format = dec->sample_fmt;

    /* A later worker places each frame at its timestamp less the offset
     * worker 0's sequential count trails the timestamps by, so every worker
     * puts a sample where one decode of the whole file would. The
     * coordinator only fans out a format whose timestamps after a seek are
     * sample-exact. Without a measurable offset the worker falls back to
     * counting from its first frame. */
    bool    from_pts   = false;
    int64_t pts_offset = 0;
    if (a->sample_start > 0) {
        from_pts = measure_pts_offset(fmt, dec, pkt, iframe, a, &pts_offset);
        avcodec_flush_buffers(dec);
    }

    /* Pre-roll: a later worker starts decoding [back] samples before the
     * first one it places, so the decoder (an MP3's bit reservoir, the
     * overlap of AAC and Vorbis, Opus's 80 ms of state) and the loudness
     * filters have settled when its region starts. The first frame after
     * the seek must land at least [prime] samples before the region, or
     * the seek goes [back] four times further back, down to the start. */
    int64_t prime = a->sample_rate / 10;
    if (a->codecpar->seek_preroll > prime)
        prime = a->codecpar->seek_preroll;
    int64_t back = a->sample_rate / 2;
    if (2 * prime > back)
        back = 2 * prime;
    bool checking = false;
reseek:
    if (a->sample_start > 0) {
        int64_t target = a->need_start - back + pts_offset;
        /* The seek takes the source's own timestamps. */
        int64_t from = (target > 0 ? target : 0) + a->start_samples;
        int64_t seek_us = from > 0 ? from * 1000000 / a->sample_rate : 0;
        if (av_seek_frame(fmt, -1, seek_us, AVSEEK_FLAG_BACKWARD) < 0)
            goto cleanup;
        avcodec_flush_buffers(dec);
        checking = target > 0;
    }

    int64_t emitted_samples = 0;
    int     stream_pos_initialized = 0;

    /* Worker 0 places the first frame at its timestamp, every later one
     * right after the samples before it. */
    bool    anchored   = false;

    while (1) {
        if (mak_waveform_current_gen() != a->my_gen ||
            atomic_load_explicit(a->abort, memory_order_relaxed))
            goto cleanup;

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
             * frame from its PTS, on the playback axis (less the start
             * time). After a backward seek the decoder re-emits frames
             * before sample_start; the bin filter inside process_samples
             * drops them. */
            int64_t frame_sample_pos;
            if (iframe->pts != AV_NOPTS_VALUE) {
                frame_sample_pos = av_rescale(iframe->pts,
                    a->sample_rate * a->time_base_num, a->time_base_den) -
                    a->start_samples;
            } else if (!stream_pos_initialized) {
                frame_sample_pos = a->sample_start;
            } else {
                frame_sample_pos = emitted_samples;
            }
            stream_pos_initialized = 1;

            /* Where the frame lands in the envelope: the first one at its
             * timestamp, every later one right after the samples before it
             * (the timestamps can run ahead of the samples, by an MP3's
             * encoder delay, or be rounded, to 1 ms in Matroska). */
            int64_t frame_seq_pos = anchored ? emitted_samples
                : (frame_sample_pos > 0 ? frame_sample_pos : 0);
            if (from_pts && iframe->pts != AV_NOPTS_VALUE)
                frame_seq_pos = frame_sample_pos - pts_offset;

            /* The seek must have left room for the pre-roll. */
            if (checking) {
                checking = false;
                if (frame_seq_pos > a->need_start - prime) {
                    av_frame_unref(iframe);
                    back *= 4;
                    goto reseek;
                }
            }

            /* Stop early once the frame starts past our region. */
            if (frame_seq_pos >= a->wave_end) {
                av_frame_unref(iframe);
                goto done_decode;
            }

            /* Each frame is converted with a converter built for its own
             * layout and format. */
            if (!worker_swr_for(&swr, &swr_layout, &swr_format, iframe,
                                a->sample_rate)) {
                av_frame_unref(iframe);
                goto cleanup;
            }
            channels = iframe->ch_layout.nb_channels;
            int needed = swr_get_out_samples(swr, iframe->nb_samples);
            if (needed > out_buf_capacity || channels > buf_channels) {
                int new_cap = needed > out_buf_capacity
                    ? needed + 1024 : out_buf_capacity;
                float *grown = av_realloc(out_buf,
                    (size_t)new_cap * channels * sizeof(float));
                if (!grown) { av_frame_unref(iframe); goto cleanup; }
                out_buf = grown;
                grown = av_realloc(mono_buf, (size_t)new_cap * sizeof(float));
                if (!grown) { av_frame_unref(iframe); goto cleanup; }
                mono_buf = grown;
                out_buf_capacity = new_cap;
                buf_channels = channels;
            }
            /* extended_data: data[] holds the first 8 planes only, and a
             * planar frame has one per channel (16 for a 16-channel Opus). */
            uint8_t *out_data[1] = { (uint8_t *)out_buf };
            int converted = swr_convert(swr, out_data, out_buf_capacity,
                (const uint8_t **)iframe->extended_data, iframe->nb_samples);
            av_frame_unref(iframe);
            if (converted <= 0) continue;

            /* Count on from where the frame was placed. */
            emitted_samples = frame_seq_pos;
            anchored = true;

            mak_downmix_mono(out_buf, converted, channels, mono_buf);
            process_samples(mono_buf, converted,
                            &emitted_samples, a->total_samples, a);

            samples_since_check += converted;
            if (samples_since_check >= MAK_WAVE_CANCEL_CHECK_INTERVAL) {
                samples_since_check = 0;
                if (mak_waveform_current_gen() != a->my_gen ||
                    atomic_load_explicit(a->abort, memory_order_relaxed))
                    goto cleanup;
            }
            if (emitted_samples >= a->wave_end) goto done_decode;
        }
    }
done_decode:

    a->status = 0;

cleanup:
    if (out_buf)  av_free(out_buf);
    if (mono_buf) av_free(mono_buf);
    if (pkt)      av_packet_free(&pkt);
    if (iframe)   av_frame_free(&iframe);
    if (swr)      swr_free(&swr);
    av_channel_layout_uninit(&swr_layout);
    if (dec)      avcodec_free_context(&dec);
    if (fmt)      mak_scan_close_source(&fmt);
    /* Liveness for the coordinator's publish loop, on every exit path (normal,
     * EOF, error, cancel). RELEASE so the coordinator's ACQUIRE of `done` also
     * observes this worker's final hw store and all its bin writes. */
    if (a->hwslot)
        atomic_store_explicit(&a->hwslot->done, 1, memory_order_release);
    MP_THREAD_RETURN();
}
