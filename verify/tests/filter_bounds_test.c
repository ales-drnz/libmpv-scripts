// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// One case of the FFmpeg filter bounds check, run against a libavfilter
// built with AddressSanitizer by filter_bounds_test.sh. A case builds
// abuffer -> <filter> -> abuffersink on two seconds of a stereo float tone
// at 48 kHz, optionally sends commands to the filter, and checks what
// patch_ffmpeg_filter_bounds.py promises:
//   refused   the filter fails to configure;
//   finite    it configures and every output sample is finite;
//   cmd-refused  it configures, the first command fails, output is finite;
//   cmds-ok   every command succeeds and output is finite.
// An out of bounds access aborts the case with an ASan report, and a leak
// ends it with a LeakSanitizer report at exit.
//
// Usage: filter_bounds_test <case> | --list

#include <math.h>
#include <stdio.h>
#include <string.h>

#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <libavutil/samplefmt.h>

enum expect { REFUSED, FINITE, CMD_REFUSED, CMDS_OK };

struct testcase {
    const char *name, *filter, *args;
    enum expect expect;
    const char *cmd;
    const char *cmd_args[4];
};

static const struct testcase cases[] = {
    // F195: values the filters take and then read out of bounds with.
    {"compand-no-number", "compand", "attacks=x:decays=x", REFUSED},
    {"aiir-zero-poles", "aiir", "zeros=1+0i 1-0i:poles=0+0i 0-0i", REFUSED},
    {"aiir-infinite-zeros", "aiir", "zeros=inf+0i inf-0i:poles=0.5+0i 0.5-0i", REFUSED},
    // FFmpeg 8.1.3 refuses an infinite zero, but finite zeros and poles far
    // apart are at a distance that overflows to infinity all the same.
    {"aiir-overflowing-distance", "aiir", "zeros=1e308+0i 1e308-0i:poles=-1e308+0i -1e308-0i", REFUSED},
    {"aeval-negative-channel", "aeval", "exprs=val(ch-1)|val(ch-1):c=same", FINITE},
    {"aeval-infinite-channel", "aeval", "exprs=val(1/0)|val(0/0):c=same", FINITE},
    // F51: lists of different lengths.
    {"chorus-uneven-lists", "chorus",
     "in_gain=0.5:out_gain=0.9:delays=40|50:decays=0.4:speeds=0.25|0.4:depths=2|1.3", REFUSED},
    // F194: NaN and values out of the domain.
    {"chorus-negative-depth", "chorus", "0.5:0.9:40:0.4:0.25:-2", REFUSED},
    {"chorus-speed-above-rate", "chorus", "0.5:0.9:40:0.4:50000:2", REFUSED},
    // Upstream from FFmpeg 8.1.3, kept to see it stay so.
    {"aecho-nan-delay", "aecho", "delays=1000|nan:decays=0.5|0.5", REFUSED},
    {"mcompand-nan-crossover", "mcompand", "args=0.005,0.1 6 -47/-40,-34/-34,-17/-33 nan", REFUSED},
    {"anequalizer-nan-band", "anequalizer", "c0 f=nan w=100 g=6 t=0", FINITE},
    {"anequalizer-nan-change", "anequalizer", "c0 f=1000 w=100 g=6 t=0", CMD_REFUSED,
     "change", {"0|f=nan|w=100|g=6"}},
    // F192: an input channel with no slot. Upstream from FFmpeg 8.1.3, kept
    // to see it stay so.
    {"pan-unk-input", "pan", "stereo|FL=UNK|FR=FR", REFUSED},
    {"pan-ambisonic-input", "pan", "stereo|FL=AMBI1|FR=FR", REFUSED},
    // F193: an empty attack or decay rate.
    {"mcompand-empty-rate", "mcompand", "args=0.005,0.1,, 6 -47/-40,-34/-34,-17/-33 100", REFUSED},
    // F191: a delay whose size in bytes wraps.
    {"adelay-huge-command", "adelay", "delays=10", CMD_REFUSED, "delays", {"4611686018427387905S"}},
    // F197: commands that leaked the expression they replaced.
    {"dynaudnorm-curve-commands", "dynaudnorm", "curve=p", CMDS_OK, "maxgain", {"5", "6", "7"}},
    {"adrc-transfer-commands", "adrc", "", CMDS_OK, "transfer", {"p*0.5", "p*0.6", "p*0.7"}},
    // Values that must keep working.
    {"compand-valid", "compand", "attacks=0.3|0.3:decays=0.8|0.8:points=-90/-90|-70/-70|-30/-9|0/-3", FINITE},
    {"aiir-valid", "aiir", "zeros=0.5+0i 0.5-0i:poles=0.2+0.1i 0.2-0.1i", FINITE},
    {"aeval-valid", "aeval", "exprs=val(0)*0.5|val(5)*0.5:c=same", FINITE},
    {"chorus-valid", "chorus", "0.5:0.9:50|60|40:0.4|0.32|0.3:0.25|0.4|0.3:2|2.3|1.3", FINITE},
    {"aecho-valid", "aecho", "0.8:0.9:1000|1800:0.3|0.25", FINITE},
    {"pan-valid", "pan", "stereo|FL=0.5*FL+0.5*FR|FR=FR", FINITE},
    {"mcompand-valid", "mcompand", "", FINITE},
    {"anequalizer-valid", "anequalizer", "c0 f=200 w=100 g=-10 t=1|c1 f=200 w=100 g=-10 t=1", FINITE},
    {"anequalizer-valid-change", "anequalizer", "c0 f=1000 w=100 g=6 t=0", CMDS_OK,
     "change", {"0|f=500|w=50|g=3"}},
    {"adelay-valid-command", "adelay", "delays=10|20", CMDS_OK, "delays", {"30|40", "5|5"}},
    {"dynaudnorm-bad-curve-command", "dynaudnorm", "curve=p", CMD_REFUSED, "curve", {"("}},
    {"adrc-valid", "adrc", "transfer=p*0.8", FINITE},
};

