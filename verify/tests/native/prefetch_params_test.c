// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// prefetch_params_test <mode> <fixtures> <tmpdir>: per-file options and the
// prefetch (F239). a.flac then b.flac with prefetch on, each loaded with its
// own per-file options. The prefetch opens the next entry with the options
// of the playing one, so it must skip an entry whose per-file options differ.
//   differ  a has http-header-fields X-Token: A, b has X-Token: B. No
//           prefetch of b while a plays, so no on_prefetch hook; b then
//           plays with X-Token: B.
//   only-b  a has no per-file options, b has X-Token: B. No prefetch.
//   same    both have X-Token: A. The prefetch runs and is used.
//   none    no per-file options. The prefetch runs and is used.
#include "mpv_test.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s differ|only-b|same|none <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    char a[1024], b[1024];
    snprintf(a, sizeof a, "%s/a.flac", argv[2]);
    snprintf(b, sizeof b, "%s/b.flac", argv[2]);
    const char *opt_a = NULL, *opt_b = NULL;
    if (strcmp(mode, "differ") == 0) {
        opt_a = "http-header-fields=X-Token: A";
        opt_b = "http-header-fields=X-Token: B";
    } else if (strcmp(mode, "only-b") == 0) {
        opt_b = "http-header-fields=X-Token: B";
    } else if (strcmp(mode, "same") == 0) {
        opt_a = opt_b = "http-header-fields=X-Token: A";
    }
    int expect_prefetch = strcmp(mode, "same") == 0 || strcmp(mode, "none") == 0;

    mpv_handle *h = mt_create();
    mpv_initialize(h);
    mpv_hook_add(h, 0, "on_prefetch", 0);
    mpv_hook_add(h, 0, "on_load", 0);
    const char *l1[] = {"loadfile", a, "replace", "-1", opt_a, NULL};
    const char *l2[] = {"loadfile", b, "append", "-1", opt_b, NULL};
    mpv_command(h, l1);
    mpv_command(h, l2);

    int prefetch_hooks = 0, load_hooks = 0, loaded = 0, checked = 0;
    double t_loaded = 0, t0 = mt_now();
    while (mt_now() - t0 < 30) {
        mpv_event *e = mpv_wait_event(h, 0.05);
        if (e->event_id == MPV_EVENT_HOOK) {
            mpv_event_hook *hk = e->data;
            if (strcmp(hk->name, "on_prefetch") == 0)
                prefetch_hooks++;
            else
                load_hooks++;
            mpv_hook_continue(h, hk->id);
        }
        if (e->event_id == MPV_EVENT_FILE_LOADED) {
            loaded++;
            if (loaded == 1)
                t_loaded = mt_now();
            if (loaded == 2) {
                char *st = mt_str(h, "prefetch-state");
                mt_check(st && (strcmp(st, "used") == 0) == expect_prefetch,
                         "transition %s the prefetch (prefetch-state %s)",
                         expect_prefetch ? "used" : "did not use", st ? st : "?");
                mpv_free(st);
                if (opt_b)
                    mt_check(mt_str_is(h, "http-header-fields", opt_b + strlen("http-header-fields=")),
                             "b plays with its own per-file options");
                break;
            }
        }
        if (loaded == 1 && !checked && mt_now() - t_loaded > 1.5) {
            // The whole of a is in the cache by now, so the prefetch of b
            // either ran or was skipped.
            checked = 1;
            char *st = mt_str(h, "prefetch-state");
            int idle = st && strcmp(st, "idle") == 0;
            if (expect_prefetch)
                mt_check(!idle && prefetch_hooks == 1 && load_hooks == 1,
                         "b prefetched while a plays (prefetch-state %s, on_prefetch %d, on_load %d)",
                         st ? st : "?", prefetch_hooks, load_hooks);
            else
                mt_check(idle && prefetch_hooks == 0 && load_hooks == 1,
                         "b not prefetched while a plays (prefetch-state %s, on_prefetch %d, on_load %d)",
                         st ? st : "?", prefetch_hooks, load_hooks);
            mpv_free(st);
            double d = -1;
            mt_double(h, "duration", &d);
            char pos[32];
            snprintf(pos, sizeof pos, "%f", d - 1.0);
            mt_cmd(h, "seek", pos, "absolute", NULL);
        }
    }
    mt_check(loaded == 2, "b loaded after a");
    mpv_terminate_destroy(h);
    return mt_result();
}
