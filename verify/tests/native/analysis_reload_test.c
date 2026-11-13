// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_reload_test <mode> <fixtures> <tmpdir>: the same file loaded
// again once its analysis is complete (F166). r23 starts the whole scan
// again at every FILE_LOADED, the file decoded once more (over SMB, a new
// download), while the client, with the same path, keeps its result and
// stops polling.
//   same    a.flac analyzed (waveform and loudness), then loaded again:
//           right after the second FILE_LOADED both stay ready, with the
//           same bins and the same loudness
//   loop    a.flac alone with loop-playlist=inf, a seek near its end: at the
//           wrap both stay ready (the scenario of the audit)
//   other   a.flac analyzed, then b.flac: a new scan (the control)
//   loudon  a.flac analyzed with the waveform only, the loudness scan turned
//           on, a.flac again: a new scan, as the loudness has no result
//   track   two.mka with aid=1 analyzed, then with aid=2: a new scan
//   ext     a.flac analyzed, then a.flac with b.flac as an external track
//           (aid=2): not the main file's ready result
//   fd      a.flac as fdclose://N analyzed, stopped, then b.flac opened on
//           the same number N: a new scan
//   rewrite a copy of a.flac analyzed, then b.flac (also 30 s) copied over
//           it: a new scan
//   hookurl an on_load hook writes a file:// URL with an escape in it
//           (re%20write.flac) to stream-open-filename, as a source resolver
//           does: the waveform is ready, and stays at a second load. r24
//           hands the URL to FFmpeg's file protocol, which takes "%20" for
//           part of the name: the re-open finds no file and the analysis
//           fails, while the file plays (F5-15).
//   hookrewrite  the same, then b.flac copied over the file: a new scan,
//           the stamp is the decoded path's
#include <fcntl.h>
#include <sys/stat.h>
#include "analysis_test.h"

static void analyze(mpv_handle *h, const char *file, int loud,
                    struct an_wave *w, struct an_loud *l)
{
    mt_cmd(h, "loadfile", file, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "%s loaded", file);
    an_wait_final(h, 1, loud, 30, w, l);
    mt_check(!strcmp(w->state, "ready"), "the waveform of %s is ready (%s)",
             file, w->state);
    if (loud)
        mt_check(!strcmp(l->state, "ready"), "its loudness is ready (%s)",
                 l->state);
}

static void load_opts(mpv_handle *h, const char *file, const char *opts)
{
    const char *l[] = {"loadfile", file, "replace", "-1", opts, NULL};
    if (mpv_command(h, l) < 0)
        printf("     loadfile %s %s failed\n", file, opts);
}

static void copy_file(const char *from, const char *to)
{
    FILE *in = fopen(from, "rb"), *out = fopen(to, "wb");
    char buf[65536];
    size_t n;
    while (in && out && (n = fread(buf, 1, sizeof buf, in)) > 0)
        fwrite(buf, 1, n, out);
    if (in) fclose(in);
    if (out) fclose(out);
}

// A new scan right after FILE_LOADED: the waveform is not ready.
static void expect_rescan(mpv_handle *h, const char *what)
{
    struct an_wave w;
    struct an_loud l;
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 40), "loaded again");
    an_wave_read(h, &w);
    an_loud_read(h, &l);
    printf("     after FILE_LOADED: waveform %s, loudness %s\n", w.state, l.state);
    mt_check(strcmp(w.state, "ready") != 0, "%s is scanned again (%s)", what,
             w.state);
    an_wave_free(&w);
}

// The states right after the next FILE_LOADED, before any poll.
static void after_loaded(mpv_handle *h, struct an_wave *w, struct an_loud *l)
{
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 40), "loaded again");
    an_wave_read(h, w);
    an_loud_read(h, l);
    printf("     after FILE_LOADED: waveform %s (%d bins filled), loudness %s (%.2f LUFS)\n",
           w->state, w->filled, l->state, l->integrated);
}

