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

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s same|loop|other|loudon <fixtures> <tmpdir>\n",
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
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    an_wave_free(&w1);
    an_wave_free(&w2);
    mpv_terminate_destroy(h);
    return mt_result();
}
