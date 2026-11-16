// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_close_test <mode> <fixtures> <tmpdir>: the analysis stops when
// nobody wants it any more (F70, F72). b.flac (3.75 MB) comes from
// slow_http.py at 600000 bytes a second (run.sh), about 6 s for the file.
//   stop       waveform and loudness on, cache=no (the re-open, one worker
//              downloading the file again). Once the pass has published
//              some bins, stop: within 1 s no connection to the server is
//              left, both results are failed, and 7 s later they still are
//              (r17 keeps downloading and turns ready on a stopped player).
//   feedstop   the same with the cache on (the cache feed): failed as well,
//              as already on r17.
//   readystop  a local file: once both are ready, stop leaves them ready.
//   loudoff    loudness alone, cache=no. Once the scan has progress, the
//              loudness is turned off (F72): within 1 s no analysis
//              connection is left, only the player's (r17 keeps downloading
//              for a result nobody reads).
//   loudkeep   waveform and loudness on, cache=no: turning the loudness off
//              leaves the waveform's pass running to ready.
//   probe      waveform on, cache=no (F71): once the re-open has published
//              some bins, which the coordinator does after it closed its
//              probe, the player and the worker hold a connection each, the
//              probe none (r17 keeps the probe open: 3).
// The 1 s of the stop modes is a ceiling (mpv_test.h, rule 1): the wait
// ends once the connections are gone and the results final.
#include "analysis_test.h"

// The pass is under way: it published some bins of the waveform (wave) or
// some progress of the loudness.
static int under_way(mpv_handle *h, int wave)
{
    struct an_wave w;
    struct an_loud l;
    an_wave_read(h, &w);
    an_loud_read(h, &l);
    int on = wave ? w.coverage > 0 : l.progress > 0;
    an_wave_free(&w);
    return on;
}

// Both results final, as after a stop.
static int both_final(mpv_handle *h)
{
    struct an_wave w;
    struct an_loud l;
    an_wave_read(h, &w);
    an_loud_read(h, &l);
    int fin = an_final_wave(w.state) && an_final_loud(l.state);
    an_wave_free(&w);
    return fin;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s stop|feedstop|readystop|loudoff|loudkeep|probe <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    int port = getenv("HTTP_PORT") ? atoi(getenv("HTTP_PORT")) : 0;
    int local = !strcmp(mode, "readystop");
    int loudoff = !strcmp(mode, "loudoff");
    int loudkeep = !strcmp(mode, "loudkeep");
    char file[1024];
    if (local)
        snprintf(file, sizeof file, "%s/b.flac", argv[2]);
    else
        snprintf(file, sizeof file, "http://127.0.0.1:%d/b.flac", port);
    const char *opts = !strcmp(mode, "feedstop") || local ? "" : "cache=no";

    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", !loudoff);
    an_flag(h, "loudness-scan-enabled", strcmp(mode, "probe") != 0);
    const char *l[] = {"loadfile", file, "replace", "-1", opts, NULL};
    mpv_command(h, l);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");

    struct an_wave w;
    struct an_loud lo;
    if (local) {
        an_wait_final(h, 1, 1, 30, &w, &lo);
        an_wave_free(&w);
    } else {
        // The file takes about 6 s to download: this is well before its end.
        mt_wait_until(5, under_way(h, !loudoff), mpv_wait_event(h, 0.02));
        an_wave_read(h, &w);
        an_loud_read(h, &lo);
        printf("     before: waveform %s, loudness %s, %d connections\n",
               w.state, lo.state, an_tcp_conns(port));
        if (!strcmp(mode, "probe")) {
            mt_check(!strcmp(w.state, "decoding"), "waveform still decoding (%s)", w.state);
            int c = an_tcp_conns(port);
            mt_check(c == 2, "2 connections, the player's and the worker's (%d)", c);
            an_wave_free(&w);
            mpv_terminate_destroy(h);
            return mt_result();
        }
        mt_check(!strcmp(lo.state, "scanning"), "loudness still scanning (%s)", lo.state);
        an_wave_free(&w);
    }
    double t0 = mt_now();
    if (loudoff || loudkeep)
        an_flag(h, "loudness-scan-enabled", 0);
    else
        mt_cmd(h, "stop", NULL, NULL, NULL);
    // readystop and loudkeep: a window in which the ready results and the
    // waveform's connection stay. The others: a wait until the connections
    // are gone and the results final.
    int left = -1, window = local || loudkeep;
    double gone = -1, max = window ? 1.0 : mt_ceil(1.0);
    while (mt_now() - t0 < max) {
        mpv_wait_event(h, 0.02);
        left = an_tcp_conns(port);
        if (gone < 0 && left <= (loudoff ? 1 : 0))
            gone = mt_now() - t0;
        if (!window && gone >= 0 && (loudoff || both_final(h)))
            break;
    }
    if (!local) {
        printf("     connections %.2f s after: %d (analysis gone after %.3f s)\n",
               mt_now() - t0, left, gone);
        if (!loudkeep)
            mt_check(left <= (loudoff ? 1 : 0), "no analysis connection left "
                     "within %.0f s (%d)", max, left);
    }
    if (loudkeep) {
        mt_check(left >= 2, "the waveform's pass keeps its connection (%d)", left);
        an_wait_final(h, 1, 0, 20, &w, &lo);
        mt_check(!strcmp(w.state, "ready"), "waveform ready (%s)", w.state);
        an_wave_free(&w);
        mpv_terminate_destroy(h);
        return mt_result();
    }
    if (loudoff) {
        an_pump(h, 0.2, MPV_EVENT_NONE);
        mt_check(an_tcp_conns(port) <= 1, "still none later (%d)", an_tcp_conns(port));
        mpv_terminate_destroy(h);
        return mt_result();
    }
    an_wave_read(h, &w);
    an_loud_read(h, &lo);
    const char *want = local ? "ready" : "failed";
    mt_check(!strcmp(w.state, want), "waveform %s after the stop (%s)", want, w.state);
    mt_check(!strcmp(lo.state, want), "loudness %s after the stop (%s)", want, lo.state);
    an_wave_free(&w);
    if (!local) {
        an_pump(h, 7.0, MPV_EVENT_NONE);
        an_wave_read(h, &w);
        an_loud_read(h, &lo);
        printf("     7 s later: waveform %s, loudness %s, %d connections\n",
               w.state, lo.state, an_tcp_conns(port));
        mt_check(!strcmp(w.state, "failed") && !strcmp(lo.state, "failed"),
                 "still failed 7 s later (%s, %s)", w.state, lo.state);
        an_wave_free(&w);
    }
    mpv_terminate_destroy(h);
    return mt_result();
}
