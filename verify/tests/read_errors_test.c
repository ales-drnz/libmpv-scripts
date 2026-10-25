// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The read errors FFmpeg reports to mpv (patch_read_error.py), on the
// patched FFmpeg of network_test.sh, against slow_http.py on <port>, which
// serves the files of network_test.sh with the options of each mode.
//   http-refused  data.bin (466574 bytes) cut at half, the resume answered
//                 503 with Content-Length 0. With reconnect=1 and
//                 reconnect_delay_max=1 (mpv uses 7) the reads end with
//                 EIO after the retries (patch_ffmpeg_http_read_errors.py);
//                 upstream ends them with AVERROR_EOF, as a complete file.
//   http-resume   the same cut, the resume served: every byte, then
//                 AVERROR_EOF (control).
//   http-nolength the whole file without Content-Length, so its end is the
//                 close, from a server with Range support: http.c takes the
//                 close for a cut, reconnects past the end and gets 416,
//                 which ends the file with AVERROR_EOF. The patch leaves a
//                 body of unknown size alone, or it would retry it and end
//                 it with EIO.
//   http-nolength-norange  the same from a server without Range support:
//                 no reconnect, and http.c ends even the whole body with
//                 EIO. An end of unknown place cannot be told from a cut:
//                 the known limit, also upstream.
//   chunked-ok    data.bin as a live chunked stream (no Range support),
//                 closed by its last chunk: every byte, then AVERROR_EOF.
//   chunked-between  the same stream closed between two chunks, at the
//                 last boundary before 233287: EIO with the 14 chunks read
//                 (upstream: AVERROR_EOF, http_get_line() at the close).
//   chunked-mid   closed at 233287 inside a chunk, with Connection: close:
//                 EIO (upstream: an empty read, AVERROR_EOF, no log).
//                 In the three the bytes are those sent once: no reconnect
//                 starts the stream again (reconnect_streamed is off), and
//                 network_test.sh checks that the server got one request.
//   hls-ok        hls.m3u8 (4 s of AAC in 1 s segments) to its end: the
//                 skipped_segments option of the demuxer reads 0
//                 (patch_ffmpeg_segment_skips.py; upstream has no option).
//   hls-404       seg2.ts answers 404: skipped_segments 1, and the packets
//                 of the segments after it are read.
//   hls-cut       seg2.ts stops at half on every request: skipped_segments 1.
//   dash-ok, dash-404, dash-cut  the same with d.mpd, whose third fragment
//                 is chunk3.m4s.
//
// Usage: read_errors_test <mode> <port>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/dict.h>
#include <libavutil/opt.h>

static int fails;
static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fflush(stdout);
    if (!ok)
        fails++;
}

// Reads url with avio to its end; *bytes gets the bytes read, the result
// is the code that ended the reading.
static int read_all(const char *url, int64_t *bytes)
{
    AVIOContext *io = NULL;
    AVDictionary *opts = NULL;
    av_dict_set(&opts, "reconnect", "1", 0);
    av_dict_set(&opts, "reconnect_delay_max", "1", 0);
    int r = avio_open2(&io, url, AVIO_FLAG_READ, NULL, &opts);
    av_dict_free(&opts);
    *bytes = 0;
    if (r < 0)
        return r;
    unsigned char buf[16384];
    for (;;) {
        r = avio_read_partial(io, buf, sizeof buf);
        if (r < 0)
            break;
        *bytes += r;
    }
    avio_closep(&io);
    return r;
}

// Demuxes url to its end; *packets gets the packets, *skipped the
// skipped_segments of the demuxer (-1 when it has none).
static int demux_all(const char *url, int *packets, int64_t *skipped)
{
    AVFormatContext *fc = NULL;
    *packets = 0;
    *skipped = -1;
    int r = avformat_open_input(&fc, url, NULL, NULL);
    if (r < 0)
        return r;
    AVPacket *pkt = av_packet_alloc();
    while ((r = av_read_frame(fc, pkt)) >= 0) {
        (*packets)++;
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    int64_t n = 0;
    if (av_opt_get_int(fc, "skipped_segments", AV_OPT_SEARCH_CHILDREN, &n) >= 0)
        *skipped = n;
    avformat_close_input(&fc);
    return r;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: read_errors_test <mode> <port>\n");
        return 2;
    }
    const char *mode = argv[1];
    char url[128], msg[256];
    av_log_set_level(AV_LOG_WARNING);

    if (!strncmp(mode, "http-", 5) || !strncmp(mode, "chunked-", 8)) {
        int64_t bytes;
        snprintf(url, sizeof url, "http://127.0.0.1:%s/data.bin", argv[2]);
        int r = read_all(url, &bytes);
        printf("read %lld bytes, ended with %s\n", (long long)bytes, av_err2str(r));
        if (!strcmp(mode, "http-refused")) {
            snprintf(msg, sizeof msg, "the cut body ends with EIO, not as a complete file (%s)",
                     av_err2str(r));
            check(r == AVERROR(EIO), msg);
            check(bytes == 233287, "the bytes up to the cut");
        } else if (!strcmp(mode, "chunked-between") || !strcmp(mode, "chunked-mid")) {
            int64_t want = !strcmp(mode, "chunked-mid") ? 233287 : 14 * 16384;
            snprintf(msg, sizeof msg, "the chunked stream cut short ends with EIO (%s)",
                     av_err2str(r));
            check(r == AVERROR(EIO), msg);
            snprintf(msg, sizeof msg, "the bytes sent once, up to the cut (%lld of %lld)",
                     (long long)bytes, (long long)want);
            check(bytes == want, msg);
        } else if (!strcmp(mode, "http-nolength-norange")) {
            snprintf(msg, sizeof msg, "the whole body of unknown size ends with EIO (%s)",
                     av_err2str(r));
            check(r == AVERROR(EIO), msg);
            check(bytes == 466574, "every byte");
        } else {
            snprintf(msg, sizeof msg, "the body ends with AVERROR_EOF (%s)", av_err2str(r));
            check(r == AVERROR_EOF, msg);
            check(bytes == 466574, "every byte");
        }
    } else {
        int hls = !strncmp(mode, "hls-", 4);
        const char *what = strchr(mode, '-') + 1;
        int packets;
        int64_t skipped;
        snprintf(url, sizeof url, "http://127.0.0.1:%s/%s", argv[2], hls ? "hls.m3u8" : "d.mpd");
        int r = demux_all(url, &packets, &skipped);
        printf("%d packets, skipped_segments %lld, ended with %s\n", packets,
               (long long)skipped, av_err2str(r));
        check(r == AVERROR_EOF, "the stream ends with AVERROR_EOF");
        snprintf(msg, sizeof msg, "skipped_segments %d (%lld)", strcmp(what, "ok") ? 1 : 0,
                 (long long)skipped);
        check(skipped == (strcmp(what, "ok") ? 1 : 0), msg);
        // About 43 AAC packets a second: the segments after the lost one play.
        snprintf(msg, sizeof msg, "the packets after the lost segment are read (%d)", packets);
        check(packets > (strcmp(what, "ok") ? 110 : 160), msg);
    }

    printf(fails ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", fails);
    return fails ? 1 : 0;
}