static void same_result(const struct an_wave *a, const struct an_loud *la,
                        const struct an_wave *b, const struct an_loud *lb)
{
    mt_check(!strcmp(b->state, "ready") && !strcmp(lb->state, "ready"),
             "both stay ready, no new scan (%s, %s)", b->state, lb->state);
    mt_check(b->filled == a->filled && b->bins == a->bins &&
             lb->integrated == la->integrated,
             "with the same result (%d of %d bins, %.2f LUFS; before %d of %d, %.2f)",
             b->filled, b->bins, lb->integrated, a->filled, a->bins,
             la->integrated);
}

// Answers the on_load hook with [url] as stream-open-filename and waits for
// FILE_LOADED. Returns 0 when the load ends without it.
static int hook_loaded(mpv_handle *h, const char *url)
{
    double t0 = mt_now();
    int hooked = 0;
    while (mt_now() - t0 < 20) {
        mpv_event *e = mpv_wait_event(h, 0.05);
        if (e->event_id == MPV_EVENT_HOOK) {
            mpv_event_hook *hk = e->data;
            mpv_set_property_string(h, "stream-open-filename", url);
            mpv_hook_continue(h, hk->id);
            hooked = 1;
        } else if (e->event_id == MPV_EVENT_FILE_LOADED) {
            return 1;
        } else if (e->event_id == MPV_EVENT_END_FILE && hooked) {
            return 0;   // before the hook it is the end of the file before
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s same|loop|other|loudon|track|ext|fd|rewrite|hookurl|hookrewrite <fixtures> <tmpdir>\n",
                argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    char a[1024], b[1024];
    snprintf(a, sizeof a, "%s/a.flac", argv[2]);
    snprintf(b, sizeof b, "%s/b.flac", argv[2]);

    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", 1);
    struct an_wave w1, w2;
    struct an_loud l1, l2;

    if (!strcmp(mode, "same")) {
        an_flag(h, "loudness-scan-enabled", 1);
        mpv_set_property_string(h, "pause", "yes");
        analyze(h, a, 1, &w1, &l1);
        mt_cmd(h, "loadfile", a, NULL, NULL);
        after_loaded(h, &w2, &l2);
        same_result(&w1, &l1, &w2, &l2);
    } else if (!strcmp(mode, "loop")) {
        an_flag(h, "loudness-scan-enabled", 1);
        mpv_set_property_string(h, "ao", "null");
        mpv_set_property_string(h, "loop-playlist", "inf");
        analyze(h, a, 1, &w1, &l1);
        mt_cmd(h, "seek", "-1", "absolute+exact", NULL);
        after_loaded(h, &w2, &l2);
        same_result(&w1, &l1, &w2, &l2);
    } else if (!strcmp(mode, "other")) {
        an_flag(h, "loudness-scan-enabled", 1);
        mpv_set_property_string(h, "pause", "yes");
        analyze(h, a, 1, &w1, &l1);
        mt_cmd(h, "loadfile", b, NULL, NULL);
        after_loaded(h, &w2, &l2);
        mt_check(strcmp(w2.state, "ready") != 0,
                 "another file is scanned again (%s)", w2.state);
        an_wave_free(&w2);
        an_wait_final(h, 1, 1, 30, &w2, &l2);
        mt_check(!strcmp(w2.state, "ready") && !strcmp(l2.state, "ready") &&
                 l2.integrated != l1.integrated,
                 "with its own result (%.2f LUFS, a.flac %.2f)",
                 l2.integrated, l1.integrated);
    } else if (!strcmp(mode, "loudon")) {
        mpv_set_property_string(h, "pause", "yes");
        analyze(h, a, 0, &w1, &l1);
        an_flag(h, "loudness-scan-enabled", 1);
        an_pump(h, 0.5, MPV_EVENT_NONE);
        mt_cmd(h, "loadfile", a, NULL, NULL);
        after_loaded(h, &w2, &l2);
        an_wave_free(&w2);
        an_wait_final(h, 1, 1, 30, &w2, &l2);
        mt_check(!strcmp(w2.state, "ready") && !strcmp(l2.state, "ready"),
                 "the loudness turned on gets its result (%s, %s)",
                 w2.state, l2.state);
    } else if (!strcmp(mode, "track")) {
        char mka[1024];
        snprintf(mka, sizeof mka, "%s/two.mka", argv[2]);
        an_flag(h, "loudness-scan-enabled", 1);
        mpv_set_property_string(h, "pause", "yes");
        load_opts(h, mka, "aid=1");
        mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "aid=1 loaded");
        an_wait_final(h, 1, 1, 30, &w1, &l1);
        mt_check(!strcmp(w1.state, "ready"), "the waveform of aid=1 is ready (%s)",
                 w1.state);
        load_opts(h, mka, "aid=2");
        expect_rescan(h, "the other track");
    } else if (!strcmp(mode, "ext")) {
        char opts[1200];
        snprintf(opts, sizeof opts, "audio-files-append=%s,aid=2", b);
        an_flag(h, "loudness-scan-enabled", 1);
        mpv_set_property_string(h, "pause", "yes");
        analyze(h, a, 1, &w1, &l1);
        load_opts(h, a, opts);
        expect_rescan(h, "the external track");
    } else if (!strcmp(mode, "fd")) {
        mpv_set_property_string(h, "pause", "yes");
        int fa = open(a, O_RDONLY);
        char url[64];
        snprintf(url, sizeof url, "fdclose://%d", fa);
        analyze(h, url, 0, &w1, &l1);
        mt_cmd(h, "stop", NULL, NULL, NULL);
        an_pump(h, 1.0, MPV_EVENT_NONE);
        int fb = open(b, O_RDONLY);
        printf("     a.flac was descriptor %d, b.flac is %d\n", fa, fb);
        mt_check(fb == fa, "b.flac got the same number");
        mt_cmd(h, "loadfile", url, NULL, NULL);
        expect_rescan(h, "another file on the same descriptor number");
    } else if (!strcmp(mode, "rewrite")) {
        char copy[1200];
        snprintf(copy, sizeof copy, "%s/rewrite.flac", argv[3]);
        copy_file(a, copy);
        mpv_set_property_string(h, "pause", "yes");
        analyze(h, copy, 0, &w1, &l1);
        copy_file(b, copy);
        mt_cmd(h, "loadfile", copy, NULL, NULL);
        expect_rescan(h, "the file written again");
    } else if (!strcmp(mode, "hookurl") || !strcmp(mode, "hookrewrite")) {
        char copy[1200], url[1300];
        snprintf(copy, sizeof copy, "%s/re write.flac", argv[3]);
        snprintf(url, sizeof url, "file://%s/re%%20write.flac", argv[3]);
        copy_file(a, copy);
        mpv_set_property_string(h, "pause", "yes");
        mpv_hook_add(h, 0, "on_load", 0);
        mt_cmd(h, "loadfile", "resolve-me", NULL, NULL);
        mt_check(hook_loaded(h, url), "the hook's URL loaded");
        an_wait_final(h, 1, 0, 30, &w1, &l1);
        mt_check(!strcmp(w1.state, "ready") && w1.filled == w1.bins,
                 "the waveform of the file:// URL is ready (%s, %d of %d bins)",
                 w1.state, w1.filled, w1.bins);
        if (!strcmp(mode, "hookrewrite"))
            copy_file(b, copy);
        mt_cmd(h, "loadfile", "resolve-me", NULL, NULL);
        mt_check(hook_loaded(h, url), "loaded again");
        an_wave_read(h, &w2);
        printf("     after FILE_LOADED: waveform %s\n", w2.state);
        if (!strcmp(mode, "hookrewrite"))
            mt_check(strcmp(w2.state, "ready") != 0,
                     "the file written again is scanned again (%s)", w2.state);
        else
            mt_check(!strcmp(w2.state, "ready") && w2.filled == w1.filled,
                     "the result stays, no new scan (%s)", w2.state);
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    an_wave_free(&w1);
    an_wave_free(&w2);
    mpv_terminate_destroy(h);
    return mt_result();
}
