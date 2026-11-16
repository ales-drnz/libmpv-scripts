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

struct ps {
    mpv_handle *h;
    const char *missing;
    int loaded, hooks, idle;
    double t_idle;
};

// Handles one event, waiting up to 50 ms. The on_prefetch hook (hookfail)
// sets prefetch-open-filename to the missing file.
static void ps_pump(struct ps *p)
{
    mpv_event *e = mpv_wait_event(p->h, 0.05);
    if (e->event_id == MPV_EVENT_FILE_LOADED)
        p->loaded++;
    if (e->event_id == MPV_EVENT_HOOK) {
        mpv_event_hook *hk = e->data;
        p->hooks++;
        int r = mpv_set_property_string(p->h, "prefetch-open-filename", p->missing);
        mt_check(r >= 0, "the hook sets prefetch-open-filename to a missing file (%s)",
                 mpv_error_string(r));
        mpv_hook_continue(p->h, hk->id);
    }
    if (e->event_id == MPV_EVENT_IDLE && p->loaded && !p->idle) {
        p->idle = 1;
        p->t_idle = mt_now();
    }
}

// Pumps events until cond holds or the ceiling of secs runs out (the time
// rule of mpv_test.h).
#define PS_WAIT(p, secs, cond) mt_wait_until(secs, cond, ps_pump(p))

static int ps_is(mpv_handle *h, const char *name, const char *want)
{
    char *v = mt_str(h, name);
    int ok = v && strcmp(v, want) == 0;
    mpv_free(v);
    return ok;
}

static int ps_cache_empty(mpv_handle *h)
{
    double d = -1;
    return mt_double(h, "prefetch-cache-duration", &d) >= 0 && d == 0;
}

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

    struct ps p = {.h = h, .missing = missing};
    PS_WAIT(&p, 30, p.loaded >= 1);
    // The whole of a goes to the cache at once, and the prefetch of b runs
    // then: wait for the state it reaches while a plays.
    const char *want = fail ? "failed" : http ? "loading" : "ready";
    PS_WAIT(&p, 10, ps_is(h, "prefetch-state", want));
    if (p.loaded >= 1) {
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
    }
    if (stop && p.loaded >= 1) {
        mt_cmd(h, "stop", NULL, NULL, NULL);
        double t_stop = mt_now();
        PS_WAIT(&p, 10, p.idle);
        if (p.idle) {
            printf("idle %.3f s after stop\n", p.t_idle - t_stop);
            // A stop that waits for the opener waits for the slow download
            // of b, minutes. Measured under valgrind on a loaded machine:
            // up to 0.16 s.
            double stop_max = mt_bound(1.0, 3.0);
            if (http)
                mt_check(p.t_idle - t_stop < stop_max, "stop reached idle within %.1f s",
                         stop_max);
        }
        // What going idle drops, waited on.
        PS_WAIT(&p, 2, ps_is(h, "prefetch-state", "idle") && ps_cache_empty(h) &&
                       (fail || http || mt_fd_open(b) == 0));
        if (p.idle) {
            mt_check(mt_str_is(h, "prefetch-state", "idle"), "prefetch-state idle after stop");
            double d = -1;
            mt_double(h, "prefetch-cache-duration", &d);
            mt_check(d == 0, "prefetch-cache-duration 0 after stop (%.2f)", d);
            if (!fail && !http)
                mt_check(mt_fd_open(b) == 0, "b closed after stop (%d fds)", mt_fd_open(b));
        }
    }
    mt_check(p.loaded >= 1, "a loaded");
    if (hookfail)
        mt_check(p.hooks == 1, "one on_prefetch hook (%d)", p.hooks);
    if (stop)
        mt_check(p.idle, "player idle after stop");
    mpv_terminate_destroy(h);
    return mt_result();
}
