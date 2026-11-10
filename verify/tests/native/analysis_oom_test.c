// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_oom_test <mode> <fixtures> <tmpdir>: an allocation that fails in
// mak_scan_start after the new generation started (F74). The test
// replaces calloc() for the process (ASan's calloc underneath) and, once
// armed, fails the first calloc(1, n) with n between 24 and 96 bytes: the
// coordinator's arguments (32 bytes on r17, 48 with the track and the
// descriptor fields).
//   start  loudness on before the load (its scan runs and ends ready), then
//          off, which stops the pass, and on again with the failure armed:
//          both results must turn failed. r17 returns with the waveform on
//          decoding and the loudness on scanning until the next file. (The
//          setter of waveform-enabled no longer starts a scan here: since
//          r24 the complete analysis of the same file stays, F166.)
#include <stdatomic.h>
#include "analysis_test.h"

extern void *__interceptor_calloc(size_t nmemb, size_t size);

static atomic_int armed;
static atomic_size_t failed_size;

void *calloc(size_t nmemb, size_t size)
{
    if (atomic_load(&armed) && nmemb == 1 && size >= 24 && size <= 96 &&
        atomic_exchange(&armed, 0)) {
        atomic_store(&failed_size, size);
        return NULL;
    }
    return __interceptor_calloc(nmemb, size);
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s start <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    char file[1024];
    snprintf(file, sizeof file, "%s/b.flac", argv[2]);
    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "loudness-scan-enabled", 1);
    mpv_set_property_string(h, "pause", "yes");
    mt_cmd(h, "loadfile", file, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");
    struct an_wave w;
    struct an_loud lo;
    an_wait_final(h, 0, 1, 20, &w, &lo);
    an_wave_free(&w);
    mt_check(!strcmp(lo.state, "ready"), "loudness ready first (%s)", lo.state);

    an_flag(h, "loudness-scan-enabled", 0);
    atomic_store(&armed, 1);
    an_flag(h, "loudness-scan-enabled", 1);
    atomic_store(&armed, 0);
    printf("     failed calloc of %zu bytes\n", atomic_load(&failed_size));
    an_pump(h, 2.0, MPV_EVENT_NONE);
    an_wave_read(h, &w);
    an_loud_read(h, &lo);
    printf("     2 s later: waveform %s, loudness %s\n", w.state, lo.state);
    mt_check(atomic_load(&failed_size) > 0, "an allocation failed");
    mt_check(!strcmp(w.state, "failed"), "waveform failed (%s)", w.state);
    mt_check(!strcmp(lo.state, "failed"), "loudness failed (%s)", lo.state);
    an_wave_free(&w);
    mpv_terminate_destroy(h);
    return mt_result();
}
