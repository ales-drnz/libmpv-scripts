// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_hint_test <mode> <fixtures> <tmpdir>: the waveform of an HTTP
// stream that cannot seek and tells no length (a transcode, mpv_audio_kit
// #29), decoded from mpv's cache with the length the per-file option
// waveform-duration-hint gives. hint.opus (Ogg Opus, 30 s of pink noise,
// about 330 KB) comes from slow_http.py at 60000 bytes a second as a
// chunked response, without Content-Length or byte ranges (run.sh): mpv
// knows neither its length nor how to seek it. Waveform and loudness on,
// paused.
//   exact  hint 30 s: "decoding" while the cache fills, then "ready" with
//          every bin filled, the loudness ready, one GET (r19 grows the
//          waveform from playback, "rolling", and never decodes it).
//   short  hint 20 s: the pass ends at 20 s of audio, before the stream
//          has reached the cache: ready on the 20 s axis, every bin filled.
//   long   hint 45 s: the pass ends at the end of the stream: ready on the
//          45 s axis, the bins up to 30 s filled and the rest left out
//          (trimmed as for a duration that overshoots), no hole between.
//   none   no hint: as before, the waveform rolls from playback and the
//          loudness scan is unavailable, after the whole stream is cached.
//   full   hint 30 s, with a cache of 100 KiB: the cache fills before the
//          end of the stream and cuts the pass. No second request (it
//          would start a second transcode): the waveform grows from
//          playback on the 30 s axis, the loudness scan is unavailable.
//   nocache  hint 30 s, cache off: no cache to feed from, the same.
//   range  b.flac (30 s) with byte ranges at 600000 bytes a second and a
//          hint of 10 s: a seekable file does not read the hint, ready on
//          mpv's own 30 s.
#include "analysis_test.h"

