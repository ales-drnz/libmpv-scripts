// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// read_error_test <mode> <fixtures> <tmpdir>: how the reading of a file
// ended (patch_read_error.py). The demuxer-read-error and
// demuxer-skipped-segments properties, and the mak_read_error and
// mak_skipped_segments fields of END_FILE, read through a copy of the
// patched layout once the property is found, as a client of a libmpv that
// may lack the patch does. Upstream ends every one of these files with
// reason eof and error 0. The files come from slow_http.py on $HTTP_PORT
// (run.sh), which cuts n.flac (4 s, with Range support) where CASES says.
// FFmpeg's reconnect (mpv sets reconnect=1, reconnect_delay_max=7) then
// tries for about 11 s before it reports EIO.
//   cutlist   n.flac cut at half, the resume gets no reply; then
//             short.flac: END_FILE of n has reason eof, error 0 and
//             mak_read_error 1; short.flac reads no and ends with 0
//   cutpark   n.flac cut at half, then the server is gone; alone with
//             keep-open: the player parks without END_FILE,
//             demuxer-read-error reads yes when eof-reached turns yes and
//             is notified; stop then sends END_FILE (stop) with
//             mak_read_error 1
//   norange   a server without Range support closes at half (FFmpeg does
//             not reconnect): END_FILE eof with mak_read_error 1
//   whole     n.flac to its end, then short.flac parked with keep-open:
//             mak_read_error 0 for both, demuxer-read-error no at the park
//   vbr       vbr.mp3, a VBR MP3 without Xing header whose duration is an
//             estimate (about 6 s for 4), to its end: no read error, and
//             the park position is short of the duration
//   resume    n.flac cut once at half, the resume served: FFmpeg's
//             reconnect repairs the drop, the whole file plays, no error
//   seekback  n.flac cut at 2/3 as in cutlist, with keep-open and the
//             cache off; at the park a seek back past the read buffers:
//             the read resumes (demuxer-read-error no) and reaches the
//             real end, since only the resume at the cut gets no reply. No
//             error at the second park: the error avio kept from the cut
//             must not come back at the real end.
//   retry     n.flac cut at 2/3, then the server answers nothing until the
//             test asks it for /up (slow_http.py outage); keep-open and the
//             seekable cache. At the park a seek to 2.9 s, 25 KB past the
//             cut, while the server is still down: the read is tried again
//             and fails, the player parks again soon with
//             demuxer-read-error yes. Then /up
//             and the same seek: the read resumes there, reaches the real
//             end, and demuxer-read-error is no at the second park. A cache
//             range that ends on a read error is no end of the file: a seek
//             past it is no seek into the cache.
//   retryback the same with a seek back to 0.5 s, into the cache: the
//             cache plays up to the cut, then the demuxer tries the read
//             again from the end of the cached range; refused, the player
//             parks at the cut again, and after /up it plays to the end.
//   retrynocache, retrybacknocache  retry and retryback with
//             demuxer-seekable-cache=no and the whole file in the stream
//             buffer (stream-buffer-size 1 MiB, as a small file is): every
//             seek goes to the demuxer and lands in the stream buffer, and
//             the stream must open the connection again where the cut left
//             it once the reading gets there. FFmpeg's reconnect is off
//             (reconnect=0): the seek opens the connection all the same.
//   hls       hls.m3u8 (n.flac in 1 s segments) whose seg2.ts answers 404,
//             then short.flac: END_FILE of the stream has
//             mak_skipped_segments 1 and mak_read_error 0 (a skipped
//             segment is no read error), short.flac reads 0. The system
//             FFmpeg of run.sh has no skipped_segments option
//             (patch_ffmpeg_segment_skips.py, checked on a patched FFmpeg
//             by network_test.sh): av_opt_get_int below stands in for it on
//             an HLS demuxer, with the 1 segment the server dropped. Where
//             the option exists the real count is read.
// A reply with an error status to the resume (503, 403), and a chunked
// stream that stops before its last chunk, end as EOF in upstream http.c
// whatever mpv does: patch_ffmpeg_http_read_errors.py, checked by
// network_test.sh. No mode here reads a chunked stream: the FFmpeg of
// run.sh decides those ends alone (9.0 ends even a whole one with EIO).
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dlfcn.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <libavutil/error.h>
#include <libavutil/opt.h>
#include "playback_test.h"

// mpv_event_end_file with the fields of patch_read_error.py.
struct mak_end_file {
    mpv_end_file_reason reason;
    int error;
    int64_t playlist_entry_id;
    int64_t playlist_insert_id;
    int playlist_insert_num_entries;
    int mak_read_error;
    int64_t mak_skipped_segments;
};

