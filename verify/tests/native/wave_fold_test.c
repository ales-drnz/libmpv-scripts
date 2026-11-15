// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// wave_fold_test <mode>: white-box test of audio/mak_waveform.c, which
// run.sh builds from the patched tree: the fold of the waveform that grows
// from playback, fed as the af-tap feeds it (mono float, a timestamp, a
// rate).
//   tail  a 10 s axis (250 bins) and 12 s of audio, quiet up to 10 s and
//         loud after: the last bin holds the last 40 ms of the axis, so it
//         stays quiet. r24 folds everything past the axis into the last
//         bin, which shows the peak of the whole tail.
//   far   the same axis and one loud frame at a timestamp far past it
//         (1e12 s, then 1e30 s): no bin changes. r24 puts it in the last
//         bin, after a signed overflow of the sample position times the
//         bins (UBSAN=1 stops there).
//   roll  a rolling window, a frame at 1 s, then frames and a cache range
//         at 1e30 s: the window still holds the first frame alone. r24
//         casts the timestamp over the bin width to an integer it does not
//         fit (UBSAN=1 stops there).
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

#define RATE 48000
static float chunk[4800];

// 100 ms at [pts]: [v] before [split] seconds, [after] from there on.
static void fold(double pts, float v, double split, float after, int gen)
{
    for (int i = 0; i < 4800; i++)
        chunk[i] = pts + (double)i / RATE < split ? v : after;
    mak_waveform_fold_samples(chunk, 4800, pts, RATE, gen);
}

struct snap {
    int bins, filled;
    float peak_last, peak_all;
    int64_t range_start_us, range_end_us;
};

static void snap(struct snap *s)
{
    struct mpv_node n;
    memset(s, 0, sizeof(*s));
    mak_waveform_read(&n, NULL);
    struct mpv_node_list *l = n.u.list;
    for (int i = 0; i < l->num; i++) {
        if (!strcmp(l->keys[i], "max")) {
            const float *v = l->values[i].u.ba->data;
            s->bins = l->values[i].u.ba->size / sizeof(float);
            for (int b = 0; b < s->bins; b++)
                if (v[b] > s->peak_all)
                    s->peak_all = v[b];
            s->peak_last = s->bins ? v[s->bins - 1] : 0;
        } else if (!strcmp(l->keys[i], "filled")) {
            const uint8_t *v = l->values[i].u.ba->data;
            for (size_t b = 0; b < l->values[i].u.ba->size; b++)
                s->filled += v[b] != 0;
        } else if (!strcmp(l->keys[i], "range_start_us")) {
            s->range_start_us = l->values[i].u.int64;
        } else if (!strcmp(l->keys[i], "range_end_us")) {
            s->range_end_us = l->values[i].u.int64;
        }
    }
    talloc_free(l);
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "";
    struct snap s;
    int gen = mak_waveform_begin_generation();
    if (!strcmp(mode, "tail") || !strcmp(mode, "far")) {
        mak_waveform_arm_progressive(gen, 10.0);
        // Quiet to the end of the axis; the frame at 9.95 s crosses it.
        for (int k = 0; k < 100; k++)
            fold(k * 0.1, 0.01f, 10.0, 0.9f, gen);
        fold(9.95, 0.01f, 10.0, 0.9f, gen);
        if (!strcmp(mode, "tail")) {
            for (int k = 100; k < 120; k++)
                fold(k * 0.1, 0.9f, 0, 0.9f, gen);
        } else {
            fold(1e12, 0.9f, 0, 0.9f, gen);
            fold(1e30, 0.9f, 0, 0.9f, gen);
        }
        snap(&s);
        check(s.bins == 250 && s.filled == 250, "250 bins, all filled (%d, %d)",
              s.bins, s.filled);
        check(s.peak_last < 0.02f, "the last bin holds the end of the axis, "
              "not what came after (peak %.2f)", s.peak_last);
        check(s.peak_all < 0.02f, "no bin holds audio past the axis (peak %.2f)",
              s.peak_all);
    } else if (!strcmp(mode, "roll")) {
        mak_waveform_arm_rolling(gen);
        fold(1.0, 0.25f, 0, 0.25f, gen);
        fold(1e30, 0.9f, 0, 0.9f, gen);
        mak_waveform_update_cache_range(1e30, 1e30);
        snap(&s);
        check(s.bins >= 2 && s.bins <= 4 && s.peak_all < 0.3f,
              "the window holds the frame at 1 s alone (%d bins, peak %.2f)",
              s.bins, s.peak_all);
        check(s.range_start_us == 1000000, "the window starts at 1 s (%lld us)",
              (long long)s.range_start_us);
    } else {
        fprintf(stderr, "usage: %s tail|far|roll\n", argv[0]);
        return 2;
    }
    mak_waveform_stop();
    printf(failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", failures);
    return failures ? 1 : 0;
}
