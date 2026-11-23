// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// playlist_no_current_test <mode> <fixtures> <tmpdir>: playlist-prev-playlist
// and playlist-next-playlist on an idle core with no current entry
// (patch_playlist_no_current.py). Two entries play, then `stop keep-playlist`.
//   prev     playlist-prev-playlist fails, the process lives on, both entries
//            stay (before the patch: a NULL read, the process ends)
//   next     playlist-next-playlist fails the same way
//   playing  control: with the first entry playing, playlist-next-playlist
//            goes to the second (entries of no playlist file count as one
//            source each), as before the patch
// The core idles as mpv_audio_kit's does (idle=yes): with no current entry
// after the stop, not out of the playlist loop.
#include "playback_test.h"

int main(int argc, char **argv)
{
    if (argc < 4)
        return 2;
    const char *mode = argv[1], *fx = argv[2];
    int m_prev = !strcmp(mode, "prev"), m_next = !strcmp(mode, "next"),
        m_playing = !strcmp(mode, "playing");
    if (!(m_prev || m_next || m_playing)) {
        printf("unknown mode %s\n", mode);
        return 2;
    }
    char path[4096];
    snprintf(path, sizeof path, "%s/sine60.flac", fx);

    mpv_handle *h = pb_create();
    mpv_set_option_string(h, "keep-open", "yes");
    mpv_set_option_string(h, "idle", "yes");
    if (mpv_initialize(h) < 0)
        return 2;
    struct pb_ev ev = {.end_reason = -1};
    mt_cmd(h, "loadfile", path, NULL, NULL);
    mt_cmd(h, "loadfile", path, "append", NULL);
    mt_wait_until(5, ev.loaded, pb_pump(h, 20, &ev));
    mt_check(ev.loaded == 1, "the first entry loaded");

    if (!m_playing) {
        mt_cmd(h, "stop", "keep-playlist", NULL, NULL);
        // idle-active reads stop_play, which the command sets at once: the
        // playloop clears the current entry after it. Wait for that.
        int64_t pos = 0;
        mt_wait_until(5, mt_int(h, "playlist-pos", &pos) >= 0 && pos == -1,
                      pb_pump(h, 20, &ev));
        mt_check(pos == -1, "no current entry (playlist-pos %lld)", (long long)pos);
        mt_check(mt_str_is(h, "idle-active", "yes"), "idle after stop keep-playlist");
    }
    const char *cmd = m_prev ? "playlist-prev-playlist" : "playlist-next-playlist";
    int r = mt_cmd(h, cmd, NULL, NULL, NULL);
    if (m_playing)
        mt_check(r >= 0, "%s goes on (%s)", cmd, mpv_error_string(r));
    else
        mt_check(r < 0, "%s fails (%s)", cmd, mpv_error_string(r));
    pb_pump(h, 300, &ev);
    int64_t count = 0;
    mt_int(h, "playlist-count", &count);
    mt_check(count == 2, "the process lives on with both entries (%lld)",
             (long long)count);
    if (m_playing) {
        int64_t at = -1;
        mt_wait_until(5, mt_int(h, "playlist-pos", &at) >= 0 && at == 1,
                      pb_pump(h, 20, &ev));
        mt_check(at == 1, "the second entry plays (playlist-pos %lld)",
                 (long long)at);
    }
    else
        mt_check(mt_str_is(h, "idle-active", "yes"), "nothing loads");

    mpv_terminate_destroy(h);
    return mt_result();
}
