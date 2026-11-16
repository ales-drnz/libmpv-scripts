// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// pcm_tap_test <mode> <fixtures> <tmpdir>: the PCM tap ring after an output
// format change (F47).
//   ch    p_st48 (stereo, +0.25) then n_mono48 (mono, -0.5)
//   up    p_mono48 (mono, +0.25) then n_st48 (stereo, -0.5)
//   rate  p_st48 (48 kHz, +0.25) then n_st44 (44.1 kHz, -0.5)
//   idle  F162: pn_st48 (+0.25 for 2 s, then -0.5) read at 30 Hz until
//         windows come, then not for 3.4 s and past the switch: the next
//         read is unavailable (the tap disarmed and starts over), the one
//         after holds only -0.5
// The tap is armed before the first file; pcm-tap-frame is then polled
// every millisecond. A window read with the second file's format must hold
// only that file's samples (-0.5, or silence): a +0.25 sample is a frame of
// the first file read with the new channel count or rate. The null output
// gets a 20 ms buffer (AO_NULL_BUFFER), so its first write is shorter than
// the window, as on a real device.
#include "playback_test.h"

struct tap {
    int64_t rate, ch;
    size_t n;     // floats
    float *s;     // malloc'ed
};

static int tap_read(mpv_handle *h, struct tap *t)
{
    memset(t, 0, sizeof(*t));
    mpv_node n;
    if (mpv_get_property(h, "pcm-tap-frame", MPV_FORMAT_NODE, &n) < 0)
        return -1;
    mpv_node *r = pb_field(&n, "sample_rate"), *c = pb_field(&n, "channels"),
             *s = pb_field(&n, "samples");
    int ok = r && c && s && r->format == MPV_FORMAT_INT64 &&
             c->format == MPV_FORMAT_INT64 && s->format == MPV_FORMAT_BYTE_ARRAY;
    if (ok) {
        t->rate = r->u.int64;
        t->ch = c->u.int64;
        t->n = s->u.ba->size / sizeof(float);
        t->s = malloc(s->u.ba->size ? s->u.ba->size : 1);
        memcpy(t->s, s->u.ba->data, s->u.ba->size);
        if (s->u.ba->size % sizeof(float))
            t->n = (size_t)-1;
    }
    mpv_free_node_contents(&n);
    return ok ? 0 : -1;
}

// Drains the events, then sleeps ms.
static void idle_pump(mpv_handle *h, int ms)
{
    while (mpv_wait_event(h, 0)->event_id != MPV_EVENT_NONE)
        ;
    mt_sleep_ms(ms);
}

// One read of the listener at 30 Hz: got counts the windows.
static void idle_read(mpv_handle *h, struct tap *t, int *got)
{
    while (mpv_wait_event(h, 0)->event_id != MPV_EVENT_NONE)
        ;
    if (tap_read(h, t) == 0) {
        (*got)++;
        free(t->s);
    }
    mt_sleep_ms(33);
}

// F162: a listener that stops for longer than the idle span (2 s).
static int mode_idle(const char *fx)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/pn_st48.flac", fx);
    mpv_handle *h = pb_create();
    mpv_set_option_string(h, "ao-null-buffer", "0.02");
    if (mpv_initialize(h) < 0)
        return 2;
    struct tap t;
    mt_check(tap_read(h, &t) < 0, "pcm-tap-frame unavailable before playback");
    mt_cmd(h, "loadfile", path, NULL, NULL);
    // Read at 30 Hz until windows come: under valgrind the first ones come
    // late.
    int got = 0;
    mt_wait_until(5, got > 5, idle_read(h, &t, &got));
    mt_check(got > 5, "windows read while listening (%d)", got);
    // No reads past the 2 s switch to -0.5 and the 2 s idle span: the
    // playback passes the switch, and 3.4 s go by since the last read.
    double last = mt_now(), pos = -1;
    mt_wait_until(5, mt_double(h, "time-pos", &pos) >= 0 && pos >= 2.1,
                  idle_pump(h, 20));
    mt_check(pos >= 2.1, "the playback passed the switch (%.3f s)", pos);
    while (mt_now() - last < 3.4)
        idle_pump(h, 20);
    int r = tap_read(h, &t);
    mt_check(r < 0, "the first read after 3.4 s without reads is unavailable "
             "(got %zu frames)", r < 0 ? (size_t)0 : t.n / 2);
    if (r == 0)
        free(t.s);
    // The tap starts over: the next window comes once the output wrote.
    mt_wait_until(1, (r = tap_read(h, &t)) == 0, idle_pump(h, 20));
    long old = 0, fresh = 0;
    for (size_t i = 0; r == 0 && i < t.n; i++) {
        old += t.s[i] > 0.2f && t.s[i] < 0.3f;
        fresh += t.s[i] < -0.4f && t.s[i] > -0.6f;
    }
    mt_check(r == 0 && fresh > 0 && old == 0,
             "the next read holds only the audio after the pause "
             "(%ld new, %ld old samples)", fresh, old);
    if (r == 0)
        free(t.s);
    mpv_terminate_destroy(h);
    return mt_result();
}