#define RATE 48000
#define FRAME 1024
#define SECONDS 2

static int nonfinite;

static void check_frame(const AVFrame *f)
{
    int planar = av_sample_fmt_is_planar(f->format);
    int planes = planar ? f->ch_layout.nb_channels : 1;
    int n = planar ? f->nb_samples : f->nb_samples * f->ch_layout.nb_channels;

    for (int p = 0; p < planes; p++) {
        for (int i = 0; i < n; i++) {
            double v;
            switch (av_get_packed_sample_fmt(f->format)) {
            case AV_SAMPLE_FMT_FLT: v = ((const float *)f->extended_data[p])[i]; break;
            case AV_SAMPLE_FMT_DBL: v = ((const double *)f->extended_data[p])[i]; break;
            default: return;
            }
            if (!isfinite(v))
                nonfinite++;
        }
    }
}

static int drain(AVFilterContext *sink, AVFrame *out)
{
    int ret;
    while ((ret = av_buffersink_get_frame(sink, out)) >= 0) {
        check_frame(out);
        av_frame_unref(out);
    }
    return ret == AVERROR(EAGAIN) || ret == AVERROR_EOF ? 0 : ret;
}

static int run(const struct testcase *c)
{
    AVFilterGraph *graph = avfilter_graph_alloc();
    AVFilterContext *src = NULL, *flt = NULL, *sink = NULL;
    AVFrame *in = av_frame_alloc(), *out = av_frame_alloc();
    int ret, cmd_ret = 0, status = 1;
    long pos = 0;

    if (!graph || !in || !out) {
        printf("out of memory\n");
        goto end;
    }
    ret = avfilter_graph_create_filter(&src, avfilter_get_by_name("abuffer"), "src",
        "sample_rate=48000:sample_fmt=fltp:channel_layout=stereo:time_base=1/48000", NULL, graph);
    if (ret >= 0)
        ret = avfilter_graph_create_filter(&sink, avfilter_get_by_name("abuffersink"), "sink",
                                           NULL, NULL, graph);
    if (ret < 0) {
        printf("abuffer or abuffersink missing (%s)\n", av_err2str(ret));
        goto end;
    }

    ret = avfilter_graph_create_filter(&flt, avfilter_get_by_name(c->filter), "flt",
                                       c->args, NULL, graph);
    if (ret >= 0)
        ret = avfilter_link(src, 0, flt, 0);
    if (ret >= 0)
        ret = avfilter_link(flt, 0, sink, 0);
    if (ret >= 0)
        ret = avfilter_graph_config(graph, NULL);
    if (ret < 0) {
        if (c->expect == REFUSED) {
            printf("refused (%s)\n", av_err2str(ret));
            status = 0;
        } else {
            printf("unexpectedly refused (%s)\n", av_err2str(ret));
        }
        goto end;
    }

    for (int i = 0; c->cmd && i < 4 && c->cmd_args[i]; i++) {
        char res[256] = "";
        cmd_ret = avfilter_graph_send_command(graph, "flt", c->cmd, c->cmd_args[i],
                                              res, sizeof(res), 0);
        if (cmd_ret < 0)
            break;
    }

    for (int k = 0; k < RATE * SECONDS / FRAME; k++) {
        in->format = AV_SAMPLE_FMT_FLTP;
        in->sample_rate = RATE;
        in->nb_samples = FRAME;
        in->pts = pos;
        av_channel_layout_default(&in->ch_layout, 2);
        if ((ret = av_frame_get_buffer(in, 0)) < 0)
            break;
        for (int ch = 0; ch < 2; ch++) {
            float *d = (float *)in->extended_data[ch];
            for (int i = 0; i < FRAME; i++)
                d[i] = 0.5f * sinf(2 * M_PI * (ch ? 660 : 440) * (pos + i) / RATE);
        }
        pos += FRAME;
        if ((ret = av_buffersrc_add_frame(src, in)) < 0 || (ret = drain(sink, out)) < 0)
            break;
    }
    if (ret >= 0 && (ret = av_buffersrc_add_frame(src, NULL)) >= 0)
        ret = drain(sink, out);
    if (ret < 0) {
        printf("processing failed (%s)\n", av_err2str(ret));
        goto end;
    }

    switch (c->expect) {
    case REFUSED:
        printf("accepted, %d samples not finite\n", nonfinite);
        break;
    case CMD_REFUSED:
        if (cmd_ret >= 0)
            printf("command accepted, %d samples not finite\n", nonfinite);
        else if (nonfinite)
            printf("command refused, but %d samples not finite\n", nonfinite);
        else {
            printf("command refused (%s), output finite\n", av_err2str(cmd_ret));
            status = 0;
        }
        break;
    case CMDS_OK:
        if (cmd_ret < 0) {
            printf("command refused (%s)\n", av_err2str(cmd_ret));
            break;
        }
        // fall through
    case FINITE:
        if (nonfinite) {
            printf("%d samples not finite\n", nonfinite);
        } else {
            printf("output finite\n");
            status = 0;
        }
        break;
    }

end:
    av_frame_free(&in);
    av_frame_free(&out);
    avfilter_graph_free(&graph);
    return status;
}

int main(int argc, char **argv)
{
    int n = sizeof(cases) / sizeof(cases[0]);

    if (argc != 2) {
        fprintf(stderr, "usage: %s <case> | --list\n", argv[0]);
        return 2;
    }
    if (!strcmp(argv[1], "--list")) {
        for (int i = 0; i < n; i++)
            printf("%s\n", cases[i].name);
        return 0;
    }
    for (int i = 0; i < n; i++)
        if (!strcmp(argv[1], cases[i].name))
            return run(&cases[i]);
    fprintf(stderr, "unknown case %s\n", argv[1]);
    return 2;
}
