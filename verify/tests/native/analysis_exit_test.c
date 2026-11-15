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
//         idle), no thread of the scan is left (they are named mak/scan,
//         mak/scan-work and mak/scan-feed), and the drain took less than
//         its 2 s limit. Without the handler the scan is still decoding
//         there, on its five threads. A thread that has told the drain it
//         is done can stay listed for a moment while the kernel takes it
//         down: the check gives it 50 ms.
// No leak check: the core is left alive on purpose.
#include "analysis_test.h"

const char *__asan_default_options(void) { return "detect_leaks=0"; }

static mpv_handle *g_h;
static double t_exit;
static int threads_scanning;

// The threads of this process whose name starts with mak/scan.
static int scan_threads(void)
{
    DIR *d = opendir("/proc/self/task");
    if (!d)
        return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.')
            continue;
        char path[300], name[32] = "";
        snprintf(path, sizeof path, "/proc/self/task/%s/comm", e->d_name);
        FILE *f = fopen(path, "r");
        if (!f)
            continue;   // gone between the listing and the read
        if (fgets(name, sizeof name, f) && !strncmp(name, "mak/scan", 8))
            n++;
        fclose(f);
    }
    closedir(d);
    return n;
}

static void at_end(void)
{
    if (!g_h)
        return;
    double took = mt_now() - t_exit;
    struct an_wave w;
    an_wave_read(g_h, &w);
    int now = scan_threads(), left = now;
    for (double t0 = mt_now(); left > 0 && mt_now() - t0 < 0.05; left = scan_threads())
        usleep(1000);
    printf("     %.3f s after exit(): waveform %s, %d scan threads at once, %d after "
           "50 ms (%d while scanning)\n", took, w.state, now, left, threads_scanning);
    mt_check(!strcmp(w.state, "idle"), "the scan was cancelled before the "
             "exit handlers after it (%s)", w.state);
    mt_check(left == 0, "the coordinator and its 4 workers are gone (%d of %d left)",
             left, threads_scanning);
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
        int now = scan_threads();
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
    mt_check(threads_scanning >= 2, "the scan runs on named threads (%d seen)",
             threads_scanning);
    g_h = h;
    t_exit = mt_now();
    exit(0);
}
