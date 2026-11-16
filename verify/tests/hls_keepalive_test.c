// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Checks patch_ffmpeg_hls_keepalive.py against keepalive_http.py, which
// network_test.sh runs and whose log it reads for the connections. Both
// modes read hls.m3u8 to its end, as mpv does, through an AVIOContext of
// their own for the playlist (s->pb has no URLContext):
//   custom-pb  the segments open with libavformat's io_open, as mpv's
//              nested_io_open without libcurl, and http_multiple=0:
//              http_persistent stays on (upstream 9.0 turned it off for
//              such an s->pb), and the script checks that every segment
//              came on one connection.
//   custom-pb-multiple  the same with http_multiple left to its
//              autodetection, which must find HTTP/1.1 (upstream 9.0 turned
//              it off too): the next segment is fetched ahead on a second
//              connection, and the script checks two.
//   custom-io  io_open wraps every AVIOContext in one without a URLContext,
//              as a custom backend does: open_url_keepalive() must not
//              abort on it but open a new connection, and the script checks
//              one connection per segment.
// Both check that the whole stream is read (4 s of audio) and print the
// value of http_persistent and http_multiple after the read.
//
// Usage: hls_keepalive_test <mode> <port>
#include <stdio.h>
#include <string.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/bprint.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>

#define BUF 32768

static int fails;
static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fflush(stdout);
    if (!ok)
        fails++;
}

// The playlist, read once into memory and handed to the demuxer as s->pb.
struct mem { const uint8_t *data; size_t size, pos; };

static int mem_read(void *opaque, uint8_t *buf, int n)
{
    struct mem *m = opaque;
    size_t left = m->size - m->pos;
    if (!left)
        return AVERROR_EOF;
    if ((size_t)n > left)
        n = (int)left;
    memcpy(buf, m->data + m->pos, n);
    m->pos += n;
    return n;
}

// An AVIOContext over another one: it has no URLContext.
static int wrap_read(void *opaque, uint8_t *buf, int n)
{
    int r = avio_read_partial(opaque, buf, n);
    return r == 0 ? AVERROR_EOF : r;
}

static int64_t wrap_seek(void *opaque, int64_t off, int whence)
{
    if (whence == AVSEEK_SIZE)
        return avio_size(opaque);
    return avio_seek(opaque, off, whence & ~AVSEEK_FORCE);
}

static int wrapped;

static int wrap_io_open(AVFormatContext *s, AVIOContext **pb, const char *url, int flags,
                        AVDictionary **opts)
{
    AVIOContext *in = NULL;
    int r = avio_open2(&in, url, flags, &s->interrupt_callback, opts);
    if (r < 0)
        return r;
    uint8_t *buf = av_malloc(BUF);
    *pb = buf ? avio_alloc_context(buf, BUF, 0, in, wrap_read, NULL, wrap_seek) : NULL;
    if (!*pb) {
        av_free(buf);
        avio_closep(&in);
        return AVERROR(ENOMEM);
    }
    (*pb)->seekable = in->seekable;
    wrapped++;
    return 0;
}

static int wrap_io_close2(AVFormatContext *s, AVIOContext *pb)
{
    AVIOContext *in = pb->opaque;
    av_freep(&pb->buffer);
    avio_context_free(&pb);
    return avio_closep(&in);
}

int main(int argc, char **argv)
{
    if (argc < 3)
        return 2;
    const char *mode = argv[1];
    int custom_io = !strcmp(mode, "custom-io");
    int autodetect = !strcmp(mode, "custom-pb-multiple");
    char url[256];
    snprintf(url, sizeof url, "http://127.0.0.1:%s/hls.m3u8", argv[2]);

    AVIOContext *src = NULL;
    AVBPrint text;
    av_bprint_init(&text, 0, AV_BPRINT_SIZE_UNLIMITED);
    if (avio_open2(&src, url, AVIO_FLAG_READ, NULL, NULL) < 0)
        return 2;
    avio_read_to_bprint(src, &text, SIZE_MAX);
    avio_closep(&src);
    struct mem m = { (const uint8_t *)text.str, text.len, 0 };

    uint8_t *buf = av_malloc(BUF);
    AVIOContext *pb = avio_alloc_context(buf, BUF, 0, &m, mem_read, NULL, NULL);
    AVFormatContext *fmt = avformat_alloc_context();
    fmt->pb = pb;
    if (custom_io) {
        fmt->io_open = wrap_io_open;
        fmt->io_close2 = wrap_io_close2;
    }
    AVDictionary *opts = NULL;
    if (!strcmp(mode, "custom-pb"))
        av_dict_set(&opts, "http_multiple", "0", 0);
    int r = avformat_open_input(&fmt, url, av_find_input_format("hls"), &opts);
    av_dict_free(&opts);
    check(r >= 0, "the playlist opens");
    if (r < 0) {
        printf("RESULT FAIL (%d)\n", fails);
        return 1;
    }
    avformat_find_stream_info(fmt, NULL);

    AVPacket *pkt = av_packet_alloc();
    double seconds = 0;
    while ((r = av_read_frame(fmt, pkt)) >= 0) {
        AVStream *st = fmt->streams[pkt->stream_index];
        if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO)
            seconds += pkt->duration * av_q2d(st->time_base);
        av_packet_unref(pkt);
    }
    char msg[128];
    snprintf(msg, sizeof msg, "the whole stream is read (%.2f s, %s)", seconds, av_err2str(r));
    check(r == AVERROR_EOF && seconds > 3.9, msg);

    int64_t persistent = -2, multiple = -2;
    av_opt_get_int(fmt, "http_persistent", AV_OPT_SEARCH_CHILDREN, &persistent);
    av_opt_get_int(fmt, "http_multiple", AV_OPT_SEARCH_CHILDREN, &multiple);
    printf("http_persistent %lld, http_multiple %lld, %d wrapped opens\n",
           (long long)persistent, (long long)multiple, wrapped);
    check(persistent == 1, "http_persistent stays on");
    if (custom_io)
        check(wrapped > 1, "the segments open through the custom io_open");
    if (autodetect)
        check(multiple == 1, "http_multiple is autodetected on");

    av_packet_free(&pkt);
    avformat_close_input(&fmt);
    av_freep(&pb->buffer);
    avio_context_free(&pb);
    av_bprint_finalize(&text, NULL);
    printf("RESULT %s (%d)\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}
