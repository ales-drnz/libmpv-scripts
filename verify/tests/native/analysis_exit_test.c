// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_exit_test <mode> <fixtures> <tmpdir>: the process exits in the
// middle of a scan without destroying its core (H-7), as an app killed by
// its window's close does. The coordinator and its workers are detached
// threads inside libavcodec: the exit handlers that come next free what
// they use, so mak_scan.c registers one (drain_at_exit) that cancels the
// scan and waits for them. This test registers its own before mpv's, so it
// runs after it, and looks at what the drain left.
//   exit  long.flac (15 min, 4 workers) decoding, then exit(0): at the
//         exit handlers after the drain the scan is cancelled (waveform
//         idle), the five threads of the scan are gone, and the drain took
//         less than its 2 s limit. Without the handler the scan is still
//         decoding there, on its five threads.
// No leak check: the core is left alive on purpose.
#include "analysis_test.h"

const char *__asan_default_options(void) { return "detect_leaks=0"; }

static mpv_handle *g_h;
static double t_exit;
static int threads_scanning;

static void at_end(void)
{
    if (!g_h)
        return;
    double took = mt_now() - t_exit;
    int threads = mt_count_files("/proc/self/task");
    struct an_wave w;
    an_wave_read(g_h, &w);
    printf("     %.3f s after exit(): waveform %s, %d threads (%d while scanning)\n",
           took, w.state, threads, threads_scanning);
    mt_check(!strcmp(w.state, "idle"), "the scan was cancelled before the "
             "exit handlers after it (%s)", w.state);
    mt_check(threads <= threads_scanning - 5,
             "the coordinator and its 4 workers are gone (%d threads, %d before)",
             threads, threads_scanning);
    mt_check(took < 2.0, "the drain did not run into its limit (%.3f s)", took);
    an_wave_free(&w);
    fflush(stdout);
    if (mt_result())
        _exit(1);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    if (argc < 4 || strcmp(argv[1], "exit")) {
        fprintf(stderr, "usage: %s exit <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    // Before mpv_create, whose core registers the drain: handlers run in
    // the reverse order.
    atexit(at_end);
    char file[1024];
    snprintf(file, sizeof file, "%s/long.flac", argv[2]);
    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", 1);
    an_flag(h, "loudness-scan-enabled", 1);
    mpv_set_property_string(h, "pause", "yes");
    mt_cmd(h, "loadfile", file, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");
    // In the middle of the decode: some bins sealed, most not.
    struct an_wave w;
    double t0 = mt_now();
    int mid = 0;
    while (mt_now() - t0 < 20 && !mid) {
        mpv_wait_event(h, 0.005);
        /* The most threads the scan had: a worker whose slice is short is
         * gone by the middle of the decode, on a loaded machine above all,
         * and the count taken there alone was one short. */
        int now = mt_count_files("/proc/self/task");
        if (now > threads_scanning)
            threads_scanning = now;
        an_wave_read(h, &w);
        mid = !strcmp(w.state, "decoding") && w.coverage > 20;
        if (an_final_wave(w.state)) {
            an_wave_free(&w);
            break;
        }
        an_wave_free(&w);
    }
    mt_check(mid, "the scan is in the middle of its decode");
    g_h = h;
    t_exit = mt_now();
    exit(0);
}
