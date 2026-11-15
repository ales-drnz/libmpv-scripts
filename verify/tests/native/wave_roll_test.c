// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// wave_roll_test <mode>: white-box test of the rolling window of
// audio/mak_waveform.c, the waveform of a live source: bins of 40 ms on
// absolute media time, grown as the af-tap feeds them, evicted with the
// demuxer's cache (mak_waveform_update_cache_range) and slid forward at
// their cap of 131072. Each sample is its own time in seconds over 1000, so
// the minimum and the maximum of a bin tell which 40 ms it holds: after any
// move of the window, every filled bin must still hold its own time.
//   evict  10 s folded, then the cache starts at 4.02 s: the window is 4 s
//          to 10 s, 150 bins. A cache that starts earlier again brings
//          nothing back, a frame before the window is dropped, one across
//          its start adds no bin, a cache without a range changes nothing,
//          and a cache that starts past the window empties it.
//   lead   the cache starts at 0.9 s and the first audio at 1 s: the window
//          starts at the first filled bin, 1 s, not at the cache's. A second
//          frame at 3 s leaves a gap of 25 unfilled bins inside; evicting
//          into the gap moves the start to 3 s, and into the audio to the
//          bin of the cache's start.
//   cap    5300 s folded at 100 Hz, 1428 bins more than the cap: the window
//          is the last 131072 bins, each with its own time. A frame 700 s
//          later slides it again and leaves the gap unfilled; a frame far
//          past the whole window leaves that frame alone.
//   stale  10 s folded, the cache starts at 5.02 s, then a frame at 12 s:
//          the 50 bins of the gap from 10 s to 12 s were never written
//          since the window moved, and must read zero, not what the arrays
//          held there before the move.
#include <stdarg.h>
#include <stdio.h>

#include "audio/mak_waveform.c"

// The loudness scan's state, which the arm calls set.
void mak_loudness_mark_unavailable(int gen) { (void)gen; }

static int failures;

static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s ", ok ? "ok  " : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    fflush(stdout);
    failures += !ok;
}

#define BIN_US 40000
#define CAP 131072

// [secs] seconds from [start] at [rate], each sample its own time over 1000.
// The samples sit half a period after the grid, so none is on the edge of a
// bin.
static void fold(double start, double secs, int rate, int gen)
{
    static float chunk[1000];
    int left = (int)(secs * rate + 0.5);
    double pts = start + 0.5 / rate;
    while (left > 0) {
        int n = left < rate ? left : rate;
        for (int i = 0; i < n; i++)
            chunk[i] = (float)((pts + (double)i / rate) / 1000.0);
        mak_waveform_fold_samples(chunk, n, pts, rate, gen);
        pts += (double)n / rate;
        left -= n;
    }
}

struct snap {
    char state[32];
    int bins, filled;
    int wrong;        // filled bins that hold another time than their own
    int dirty;        // unfilled bins whose min, max or rms is not zero
    int first_gap, gap_bins;
    int64_t start_us, end_us, duration_us;
};

static void snap(struct snap *s)
{
    struct mpv_node n;
    const float *mn = NULL, *mx = NULL, *rms = NULL;
    const uint8_t *fl = NULL;
    memset(s, 0, sizeof(*s));
    s->first_gap = -1;
    mak_waveform_read(&n, NULL);
    struct mpv_node_list *l = n.u.list;
    for (int i = 0; i < l->num; i++) {
        struct mpv_node *v = &l->values[i];
        const char *k = l->keys[i];
        if (!strcmp(k, "state"))
            snprintf(s->state, sizeof s->state, "%s", v->u.string);
        else if (!strcmp(k, "min") && v->format == MPV_FORMAT_BYTE_ARRAY)
            mn = v->u.ba->data;
        else if (!strcmp(k, "max") && v->format == MPV_FORMAT_BYTE_ARRAY)
            mx = v->u.ba->data;
        else if (!strcmp(k, "rms") && v->format == MPV_FORMAT_BYTE_ARRAY)
            rms = v->u.ba->data;
        else if (!strcmp(k, "filled") && v->format == MPV_FORMAT_BYTE_ARRAY) {
            fl = v->u.ba->data;
            s->bins = v->u.ba->size;
        } else if (!strcmp(k, "range_start_us"))
            s->start_us = v->u.int64;
        else if (!strcmp(k, "range_end_us"))
            s->end_us = v->u.int64;
        else if (!strcmp(k, "duration_us"))
            s->duration_us = v->u.int64;
    }
    for (int b = 0; b < s->bins && mn && mx && rms; b++) {
        if (!fl[b]) {
            if (s->first_gap < 0)
                s->first_gap = b;
            s->gap_bins++;
            s->dirty += mn[b] != 0 || mx[b] != 0 || rms[b] != 0;
            continue;
        }
        s->filled++;
        int64_t own = s->start_us / BIN_US + b;
        int64_t lo = (int64_t)(mn[b] * 1000.0 / 0.04);
        int64_t hi = (int64_t)(mx[b] * 1000.0 / 0.04);
        if ((lo != own || hi != own) && s->wrong++ < 5)
            printf("     bin %d of the window is bin %lld of the media, holds "
                   "%.4f s to %.4f s\n", b, (long long)own, mn[b] * 1000.0,
                   mx[b] * 1000.0);
    }
    if (s->bins && !(mn && mx && rms))
        s->wrong = -1;
    talloc_free(l);
}

