// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// prefetch_guard_test <mode> <fixtures> <tmpdir>: the prefetch of one player
// does not wait on another's (F58). Two players in one process, each with
// a.flac then b.flac and prefetch on. The client holds the on_prefetch hook
// of player A for up to 4 s and starts player B meanwhile. B must reach its
// own on_prefetch while A's is held: r17 kept the prefetch guard in one
// static for the whole process, so B skipped its prefetch until A's hook
// returned. The hook state is per player now.
// mode: "two" (the only one).
#include "mpv_test.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s two <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    char a[1024], b[1024];
    snprintf(a, sizeof a, "%s/a.flac", argv[2]);
    snprintf(b, sizeof b, "%s/b.flac", argv[2]);

    mpv_handle *h[2];
    int hooks[2] = {0, 0};
    for (int n = 0; n < 2; n++) {
        h[n] = mt_create();
        mpv_initialize(h[n]);
        mpv_hook_add(h[n], 0, "on_prefetch", 0);
    }
    mt_cmd(h[0], "loadfile", a, NULL, NULL);
    mt_cmd(h[0], "loadfile", b, "append", NULL);

    uint64_t held_id = 0;
    double held_at = 0, b_prefetch_at = 0, a_released_at = 0;
    double t0 = mt_now();
    while (mt_now() - t0 < 30) {
        for (int n = 0; n < 2; n++) {
            mpv_event *e = mpv_wait_event(h[n], 0.02);
            if (e->event_id != MPV_EVENT_HOOK)
                continue;
            mpv_event_hook *hk = e->data;
            hooks[n]++;
            printf("player %c hook #%d at %.3f\n", 'A' + n, hooks[n], mt_now() - t0);
            if (n == 0 && hooks[0] == 1) {
                // A's prefetch hook: hold it, then start B.
                held_id = hk->id;
                held_at = mt_now();
                mt_cmd(h[1], "loadfile", a, NULL, NULL);
                mt_cmd(h[1], "loadfile", b, "append", NULL);
                continue;
            }
            if (n == 1 && hooks[1] == 1 && !b_prefetch_at)
                b_prefetch_at = mt_now();
            mpv_hook_continue(h[n], hk->id);
        }
        if (held_id && (b_prefetch_at || mt_now() - held_at > 4.0)) {
            mpv_hook_continue(h[0], held_id);
            held_id = 0;
            a_released_at = mt_now();
            printf("player A hook released at %.3f\n", a_released_at - t0);
        }
        if (a_released_at && b_prefetch_at)
            break;
    }
    mt_check(held_at > 0, "player A reached its prefetch hook");
    mt_check(b_prefetch_at > 0, "player B reached its prefetch hook");
    mt_check(b_prefetch_at > 0 && b_prefetch_at <= a_released_at,
             "player B prefetched while A's hook was held (B at %.3f, A released at %.3f)",
             b_prefetch_at - t0, a_released_at - t0);
    for (int n = 0; n < 2; n++)
        mpv_terminate_destroy(h[n]);
    return mt_result();
}
