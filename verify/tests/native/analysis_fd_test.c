// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_fd_test <mode> <fixtures> <tmpdir>: the analysis of an fd://N
// source, what an Android content:// URI reaches mpv as (F156). Linux
// stands in for Android: the test opens the fixture itself and passes the
// descriptor. Waveform and loudness on.
//   fd       b.flac by path, then the same file as fd://N: the fd analysis is
//            ready with the bins and the loudness of the path one, and
//            playback of the fd keeps going (r17: both failed).
//   fdclose  the same with fdclose://N.
//   reuse    fd://N, and right after the load the test makes N name a.flac
//            (dup2): the analysis still describes b.flac.
//   late     fd://N loaded with the loudness off, N made to name a.flac once
//            the waveform is ready, then the loudness on: its pass still
//            reads b.flac (r21: it read a.flac and replaced the waveform).
//   lateoff  the same with both analyses off at the load, then both on.
//   two      two players of one process, each on an fd://N of its own file:
//            the analysis of the second one reads its own (a.flac).
//   nine     nine players, each on an fd://N of b.flac with the analyses
//            off; N of the ninth is made to name a.flac, then its analyses
//            go on: they read b.flac (r22 before: a table of eight had no
//            room for the ninth, which read N again).
//   pipe     fd://N on a pipe the test writes b.flac into: not a regular
//            file, so the waveform grows from playback (progressive) and
//            the loudness scan reports unavailable (r17: both failed).
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include "analysis_test.h"

struct writer { int fd; char path[1024]; };

static void *write_pipe(void *p)
{
    struct writer *w = p;
    int in = open(w->path, O_RDONLY);
    char buf[16384];
    ssize_t n;
    while (in >= 0 && (n = read(in, buf, sizeof buf)) > 0)
        if (write(w->fd, buf, n) != n)
            break;
    if (in >= 0)
        close(in);
    close(w->fd);
    return NULL;
}

