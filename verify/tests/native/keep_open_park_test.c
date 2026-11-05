// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// keep_open_park_test <mode> <fixtures> <tmpdir>: the park of keep-open
// apart from a pause of the client in the gapless tail
// (patch_keep_open_park.py). start=1,end=2 of sine60 with keep-open, in
// real time on the null output, whose queue and device hold the tail
// once eof-reached is yes.
//   pause    pause in the tail: the pause returns at once (r22: it drained
//            the output first, about the length of the tail), the position
//            stays short of the end, keep-open-parked stays no; a resume
//            plays the tail, then keep-open parks at 2 with it yes
//   park     playing to the end parks with keep-open-parked yes, and a
//            seek back leaves it no
//   nopause  keep-open-pause=no: no park, keep-open-parked stays no
//   stop     a stop at the park leaves it: idle, keep-open-parked is no
//   seekend  seeks while parked: to 10 ms before the end it is no park
//            until a resume plays them; to the end itself, paused with
//            nothing to play, keep-open-parked is yes again (r22 before:
//            a seek in pause never parked again)
#include "playback_test.h"

// Pumps until [name] reads [want], for up to [secs]. Returns whether it did.
static int wait_str(mpv_handle *h, const char *name, const char *want,
                    double secs, struct pb_ev *ev)
{
    double t0 = mt_now();
    while (mt_now() - t0 < secs) {
        if (mt_str_is(h, name, want))
            return 1;
        pb_pump(h, 2, ev);
    }
    return mt_str_is(h, name, want);
}

int main(int argc, char **argv)
{
    if (argc < 4)
        return 2;
    const char *mode = argv[1], *fx = argv[2];
    int m_pause = !strcmp(mode, "pause"), m_park = !strcmp(mode, "park"),
        m_nopause = !strcmp(mode, "nopause"), m_stop = !strcmp(mode, "stop"),
        m_seekend = !strcmp(mode, "seekend");
    if (!(m_pause || m_park || m_nopause || m_stop || m_seekend)) {
        printf("unknown mode %s\n", mode);
        return 2;
    }
    char path[4096];
    snprintf(path, sizeof path, "%s/sine60.flac", fx);

    mpv_handle *h = pb_create();
    mpv_set_option_string(h, "keep-open", "yes");
    mpv_set_option_string(h, "idle", "yes");
    if (m_nopause)
        mpv_set_option_string(h, "keep-open-pause", "no");
    if (mpv_initialize(h) < 0)
        return 2;
    struct pb_ev ev = {.end_reason = -1};
    mt_check(mt_str_is(h, "keep-open-parked", "no"),
             "keep-open-parked is a property, no before a file");
    const char *a[] = {"loadfile", path, "replace", "-1", "start=1,end=2", NULL};
    mpv_command(h, a);
    const double end = 2;

    if (m_pause) {
        mt_check(wait_str(h, "eof-reached", "yes", 10, &ev),
                 "eof-reached with the tail still playing");
        mt_check(mt_str_is(h, "pause", "no"), "not paused yet in the tail");
        double t0 = mt_now();
        mpv_set_property_string(h, "pause", "yes");
        double took = mt_now() - t0;
        mt_check(took < 0.05, "the pause in the tail returns at once (%.3f s)",
                 took);
        // The next pass of the core settles time-pos on the delay the
        // output froze at the pause (a few ms), then it stays.
        pb_pump(h, 50, &ev);
        double pos = -1;
        mt_double(h, "time-pos", &pos);
        mt_check(pos < end - 0.02, "paused short of the end (%.3f of %.0f)",
                 pos, end);
        pb_pump(h, 400, &ev);
        double still = -1;
        mt_double(h, "time-pos", &still);
        mt_check(still == pos, "the position stays while paused (%.3f, %.3f)",
                 pos, still);
        mt_check(mt_str_is(h, "keep-open-parked", "no"),
                 "a pause in the tail is no park");
        mpv_set_property_string(h, "pause", "no");
        mt_check(wait_str(h, "keep-open-parked", "yes", 5, &ev),
                 "the resume plays the tail, then keep-open parks");
        mt_check(mt_str_is(h, "pause", "yes"), "paused by the park");
        mt_double(h, "time-pos", &pos);
        mt_check(pos > end - 0.005, "parked at the end (%.6f)", pos);
    } else if (m_seekend) {
        mt_check(wait_str(h, "keep-open-parked", "yes", 10, &ev),
                 "playing to the end parks");
        // 10 ms before the end: they wait for the resume, no park.
        mt_cmd(h, "seek", "1.99", "absolute", NULL);
        mt_check(wait_str(h, "keep-open-parked", "no", 2, &ev),
                 "the seek leaves the park");
        pb_pump(h, 500, &ev);
        mt_check(mt_str_is(h, "keep-open-parked", "no") &&
                 mt_str_is(h, "pause", "yes"),
                 "paused with 10 ms left is no park");
        mpv_set_property_string(h, "pause", "no");
        mt_check(wait_str(h, "keep-open-parked", "yes", 3, &ev),
                 "the resume plays them, then keep-open parks");
        // To the end itself: nothing left, a park again while paused.
        mt_cmd(h, "seek", "2", "absolute", NULL);
        mt_check(wait_str(h, "keep-open-parked", "no", 2, &ev),
                 "the seek to the end leaves the park");
        mt_check(wait_str(h, "keep-open-parked", "yes", 3, &ev),
                 "landed on the end, paused, it parks again");
        mt_check(mt_str_is(h, "pause", "yes"), "still paused");
    } else if (m_stop) {
        mt_check(wait_str(h, "keep-open-parked", "yes", 10, &ev),
                 "playing to the end parks");
        mt_cmd(h, "stop", NULL, NULL, NULL);
        mt_check(wait_str(h, "idle-active", "yes", 5, &ev), "idle after stop");
        // idle-active turns yes with the stop request, before the core has
        // closed the file: the flag goes with the close.
        mt_check(wait_str(h, "keep-open-parked", "no", 2, &ev),
                 "a stop at the park leaves it");
    } else if (m_park) {
        mt_check(wait_str(h, "keep-open-parked", "yes", 10, &ev),
                 "playing to the end parks");
        mt_check(mt_str_is(h, "pause", "yes") &&
                 mt_str_is(h, "eof-reached", "yes"),
                 "the park is paused at eof");
        mt_cmd(h, "seek", "1", "absolute", NULL);
        mt_check(wait_str(h, "keep-open-parked", "no", 2, &ev),
                 "a seek back leaves the park");
    } else {
        mt_check(wait_str(h, "eof-reached", "yes", 10, &ev), "eof reached");
        pb_pump(h, 1000, &ev);
        mt_check(mt_str_is(h, "pause", "no"), "no pause without keep-open-pause");
        mt_check(mt_str_is(h, "keep-open-parked", "no"),
                 "no park without keep-open-pause");
    }
    mpv_terminate_destroy(h);
    return mt_result();
}
