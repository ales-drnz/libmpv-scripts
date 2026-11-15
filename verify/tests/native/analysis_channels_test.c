// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_channels_test <mode> <fixtures> <tmpdir>: frames the bulk
// analysis converts with more than 8 planes or a layout that changes (F63).
//   opus16      x16.opus (16 channels), waveform and loudness on: both
//               ready, every bin filled. r17 reads data[8..15] past the
//               AVFrame array in the worker and the loudness (SEGV).
//   opus16wave  the same, waveform only.
//   opus16loud  the same, loudness only.
//   opus16http  x16.opus over HTTP (served by run.sh), waveform and
//               loudness on: the cache-fed pass converts the frames.
//   opus16httpwave  the same, waveform only (mak_feed.c's own converter).
//   sm          sm.mp3 (stereo then mono), waveform on: ready, the bins of
//               the mono half filled and not silent. r17 keeps the stereo
//               converter for the mono frames (data[1] NULL, SEGV).
//   smloud      sm.mp3 with the loudness on too: both final, no crash.
//   ms          ms.mp3 (mono then stereo), waveform on: ready, the stereo
//               half not silent (the converter and its buffer grow).
#include "analysis_test.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s opus16|opus16wave|opus16loud|opus16http|opus16httpwave|sm|smloud|ms <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    int sm = !strncmp(mode, "sm", 2) || !strcmp(mode, "ms");
    int wave = strcmp(mode, "opus16loud") != 0;
    int http = !strncmp(mode, "opus16http", 10);
    int loud = !strcmp(mode, "opus16") || !strcmp(mode, "opus16loud") ||
               !strcmp(mode, "smloud") || !strcmp(mode, "opus16http");
    char file[1024];
    if (http)
        snprintf(file, sizeof file, "http://127.0.0.1:%s/x16.opus",
                 getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0");
    else
        snprintf(file, sizeof file, "%s/%s", argv[2],
                 !strcmp(mode, "ms") ? "ms.mp3" : sm ? "sm.mp3" : "x16.opus");

    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", wave);
    an_flag(h, "loudness-scan-enabled", loud);
    mpv_set_property_string(h, "pause", "yes");
    mt_cmd(h, "loadfile", file, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 10), "file loaded");

    struct an_wave w;
    struct an_loud l;
    // A bound, not a measure: the wait ends when both are final. Under
    // valgrind on a CI runner the 16 channels of opus16 take about 30 s with
    // the loudness on (29.2 s on one run, 1736 of 2000 bins at 30 s on a
    // slower one), so 30 s was the edge; 90 s stays inside the 120 s each
    // mode has without valgrind.
    an_wait_final(h, wave, loud, 90, &w, &l);
    if (wave) {
        mt_check(!strcmp(w.state, "ready"), "waveform ready (%s)", w.state);
        mt_check(w.bins > 0 && w.filled == w.bins, "every bin filled (%d of %d)",
                 w.filled, w.bins);
        if (sm && w.max && w.bins > 0 && w.total_bins > 0 &&
            w.duration_us > 11000000) {
            // The second file starts at 10 s. The axis is a duration mp3
            // estimates from the bitrate (15 s for sm, 30 s for ms, whose
            // empty tail the reader trims), so check from 10.5 s, past the
            // gap where the files join, to 95% of the bins emitted.
            int quiet = 0;
            int first = (int)(10.5e6 * w.total_bins / w.duration_us);
            for (int i = first; i < w.bins * 95 / 100; i++) {
                if (!(w.max[i] > 0.01f) && quiet++ < 8)
                    printf("     quiet bin %d: min %f max %f\n", i, w.min[i], w.max[i]);
            }
            printf("     duration_us %lld\n", (long long)w.duration_us);
            mt_check(quiet == 0, "the second half is not silent (%d quiet bins)", quiet);
        }
    }
    if (loud) {
        if (sm) {
            mt_check(an_final_loud(l.state), "loudness final (%s)", l.state);
        } else {
            mt_check(!strcmp(l.state, "ready"), "loudness ready (%s)", l.state);
            mt_check(l.integrated > -40 && l.integrated < 0,
                     "integrated loudness plausible (%.2f)", l.integrated);
        }
    }
    an_wave_free(&w);
    mpv_terminate_destroy(h);
    return mt_result();
}