// The skipped_segments of an HLS demuxer, when its FFmpeg has none (hls
// mode); -1 stands in for nothing.
static int64_t stand_in = -1;

// Whether obj, an AVFormatContext, has an HLS demuxer: one of its child
// objects has FFmpeg's "hls demuxer" class. By class name, which every
// FFmpeg has, not by one of its options, which the FFmpeg 6.1 of the CI
// runner did not find (Build 40213197005).
static int is_hls(void *obj)
{
    // Through dlsym, like av_opt_get_int: the test links libmpv only.
    static void *(*child_next)(void *, void *);
    if (!child_next)
        child_next = (void *(*)(void *, void *))dlsym(RTLD_DEFAULT, "av_opt_child_next");
    if (!child_next)
        return 0;
    for (void *c = NULL; (c = child_next(obj, c));) {
        const AVClass *cls = *(const AVClass **)c;
        if (cls && cls->class_name && strstr(cls->class_name, "hls"))
            return 1;
    }
    return 0;
}

int av_opt_get_int(void *obj, const char *name, int search_flags, int64_t *out_val)
{
    static int (*real)(void *, const char *, int, int64_t *);
    static int told;
    if (!real)
        real = (int (*)(void *, const char *, int, int64_t *))dlsym(RTLD_NEXT, "av_opt_get_int");
    int r = real(obj, name, search_flags, out_val);
    // FFmpeg 7 and later answer a missing option with
    // AVERROR_OPTION_NOT_FOUND, earlier ones (the 6.1 of the CI runner)
    // with -1: any error stands in.
    if (r < 0 && stand_in >= 0 && !strcmp(name, "skipped_segments"))
    {
        int hls = is_hls(obj);
        if (!told++)
            printf("stand-in for skipped_segments: %s\n",
                   hls ? "an HLS demuxer" : "no HLS demuxer");
        if (hls) {
            *out_val = stand_in;
            return 0;
        }
    }
    return r;
}

struct st {
    int patched;
    int starts, loaded, ends;
    int end_reason[4], end_error[4];
    struct mak_end_file end[4];
    int64_t end_skipped_seen[4]; // demuxer-skipped-segments notified before it
    int read_error;     // last notified demuxer-read-error, -1 unavailable
    int64_t skipped;    // last notified demuxer-skipped-segments
    int eof;            // last notified eof-reached
    int yes_seen;       // demuxer-read-error notified yes since START_FILE
    int no_after_yes;   // ... then no again, within the same file
};

static void pump(mpv_handle *h, int ms, struct st *s)
{
    double until = mt_now() + ms / 1000.0;
    for (;;) {
        double left = until - mt_now();
        mpv_event *e = mpv_wait_event(h, left > 0 ? left : 0);
        if (e->event_id == MPV_EVENT_NONE) {
            if (left <= 0)
                return;
            continue;
        }
        if (e->event_id == MPV_EVENT_START_FILE) {
            s->starts++;
            s->yes_seen = s->no_after_yes = 0;
        }
        if (e->event_id == MPV_EVENT_FILE_LOADED)
            s->loaded++;
        if (e->event_id == MPV_EVENT_END_FILE && s->ends < 4) {
            mpv_event_end_file *ef = e->data;
            s->end_reason[s->ends] = ef->reason;
            s->end_error[s->ends] = ef->error;
            s->end_skipped_seen[s->ends] = s->skipped;
            if (s->patched)
                s->end[s->ends] = *(struct mak_end_file *)e->data;
            printf("END_FILE %d: reason %d, error %d", s->ends, ef->reason, ef->error);
            if (s->patched)
                printf(", mak_read_error %d, mak_skipped_segments %lld",
                       s->end[s->ends].mak_read_error,
                       (long long)s->end[s->ends].mak_skipped_segments);
            printf("\n");
            s->ends++;
        }
        if (e->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            mpv_event_property *p = e->data;
            int have = p->format != MPV_FORMAT_NONE;
            if (!strcmp(p->name, "demuxer-read-error")) {
                int v = have ? *(int *)p->data : -1;
                if (v == 1)
                    s->yes_seen = 1;
                if (v == 0 && s->yes_seen)
                    s->no_after_yes = 1;
                s->read_error = v;
            } else if (!strcmp(p->name, "demuxer-skipped-segments")) {
                s->skipped = have ? *(int64_t *)p->data : -1;
            } else if (!strcmp(p->name, "eof-reached")) {
                s->eof = have ? *(int *)p->data : -1;
            }
        }
    }
}