int main(int argc, char **argv)
{
    if (argc < 4)
        return 2;
    const char *mode = argv[1], *fx = argv[2];
    if (!strcmp(mode, "idle"))
        return mode_idle(fx);
    const char *fa, *fb;
    int64_t a_rate = 48000, a_ch, b_rate, b_ch;
    if (!strcmp(mode, "ch")) {
        fa = "p_st48.flac"; a_ch = 2; fb = "n_mono48.flac"; b_rate = 48000; b_ch = 1;
    } else if (!strcmp(mode, "up")) {
        fa = "p_mono48.flac"; a_ch = 1; fb = "n_st48.flac"; b_rate = 48000; b_ch = 2;
    } else if (!strcmp(mode, "rate")) {
        fa = "p_st48.flac"; a_ch = 2; fb = "n_st44.flac"; b_rate = 44100; b_ch = 2;
    } else {
        printf("unknown mode %s\n", mode);
        return 2;
    }
    char pa[4096], pb[4096];
    snprintf(pa, sizeof pa, "%s/%s", fx, fa);
    snprintf(pb, sizeof pb, "%s/%s", fx, fb);

    mpv_handle *h = pb_create();
    // A small null-output buffer, so the first write of the new output is
    // shorter than the 4096-frame window, as with a real device period.
    mpv_set_option_string(h, "ao-null-buffer",
                          getenv("AO_NULL_BUFFER") ? getenv("AO_NULL_BUFFER") : "0.02");
    if (mpv_initialize(h) < 0)
        return 2;
    struct tap t;
    // The first read arms the tap; nothing has played yet.
    mt_check(tap_read(h, &t) < 0, "pcm-tap-frame unavailable before playback");
    free(t.s);
    mt_cmd(h, "loadfile", pa, "replace", NULL);
    mt_cmd(h, "loadfile", pb, "append", NULL);

    int a_win = 0, b_win = 0, stale_win = 0, other_win = 0, misaligned = 0;
    long b_new = 0, b_stale = 0;
    double first_b = 0, t0 = mt_now();
    while (mt_now() - t0 < mt_ceil(15)) {
        mpv_event *e;
        while ((e = mpv_wait_event(h, 0))->event_id != MPV_EVENT_NONE)
            ;
        if (tap_read(h, &t) == 0) {
            if (t.n == (size_t)-1 || (t.ch > 0 && t.n % t.ch))
                misaligned++;
            if (t.ch == b_ch && t.rate == b_rate) {
                if (!b_win)
                    first_b = mt_now();
                b_win++;
                long stale = 0, fresh = 0, zero = 0;
                for (size_t i = 0; t.n != (size_t)-1 && i < t.n; i++) {
                    if (t.s[i] > 0.2f && t.s[i] < 0.3f)
                        stale++;
                    else if (t.s[i] < -0.4f && t.s[i] > -0.6f)
                        fresh++;
                    else if (t.s[i] == 0.0f)
                        zero++;
                }
                if (b_win <= 3 && getenv("TRACE"))
                    printf("     trace: window %d: %zu frames, %ld old, %ld new, %ld zero\n",
                           b_win, t.n / t.ch, stale, fresh, zero);
                b_new += fresh;
                b_stale += stale;
                if (stale) {
                    if (stale_win < 4)
                        printf("     window %d of the new format: %zu frames, "
                               "%ld samples of the first file, %ld of the second\n",
                               b_win, t.n / t.ch, stale, fresh);
                    stale_win++;
                }
                if (mt_now() - first_b > 1.0) {
                    free(t.s);
                    break;
                }
            } else if (t.ch == a_ch && t.rate == a_rate) {
                a_win++;
            } else {
                other_win++;
            }
            free(t.s);
        }
        mt_sleep_ms(1);
    }
    printf("     windows: first format %d, second format %d, other %d\n",
           a_win, b_win, other_win);
    mt_check(a_win > 0, "the first file's format was read (%d windows)", a_win);
    mt_check(b_win > 0, "the second file's format was read (%d windows)", b_win);
    mt_check(b_new > 0, "the second file's samples were read (%ld)", b_new);
    mt_check(stale_win == 0,
             "no window of the new format holds the old file (%d windows, %ld samples)",
             stale_win, b_stale);
    mt_check(misaligned == 0, "every window is whole frames (%d not)", misaligned);
    mpv_terminate_destroy(h);
    return mt_result();
}
