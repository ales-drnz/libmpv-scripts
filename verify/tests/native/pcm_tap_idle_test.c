// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// pcm_tap_idle_test <mode>: white-box test of audio/out/mak_pcm_tap.c (F162),
// which run.sh builds from the patched tree, with a fake clock and a fake
// 48 kHz stereo float output that writes 480 frames every 10 ms.
//   idle   a listener reads at 30 Hz for 1 s, then stops for 5 s: the
//          writes must stop within 2 s of the last read, the first read
//          after that is unavailable (the ring starts over) and the next
//          one holds only what was written since
//   slow   a reader every 3 s: from the third read on every read returns
//          a full window, and no write after the second read is dropped
//   pause  reads at 30 Hz go on through 10 s without writes (a pause):
//          the first read after it still has the samples from before
//          (control, green before and after)
//   quiet  a pause the kit does not poll (it rests while the core is idle):
//          5 s with no writes and no reads, then a read must still return
//          the samples from before, and the writes after it go on from them
//   busy   the reader holds the tap's lock (F5-1): a write of the output's
//          thread returns at once and drops its chunk, and the next one
//          goes through. r24 waits on the lock, in the device's callback
//          for a pull output.
//   alloc  a read allocates nothing while it holds the tap's lock, where
//          the output's thread may be waiting for it. r24 allocates the
//          whole node there, six times a read.
//   nan    a float chunk with NaN and infinite samples (F5-4): the window
//          read back holds zeros in their place, and the samples around
//          them. r24 hands them to the reader.
//   bench  time of one write (480 stereo float frames) while a listener
//          reads, and 10 s after it stopped (real clock for the timing,
//          fake clock for the tap); prints, never fails
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "osdep/threads.h"

// The tap's lock, counted per thread, and the allocations made under it:
// the test replaces malloc, calloc and realloc for the process (ASan's
// underneath), which talloc calls.
static _Thread_local int locks_held;
static atomic_int allocs_locked;

static int t_lock(pthread_mutex_t *m)
{
    int r = pthread_mutex_lock(m);
    locks_held++;
    return r;
}

static int t_trylock(pthread_mutex_t *m)
{
    int r = pthread_mutex_trylock(m);
    if (!r)
        locks_held++;
    return r;
}

static int t_unlock(pthread_mutex_t *m)
{
    locks_held--;
    return pthread_mutex_unlock(m);
}

#undef mp_mutex_lock
#undef mp_mutex_trylock
#undef mp_mutex_unlock
#define mp_mutex_lock(m) t_lock(m)
#define mp_mutex_trylock(m) t_trylock(m)
#define mp_mutex_unlock(m) t_unlock(m)

extern void *__interceptor_malloc(size_t n);
extern void *__interceptor_calloc(size_t nmemb, size_t n);
extern void *__interceptor_realloc(void *p, size_t n);

void *malloc(size_t n)
{
    if (locks_held)
        atomic_fetch_add(&allocs_locked, 1);
    return __interceptor_malloc(n);
}

void *calloc(size_t nmemb, size_t n)
{
    if (locks_held)
        atomic_fetch_add(&allocs_locked, 1);
    return __interceptor_calloc(nmemb, n);
}

void *realloc(void *p, size_t n)
{
    if (locks_held)
        atomic_fetch_add(&allocs_locked, 1);
    return __interceptor_realloc(p, n);
}

#include "audio/out/mak_pcm_tap.c"

static int64_t fake_now = 1000000000;   // 1 s
int64_t mp_time_ns(void) { return fake_now; }
bool af_fmt_is_pcm(int format) { return format == AF_FORMAT_FLOAT; }

static int failures;

static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s ", ok ? "ok  " : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    failures += !ok;
}

static struct ao fake_ao;
static float chunk[480 * 2];

// One AO chunk of 480 frames at value v. Returns whether it reached the ring.
static int wr(float v)
{
    for (int i = 0; i < 480 * 2; i++)
        chunk[i] = v;
    void *d[1] = {chunk};
    size_t before = g_tap.write_pos, valid = g_tap.valid_bytes;
    mak_pcm_tap_write(&fake_ao, d, 480);
    return g_tap.write_pos != before || g_tap.valid_bytes != valid;
}

struct win {
    size_t frames;
    long count[3];   // samples at 0.25, -0.5, 0.75
    float last;
};

// pcm-tap-frame through the tap's reader. Returns -1 when unavailable.
static int rd(struct win *w)
{
    memset(w, 0, sizeof(*w));
    struct mpv_node n = {0};
    if (mak_pcm_tap_read(&n, 4096) < 0)
        return -1;
    struct mpv_node_list *l = n.u.list;
    for (int i = 0; i < l->num; i++) {
        if (strcmp(l->keys[i], "samples"))
            continue;
        struct mpv_byte_array *ba = l->values[i].u.ba;
        const float *s = ba->data;
        size_t ns = ba->size / sizeof(float);
        w->frames = ns / 2;
        for (size_t k = 0; k < ns; k++) {
            w->count[0] += s[k] == 0.25f;
            w->count[1] += s[k] == -0.5f;
            w->count[2] += s[k] == 0.75f;
        }
        w->last = ns ? s[ns - 1] : 0;
    }
    talloc_free(l);
    return 0;
}