// Whether the end of the stream has reached the demuxer cache.
static int eof_cached(mpv_handle *h)
{
    mpv_node n;
    if (mpv_get_property(h, "demuxer-cache-state", MPV_FORMAT_NODE, &n) < 0)
        return 0;
    mpv_node *f = an_field(&n, "eof-cached");
    int eof = f && f->format == MPV_FORMAT_FLAG && f->u.flag;
    mpv_free_node_contents(&n);
    return eof;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s exact|short|long|none|full|nocache|range "
                "<fixtures> <tmpdir>\n",
                argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    int range = !strcmp(mode, "range");
    int grown = !strcmp(mode, "full") || !strcmp(mode, "nocache");
    const char *hint = !strcmp(mode, "exact") || grown ? "30"
                     : !strcmp(mode, "short") ? "20" : !strcmp(mode, "long") ? "45"
                     : range ? "10" : NULL;
    char url[256], opt[64];
    snprintf(url, sizeof url, "http://127.0.0.1:%s/%s",
             getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0",
             range ? "b.flac" : "hint.opus");
    snprintf(opt, sizeof opt, "waveform-duration-hint=%s", hint ? hint : "");
    mpv_handle *h = an_create();
    if (!strcmp(mode, "full"))
        mpv_set_option_string(h, "demuxer-max-bytes", "100KiB");
    if (!strcmp(mode, "nocache"))
        mpv_set_option_string(h, "cache", "no");
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", 1);
    an_flag(h, "loudness-scan-enabled", 1);
    mpv_set_property_string(h, "pause", "yes");
    const char *load[] = {"loadfile", url, "replace", "-1", hint ? opt : NULL, NULL};
    mpv_command(h, load);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");

    struct an_wave w = {0};
    struct an_loud l = {0};
    int partials = 0, other = 0, eof_at_ready = -1;
    char other_state[32] = "";
    double t0 = mt_now(), t_eof = 0, t_grown = 0;
    while (mt_now() - t0 < 30) {
        mpv_wait_event(h, 0.05);
        an_wave_free(&w);
        an_wave_read(h, &w);
        an_loud_read(h, &l);
        int eof = eof_cached(h);
        if (eof && !t_eof)
            t_eof = mt_now();
        if (eof_at_ready < 0 && !strcmp(w.state, "ready"))
            eof_at_ready = eof;
        if (an_final_wave(w.state) && an_final_loud(l.state))
            break;
        // Without a hint nothing ends: give up a while after the whole
        // stream is cached.
        if (!hint && t_eof && mt_now() - t_eof > 1.5)
            break;
        // Nor once it grows from playback: give up a while after.
        if (!strcmp(w.state, "progressive") && an_final_loud(l.state) && !t_grown)
            t_grown = mt_now();
        if (grown && t_grown && mt_now() - t_grown > 1.5)
            break;
        if (an_final_wave(w.state))
            continue;
        if (strcmp(w.state, "decoding")) {
            if (!other++)
                snprintf(other_state, sizeof other_state, "%s", w.state);
            continue;
        }
        partials += w.bins && w.coverage > 0 && w.coverage < w.total_bins;
    }
    printf("     after %.2f s (end cached at %.2f s): waveform %s, %d of %d bins "
           "filled, %lld total, %.2f s; %d partial snapshots, %d in another state "
           "(%s); loudness %s (%.2f LUFS)\n", mt_now() - t0, t_eof ? t_eof - t0 : -1,
           w.state, w.filled, w.bins, (long long)w.total_bins, w.duration_us / 1e6,
           partials, other, other ? other_state : "none", l.state, l.integrated);

    // The server's log: one line per GET. Each download starts at byte 0.
    char path[1100], line[256];
    snprintf(path, sizeof path, "%s.http.log", argv[3]);
    FILE *f = fopen(path, "r");
    int gets = 0;
    while (f && fgets(line, sizeof line, f)) {
        printf("     server: %s", line);
        gets += strstr(line, " chunked") || strstr(line, "range=0-");
    }
    if (f)
        fclose(f);

    if (grown) {
        mt_check(!strcmp(w.state, "progressive") && w.duration_us == 30000000,
                 "the waveform grows from playback on the 30 s axis (%s, %.3f s)",
                 w.state, w.duration_us / 1e6);
        mt_check(!strcmp(l.state, "unavailable"), "the loudness scan is unavailable (%s)",
                 l.state);
        mt_check(gets == 1, "no second request (%d GETs from the start)", gets);
    } else if (!hint) {
        mt_check(t_eof > 0, "the whole stream reached the cache");
        mt_check(!strcmp(w.state, "rolling"), "the waveform rolls from playback (%s)",
                 w.state);
        mt_check(!strcmp(l.state, "unavailable"), "the loudness scan is unavailable (%s)",
                 l.state);
    } else {
        int64_t want_us = range ? 30000000 : (int64_t)atoi(hint) * 1000000;
        mt_check(!strcmp(w.state, "ready"), "the waveform is ready (%s)", w.state);
        mt_check(!other, "it reads decoding until it is ready (%d read %s)", other,
                 other ? other_state : "otherwise");
        mt_check(w.duration_us == want_us, "its axis is %.0f s (%.3f s)", want_us / 1e6,
                 w.duration_us / 1e6);
        mt_check(w.bins > 0 && w.filled == w.bins, "no hole: %d of %d bins filled",
                 w.filled, w.bins);
        mt_check(!strcmp(l.state, "ready") && l.integrated > -30 && l.integrated < -10,
                 "the loudness is ready (%s, %.2f LUFS)", l.state, l.integrated);
        mt_check(gets == 1, "no second download (%d GETs from the start)", gets);
        if (!strcmp(mode, "exact") || !strcmp(mode, "range"))
            mt_check(w.bins >= w.total_bins - 2, "the axis is filled to its end "
                     "(%d of %lld bins)", w.bins, (long long)w.total_bins);
        if (!strcmp(mode, "exact"))
            mt_check(partials >= 3, "partial envelopes while the cache fills (%d)",
                     partials);
        if (!strcmp(mode, "short")) {
            mt_check(w.bins == w.total_bins, "every bin of the axis (%d of %lld)",
                     w.bins, (long long)w.total_bins);
            mt_check(eof_at_ready == 0, "ready before the end of the stream was "
                     "cached (%d)", eof_at_ready);
        }
        if (!strcmp(mode, "long"))
            // 30 s of a 45 s axis of 2000 bins.
            mt_check(w.total_bins == 2000 && w.bins >= 1300 && w.bins <= 1340,
                     "the bins past the end of the stream are left out "
                     "(%d of %lld)", w.bins, (long long)w.total_bins);
    }
    an_wave_free(&w);
    mpv_terminate_destroy(h);
    return mt_result();
}
