// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// gapless_tail_test <mode> <fixtures> <tmpdir>: an output underrun in the
// gapless tail (patch_gapless_tail.py). ao-null-speed=5 drains the null
// device five times faster than real time, so buffer.c's thread, which
// wakes every quarter of the device buffer, finds it empty each time: an
// underrun on every pass, made deterministic. While the file plays mpv
// recovers it; once gapless set STATUS_EOF it did not, and keep-open
// parked with the tail queued: time-pos 1.789 for an end of 2.
//   park       start=1,end=2 of sine60, keep-open: parks at 2 (red on r20)
//   gyes       the same with gapless-audio=yes (red on r20)
//   last       two entries (end=1; start=3,end=4): the second parks at 4
//              (red on r20)
//   idle       the same two entries without keep-open: the tail is drained
//              before the output closes (sanity: green on r20 as well,
//              ao_null drains whatever it still plays)
//   nogapless  gapless-audio=no parks at 2 (control, green on r20)
//   realtime   ao-null-speed=1 parks at 2 (control, green on r20)
#include "playback_test.h"

// Pumps until eof-reached and pause are both yes (the keep-open park) or
// idle-active is yes, for up to 10 s. Returns 1 at the park, 2 at idle.
static int wait_end(mpv_handle *h, struct pb_ev *ev)
{
    double t0 = mt_now();
    while (mt_now() - t0 < 10) {
        pb_pump(h, 5, ev);
        char *e = mt_str(h, "eof-reached"), *p = mt_str(h, "pause"),
             *i = mt_str(h, "idle-active");
        int park = e && p && !strcmp(e, "yes") && !strcmp(p, "yes");
        int idle = i && !strcmp(i, "yes");
        mpv_free(e);
        mpv_free(p);
        mpv_free(i);
        if (park)
            return 1;
        if (idle)
            return 2;
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 4)
        return 2;
    const char *mode = argv[1], *fx = argv[2];
    int m_park = !strcmp(mode, "park"), m_gyes = !strcmp(mode, "gyes"),
        m_last = !strcmp(mode, "last"), m_idle = !strcmp(mode, "idle"),
        m_nogap = !strcmp(mode, "nogapless"), m_rt = !strcmp(mode, "realtime");
    if (!(m_park || m_gyes || m_last || m_idle || m_nogap || m_rt)) {
        printf("unknown mode %s\n", mode);
        return 2;
    }
    char path[4096];
    snprintf(path, sizeof path, "%s/sine60.flac", fx);

    mpv_handle *h = pb_create();
    mpv_set_option_string(h, "keep-open", m_idle ? "no" : "yes");
    mpv_set_option_string(h, "idle", "yes");
    mpv_set_option_string(h, "ao-null-speed", m_rt ? "1" : "5");
    if (m_gyes)
        mpv_set_option_string(h, "gapless-audio", "yes");
    if (m_nogap)
        mpv_set_option_string(h, "gapless-audio", "no");
    if (mpv_initialize(h) < 0)
        return 2;
    mpv_request_log_messages(h, "v");
    struct pb_ev ev = {.end_reason = -1,
                       .needle = {"draining left over audio", NULL}};

    double end = 2;
    if (m_last || m_idle) {
        const char *a[] = {"loadfile", path, "replace", "-1", "end=1", NULL};
        const char *b[] = {"loadfile", path, "append", "-1", "start=3,end=4", NULL};
        mpv_command(h, a);
        mpv_command(h, b);
        end = 4;
    } else {
        const char *a[] = {"loadfile", path, "replace", "-1", "start=1,end=2", NULL};
        mpv_command(h, a);
    }

    int got = wait_end(h, &ev);
    if (m_idle) {
        mt_check(got == 2, "the playlist ended in idle (%d)", got);
        mt_check(ev.hits[0] >= 1,
                 "the tail was drained before the output closed (%d)",
                 ev.hits[0]);
    } else {
        mt_check(got == 1, "parked by keep-open (%d)", got);
        double pos = -1;
        mt_double(h, "time-pos", &pos);
        mt_check(pos > end - 0.005, "time-pos at the park %.6f, end %.0f",
                 pos, end);
        // Nothing moves it while parked.
        pb_pump(h, 300, &ev);
        double again = -1;
        mt_double(h, "time-pos", &again);
        mt_check(again == pos, "time-pos stays %.6f (%.6f)", pos, again);
        if (m_last) {
            int64_t ppos = -1;
            mt_int(h, "playlist-pos", &ppos);
            mt_check(ppos == 1, "the second entry parked (%lld)",
                     (long long)ppos);
        }
    }
    mpv_terminate_destroy(h);
    return mt_result();
}
