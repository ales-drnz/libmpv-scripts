// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_hostile_test <mode> <fixtures> <tmpdir>: files and failures the
// bulk analysis must not take for a clean scan. The test replaces
// posix_memalign() for the process (FFmpeg's av_malloc, ASan's underneath)
// to fail one allocation or to record the largest one, and writes its own
// WAV files into <tmpdir>.
//   loudpart  long.flac (15 min, 4 workers), waveform and loudness on, and
//             the allocation of one worker's sub-block sums (18000 bytes)
//             fails: that worker measures nothing. The loudness must be
//             failed, the waveform ready. r24 merges the other three slices
//             and publishes the loudness of three quarters of the file as
//             ready.
//   longloud  an RF64 file of 2 s that declares 4,000,000 s (46 days),
//             loudness on: no allocation of the scan may grow with the
//             declared length (16 MB at most), and the loudness is not
//             ready. r24 allocates 80 MB per worker and array (640 MB), and
//             1.3 GB more at the merge of a file one worker decodes.
//   rate      an RF64 file at 2,000,000,000 Hz that declares 10,000 s: both
//             results failed. r24 multiplies the two into a signed overflow
//             (UBSAN=1 stops there), then fails on its seeks.
//   nan       20 s of float WAV, loud for 5 s then 20 dB lower, with 1000
//             NaN samples at 1 s and 1000 infinite ones at 2 s, against the
//             same file without them: every bin and every loudness figure
//             finite, the integrated loudness within 0.5 LU of the clean
//             file's. r24 leaves NaN in the bins, an infinite peak, and the
//             K filter of the first worker on NaN to the end of its slice,
//             which drops its blocks from the gate: 11 LU lower.
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include "analysis_test.h"

extern int __interceptor_posix_memalign(void **p, size_t align, size_t size);

static atomic_size_t fail_size;      // fail the next allocation of this size
static atomic_int failed_allocs;
static atomic_int watch;             // record the largest allocation
static atomic_size_t largest;

int posix_memalign(void **p, size_t align, size_t size)
{
    size_t want = atomic_load(&fail_size);
    if (want && size == want && atomic_exchange(&fail_size, 0)) {
        atomic_fetch_add(&failed_allocs, 1);
        return ENOMEM;
    }
    if (atomic_load(&watch)) {
        size_t old = atomic_load(&largest);
        while (size > old && !atomic_compare_exchange_weak(&largest, &old, size))
            ;
    }
    return __interceptor_posix_memalign(p, align, size);
}

static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void put16(FILE *f, uint16_t v) { fwrite(&v, 2, 1, f); }
static void put64(FILE *f, uint64_t v) { fwrite(&v, 8, 1, f); }

// An RF64 file of 8-bit mono PCM at [rate] whose ds64 chunk declares
// [declared] bytes of data, with 16000 bytes of a tone after it.
static void write_rf64(const char *path, uint32_t rate, uint64_t declared)
{
    FILE *f = fopen(path, "wb");
    fwrite("RF64", 4, 1, f); put32(f, 0xFFFFFFFFu); fwrite("WAVE", 4, 1, f);
    fwrite("ds64", 4, 1, f); put32(f, 28);
    put64(f, declared + 72); put64(f, declared); put64(f, declared); put32(f, 0);
    fwrite("fmt ", 4, 1, f); put32(f, 16);
    put16(f, 1); put16(f, 1); put32(f, rate); put32(f, rate); put16(f, 1); put16(f, 8);
    fwrite("data", 4, 1, f); put32(f, 0xFFFFFFFFu);
    for (int i = 0; i < 16000; i++)
        fputc(128 + (int)(60 * sin(i * 0.3)), f);
    fclose(f);
}

// 20 s of 48 kHz stereo float: a 440 Hz sine at 0.5 for 5 s, then at 0.05.
// With [bad], 1000 NaN frames at 1 s and 1000 infinite ones at 2 s.
static void write_float_wav(const char *path, int bad)
{
    const int rate = 48000, n = 20 * rate;
    FILE *f = fopen(path, "wb");
    fwrite("RIFF", 4, 1, f); put32(f, 36 + n * 8); fwrite("WAVE", 4, 1, f);
    fwrite("fmt ", 4, 1, f); put32(f, 16);
    put16(f, 3); put16(f, 2); put32(f, rate); put32(f, rate * 8); put16(f, 8); put16(f, 32);
    fwrite("data", 4, 1, f); put32(f, n * 8);
    for (int i = 0; i < n; i++) {
        float s = (i < 5 * rate ? 0.5f : 0.05f) * sinf(i * 2 * M_PI * 440 / rate);
        if (bad && i >= rate && i < rate + 1000)
            s = NAN;
        if (bad && i >= 2 * rate && i < 2 * rate + 1000)
            s = i & 1 ? INFINITY : -INFINITY;
        fwrite(&s, 4, 1, f);
        fwrite(&s, 4, 1, f);
    }
    fclose(f);
}

