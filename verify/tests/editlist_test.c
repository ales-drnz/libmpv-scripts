// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The AAC priming of fragmented MP4 (patch_ffmpeg_advanced_editlist.py),
// on the patched FFmpeg of network_test.sh. The fixtures are 4 s of a
// 1 kHz sine at 48 kHz, mono, AAC from FFmpeg's encoder, whose edit list
// declares 1024 samples of priming. Each mode demuxes and decodes with
// libavformat and libavcodec, which drop the samples the demuxer marks for
// skipping, as mpv does.
//   fmp4  a file written with frag_keyframe+empty_moov+delay_moov: the moov
//         has no samples, and delay_moov lets it carry the edit list (as
//         the HLS and DASH muxers write it; empty_moov alone writes none,
//         and then no demuxer knows of the priming). Upstream mov.c turns
//         advanced_editlist off and skips the priming once. The samples
//         before the first one that is not silent must be fewer than 128
//         (with the priming kept, about 1024).
//   dash  e.mpd, the same audio in 1 s segments, read through the DASH
//         demuxer, which opens a new mov demuxer at every segment. Nothing
//         may be cut: at least the 192000 samples of the source, and the
//         sine without a jump of phase anywhere after its start (a sample
//         that the two before it do not predict). Skipping the priming at
//         every segment cuts 1024 samples at each boundary.
// Usage: editlist_test <mode> <file>

#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/samplefmt.h>

#define RATE 48000
#define SOURCE_SAMPLES (4 * RATE)
#define FREQ 1000.0
#define SILENT 0.01
#define MAX_LEAD 128
// Of a decoded sine against the recurrence x[n] = 2 cos(w) x[n-1] - x[n-2].
#define MAX_RESIDUAL 0.02
// Left out of the jump check at the start (the ramp after the priming) and
// at the end (the padding of the last frame).
#define EDGE 2048

static float *pcm;
static size_t pcm_n, pcm_cap;

static int push(const AVFrame *f)
{
    if (f->format != AV_SAMPLE_FMT_FLTP && f->format != AV_SAMPLE_FMT_FLT) {
        fprintf(stderr, "unexpected sample format %d\n", f->format);
        return -1;
    }
    if (pcm_n + f->nb_samples > pcm_cap) {
        pcm_cap = (pcm_n + f->nb_samples) * 2;
        float *p = realloc(pcm, pcm_cap * sizeof(*pcm));
        if (!p)
            return -1;
        pcm = p;
    }
    // The first channel: the fixtures are mono.
    int stride = f->format == AV_SAMPLE_FMT_FLT ? f->ch_layout.nb_channels : 1;
    const float *src = (const float *)f->extended_data[0];
    for (int i = 0; i < f->nb_samples; i++)
        pcm[pcm_n++] = src[i * stride];
    return 0;
}

static int drain(AVCodecContext *dec, AVFrame *frame)
{
    int ret;
    while ((ret = avcodec_receive_frame(dec, frame)) >= 0) {
        if (push(frame) < 0)
            return -1;
        av_frame_unref(frame);
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static int decode(const char *url)
{
    AVFormatContext *fmt = NULL;
    AVCodecContext *dec = NULL;
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int ret = avformat_open_input(&fmt, url, NULL, NULL);
    if (ret < 0) {
        fprintf(stderr, "open %s: %s\n", url, av_err2str(ret));
        goto end;
    }
    if ((ret = avformat_find_stream_info(fmt, NULL)) < 0)
        goto end;
    int idx = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (idx < 0) {
        ret = idx;
        goto end;
    }
    const AVCodec *codec = avcodec_find_decoder(fmt->streams[idx]->codecpar->codec_id);
    dec = avcodec_alloc_context3(codec);
    if (!dec || (ret = avcodec_parameters_to_context(dec, fmt->streams[idx]->codecpar)) < 0 ||
        (ret = avcodec_open2(dec, codec, NULL)) < 0)
        goto end;
    while ((ret = av_read_frame(fmt, pkt)) >= 0) {
        if (pkt->stream_index == idx) {
            size_t skip_size = 0;
            const uint8_t *skip = av_packet_get_side_data(pkt, AV_PKT_DATA_SKIP_SAMPLES, &skip_size);
            if (skip && skip_size >= 4 && AV_RL32(skip))
                printf("packet pts %" PRId64 ": skip %u samples\n", pkt->pts, AV_RL32(skip));
            if ((ret = avcodec_send_packet(dec, pkt)) < 0 || (ret = drain(dec, frame)) < 0) {
                av_packet_unref(pkt);
                goto end;
            }
        }
        av_packet_unref(pkt);
    }
    if (ret != AVERROR_EOF)
        goto end;
    avcodec_send_packet(dec, NULL);
    ret = drain(dec, frame);
end:
    av_frame_free(&frame);
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);
    return ret;
}

static void free_pcm(void)
{
    free(pcm);
}

static size_t lead(void)
{
    size_t i = 0;
    while (i < pcm_n && fabsf(pcm[i]) <= SILENT)
        i++;
    return i;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: editlist_test <fmp4|dash> <file>\n");
        return 2;
    }
    const char *mode = argv[1];
    atexit(free_pcm);
    int ret = decode(argv[2]);
    if (ret < 0) {
        printf("RESULT FAIL: decoding %s: %s\n", argv[2], av_err2str(ret));
        return 1;
    }
    size_t first = lead();
    printf("decoded %zu samples, the first not silent at %zu\n", pcm_n, first);
    if (!strcmp(mode, "fmp4")) {
        if (first >= MAX_LEAD) {
            printf("RESULT FAIL: %zu samples before the sine (the priming kept)\n", first);
            return 1;
        }
        printf("RESULT PASS: %zu samples before the sine\n", first);
        return 0;
    }
    if (strcmp(mode, "dash")) {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    double k = 2 * cos(2 * M_PI * FREQ / RATE), worst = 0;
    size_t worst_at = 0, jumps = 0;
    for (size_t n = first + EDGE; n + EDGE < pcm_n; n++) {
        double r = fabs(pcm[n] - k * pcm[n - 1] + pcm[n - 2]);
        if (r > worst) {
            worst = r;
            worst_at = n;
        }
        if (r > MAX_RESIDUAL) {
            if (jumps < 8)
                printf("jump at sample %zu (%.3f s): residual %.4f\n", n, (double)n / RATE, r);
            jumps++;
            n += 64;
        }
    }
    printf("largest residual %.4f at sample %zu\n", worst, worst_at);
    if (pcm_n < SOURCE_SAMPLES || jumps) {
        printf("RESULT FAIL: %zu samples of %d, %zu jumps of phase (audio cut at the boundaries)\n",
               pcm_n, SOURCE_SAMPLES, jumps);
        return 1;
    }
    printf("RESULT PASS: %zu samples of %d, no jump of phase\n", pcm_n, SOURCE_SAMPLES);
    return 0;
}
