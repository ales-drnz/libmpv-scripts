// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// fd_offset_test <mode> <fixtures> <tmpdir>: two streams of one fd://N
// (F16). An Android content:// URI reaches mpv as fd://N, and every open
// of the entry reads the same N: the current file and its prefetch (a
// one-entry playlist in a loop), or two players of one source. stream_file
// read N with read() and lseek(), at the one offset the kernel keeps for
// the open file description, so a stream read where the other had left it.
// Linux stands in for Android: the test opens the fixture itself.
//   two   player A loads sine60.flac (60 s) as fd://N, paused, with a small
//         read-ahead. Player B loads the same fd://N and plays it to its
//         end, untimed. Then A plays to its end, untimed: it must reach
//         the end of the file. With the shared offset at the end of the
//         file, A read nothing more and ended after its read-ahead.
#include <fcntl.h>
#include "mpv_test.h"

// Plays h to its end, untimed, and returns time-pos there: keep-open parks
// the player at the last frame it decoded, early or not.
static double play_to_end(mpv_handle *h, const char *who)
{
    double t0 = mt_now(), pos = -1;
    int eof = 0;
    mpv_set_property_string(h, "pause", "no");
    while (mt_now() - t0 < 60) {
        mpv_wait_event(h, 0.02);
        if (mpv_get_property(h, "eof-reached", MPV_FORMAT_FLAG, &eof) >= 0 && eof)
            break;
    }
    mt_double(h, "time-pos", &pos);
    printf("player %s: eof-reached %d at time-pos %.2f, after %.2f s\n",
           who, eof, pos, mt_now() - t0);
    return pos;
}

static mpv_handle *player(int paused)
{
    mpv_handle *h = mt_create();
    mpv_set_option_string(h, "prefetch-playlist", "no");
    mpv_set_option_string(h, "cache", "no");
    mpv_set_option_string(h, "demuxer-readahead-secs", "1");
    mpv_set_option_string(h, "ao-null-untimed", "yes");
    mpv_set_option_string(h, "keep-open", "yes");
    mpv_set_option_string(h, "pause", paused ? "yes" : "no");
    mpv_initialize(h);
    return h;
}

static int wait_loaded(mpv_handle *h)
{
    double t0 = mt_now();
    while (mt_now() - t0 < 15) {
        mpv_event *e = mpv_wait_event(h, 0.1);
        if (e->event_id == MPV_EVENT_FILE_LOADED)
            return 1;
        if (e->event_id == MPV_EVENT_END_FILE)
            return 0;
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 4 || strcmp(argv[1], "two")) {
        fprintf(stderr, "usage: %s two <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    char path[1024], url[64];
    snprintf(path, sizeof path, "%s/sine60.flac", argv[2]);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    mt_check(fd >= 0, "open %s", path);
    if (fd < 0)
        return mt_result();
    snprintf(url, sizeof url, "fd://%d", fd);

    mpv_handle *a = player(1);
    mt_cmd(a, "loadfile", url, NULL, NULL);
    mt_check(wait_loaded(a), "player A loaded %s", url);
    mt_sleep_ms(500);

    mpv_handle *b = player(0);
    mt_cmd(b, "loadfile", url, NULL, NULL);
    mt_check(wait_loaded(b), "player B loaded %s", url);
    double end_b = play_to_end(b, "B");
    mt_check(end_b > 59,
             "player B played the whole file (to %.2f s)", end_b);

    double end_a = play_to_end(a, "A");
    mt_check(end_a > 59,
             "player A played the whole file after B (to %.2f s)", end_a);

    mpv_terminate_destroy(b);
    mpv_terminate_destroy(a);
    close(fd);
    return mt_result();
}
