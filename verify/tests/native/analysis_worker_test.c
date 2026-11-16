// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_worker_test <mode> <fixtures> <tmpdir>: a bulk worker that fails
// (F68). long.flac (15 min) fans out to 4 workers; this test replaces
// read() for the whole process and fails, with EIO, every read of that
// file past 80% of it. Only the last worker reads there (playback reads
// ahead about a second from the start), so it fails a few seconds into its
// region while the others decode theirs.
//   fail  waveform and loudness on. No snapshot may count the failed
//         worker's region as covered while decoding (coverage_bins over the
//         filled bins), and the result is failed. r17 counts the failed
//         region as sealed (progress jumps by a quarter) and lets the
//         other workers decode to their end before failing.
#include <errno.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include "analysis_test.h"

static dev_t fail_dev;
static ino_t fail_ino;
static off_t fail_from = -1;
static atomic_int failed_reads;

// Every read() of the process lands here: FFmpeg's file protocol and mpv's
// stream layer read with read(). syscall() keeps the real one.
ssize_t read(int fd, void *buf, size_t n)
{
    if (fail_from >= 0) {
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_ino == fail_ino &&
            st.st_dev == fail_dev) {
            off_t pos = lseek(fd, 0, SEEK_CUR);
            if (pos >= fail_from && pos < st.st_size - 4096) {
                atomic_fetch_add(&failed_reads, 1);
                errno = EIO;
                return -1;
            }
        }
    }
    return syscall(SYS_read, fd, buf, n);
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s fail <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    char file[1024];
    snprintf(file, sizeof file, "%s/long.flac", argv[2]);
    struct stat st;
    if (stat(file, &st) < 0)
        return 2;
    fail_dev = st.st_dev;
    fail_ino = st.st_ino;
    fail_from = st.st_size * 8 / 10;

    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", 1);
    an_flag(h, "loudness-scan-enabled", 1);
    mpv_set_property_string(h, "pause", "yes");
    mt_cmd(h, "loadfile", file, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");

    double t0 = mt_now(), max = mt_ceil(30), worst = 0, t_end = -1;
    int snaps = 0, over = 0;
    struct an_wave w;
    struct an_loud lo;
    while (mt_now() - t0 < max) {
        mpv_wait_event(h, 0.01);
        an_wave_read(h, &w);
        an_loud_read(h, &lo);
        if (!strcmp(w.state, "decoding") && w.total_bins > 0) {
            snaps++;
            // Bins counted as covered that hold no sample.
            double extra = (double)(w.coverage - w.filled) / w.total_bins;
            if (extra > worst)
                worst = extra;
            if (extra > 0.05 && over++ < 3)
                printf("     decoding at %.3f s: coverage %lld, %d bins filled of %lld, loudness progress %.2f\n",
                       mt_now() - t0, (long long)w.coverage, w.filled,
                       (long long)w.total_bins, lo.progress);
        }
        int fin = an_final_wave(w.state) && an_final_loud(lo.state);
        an_wave_free(&w);
        if (fin) {
            t_end = mt_now() - t0;
            break;
        }
    }
    an_wave_read(h, &w);
    printf("     final after %.3f s: waveform %s, loudness %s; %d decoding snapshots, "
           "%d reads failed\n", t_end, w.state, lo.state, snaps,
           atomic_load(&failed_reads));
    mt_check(atomic_load(&failed_reads) > 0, "the last worker's reads failed");
    mt_check(!strcmp(w.state, "failed") && !strcmp(lo.state, "failed"),
             "both results failed (%s, %s)", w.state, lo.state);
    mt_check(worst <= 0.05, "no decoding snapshot counts the failed region "
             "(worst %.1f%% of the bins)", worst * 100);
    an_wave_free(&w);
    fail_from = -1;
    mpv_terminate_destroy(h);
    return mt_result();
}