static void load(mpv_handle *h, const char *url)
{
    mt_cmd(h, "loadfile", url, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "%s loaded", url);
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s fd|fdclose|reuse|late|lateoff|two|nine|pipe <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    const char *mode = argv[1];
    char b[1024], a[1024], url[64];
    snprintf(b, sizeof b, "%s/b.flac", argv[2]);
    snprintf(a, sizeof a, "%s/a.flac", argv[2]);

    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", 1);
    an_flag(h, "loudness-scan-enabled", 1);
    mpv_set_property_string(h, "pause", "yes");
    struct an_wave ref = {0}, w;
    struct an_loud lref = {0}, l;

    if (!strcmp(mode, "pipe")) {
        int p[2];
        if (pipe(p) < 0)
            return 2;
        struct writer wr = {.fd = p[1]};
        snprintf(wr.path, sizeof wr.path, "%s", b);
        pthread_t t;
        pthread_create(&t, NULL, write_pipe, &wr);
        snprintf(url, sizeof url, "fd://%d", p[0]);
        load(h, url);
        an_wait_final(h, 0, 1, 10, &w, &l);
        mt_check(!strcmp(l.state, "unavailable"), "loudness unavailable for a pipe (%s)", l.state);
        mt_check(!strcmp(w.state, "progressive"), "waveform grows from playback (%s)", w.state);
        an_wave_free(&w);
        mt_cmd(h, "stop", NULL, NULL, NULL);
        an_pump(h, 0.3, MPV_EVENT_NONE);
        close(p[0]);
        pthread_join(t, NULL);
        mpv_terminate_destroy(h);
        return mt_result();
    }

    if (!strcmp(mode, "nine")) {
        load(h, b);
        an_wait_final(h, 1, 1, 30, &ref, &lref);
        mt_cmd(h, "stop", NULL, NULL, NULL);
        an_flag(h, "waveform-enabled", 0);
        an_flag(h, "loudness-scan-enabled", 0);
        enum { PLAYERS = 9 };
        mpv_handle *ps[PLAYERS];
        int fds[PLAYERS];
        for (int i = 0; i < PLAYERS; i++) {
            ps[i] = an_create();
            mpv_initialize(ps[i]);
            mpv_set_property_string(ps[i], "pause", "yes");
            fds[i] = open(b, O_RDONLY);
            snprintf(url, sizeof url, "fd://%d", fds[i]);
            load(ps[i], url);
        }
        mpv_handle *last = ps[PLAYERS - 1];
        int other = open(a, O_RDONLY);
        mt_check(dup2(other, fds[PLAYERS - 1]) == fds[PLAYERS - 1],
                 "descriptor %d now reads a.flac", fds[PLAYERS - 1]);
        close(other);
        an_flag(last, "waveform-enabled", 1);
        an_flag(last, "loudness-scan-enabled", 1);
        an_wait_final(last, 1, 1, 30, &w, &l);
        mt_check(!strcmp(w.state, "ready"), "the ninth player's waveform ready (%s)", w.state);
        int same = w.bins == ref.bins && w.bins > 0 && w.min && ref.min;
        for (int i = 0; same && i < w.bins; i++)
            same = fabsf(w.min[i] - ref.min[i]) <= 1e-6f &&
                   fabsf(w.max[i] - ref.max[i]) <= 1e-6f;
        mt_check(same, "the ninth player's bins are its own file's (%d and %d bins)",
                 w.bins, ref.bins);
        mt_check(fabs(l.integrated - lref.integrated) < 0.01,
                 "the ninth player's loudness is its own file's (%.3f and %.3f)",
                 l.integrated, lref.integrated);
        an_wave_free(&w);
        an_wave_free(&ref);
        for (int i = 0; i < PLAYERS; i++) {
            mpv_terminate_destroy(ps[i]);
            close(fds[i]);
        }
        mpv_terminate_destroy(h);
        return mt_result();
    }

    if (!strcmp(mode, "two")) {
        // The references, by path, then b.flac as fd:// on h and a.flac as
        // fd:// on a second player: the analysis is the process's, of the
        // file loaded last.
        struct an_wave refa = {0};
        load(h, a);
        an_wait_final(h, 1, 1, 30, &refa, &lref);
        int fb = open(b, O_RDONLY), fa = open(a, O_RDONLY);
        snprintf(url, sizeof url, "fd://%d", fb);
        load(h, url);
        an_wait_final(h, 1, 1, 30, &w, &l);
        an_wave_free(&w);
        mpv_handle *h2 = an_create();
        mpv_initialize(h2);
        mpv_set_property_string(h2, "pause", "yes");
        snprintf(url, sizeof url, "fd://%d", fa);
        load(h2, url);
        an_wait_final(h2, 1, 1, 30, &w, &l);
        mt_check(!strcmp(w.state, "ready"), "second player's waveform ready (%s)", w.state);
        int same = w.bins == refa.bins && w.bins > 0 && w.min && refa.min;
        for (int i = 0; same && i < w.bins; i++)
            same = fabsf(w.min[i] - refa.min[i]) <= 1e-6f &&
                   fabsf(w.max[i] - refa.max[i]) <= 1e-6f;
        mt_check(same, "the second player's bins are a.flac's (%d and %d bins)",
                 w.bins, refa.bins);
        mt_check(fabs(l.integrated - lref.integrated) < 0.01,
                 "the second player's loudness is a.flac's (%.3f and %.3f)",
                 l.integrated, lref.integrated);
        an_wave_free(&w);
        an_wave_free(&refa);
        mpv_terminate_destroy(h2);
        mpv_terminate_destroy(h);
        close(fa);
        close(fb);
        return mt_result();
    }

    // The reference: the same file opened by path.
    load(h, b);
    an_wait_final(h, 1, 1, 30, &ref, &lref);
    mt_check(!strcmp(ref.state, "ready") && !strcmp(lref.state, "ready"),
             "path analysis ready (%s, %s)", ref.state, lref.state);

    int fd = open(b, O_RDONLY);
    snprintf(url, sizeof url, "%s://%d", strcmp(mode, "fdclose") ? "fd" : "fdclose", fd);
    if (!strcmp(mode, "fd"))
        mpv_set_property_string(h, "pause", "no");
    if (!strcmp(mode, "late") || !strcmp(mode, "lateoff"))
        an_flag(h, "loudness-scan-enabled", 0);
    if (!strcmp(mode, "lateoff"))
        an_flag(h, "waveform-enabled", 0);
    load(h, url);
    if (!strcmp(mode, "lateoff")) {
        // Nothing analyzed at the load; N is reused, then both go on.
        an_pump(h, 0.5, MPV_EVENT_NONE);
        int other = open(a, O_RDONLY);
        mt_check(dup2(other, fd) == fd, "descriptor %d now reads a.flac", fd);
        close(other);
        an_flag(h, "waveform-enabled", 1);
        an_flag(h, "loudness-scan-enabled", 1);
    }
    if (!strcmp(mode, "late")) {
        an_wait_final(h, 1, 0, 30, &w, &l);
        mt_check(!strcmp(w.state, "ready"), "fd waveform ready before the loudness (%s)", w.state);
        an_wave_free(&w);
        // N is reused once the file is loaded, then the loudness goes on
        // and its pass decodes the file again.
        int other = open(a, O_RDONLY);
        mt_check(dup2(other, fd) == fd, "descriptor %d now reads a.flac", fd);
        close(other);
        an_flag(h, "loudness-scan-enabled", 1);
    }
    if (!strcmp(mode, "reuse")) {
        // N now names a.flac, as when the app closes N and the number is
        // reused by its next open.
        int other = open(a, O_RDONLY);
        mt_check(dup2(other, fd) == fd, "descriptor %d now reads a.flac", fd);
        close(other);
    }
    an_wait_final(h, 1, 1, 30, &w, &l);
    mt_check(!strcmp(w.state, "ready"), "fd waveform ready (%s)", w.state);
    mt_check(!strcmp(l.state, "ready"), "fd loudness ready (%s)", l.state);
    int same = w.bins == ref.bins && w.bins > 0 && w.min && ref.min;
    for (int i = 0; same && i < w.bins; i++)
        same = fabsf(w.min[i] - ref.min[i]) <= 1e-6f &&
               fabsf(w.max[i] - ref.max[i]) <= 1e-6f && w.fill[i] == ref.fill[i];
    mt_check(same, "fd bins equal the path bins (%d and %d bins)", w.bins, ref.bins);
    mt_check(fabs(l.integrated - lref.integrated) < 0.01,
             "fd loudness equals the path loudness (%.3f and %.3f)",
             l.integrated, lref.integrated);
    if (!strcmp(mode, "fd")) {
        // Playback of the fd went on while the analysis read the same file.
        an_pump(h, 1.0, MPV_EVENT_NONE);
        double pos = -1;
        mt_double(h, "time-pos", &pos);
        mt_check(pos > 0.5, "the fd plays on (time-pos %.2f)", pos);
    }
    an_wave_free(&w);
    an_wave_free(&ref);
    mpv_terminate_destroy(h);
    if (strcmp(mode, "fdclose"))
        close(fd);
    return mt_result();
}
