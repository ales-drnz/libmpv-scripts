// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// tap_ring_test <mode>: white-box test of audio/mak_tap.c (F81), which run.sh
// builds from the patched tree, on frames of a fake mp_aframe. The ring of a
// tapped label covers TAP_BUFFER_SECONDS of the format it holds, whatever
// format came first, and goes when no label is tapped any more.
//   grow   an 8 kHz mono frame, then a 48 kHz stereo one: the ring covers
//          3 s of the second format (it covered 0.25 s, sized on the first)
//   free   the taps turned off: the ring's buffer is freed (it was kept
//          for the life of the process, up to 256 MB)
//   flip   two players tapping one label at two formats, frame after frame:
//          the ring keeps the buffer it grew to (it was freed and allocated
//          again on every frame, up to 16 MB)
//   rearm  a writer of label A while the taps go from A to X and back: the
//          slot armed for X, which nobody writes, stays empty (a writer that
//          found A's slot before the change wrote A's audio into it)
//   race   a writer changing format, three readers of audio-tap-frames and
//          the taps turned on and off, on five threads for 4 s: no use after
//          free of a reallocated ring (AddressSanitizer)
//   nan    a float frame with NaN and infinite samples (F5-4): the ring
//          holds zeros in their place. r24 keeps them, for the reader and
//          for the waveform that grows from playback.
//   stale  a ring whose last frame ended at 1e15 s, read at time 0 (F5-9):
//          the read falls back to the latest window. r24 casts the distance
//          in bytes to a size_t it does not fit (UBSAN=1 stops there; on a
//          32-bit size_t three hours at 48 kHz stereo are enough).
// tap_tsan_test.c builds this file with ThreadSanitizer and runs rearm and
// race (F5-8): r24 reads a slot's name in find_slot with no lock while
// set_active writes it.
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "audio/mak_tap.c"

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

// ── a fake mp_aframe: packed float, one plane ──────────────────────────

struct mp_aframe {
    int channels, rate, size;
    double pts;
    uint8_t *planes[1];
};

int mp_aframe_get_format(struct mp_aframe *f) { (void)f; return AF_FORMAT_FLOAT; }
int mp_aframe_get_channels(struct mp_aframe *f) { return f->channels; }
int mp_aframe_get_rate(struct mp_aframe *f) { return f->rate; }
int mp_aframe_get_size(struct mp_aframe *f) { return f->size; }
double mp_aframe_get_pts(struct mp_aframe *f) { return f->pts; }
uint8_t **mp_aframe_get_data_ro(struct mp_aframe *f) { return f->planes; }
bool af_fmt_is_pcm(int format) { return format == AF_FORMAT_FLOAT; }
bool af_fmt_is_planar(int format) { (void)format; return false; }
int af_fmt_from_planar(int format) { return format; }

// The waveform fold of bulk_analysis, which this test does not feed.
bool mak_waveform_wants_frames(void) { return false; }
int mak_waveform_current_gen(void) { return 0; }
void mak_waveform_fold_samples(const float *mono, int n, double pts_secs,
                               int rate, int gen)
{
    (void)mono; (void)n; (void)pts_secs; (void)rate; (void)gen;
}

static struct mp_aframe *frame(int rate, int channels, int size, double pts)
{
    struct mp_aframe *f = calloc(1, sizeof(*f));
    f->rate = rate;
    f->channels = channels;
    f->size = size;
    f->pts = pts;
    f->planes[0] = calloc((size_t)size * channels, sizeof(float));
    return f;
}

static void drop(struct mp_aframe *f)
{
    free(f->planes[0]);
    free(f);
}

static void write_label(const char *label, int rate, int channels, double pts)
{
    struct mp_aframe *f = frame(rate, channels, 1024, pts);
    mak_tap_write(label, true, f);
    drop(f);
}

static void write_one(int rate, int channels, double pts)
{
    write_label("t", rate, channels, pts);
}

