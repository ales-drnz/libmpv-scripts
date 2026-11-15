// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_feed_test <mode> <fixtures> <tmpdir>: the waveform of an HTTP
// file decoded from mpv's cache (the cache feed) reads as a decode while the
// file downloads. b.flac (30 s, 3.7 MB) comes from slow_http.py at 600000
// bytes a second (run.sh), about 6 s for the file, with the cache on.
//   grow   waveform on: every snapshot before the end reads "decoding",
//          with the bins filled so far as its coverage, never shrinking,
//          and several of them partial; then "ready" with every bin filled,
//          and no GET after the player's own, so the pass was the feed's
//          (r18 reads the partials as "progressive", like an envelope that
//          grows from playback and never turns ready).
//   ahead  cache-secs=5, paused: the read-ahead stops 5 s into the file, the
//          feed is cut there and the re-open (more GETs from the start)
//          reads the file; ready with every bin filled. Without the cut the
//          pass would wait for a playback that never comes.
//   hyst   the same with demuxer-hysteresis-bytes=256KiB, which mpv 0.42
//          added: the read-ahead with a byte hysteresis still cuts the feed.
#include "analysis_test.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s grow|ahead|hyst <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    int ahead = !strcmp(mode, "ahead") || !strcmp(mode, "hyst");
    if (!ahead && strcmp(mode, "grow")) {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    char url[256];
    snprintf(url, sizeof url, "http://127.0.0.1:%s/b.flac",
             getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0");
    mpv_handle *h = an_create();
    if (ahead)
        mpv_set_option_string(h, "cache-secs", "5");
    if (!strcmp(mode, "hyst"))
        mpv_set_option_string(h, "demuxer-hysteresis-bytes", "256KiB");
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", 1);
    mpv_set_property_string(h, "pause", "yes");
    mt_cmd(h, "loadfile", url, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");

    struct an_wave w = {0};
    int partials = 0, other = 0, shrank = 0, uncounted = 0;
    int64_t last = 0;
    char other_state[32] = "";
    double t0 = mt_now();
    while (mt_now() - t0 < 30) {
        mpv_wait_event(h, 0.05);
        an_wave_free(&w);
        an_wave_read(h, &w);
        if (an_final_wave(w.state))
            break;
        if (strcmp(w.state, "decoding")) {
            if (!other++)
                snprintf(other_state, sizeof other_state, "%s", w.state);
            continue;
        }
        if (!w.bins)
            continue;   // the pass has not laid out its axis yet
        partials += w.coverage > 0 && w.coverage < w.total_bins;
        shrank += w.coverage < last;
        uncounted += w.coverage != w.filled;
        last = w.coverage;
    }
    printf("     after %.2f s: %s, %d of %d bins filled; %d partial snapshots, "
           "%d in another state (%s)\n", mt_now() - t0, w.state, w.filled,
           w.bins, partials, other, other ? other_state : "none");
    if (!ahead) {
        mt_check(!other, "the pass reads decoding until it ends (%d read %s)",
                 other, other ? other_state : "otherwise");
        mt_check(partials >= 3, "partial envelopes while the file downloads (%d)",
                 partials);
        mt_check(!shrank, "the coverage never shrinks (%d)", shrank);
        mt_check(!uncounted, "the coverage is the bins filled (%d differ)", uncounted);
    }
    mt_check(!strcmp(w.state, "ready") && w.bins > 0 && w.filled == w.bins,
             "ready with every bin filled (%s, %d of %d)", w.state, w.filled,
             w.bins);

    // The server's log: one line per GET. The flac demuxer reads the file
    // once from the start; a re-open would read it from the start again.
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
    if (ahead)  // the re-open probes the file, then decodes it
        mt_check(from0 >= 2, "the re-open took over (%d GETs from the start)", from0);
    else
        mt_check(from0 == 1, "no second download (%d GETs from the start)", from0);
    an_wave_free(&w);
    mpv_terminate_destroy(h);
    return mt_result();
}
