// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// ao_close_test <mode> <fixtures> <tmpdir>: the audio output closes on the
// core thread (F289). The core thread opens the audio output; with gapless
// weak (the default) quit does not close it, so r17 closes it in
// mp_destroy() on the thread that calls mpv_terminate_destroy. On Windows
// that runs the WASAPI COM teardown on a thread that never ran its init
// (the hotplug crash, for the AO).
// With ao=pcm (the default here) the test sees the thread: it interposes
// fopen64, fdopen and fclose and records the thread name for the
// ao-pcm-file. mpv 0.42 opens it with mp_fopen, open() then fdopen(), so
// fdopen tells it by the path of its descriptor; mpv 0.41 called fopen.
// Init and close must both run on "core". AO=null skips the thread check and
// leaves the clean sequence under ASan and TSan.
// Options as the kit sets them: keep-open, idle, audio-device-list and
// audio-output-state observed, quit then mpv_terminate_destroy.
// modes:
//   play       quit right after playback-restart
//   pause      opened with pause=yes, quit once the output is active
//   eof        quit at the end of the file, parked by keep-open
//   direct     mpv_terminate_destroy without a quit command
//   silence    audio-stream-silence=yes and paused
//   stop       stop first: idle_loop closes the output (control, green on r17)
//   nogapless  gapless-audio=no closes it at unload (control, green on r17)
#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>
#include "mpv_test.h"

static char target[4096];
static _Atomic(FILE *) target_fp;
static atomic_int opens, closes;
static char open_thread[16], close_thread[16];
static FILE *(*real_fopen64)(const char *, const char *);
static FILE *(*real_fdopen)(int, const char *);
static int (*real_fclose)(FILE *);