static double covered_secs(const struct tap_ring *r)
{
    if (r->sample_rate <= 0 || r->channels <= 0) return 0;
    return (double)r->capacity /
           ((double)r->sample_rate * r->channels * sizeof(float));
}

// ── race ────────────────────────────────────────────────────────────────

static atomic_bool stop;

static void *writer(void *arg)
{
    (void)arg;
    static const int formats[][2] = {{8000, 1}, {48000, 2}, {192000, 8}};
    double pts = 0;
    for (int i = 0; !atomic_load(&stop); i++) {
        const int *fm = formats[i % 3];   // the ring grows, the toggler frees it
        write_one(fm[0], fm[1], pts);
        pts += 1024.0 / fm[0];
    }
    return NULL;
}

static void *reader(void *arg)
{
    (void)arg;
    while (!atomic_load(&stop)) {
        struct mpv_node node;
        if (mak_tap_read_all(&node, NULL, NAN) == 0)
            talloc_free(node.u.list);
    }
    return NULL;
}

static void *writer_a(void *arg)
{
    (void)arg;
    for (double pts = 0; !atomic_load(&stop); pts += 0.02)
        write_label("A", 48000, 2, pts);
    return NULL;
}

static void *toggler(void *arg)
{
    (void)arg;
    for (int i = 0; !atomic_load(&stop); i++) {
        mak_tap_set_active(i % 2 ? "" : "t");
        usleep(100);
    }
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s grow|free|flip|rearm|race|nan|stale\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    struct tap_ring *ring = &g_tap.slots[0].post;

    if (!strcmp(mode, "grow")) {
        mak_tap_set_active("t");
        write_one(8000, 1, 0);
        printf("8 kHz mono: %.2f s in %zu bytes\n", covered_secs(ring), ring->alloc_bytes);
        write_one(48000, 2, 1);
        double s = covered_secs(ring);
        printf("48 kHz stereo: %.2f s in %zu bytes\n", s, ring->alloc_bytes);
        check(s >= TAP_BUFFER_SECONDS - 0.01,
              "the ring covers %.1f s of the format it holds (%.2f s)",
              TAP_BUFFER_SECONDS, s);
        size_t grown = ring->alloc_bytes;
        write_one(8000, 1, 2);
        s = covered_secs(ring);
        check(s >= TAP_BUFFER_SECONDS - 0.01 && ring->alloc_bytes == grown,
              "back at 8 kHz mono it keeps the buffer it grew to (%.2f s in %zu bytes)",
              s, ring->alloc_bytes);
    } else if (!strcmp(mode, "free")) {
        mak_tap_set_active("t");
        write_one(48000, 2, 0);
        check(ring->buf != NULL, "a tapped label has a ring");
        mak_tap_set_active("");
        check(ring->buf == NULL && ring->alloc_bytes == 0,
              "no label tapped: the ring's buffer is freed (%zu bytes left)",
              ring->alloc_bytes);
        mak_tap_set_active("t");
        write_one(8000, 1, 1);
        check(ring->buf != NULL && covered_secs(ring) >= TAP_BUFFER_SECONDS - 0.01,
              "tapped again: a new ring for the format (%.2f s)", covered_secs(ring));
    } else if (!strcmp(mode, "flip")) {
        mak_tap_set_active("t");
        write_one(48000, 2, 0);
        write_one(8000, 1, 0);
        uint8_t *buf = ring->buf;
        int moved = 0;
        for (int i = 0; i < 200; i++) {
            write_one(i % 2 ? 8000 : 48000, i % 2 ? 1 : 2, i * 0.02);
            moved += ring->buf != buf;
        }
        check(moved == 0, "200 frames at two formats keep one buffer "
              "(%d allocated again)", moved);
        check(covered_secs(ring) >= TAP_BUFFER_SECONDS - 0.01,
              "and it covers 3 s of either (%.2f s)", covered_secs(ring));
    } else if (!strcmp(mode, "rearm")) {
        pthread_t w;
        mak_tap_set_active("A");
        pthread_create(&w, NULL, writer_a, NULL);
        int dirty = 0, rounds = 0;
        double t0 = (double)clock() / CLOCKS_PER_SEC;
        while ((double)clock() / CLOCKS_PER_SEC - t0 < 3 && !dirty) {
            mak_tap_set_active("A");
            usleep(200);
            mak_tap_set_active("X");
            usleep(500);
            mp_mutex_lock(&g_tap_write_lock);
            for (int i = 0; i < MAK_TAP_MAX; i++)
                if (!strcmp(g_tap.slots[i].name, "X") &&
                    g_tap.slots[i].post.valid_bytes > 0)
                    dirty++;
            mp_mutex_unlock(&g_tap_write_lock);
            rounds++;
        }
        atomic_store(&stop, true);
        pthread_join(w, NULL);
        check(!dirty, "the slot of X holds no audio of A (%d rounds)", rounds);
        mak_tap_set_active("");
    } else if (!strcmp(mode, "nan")) {
        mak_tap_set_active("t");
        struct mp_aframe *f = frame(48000, 2, 1024, 0);
        float *v = (float *)f->planes[0];
        for (int i = 0; i < 2048; i++)
            v[i] = 0.25f;
        for (int i = 100; i < 200; i++)
            v[i] = i % 3 == 0 ? NAN : i % 3 == 1 ? INFINITY : -INFINITY;
        mak_tap_write("t", true, f);
        drop(f);
        const float *r = (const float *)ring->buf;
        int bad = 0, zero = 0, kept = 0;
        for (size_t i = 0; r && i < ring->valid_bytes / sizeof(float); i++) {
            bad += !isfinite(r[i]);
            zero += r[i] == 0.0f;
            kept += r[i] == 0.25f;
        }
        check(ring->valid_bytes == 2048 * sizeof(float), "the frame is in the ring");
        check(bad == 0, "no sample of the ring is NaN or infinite (%d are)", bad);
        check(zero == 100 && kept == 1948, "they are silence, the others as "
              "written (%d zeros, %d kept)", zero, kept);
        mak_tap_set_active("");
    } else if (!strcmp(mode, "stale")) {
        mak_tap_set_active("t");
        write_one(48000, 2, 1e15);
        struct mpv_node node;
        int r = mak_tap_read_all(&node, NULL, 0.0);
        size_t bytes = 0;
        if (r == 0) {
            struct mpv_node_list *slot = node.u.list->num > 0
                ? node.u.list->values[0].u.list : NULL;
            for (int i = 0; slot && i < slot->num; i++) {
                if (strcmp(slot->keys[i], "post"))
                    continue;
                struct mpv_node_list *side = slot->values[i].u.list;
                for (int k = 0; k < side->num; k++)
                    if (!strcmp(side->keys[k], "samples"))
                        bytes = side->values[k].u.ba->size;
            }
            talloc_free(node.u.list);
        }
        check(bytes == 1024 * 2 * sizeof(float),
              "a read far behind the ring returns its latest window (%zu bytes)",
              bytes);
        mak_tap_set_active("");
    } else if (!strcmp(mode, "race")) {
        mak_tap_set_active("t");
        pthread_t w, r[3], t;
        pthread_create(&w, NULL, writer, NULL);
        for (int i = 0; i < 3; i++) pthread_create(&r[i], NULL, reader, NULL);
        pthread_create(&t, NULL, toggler, NULL);
        sleep(4);
        atomic_store(&stop, true);
        pthread_join(w, NULL);
        for (int i = 0; i < 3; i++) pthread_join(r[i], NULL);
        pthread_join(t, NULL);
        check(1, "4 s of writes, reads and toggles with no fault");
        mak_tap_set_active("");
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    printf(failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", failures);
    return failures ? 1 : 0;
}