static void step_ms(int ms) { fake_now += (int64_t)ms * 1000000; }

static double now_s(void) { return fake_now / 1e9; }

static void mode_idle(void)
{
    struct win w;
    check(!wr(0.25f), "a write before any read is dropped");
    step_ms(10);
    check(rd(&w) < 0, "the first read arms the tap and finds it empty");
    int bad = 0;
    double last_read = 0;
    for (int t = 0; t < 1000; t += 10) {
        step_ms(10);
        bad += !wr(0.25f);
        if (t % 30 == 0) {
            bad += rd(&w) < 0;
            last_read = now_s();
        }
    }
    check(bad == 0, "1 s of writes and 30 Hz reads all go through (%d not)", bad);
    double last_write = 0;
    int passed = 0;
    for (int t = 0; t < 5000; t += 10) {
        step_ms(10);
        if (wr(-0.5f)) {
            last_write = now_s();
            passed++;
        }
    }
    printf("     after the last read at %.2f s: %d of 500 writes reached the "
           "ring, the last at %.2f s\n", last_read, passed, last_write);
    check(last_write - last_read <= 2.01,
          "writes stop within 2 s of the last read (last %.2f s after it)",
          last_write - last_read);
    step_ms(10);
    int r = rd(&w);
    check(r < 0, "the first read after the idle span is unavailable "
          "(got %zu frames, %ld old samples)", w.frames, w.count[0] + w.count[1]);
    step_ms(10);
    wr(0.75f);
    step_ms(10);
    r = rd(&w);
    check(r == 0 && w.frames == 480 && w.count[2] == 960,
          "the next read holds only the new chunk (%zu frames, %ld new samples)",
          w.frames, w.count[2]);
}

static void mode_slow(void)
{
    struct win w;
    int ok_reads = 0, late_drops = 0, reads = 0;
    for (int t = 0; t <= 21000; t += 10) {
        if (t % 3000 == 0) {
            int r = rd(&w);
            reads++;
            printf("     read %d at %.1f s: %s, %zu frames\n", reads, now_s(),
                   r < 0 ? "unavailable" : "window", w.frames);
            if (reads >= 3 && r == 0 && w.frames == 4096)
                ok_reads++;
        }
        step_ms(10);
        int in = wr(0.25f);
        if (reads >= 2 && !in)
            late_drops++;
    }
    check(ok_reads == reads - 2, "reads 3 to %d return a full window (%d do)",
          reads, ok_reads);
    check(late_drops == 0, "no write after the second read is dropped (%d are)",
          late_drops);
}

static void mode_pause(void)
{
    struct win w;
    rd(&w);
    for (int t = 0; t < 1000; t += 10) {
        step_ms(10);
        wr(0.25f);
        if (t % 30 == 0)
            rd(&w);
    }
    for (int t = 0; t < 10000; t += 30) {
        step_ms(30);
        rd(&w);
    }
    step_ms(10);
    check(wr(0.75f), "the write after the pause reaches the ring");
    step_ms(10);
    int r = rd(&w);
    check(r == 0 && w.frames == 4096 && w.count[0] > 0 && w.count[2] == 960,
          "the read after the pause keeps the samples from before "
          "(%zu frames, %ld before, %ld after)", w.frames, w.count[0], w.count[2]);
}

static void mode_quiet(void)
{
    struct win w;
    rd(&w);
    for (int t = 0; t < 1000; t += 10) {
        step_ms(10);
        wr(0.25f);
        if (t % 30 == 0)
            rd(&w);
    }
    step_ms(5000);
    int r = rd(&w);
    check(r == 0 && w.frames == 4096 && w.count[0] == 8192,
          "the first read after a quiet pause returns the samples from "
          "before (%s, %zu frames, %ld before)", r < 0 ? "unavailable" : "window",
          w.frames, w.count[0]);
    step_ms(10);
    check(wr(0.75f), "the write after the pause reaches the ring");
    step_ms(10);
    r = rd(&w);
    check(r == 0 && w.frames == 4096 && w.count[0] > 0 && w.count[2] == 960,
          "the next read holds the samples from before and the new chunk "
          "(%zu frames, %ld before, %ld after)", w.frames, w.count[0], w.count[2]);
}

static atomic_int busy_done;

static void *busy_writer(void *arg)
{
    (void)arg;
    wr(0.75f);
    atomic_store(&busy_done, 1);
    return NULL;
}