// Resolved before main, so no thread races on the lazy lookup.
__attribute__((constructor)) static void resolve(void)
{
    real_fopen64 = (FILE *(*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen64");
    real_fdopen = (FILE *(*)(int, const char *))dlsym(RTLD_NEXT, "fdopen");
    real_fclose = (int (*)(FILE *))dlsym(RTLD_NEXT, "fclose");
}

static void opened(FILE *f)
{
    pthread_getname_np(pthread_self(), open_thread, sizeof open_thread);
    atomic_store(&target_fp, f);
    atomic_fetch_add(&opens, 1);
}

FILE *fopen64(const char *path, const char *mode)
{
    if (!real_fopen64)
        resolve();
    FILE *f = real_fopen64(path, mode);
    if (f && target[0] && strcmp(path, target) == 0)
        opened(f);
    return f;
}

// target is a canonical path, as the link of the descriptor.
FILE *fdopen(int fd, const char *mode)
{
    if (!real_fdopen)
        resolve();
    FILE *f = real_fdopen(fd, mode);
    if (f && target[0]) {
        char link[64], path[PATH_MAX];
        snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
        ssize_t n = readlink(link, path, sizeof path - 1);
        if (n > 0) {
            path[n] = '\0';
            if (strcmp(path, target) == 0)
                opened(f);
        }
    }
    return f;
}

int fclose(FILE *f)
{
    if (!real_fclose)
        resolve();
    if (f && f == atomic_load(&target_fp)) {
        pthread_getname_np(pthread_self(), close_thread, sizeof close_thread);
        atomic_store(&target_fp, NULL);
        atomic_fetch_add(&closes, 1);
    }
    return real_fclose(f);
}

// Waits for the event, up to secs (a ceiling, mt_ceil). 1 if seen.
static int wait_event(mpv_handle *h, int id, double secs)
{
    double t0 = mt_now();
    while (mt_now() - t0 < mt_ceil(secs)) {
        mpv_event *e = mpv_wait_event(h, 0.05);
        if (e->event_id == id)
            return 1;
    }
    return 0;
}

// Waits until the property reads want, up to secs (a ceiling, mt_ceil).
static int wait_prop(mpv_handle *h, const char *name, const char *want, double secs)
{
    double t0 = mt_now();
    while (mt_now() - t0 < mt_ceil(secs)) {
        char *v = mt_str(h, name);
        int ok = v && strcmp(v, want) == 0;
        mpv_free(v);
        if (ok)
            return 1;
        mpv_wait_event(h, 0.05);
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s <mode> <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    const char *ao = getenv("AO") ? getenv("AO") : "pcm";
    int pcm = strcmp(ao, "pcm") == 0;
    pthread_setname_np(pthread_self(), "destroyer");
    char a[1024];
    snprintf(a, sizeof a, "%s/a.flac", argv[2]);
    // Stream silence makes ao=pcm write silence as fast as it can: that
    // goes to /dev/null, not to a file in a tmpfs.
    char dir[PATH_MAX];
    if (!realpath(argv[3], dir)) {
        fprintf(stderr, "no dir %s\n", argv[3]);
        return 2;
    }
    snprintf(target, sizeof target, "%s/out.wav", dir);
    if (!strcmp(mode, "silence"))
        snprintf(target, sizeof target, "/dev/null");

    mpv_handle *h = mpv_create();
    mpv_set_option_string(h, "ao", ao);
    mpv_set_option_string(h, "ao-pcm-file", target);
    mpv_set_option_string(h, "vid", "no");
    mpv_set_option_string(h, "terminal", "yes");
    mpv_set_option_string(h, "msg-level", "all=warn,cplayer=v,ao=v");
    mpv_set_option_string(h, "keep-open", "yes");
    mpv_set_option_string(h, "idle", "yes");
    const char *off[] = {"load-scripts", "ytdl", "load-auto-profiles",
        "load-stats-overlay", "load-console", "load-select", "load-commands",
        "load-context-menu", "load-positioning", "osc", NULL};
    for (int n = 0; off[n]; n++)
        mpv_set_option_string(h, off[n], "no");
    if (!strcmp(mode, "pause") || !strcmp(mode, "silence"))
        mpv_set_option_string(h, "pause", "yes");
    if (!strcmp(mode, "silence"))
        mpv_set_option_string(h, "audio-stream-silence", "yes");
    if (!strcmp(mode, "nogapless"))
        mpv_set_option_string(h, "gapless-audio", "no");
    mpv_initialize(h);
    mpv_observe_property(h, 1, "audio-device-list", MPV_FORMAT_NODE);
    mpv_observe_property(h, 2, "audio-output-state", MPV_FORMAT_STRING);

    mt_cmd(h, "loadfile", a, NULL, NULL);
    int ready;
    if (!strcmp(mode, "pause") || !strcmp(mode, "silence")) {
        ready = wait_prop(h, "audio-output-state", "active", 10);
    } else if (!strcmp(mode, "eof")) {
        ready = wait_event(h, MPV_EVENT_PLAYBACK_RESTART, 10);
        if (!pcm)
            mt_cmd(h, "seek", "58", "absolute", NULL);
        ready = ready && wait_prop(h, "eof-reached", "yes", 20);
    } else {
        ready = wait_event(h, MPV_EVENT_PLAYBACK_RESTART, 10);
    }
    mt_check(ready, "%s: the file reached its state", mode);
    mt_check(mt_str_is(h, "audio-output-state", "active"), "output active before quit");
    if (!strcmp(mode, "stop")) {
        mt_cmd(h, "stop", NULL, NULL, NULL);
        mt_check(wait_event(h, MPV_EVENT_IDLE, 10), "idle after stop");
    }
    if (!strcmp(mode, "play"))
        mt_sleep_ms(300);

    if (strcmp(mode, "direct"))
        mt_cmd(h, "quit", NULL, NULL, NULL);
    double t0 = mt_now();
    mpv_terminate_destroy(h);
    double took = mt_now() - t0;

    printf("terminate_destroy took %.3f s\n", took);
    // ao_pcm is untimed: a drain ends once it took everything, and the
    // bound fails a teardown that hangs. Under valgrind silence took 1.5 to
    // 2.2 s on CI, ao_pcm writing silence with no pause next to the core;
    // on the runner image of 16-11-2026 7.9 s and 30.9 s (Checks 45047475032
    // and 45067175751, with the libmpv and the test of the runs that
    // passed, main's among them), 0.06 to 1.4 s locally on 1 to 16 cores.
    // valgrind runs one thread at a time and the writer rarely yields, so the
    // time is the runner's scheduling. The slow bound stays far from a hang,
    // which only the mode's timeout (MEMCHECK_TIMEOUT) would end.
    double bound = mt_bound(1.0, 120.0);
    mt_check(took < bound, "no drain on the way out (%.3f s, under %.0f s)",
             took, bound);
    if (pcm) {
        printf("pcm file opened %d times on '%s', closed %d times on '%s'\n",
               atomic_load(&opens), open_thread, atomic_load(&closes), close_thread);
        mt_check(atomic_load(&opens) == 1 && atomic_load(&closes) == 1,
                 "the output file was opened and closed once");
        mt_check(strcmp(open_thread, "core") == 0, "the output opened on the core thread");
        mt_check(strcmp(close_thread, "core") == 0,
                 "the output closed on the core thread (got '%s')", close_thread);
    }
    return mt_result();
}