// The window is [start_s, end_s) with [bins] bins, [filled] of them filled,
// and every filled bin holds its own time.
static void window(const char *what, double start_s, double end_s, int bins,
                   int filled)
{
    struct snap s;
    snap(&s);
    check(!strcmp(s.state, "rolling"), "%s: state rolling (%s)", what, s.state);
    check(s.start_us == llround(start_s * 1e6) && s.end_us == llround(end_s * 1e6),
          "%s: the window is %.2f s to %.2f s (%.2f, %.2f)", what, start_s,
          end_s, s.start_us / 1e6, s.end_us / 1e6);
    check(s.bins == bins && s.filled == filled, "%s: %d bins, %d filled (%d, %d)",
          what, bins, filled, s.bins, s.filled);
    check(s.duration_us == (int64_t)s.bins * BIN_US,
          "%s: the duration is its bins at 40 ms (%lld us, %d bins)", what,
          (long long)s.duration_us, s.bins);
    check(s.wrong == 0, "%s: every filled bin holds its own 40 ms (%d do not)",
          what, s.wrong);
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "";
    struct snap s;
    int gen = mak_waveform_begin_generation();
    mak_waveform_arm_rolling(gen);
    if (!strcmp(mode, "evict")) {
        window("armed", 0, 0, 0, 0);
        fold(0, 10, 1000, gen);
        mak_waveform_update_cache_range(0, 10);
        window("10 s folded", 0, 10, 250, 250);
        mak_waveform_update_cache_range(4.02, 10);
        window("the cache starts at 4.02 s", 4, 10, 150, 150);
        mak_waveform_update_cache_range(2.02, 10);
        window("the cache starts at 2.02 s again", 4, 10, 150, 150);
        fold(1, 1, 1000, gen);
        window("a frame before the window", 4, 10, 150, 150);
        fold(3.9, 0.2, 1000, gen);
        window("a frame across its start", 4, 10, 150, 150);
        mak_waveform_update_cache_range(-1, -1);
        window("a cache without a range", 4, 10, 150, 150);
        mak_waveform_update_cache_range(20.02, 30);
        window("the cache starts past the window", 20, 20, 0, 0);
        fold(20.4, 0.2, 1000, gen);
        window("a frame after that", 20.4, 20.6, 5, 5);
    } else if (!strcmp(mode, "lead")) {
        mak_waveform_update_cache_range(0.9, 5);
        fold(1, 1, 1000, gen);
        window("audio from 1 s, cache from 0.9 s", 1, 2, 25, 25);
        fold(3, 1, 1000, gen);
        window("a second frame at 3 s", 1, 4, 75, 50);
        snap(&s);
        check(s.first_gap == 25 && s.gap_bins == 25,
              "the gap is the 25 bins from 2 s to 3 s (%d from bin %d)",
              s.gap_bins, s.first_gap);
        mak_waveform_update_cache_range(2.5, 5);
        window("the cache starts in the gap", 3, 4, 25, 25);
        mak_waveform_update_cache_range(3.5, 5);
        window("the cache starts in the audio", 3.48, 4, 13, 13);
    } else if (!strcmp(mode, "cap")) {
        fold(0, 5300, 100, gen);
        window("5300 s folded", 5300 - CAP * 0.04, 5300, CAP, CAP);
        // The window slides to end at 6001 s: what is left of the first run
        // (758.12 s to 5300 s), 700 s unfilled, then the 25 new bins.
        fold(6000, 1, 100, gen);
        window("a frame at 6000 s", 6001 - CAP * 0.04, 6001, CAP, CAP - 17500);
        snap(&s);
        check(s.first_gap == CAP - 17525 && s.gap_bins == 17500,
              "the gap is the 17500 bins from 5300 s to 6000 s (%d from bin %d)",
              s.gap_bins, s.first_gap);
        fold(20000, 1, 100, gen);
        window("a frame far past the window", 20000, 20001, 25, 25);
    } else if (!strcmp(mode, "stale")) {
        fold(0, 10, 1000, gen);
        mak_waveform_update_cache_range(5.02, 10);
        fold(12, 1, 1000, gen);
        window("5 s to 10 s, then a frame at 12 s", 5, 13, 200, 150);
        snap(&s);
        check(s.first_gap == 125 && s.gap_bins == 50,
              "the gap is the 50 bins from 10 s to 12 s (%d from bin %d)",
              s.gap_bins, s.first_gap);
        check(s.dirty == 0, "an unfilled bin reads zero (%d of %d do not)",
              s.dirty, s.gap_bins);
        } else {
        fprintf(stderr, "usage: %s evict|lead|cap|stale\n", argv[0]);
        return 2;
    }
    mak_waveform_stop();
    printf(failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", failures);
    return failures ? 1 : 0;
}