static void mode_busy(void)
{
    struct win w;
    rd(&w);
    step_ms(10);
    check(wr(0.25f), "a write reaches the ring");
    size_t valid = g_tap.valid_bytes;
    pthread_mutex_lock(&g_tap_lock);   // a reader inside its copy
    pthread_t t;
    pthread_create(&t, NULL, busy_writer, NULL);
    for (int i = 0; i < 100 && !atomic_load(&busy_done); i++)
        usleep(5000);
    int returned = atomic_load(&busy_done);
    check(returned, "a write returns while the reader holds the lock");
    check(g_tap.valid_bytes == valid, "and leaves the ring as it was "
          "(%zu bytes, %zu before)", g_tap.valid_bytes, valid);
    pthread_mutex_unlock(&g_tap_lock);
    pthread_join(t, NULL);
    step_ms(10);
    check(wr(0.25f), "the next write reaches the ring");
    int r = rd(&w);
    check(r == 0 && w.count[0] == 1920 && w.count[2] == 0,
          "the reader gets the two chunks written (%ld samples, %ld of the "
          "dropped one)", w.count[0], w.count[2]);
}

static void mode_alloc(void)
{
    struct win w;
    rd(&w);
    for (int t = 0; t < 200; t += 10) {
        step_ms(10);
        wr(0.25f);
    }
    atomic_store(&allocs_locked, 0);
    int r = rd(&w);
    int n = atomic_load(&allocs_locked);
    check(r == 0 && w.frames == 4096, "a read returns a full window (%zu frames)",
          w.frames);
    check(n == 0, "it allocates nothing under the tap's lock (%d allocations)", n);
}

static void mode_nan(void)
{
    struct win w;
    rd(&w);
    step_ms(10);
    for (int i = 0; i < 480 * 2; i++)
        chunk[i] = 0.25f;
    for (int i = 100; i < 200; i++)
        chunk[i] = i % 3 == 0 ? NAN : i % 3 == 1 ? INFINITY : -INFINITY;
    void *d[1] = {chunk};
    mak_pcm_tap_write(&fake_ao, d, 480);
    struct mpv_node n = {0};
    int r = mak_pcm_tap_read(&n, 4096);
    check(r == 0, "the chunk reads back");
    if (r < 0)
        return;
    struct mpv_node_list *l = n.u.list;
    int bad = 0, zero = 0, kept = 0;
    for (int i = 0; i < l->num; i++) {
        if (strcmp(l->keys[i], "samples"))
            continue;
        const float *s = l->values[i].u.ba->data;
        size_t ns = l->values[i].u.ba->size / sizeof(float);
        for (size_t k = 0; k < ns; k++) {
            bad += !isfinite(s[k]);
            zero += s[k] == 0.0f;
            kept += s[k] == 0.25f;
        }
    }
    talloc_free(l);
    check(bad == 0, "no sample of the window is NaN or infinite (%d are)", bad);
    check(zero == 100 && kept == 860, "they read as silence, the others as "
          "written (%d zeros, %d kept)", zero, kept);
}

static double real_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e9 + ts.tv_nsec;
}

static void mode_bench(void)
{
    struct win w;
    rd(&w);
    for (int i = 0; i < 480 * 2; i++)
        chunk[i] = 0.25f;
    void *d[1] = {chunk};
    const int n = 200000;
    double listening = 0;
    for (int i = 0; i < n; i++) {
        if (i % 3 == 0) {
            step_ms(10);
            rd(&w);
        }
        double t0 = real_ns();
        mak_pcm_tap_write(&fake_ao, d, 480);
        listening += real_ns() - t0;
    }
    step_ms(10000);
    double t0 = real_ns();
    for (int i = 0; i < n; i++)
        mak_pcm_tap_write(&fake_ao, d, 480);
    double after = (real_ns() - t0) / n;
    printf("     one write of 480 stereo frames while listening: %.0f ns, "
           "10 s after the last read: %.0f ns\n", listening / n, after);
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "idle";
    fake_ao.format = AF_FORMAT_FLOAT;
    fake_ao.channels.num = 2;
    fake_ao.samplerate = 48000;
    if (!strcmp(mode, "idle"))
        mode_idle();
    else if (!strcmp(mode, "slow"))
        mode_slow();
    else if (!strcmp(mode, "pause"))
        mode_pause();
    else if (!strcmp(mode, "quiet"))
        mode_quiet();
    else if (!strcmp(mode, "busy"))
        mode_busy();
    else if (!strcmp(mode, "alloc"))
        mode_alloc();
    else if (!strcmp(mode, "nan"))
        mode_nan();
    else if (!strcmp(mode, "bench"))
        mode_bench();
    else {
        printf("unknown mode %s\n", mode);
        return 2;
    }
    printf(failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", failures);
    return failures ? 1 : 0;
}
