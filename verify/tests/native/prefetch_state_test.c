// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// prefetch_state_test <mode> <fixtures> <tmpdir>: prefetch-state after a
// failed prefetch and after stop (F60, F165).
//   fail      a.flac then a missing file. The prefetch open fails at once:
//             prefetch-state is failed while a still plays (r17 keeps
//             loading until the transition).
//   stop      a.flac then b.flac. Once the prefetch of b is ready, stop:
//             prefetch-state goes idle, prefetch-cache-duration 0, and the
//             prefetched b is closed (r17 keeps ready and b open).
//   failstop  fail, then stop: prefetch-state goes idle.
//   hookfail  a.flac then b.flac; the on_prefetch hook of b sets
//             prefetch-open-filename to a missing file: prefetch-state is
//             failed while a plays.
//   httpstop  b comes from slow_http.py on $HTTP_PORT at 2000 bytes a
//             second (run.sh), so the prefetch open is still running at
//             the stop. Prints how long the stop takes to reach idle, now
//             that it joins the opener.
#include "mpv_test.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s fail|stop|failstop|hookfail|httpstop <fixtures> <tmpdir>\n",
                argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    int hookfail = strcmp(mode, "hookfail") == 0;
    int fail = strcmp(mode, "fail") == 0 || strcmp(mode, "failstop") == 0 || hookfail;
    int http = strcmp(mode, "httpstop") == 0;
    int stop = strcmp(mode, "stop") == 0 || strcmp(mode, "failstop") == 0 || http;
    char a[1024], b[1024], missing[1024];
    snprintf(a, sizeof a, "%s/a.flac", argv[2]);
    snprintf(missing, sizeof missing, "%s/missing.flac", argv[3]);
    if (fail && !hookfail)
        snprintf(b, sizeof b, "%s", missing);
    else if (http)
        snprintf(b, sizeof b, "http://127.0.0.1:%s/b.flac",
                 getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0");
    else
        snprintf(b, sizeof b, "%s/b.flac", argv[2]);

    mpv_handle *h = mt_create();
    mpv_initialize(h);
    if (hookfail)
        mpv_hook_add(h, 0, "on_prefetch", 0);
    mt_cmd(h, "loadfile", a, NULL, NULL);
    mt_cmd(h, "loadfile", b, "append", NULL);

    int loaded = 0, stopped = 0, idle_seen = 0, hooks = 0;
    double t_loaded = 0, t_stop = 0, t0 = mt_now();
    while (mt_now() - t0 < 30) {
        mpv_event *e = mpv_wait_event(h, 0.05);
        if (e->event_id == MPV_EVENT_FILE_LOADED && ++loaded == 1)
            t_loaded = mt_now();
        if (e->event_id == MPV_EVENT_HOOK) {
            mpv_event_hook *hk = e->data;
            hooks++;
            int r = mpv_set_property_string(h, "prefetch-open-filename", missing);
            mt_check(r >= 0, "the hook sets prefetch-open-filename to a missing file (%s)",
                     mpv_error_string(r));
            mpv_hook_continue(h, hk->id);
        }
        if (e->event_id == MPV_EVENT_IDLE && stopped && !idle_seen) {
            idle_seen = 1;
            printf("idle %.3f s after stop\n", mt_now() - t_stop);
            if (http)
                mt_check(mt_now() - t_stop < 1.0, "stop reached idle within 1 s");
        }
        if (loaded == 1 && !stopped && mt_now() - t_loaded > 1.5) {
            // The whole of a is in the cache, so the prefetch of b ran.
            double pos = -1;
            mt_double(h, "time-pos", &pos);
            if (fail) {
                mt_check(mt_str_is(h, "prefetch-state", "failed"),
                         "prefetch-state failed while a plays (time-pos %.2f)", pos);
            } else if (http) {
                mt_check(mt_str_is(h, "prefetch-state", "loading"),
                         "prefetch of b still opening at the stop");
            } else {
                mt_check(mt_str_is(h, "prefetch-state", "ready"),
                         "prefetch-state ready while a plays");
                mt_check(mt_fd_open(b) > 0, "the prefetch holds b open");
            }
            if (!stop)
                break;
            mt_cmd(h, "stop", NULL, NULL, NULL);
            stopped = 1;
            t_stop = mt_now();
        }
        if (stopped && idle_seen && mt_now() - t_stop > 0.5) {
            mt_check(mt_str_is(h, "prefetch-state", "idle"), "prefetch-state idle after stop");
            double d = -1;
            mt_double(h, "prefetch-cache-duration", &d);
            mt_check(d == 0, "prefetch-cache-duration 0 after stop (%.2f)", d);
            if (!fail && !http)
                mt_check(mt_fd_open(b) == 0, "b closed after stop (%d fds)", mt_fd_open(b));
            break;
        }
    }
    mt_check(loaded >= 1, "a loaded");
    if (hookfail)
        mt_check(hooks == 1, "one on_prefetch hook (%d)", hooks);
    if (stop)
        mt_check(idle_seen, "player idle after stop");
    mpv_terminate_destroy(h);
    return mt_result();
}