// Pumps until cond() or ms; returns cond().
static int wait_for(mpv_handle *h, struct st *s, int ms, int (*cond)(struct st *))
{
    double t0 = mt_now();
    while (!cond(s) && (mt_now() - t0) * 1000 < ms)
        pump(h, 20, s);
    return cond(s);
}

static int one_loaded(struct st *s) { return s->loaded >= 1; }
static int one_end(struct st *s) { return s->ends >= 1; }
static int two_ends(struct st *s) { return s->ends >= 2; }
static int two_loaded(struct st *s) { return s->loaded >= 2; }

// eof-reached now: 1, 0, or -1 when unavailable.
static int eof_now(mpv_handle *h)
{
    int f = 0;
    return mpv_get_property(h, "eof-reached", MPV_FORMAT_FLAG, &f) >= 0 ? f : -1;
}

// Pumps until eof-reached reads want for the file of START_FILE number
// starts, or ms. Read, not notified: a notification of the file before can
// come after the next START_FILE.
static int wait_eof(mpv_handle *h, struct st *s, int starts, int want, int ms)
{
    double t0 = mt_now();
    while ((s->starts != starts || eof_now(h) != want) && (mt_now() - t0) * 1000 < ms)
        pump(h, 20, s);
    return s->starts == starts && eof_now(h) == want;
}

// time-pos at a park, once the output played the audio it held when
// eof-reached turned yes (a few hundred ms).
static double park_pos(mpv_handle *h, struct st *s)
{
    double pos = -1;
    pump(h, 700, s);
    mt_double(h, "time-pos", &pos);
    return pos;
}

// demuxer-read-error now: 1, 0, or -1 when unavailable.
static int read_error_now(mpv_handle *h)
{
    int f = 0;
    return mpv_get_property(h, "demuxer-read-error", MPV_FORMAT_FLAG, &f) >= 0 ? f : -1;
}

static int64_t skipped_now(mpv_handle *h)
{
    int64_t n = -1;
    mpv_get_property(h, "demuxer-skipped-segments", MPV_FORMAT_INT64, &n);
    return n;
}

// GET path from the server on port, the outage switch of slow_http.py;
// returns whether the server answered.
static int http_get(const char *port, const char *path)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(atoi(port))};
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    char buf[256];
    int ok = fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof a) == 0;
    if (ok) {
        int n = snprintf(buf, sizeof buf, "GET %s HTTP/1.0\r\n\r\n", path);
        ok = write(fd, buf, n) == n && read(fd, buf, sizeof buf - 1) > 0;
    }
    if (fd >= 0)
        close(fd);
    return ok;
}

// Seeks to pos and plays: pumps until eof-reached reads no (up to ms, a
// seek that fails at once may skip it) and returns whether it did.
static int seek_play(mpv_handle *h, struct st *s, const char *pos, int ms)
{
    mt_cmd(h, "seek", pos, "absolute", NULL);
    mpv_set_property_string(h, "pause", "no");
    return wait_eof(h, s, 1, 0, ms);
}

static void check_end(struct st *s, int i, int reason, int read_error, int64_t skipped,
                      const char *what)
{
    mt_check(s->ends > i, "%s: END_FILE %d arrived", what, i);
    if (s->ends <= i)
        return;
    mt_check(s->end_reason[i] == reason && s->end_error[i] == 0,
             "%s: reason %d, error 0 (%d, %d)", what, reason, s->end_reason[i], s->end_error[i]);
    if (!s->patched)
        return;
    mt_check(s->end[i].mak_read_error == read_error, "%s: mak_read_error %d (%d)", what,
             read_error, s->end[i].mak_read_error);
    mt_check(s->end[i].mak_skipped_segments == skipped, "%s: mak_skipped_segments %lld (%lld)",
             what, (long long)skipped, (long long)s->end[i].mak_skipped_segments);
}

