// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_declared_test <mode> <fixtures> <tmpdir>: 3 s of audio in a file
// that declares far more, a download cut short or a crafted header, where
// the bulk scan gives three of its four workers a part of the file that
// does not exist. analysis_hostile_test has the lengths past the bounds
// (46 days with the loudness alone, a rate of 2 GHz); these are the lengths
// under them, with the waveform on, and the same files read over HTTP.
// The audio is a 1 kHz sine at -20 dBFS, 48 kHz stereo, -20.0 LUFS
// (hostile/, see fixtures.sh). The test replaces posix_memalign() for the
// process to record the largest allocation, as analysis_hostile_test does.
// For every mode: within 30 s the waveform is ready and the loudness final;
// the waveform holds the sine at 0.1 in its first 3 s, nothing after, and
// its bins end with the audio; a ready loudness is the sine's, -20.0 LUFS
// within 0.1 LU, never the figure of a file padded with silence; no
// allocation is larger than 64 MB (the scan's own bound at 48 hours is
// 55 MB).
//   short      short.flac, which declares 600 s.
//   long       long.flac, 30 hours, under the 48 hours the loudness
//              measures.
//   longwav    long.wav, an RF64 of 40 hours.
//   huge       huge.flac, 2^36 - 1 samples, 16 days: under the bound of the
//              waveform, past the loudness's, which must not be ready.
//   shorthttp, longhttp, hugehttp  the FLAC files over HTTP (served by
//              run.sh): the pass that decodes mpv's cache.
#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include "analysis_test.h"

extern int __interceptor_posix_memalign(void **p, size_t align, size_t size);

static atomic_size_t largest;

int posix_memalign(void **p, size_t align, size_t size)
{
    size_t old = atomic_load(&largest);
    while (size > old && !atomic_compare_exchange_weak(&largest, &old, size))
        ;
    return __interceptor_posix_memalign(p, align, size);
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s short|long|longwav|huge|shorthttp|longhttp|hugehttp <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    char mode[32];
    snprintf(mode, sizeof mode, "%s", argv[1]);
    size_t len = strlen(mode);
    int http = len > 4 && !strcmp(mode + len - 4, "http");
    if (http)
        mode[len - 4] = 0;
    const char *name = !strcmp(mode, "short") ? "short.flac"
                     : !strcmp(mode, "long") ? "long.flac"
                     : !strcmp(mode, "longwav") && !http ? "long.wav"
                     : !strcmp(mode, "huge") ? "huge.flac" : NULL;
    if (!name) {
        fprintf(stderr, "unknown mode %s\n", argv[1]);
        return 2;
    }
    int huge = !strcmp(mode, "huge");
    char file[1024];
    if (http)
        snprintf(file, sizeof file, "http://127.0.0.1:%s/%s",
                 getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0", name);
    else
        snprintf(file, sizeof file, "%s/%s", argv[2], name);

    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", 1);
    an_flag(h, "loudness-scan-enabled", 1);
    mpv_set_property_string(h, "pause", "yes");
    mt_cmd(h, "loadfile", file, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");
    double dur = 0;
    mt_double(h, "duration", &dur);
    printf("     mpv's duration: %.1f s\n", dur);

    struct an_wave w;
    struct an_loud l;
    an_wait_final(h, 1, 1, 30, &w, &l);
    printf("     waveform %s: %d bins of %lld, %d filled, axis %.1f s; largest "
           "allocation %zu bytes\n", w.state, w.bins, (long long)w.total_bins,
           w.filled, w.duration_us / 1e6, atomic_load(&largest));
    mt_check(!strcmp(w.state, "ready") && an_final_loud(l.state),
             "the waveform is ready and the loudness final within 30 s (%s, %s)",
             w.state, l.state);
    mt_check(atomic_load(&largest) <= 64u << 20,
             "no allocation over 64 MB (%zu bytes)", atomic_load(&largest));
    if (!strcmp(w.state, "ready")) {
        // The time a bin starts at, from the axis and the bins it was laid
        // on.
        int loud_bins = 0, late = 0, off = 0;
        for (int i = 0; i < w.bins && w.max && w.total_bins > 0; i++) {
            double t0 = (double)i * w.duration_us / 1e6 / w.total_bins;
            double t1 = (double)(i + 1) * w.duration_us / 1e6 / w.total_bins;
            int sound = w.max[i] != 0 || w.min[i] != 0;
            if (t0 >= 3.05) {
                if (sound && late++ < 5)
                    printf("     bin %d at %.1f s: min %f max %f\n", i, t0,
                           w.min[i], w.max[i]);
            } else if (sound) {
                loud_bins++;
                if (t1 <= 3.0 && (fabsf(w.max[i] - 0.1f) > 0.005f ||
                                  fabsf(w.min[i] + 0.1f) > 0.005f))
                    off++;
            }
        }
        mt_check(w.max && loud_bins > 0 && off == 0,
                 "the bins of the first 3 s hold the sine at 0.1 (%d bins, %d "
                 "off)", loud_bins, off);
        mt_check(late == 0, "no bin past the audio holds anything (%d do)", late);
        // As for a duration estimated too long (analysis_tail_test): the
        // bins end with the audio, at most one bin past it.
        double bin_secs = w.total_bins > 0 ? w.duration_us / 1e6 / w.total_bins : 0;
        mt_check(w.filled == w.bins && (w.bins - 1) * bin_secs <= 3.0,
                 "the bins end with the audio (%d bins of %.2f s, %d filled)",
                 w.bins, bin_secs, w.filled);
    }
    if (!strcmp(l.state, "ready"))
        mt_check(fabs(l.integrated - -20.0) <= 0.1,
                 "a ready loudness is the sine's, -20.0 LUFS (%.3f)", l.integrated);
    if (huge)
        mt_check(strcmp(l.state, "ready") != 0,
                 "no loudness for a file that declares 16 days (%s)", l.state);
    an_wave_free(&w);
    mpv_terminate_destroy(h);
    return mt_result();
}