static mpv_handle *start(const char *file, int wave, int loud)
{
    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", wave);
    an_flag(h, "loudness-scan-enabled", loud);
    mpv_set_property_string(h, "pause", "yes");
    mt_cmd(h, "loadfile", file, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");
    return h;
}

// The doubles of loudness-scan-data, and whether all are finite.
struct loud_all {
    double integrated, lra, sample_peak, true_peak;
};

static int loud_all(mpv_handle *h, struct loud_all *l)
{
    mpv_node n;
    memset(l, 0, sizeof(*l));
    if (mpv_get_property(h, "loudness-scan-data", MPV_FORMAT_NODE, &n) < 0)
        return 0;
    const char *keys[] = {"integrated_lufs", "lra_lu", "sample_peak", "true_peak"};
    double *out[] = {&l->integrated, &l->lra, &l->sample_peak, &l->true_peak};
    int finite = 1;
    for (int i = 0; i < 4; i++) {
        mpv_node *f = an_field(&n, keys[i]);
        *out[i] = f && f->format == MPV_FORMAT_DOUBLE ? f->u.double_ : NAN;
        finite &= isfinite(*out[i]) != 0;
    }
    mpv_free_node_contents(&n);
    return finite;
}

// Bins of waveform-data whose min, max or rms is not finite; -1 on no data.
static int bad_bins(mpv_handle *h)
{
    mpv_node n;
    if (mpv_get_property(h, "waveform-data", MPV_FORMAT_NODE, &n) < 0)
        return -1;
    const char *keys[] = {"min", "max", "rms"};
    int bad = 0, seen = 0;
    for (int k = 0; k < 3; k++) {
        mpv_node *f = an_field(&n, keys[k]);
        if (!f || f->format != MPV_FORMAT_BYTE_ARRAY)
            continue;
        const float *v = f->u.ba->data;
        size_t bins = f->u.ba->size / 4;
        seen += bins > 0;
        for (size_t i = 0; i < bins; i++)
            bad += !isfinite(v[i]);
    }
    mpv_free_node_contents(&n);
    return seen == 3 ? bad : -1;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s loudpart|longloud|rate|nan <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    char file[1024];
    struct an_wave w;
    struct an_loud lo;

    if (!strcmp(mode, "loudpart")) {
        snprintf(file, sizeof file, "%s/long.flac", argv[2]);
        // 900 s at 44.1 kHz in 4 slices: 2250 sub-blocks of 100 ms each,
        // 8 bytes per sum.
        atomic_store(&fail_size, 2250 * 8);
        mpv_handle *h = start(file, 1, 1);
        an_wait_final(h, 1, 1, 60, &w, &lo);
        mt_check(atomic_load(&failed_allocs) == 1,
                 "one worker's accumulator failed to allocate (%d)",
                 atomic_load(&failed_allocs));
        mt_check(!strcmp(w.state, "ready"), "waveform ready (%s)", w.state);
        mt_check(!strcmp(lo.state, "failed"),
                 "loudness failed, not the measure of the other workers (%s, %.2f LUFS)",
                 lo.state, lo.integrated);
        an_wave_free(&w);
        mpv_terminate_destroy(h);
    } else if (!strcmp(mode, "longloud") || !strcmp(mode, "rate")) {
        int rate = !strcmp(mode, "rate");
        snprintf(file, sizeof file, "%s/declared.wav", argv[3]);
        if (rate)
            write_rf64(file, 2000000000u, 2000000000ull * 10000);
        else
            write_rf64(file, 8000, 8000ull * 4000000);
        atomic_store(&watch, 1);
        mpv_handle *h = start(file, rate, 1);
        an_wait_final(h, rate, 1, 30, &w, &lo);
        atomic_store(&watch, 0);
        printf("     largest allocation %zu bytes\n", atomic_load(&largest));
        if (rate) {
            mt_check(!strcmp(w.state, "failed") && !strcmp(lo.state, "failed"),
                     "both results failed (%s, %s)", w.state, lo.state);
        } else {
            mt_check(atomic_load(&largest) <= 16u << 20,
                     "no allocation follows the declared length (%zu bytes)",
                     atomic_load(&largest));
            mt_check(an_final_loud(lo.state) && strcmp(lo.state, "ready"),
                     "loudness final and not ready (%s)", lo.state);
        }
        an_wave_free(&w);
        mpv_terminate_destroy(h);
    } else if (!strcmp(mode, "nan")) {
        struct loud_all clean, bad;
        for (int pass = 0; pass < 2; pass++) {
            snprintf(file, sizeof file, "%s/%s.wav", argv[3], pass ? "bad" : "clean");
            write_float_wav(file, pass);
            mpv_handle *h = start(file, 1, 1);
            an_wait_final(h, 1, 1, 30, &w, &lo);
            mt_check(!strcmp(w.state, "ready") && !strcmp(lo.state, "ready"),
                     "%s: both ready (%s, %s)", pass ? "bad" : "clean", w.state, lo.state);
            int finite = loud_all(h, pass ? &bad : &clean);
            struct loud_all *l = pass ? &bad : &clean;
            printf("     %s: %.2f LUFS, LRA %.2f, sample peak %f, true peak %f\n",
                   pass ? "bad" : "clean", l->integrated, l->lra, l->sample_peak,
                   l->true_peak);
            mt_check(finite, "%s: every loudness figure finite", pass ? "bad" : "clean");
            int nb = bad_bins(h);
            mt_check(nb == 0, "%s: every bin finite (%d not)", pass ? "bad" : "clean", nb);
            an_wave_free(&w);
            mpv_terminate_destroy(h);
        }
        mt_check(fabs(bad.integrated - clean.integrated) < 0.5,
                 "integrated loudness within 0.5 LU of the clean file (%.2f, %.2f)",
                 bad.integrated, clean.integrated);
        mt_check(fabs(bad.sample_peak - clean.sample_peak) < 0.01,
                 "sample peak as the clean file's (%f, %f)", bad.sample_peak,
                 clean.sample_peak);
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    return mt_result();
}