int main(int argc, char **argv)
{
    static const char *modes[] = {"cutlist", "cutpark", "norange", "whole", "vbr", "resume",
                                  "seekback", "hls", "retry", "retryback", "retrynocache",
                                  "retrybacknocache", NULL};
    const char *mode = argc > 1 ? argv[1] : "";
    int known = 0;
    for (int n = 0; modes[n]; n++)
        known |= !strcmp(mode, modes[n]);
    if (argc < 4 || !known) {
        fprintf(stderr, "usage: %s cutlist|cutpark|norange|whole|vbr|resume|seekback|hls|retry"
                "|retryback|retrynocache|retrybacknocache <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    int m_cutlist = !strcmp(mode, "cutlist"), m_cutpark = !strcmp(mode, "cutpark"),
        m_norange = !strcmp(mode, "norange"), m_whole = !strcmp(mode, "whole"),
        m_vbr = !strcmp(mode, "vbr"), m_resume = !strcmp(mode, "resume"),
        m_seekback = !strcmp(mode, "seekback"), m_hls = !strcmp(mode, "hls");
    // The retry modes: the seek after the park goes back or past the cut,
    // with or without the seekable cache.
    int m_retry = !strncmp(mode, "retry", 5);
    int retry_back = m_retry && strstr(mode, "back") != NULL;
    int retry_nocache = m_retry && strstr(mode, "nocache") != NULL;
    const char *port = getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0";
    char url[256], local[1024];
    snprintf(url, sizeof url, "http://127.0.0.1:%s/%s", port,
             m_vbr ? "vbr.mp3" : m_hls ? "hls.m3u8" : "n.flac");
    snprintf(local, sizeof local, "%s/short.flac", argv[2]);
    int playlist = m_cutlist || m_whole || m_hls;
    int park = m_cutpark || m_whole || m_vbr || m_resume || m_seekback || m_retry;
    if (m_hls)
        stand_in = 1;

    mpv_handle *h = pb_create();
    mpv_set_option_string(h, "keep-open", park ? "yes" : "no");
    if (m_seekback)
        mpv_set_option_string(h, "cache", "no");
    if (m_retry) {
        mpv_set_option_string(h, "cache", "yes");
        mpv_set_option_string(h, "demuxer-seekable-cache", retry_nocache ? "no" : "yes");
        // The whole file in the stream buffer, as a small file is: the
        // seeks of the nocache modes land in it. And FFmpeg's reconnect
        // off, as a client may set it: the cut ends the reading at once.
        if (retry_nocache) {
            mpv_set_option_string(h, "stream-buffer-size", "1MiB");
            mpv_set_option_string(h, "stream-lavf-o", "reconnect=0");
        }
    }
    mpv_initialize(h);

    struct st s = {.read_error = -1, .skipped = -1, .eof = -1};
    int f = 0;
    int r = mpv_get_property(h, "demuxer-read-error", MPV_FORMAT_FLAG, &f);
    s.patched = r != MPV_ERROR_PROPERTY_NOT_FOUND;
    mt_check(s.patched, "the libmpv has demuxer-read-error (%s)", mpv_error_string(r));
    mt_check(r == MPV_ERROR_PROPERTY_UNAVAILABLE || !s.patched,
             "demuxer-read-error unavailable without a file (%s)", mpv_error_string(r));
    mpv_observe_property(h, 1, "demuxer-read-error", MPV_FORMAT_FLAG);
    mpv_observe_property(h, 2, "demuxer-skipped-segments", MPV_FORMAT_INT64);
    mpv_observe_property(h, 3, "eof-reached", MPV_FORMAT_FLAG);

    mt_cmd(h, "loadfile", url, NULL, NULL);
    if (playlist)
        mt_cmd(h, "loadfile", local, "append", NULL);

    if (m_cutlist || m_hls) {
        // The cut starves the playback: the demuxer and the output reach the
        // end together, and END_FILE (queued) can come before the change of
        // demuxer-read-error. The field is what a playlist client reads.
        wait_for(h, &s, 30000, one_end);
        if (m_hls)
            mt_check(s.end_skipped_seen[0] == 1,
                     "demuxer-skipped-segments notified 1 while the stream played (%lld)",
                     (long long)s.end_skipped_seen[0]);
        check_end(&s, 0, MPV_END_FILE_REASON_EOF, m_cutlist, m_hls ? 1 : 0, "the stream");
        mt_check(wait_for(h, &s, 5000, two_loaded), "short.flac loaded");
        mt_check(read_error_now(h) == 0, "short.flac: demuxer-read-error no (%d)",
                 read_error_now(h));
        mt_check(skipped_now(h) == 0, "short.flac: demuxer-skipped-segments 0 (%lld)",
                 (long long)skipped_now(h));
        wait_for(h, &s, 10000, two_ends);
        check_end(&s, 1, MPV_END_FILE_REASON_EOF, 0, 0, "short.flac");
    }

    if (m_norange) {
        wait_for(h, &s, 30000, one_end);
        check_end(&s, 0, MPV_END_FILE_REASON_EOF, 1, 0, "n.flac");
    }

    if (park) {
        if (m_whole) {
            wait_for(h, &s, 30000, one_end);
            check_end(&s, 0, MPV_END_FILE_REASON_EOF, 0, 0, "n.flac");
        }
        double dur = -1, pos = -1;
        if (m_vbr) {
            mt_check(wait_for(h, &s, 5000, one_loaded), "vbr.mp3 loaded");
            mpv_get_property(h, "duration", MPV_FORMAT_DOUBLE, &dur);
        }
        int last = m_whole ? 2 : 1;
        mt_check(wait_eof(h, &s, last, 1, 30000), "parked at the end (eof-reached)");
        int now = read_error_now(h);
        mt_check(s.ends == last - 1, "no END_FILE at the park (%d)", s.ends);
        pos = park_pos(h, &s);
        printf("park: time-pos %.2f, demuxer-read-error %d\n", pos, now);
        if (m_cutpark || m_seekback || m_retry) {
            mt_check(now == 1, "demuxer-read-error yes at the park (%d)", now);
            mt_check(s.yes_seen, "demuxer-read-error notified yes");
            if (m_cutpark)
                mt_check(pos > 1.5 && pos < 2.6, "the park is at the cut, 2 s (%.2f)", pos);
            else
                mt_check(pos > 2.0 && pos < 3.2, "the park is at the cut, 2.7 s (%.2f)", pos);
        } else {
            mt_check(now == 0, "demuxer-read-error no at the park (%d)", now);
            mt_check(!s.yes_seen, "demuxer-read-error never notified yes");
        }
        if (m_resume)
            mt_check(pos > 3.8, "the whole file played (%.2f)", pos);
        if (m_whole)
            mt_check(pos > 0.8, "the whole of short.flac played (%.2f)", pos);
        if (m_vbr) {
            printf("vbr: duration %.2f, park at %.2f\n", dur, pos);
            mt_check(dur > 5.0, "the duration is an estimate over the 4 s of the file (%.2f)", dur);
            mt_check(pos > 3.8 && pos < dur - 1, "the park is at the end, short of the duration (%.2f)",
                     pos);
        }
        if (m_seekback) {
            // keep-open paused at the end.
            mt_cmd(h, "seek", "0.5", "absolute", NULL);
            mpv_set_property_string(h, "pause", "no");
            mt_check(wait_eof(h, &s, 1, 0, 5000), "playing again after the seek");
            mt_check(wait_eof(h, &s, 1, 1, 30000), "parked again at the real end");
            now = read_error_now(h);
            pos = park_pos(h, &s);
            printf("second park: time-pos %.2f, demuxer-read-error %d\n", pos, now);
            mt_check(s.no_after_yes, "demuxer-read-error back to no once the read resumed");
            mt_check(now == 0, "demuxer-read-error no at the real end (%d)", now);
            mt_check(pos > 3.8, "the second park is at the real end (%.2f)", pos);
        }
        if (m_retry) {
            const char *to = retry_back ? "0.5" : "2.9";
            // The server is still down: the read is tried again and fails.
            // A seek that fails at once may leave eof-reached yes throughout.
            if (!seek_play(h, &s, to, 3000))
                pump(h, 2000, &s);
            mt_check(wait_eof(h, &s, 1, 1, 30000), "parked again with the server down");
            now = read_error_now(h);
            pos = park_pos(h, &s);
            printf("park with the server down: time-pos %.2f, demuxer-read-error %d\n", pos, now);
            mt_check(now == 1, "demuxer-read-error yes while the server is down (%d)", now);
            if (retry_back && !retry_nocache)
                mt_check(pos > 2.0 && pos < 3.2, "the cache played up to the cut, 2.7 s (%.2f)", pos);
            mt_check(http_get(port, "/up"), "the server is back (/up)");
            s.no_after_yes = 0;
            s.yes_seen = now == 1;
            mt_check(seek_play(h, &s, to, 5000), "playing again after the seek");
            mt_check(wait_eof(h, &s, 1, 1, 30000), "parked again at the real end");
            now = read_error_now(h);
            pos = park_pos(h, &s);
            printf("second park: time-pos %.2f, demuxer-read-error %d\n", pos, now);
            mt_check(s.no_after_yes, "demuxer-read-error back to no once the read resumed");
            mt_check(now == 0, "demuxer-read-error no at the real end (%d)", now);
            mt_check(pos > 3.8, "the second park is at the real end (%.2f)", pos);
        }
        int before = s.ends;
        mt_cmd(h, "stop", NULL, NULL, NULL);
        double t0 = mt_now();
        while (s.ends == before && mt_now() - t0 < 5)
            pump(h, 20, &s);
        check_end(&s, before, MPV_END_FILE_REASON_STOP, m_cutpark, 0, "stop after the park");
    }

    mpv_terminate_destroy(h);
    return mt_result();
}
