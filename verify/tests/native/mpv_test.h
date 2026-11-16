// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Helpers every native test shares: checks, the RESULT line, time, and the
// mpv handle of the prefetch tests. run.sh builds and runs the tests.
#include <dirent.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <mpv/client.h>

static int mt_failures;

static double mt_now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void mt_sleep_ms(int ms) { usleep(ms * 1000); }

// Time in the native tests: one rule for every test, the same natively and
// under valgrind, which runs the code many times slower and one thread at a
// time.
//  1. A test that waits for something to happen waits on that condition
//     (mt_wait_until, an_wait_event, an_wait_final). The time it gives is a
//     ceiling: it only bounds a failure, and mt_ceil() multiplies it by
//     mt_slow(), so a slow run waits longer and never fails on the clock.
//     No fixed sleep stands in for "long enough for it to happen".
//  2. A fixed window is for a check that something does not happen (no
//     second warning, no seek, an idle core) and for a measure. It starts
//     once the condition it follows was waited on, and is not scaled.
//  3. A bound on a measure that the speed of the code decides (CPU time, how
//     long a step took) is mt_bound(native, slow): the slow bound is used
//     under valgrind and is set where valgrind's cost was measured, with
//     the reason, and still fails on what the check is there to catch.
//  4. A test of a pace the product keeps in real time against playback or a
//     download is not scaled: when valgrind cannot keep it, the mode is in
//     MEMCHECK_SLOW of run.sh, with the reason.
// run.sh sets MAK_TIME_SCALE (10) under valgrind; mt_slow() is 1 without it.
static double mt_slow(void)
{
    const char *s = getenv("MAK_TIME_SCALE");
    double f = s ? atof(s) : 1;
    return f >= 1 ? f : 1;
}

static double mt_ceil(double secs) { return secs * mt_slow(); }

static double mt_bound(double native, double slow)
{
    return mt_slow() > 1 ? slow : native;
}

// Runs step until cond holds or the ceiling (seconds, rule 1) runs out.
// cond is read again after the last step.
#define mt_wait_until(secs, cond, step)                                     \
    do {                                                                    \
        double mt_t0_ = mt_now(), mt_max_ = mt_ceil(secs);                  \
        while (!(cond) && mt_now() - mt_t0_ < mt_max_) {                    \
            step;                                                           \
        }                                                                   \
    } while (0)

static void mt_check(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s ", ok ? "ok  " : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    fflush(stdout);
    if (!ok)
        mt_failures++;
}

static int mt_result(void)
{
    printf(mt_failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", mt_failures);
    return mt_failures ? 1 : 0;
}

// mpv handle with the options every prefetch test shares: null audio output,
// prefetch on, the whole local file in the cache so the prefetch starts
// right after the first file loads.
static mpv_handle *mt_create(void)
{
    mpv_handle *h = mpv_create();
    mpv_set_option_string(h, "ao", getenv("AO") ? getenv("AO") : "null");
    mpv_set_option_string(h, "vid", "no");
    mpv_set_option_string(h, "terminal", "yes");
    mpv_set_option_string(h, "msg-time", "yes");
    mpv_set_option_string(h, "msg-level",
        getenv("MSGLEVEL") ? getenv("MSGLEVEL") : "all=warn,cplayer=v");
    mpv_set_option_string(h, "prefetch-playlist", "yes");
    mpv_set_option_string(h, "cache", "yes");
    // No builtin scripts: their own on_load hooks only add noise.
    const char *off[] = {"load-scripts", "ytdl", "load-auto-profiles",
        "load-stats-overlay", "load-console", "load-select", "load-commands",
        "load-context-menu", "load-positioning", "osc", NULL};
    for (int n = 0; off[n]; n++)
        mpv_set_option_string(h, off[n], "no");
    return h;
}

// String property or NULL (caller frees with mpv_free).
static char *mt_str(mpv_handle *h, const char *name)
{
    return mpv_get_property_string(h, name);
}

static int mt_double(mpv_handle *h, const char *name, double *out)
{
    return mpv_get_property(h, name, MPV_FORMAT_DOUBLE, out);
}

static int mt_int(mpv_handle *h, const char *name, int64_t *out)
{
    return mpv_get_property(h, name, MPV_FORMAT_INT64, out);
}

static int mt_str_is(mpv_handle *h, const char *name, const char *want)
{
    char *v = mt_str(h, name);
    int ok = v && want && strcmp(v, want) == 0;
    if (!ok)
        printf("     %s = %s (want %s)\n", name, v ? v : "<error>", want);
    mpv_free(v);
    return ok;
}

static int mt_cmd(mpv_handle *h, const char *a0, const char *a1, const char *a2,
                  const char *a3)
{
    const char *args[] = {a0, a1, a2, a3, NULL};
    int r = mpv_command(h, args);
    if (r < 0)
        printf("     command %s: %s\n", a0, mpv_error_string(r));
    return r;
}

static int mt_count_files(const char *dir)
{
    DIR *d = opendir(dir);
    if (!d)
        return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)))
        if (e->d_name[0] != '.')
            n++;
    closedir(d);
    return n;
}

// Number of this process's open file descriptors that point at path.
static int mt_fd_open(const char *path)
{
    DIR *d = opendir("/proc/self/fd");
    if (!d)
        return -1;
    int n = 0;
    struct dirent *e;
    char link[64], target[4096];
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.')
            continue;
        snprintf(link, sizeof link, "/proc/self/fd/%s", e->d_name);
        ssize_t l = readlink(link, target, sizeof target - 1);
        if (l <= 0)
            continue;
        target[l] = 0;
        if (strcmp(target, path) == 0)
            n++;
    }
    closedir(d);
    return n;
}
