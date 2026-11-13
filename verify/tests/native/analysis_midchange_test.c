// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_midchange_test <mode> <fixtures> <tmpdir>: a file whose channel
// count changes in the middle, scanned by more than one worker. sm.mp3 of
// analysis_channels_test is decoded by one worker, MP3 seeks by an estimate;
// chg.flac (hostile/, see fixtures.sh) is a FLAC stream FFmpeg seeks by
// sample, so the bulk scan gives it four: the first decodes stereo frames,
// the second meets the change at 10.24 s of 30.72 s, the third and the
// fourth open a decoder told stereo and get mono frames from their first.
// The stereo part is a sine at 0.25, the mono part one at 0.5, so a bin
// tells which part it was folded from.
//   flac      waveform and loudness on: the waveform is ready with every
//             bin filled, 0.25 up to the change and 0.5 after it, and the
//             loudness is unavailable, not the measure of a part.
//   flacwave  the same, waveform only.
//   flacloud  loudness only: unavailable.
//   http      chg.flac over HTTP (served by run.sh), both on: the pass that
//             decodes mpv's cache gives the same, and reads the file once.
#include <math.h>
#include "analysis_test.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s flac|flacwave|flacloud|http <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    int http = !strcmp(mode, "http");
    int wave = strcmp(mode, "flacloud") != 0;
    int loud = strcmp(mode, "flacwave") != 0;
    if (!http && strncmp(mode, "flac", 4)) {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    char file[1024];
    if (http)
        snprintf(file, sizeof file, "http://127.0.0.1:%s/chg.flac",
                 getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0");
    else
        snprintf(file, sizeof file, "%s/chg.flac", argv[2]);

    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", wave);
    an_flag(h, "loudness-scan-enabled", loud);
    mpv_set_property_string(h, "pause", "yes");
    mt_cmd(h, "loadfile", file, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");

    struct an_wave w;
    struct an_loud l;
    an_wait_final(h, wave, loud, 30, &w, &l);
    if (wave) {
        mt_check(!strcmp(w.state, "ready"), "waveform ready (%s)", w.state);
        mt_check(w.duration_us > 30700000 && w.duration_us < 30740000,
                 "the axis is both parts, 30.72 s (%.3f s)", w.duration_us / 1e6);
        mt_check(w.bins > 0 && w.filled == w.bins, "every bin filled (%d of %d)",
                 w.filled, w.bins);
        // The change is at a third of the axis. The bin that holds it and
        // its neighbours may hold both parts.
        int change = w.bins / 3, wrong = 0;
        for (int i = 0; i < w.bins && w.max; i++) {
            if (i >= change - 1 && i <= change + 1)
                continue;
            float want = i < change ? 0.25f : 0.5f;
            if ((fabsf(w.max[i] - want) > 0.01f || fabsf(w.min[i] + want) > 0.01f) &&
                wrong++ < 8)
                printf("     bin %d: min %f max %f, want %.2f\n", i, w.min[i],
                       w.max[i], want);
        }
        mt_check(w.max && wrong == 0, "the bins are 0.25 up to the change and "
                 "0.5 after it (%d are not)", wrong);
    }
    if (loud)
        mt_check(!strcmp(l.state, "unavailable"),
                 "loudness unavailable, not the measure of a part (%s, %.2f LUFS)",
                 l.state, l.integrated);
    if (http) {
        char path[1100], line[256];
        snprintf(path, sizeof path, "%s.http.log", argv[3]);
        FILE *f = fopen(path, "r");
        int from0 = 0;
        while (f && fgets(line, sizeof line, f)) {
            printf("     server: %s", line);
            from0 += strstr(line, "range=0-") != NULL;
        }
        if (f)
            fclose(f);
        mt_check(from0 == 1, "no second download (%d GETs from the start)", from0);
    }
    an_wave_free(&w);
    mpv_terminate_destroy(h);
    return mt_result();
}
