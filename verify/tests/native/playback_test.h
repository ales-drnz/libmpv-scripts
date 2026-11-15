// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Helpers of the playback tests (PCM tap, live PCM, chapters). Reuses the
// check and result helpers of mpv_test.h.
#include <stdint.h>
#include <sys/resource.h>
#include "mpv_test.h"

// mpv handle for the playback tests: null audio output, no video, no builtin
// scripts, no prefetch. Options the test needs go on before initialize.
static mpv_handle *pb_create(void)
{
    mpv_handle *h = mpv_create();
    mpv_set_option_string(h, "ao", getenv("AO") ? getenv("AO") : "null");
    mpv_set_option_string(h, "vid", "no");
    mpv_set_option_string(h, "terminal", "yes");
    mpv_set_option_string(h, "msg-time", "yes");
    mpv_set_option_string(h, "msg-level",
        getenv("MSGLEVEL") ? getenv("MSGLEVEL") : "all=warn");
    const char *off[] = {"load-scripts", "ytdl", "load-auto-profiles",
        "load-stats-overlay", "load-console", "load-select", "load-commands",
        "load-context-menu", "load-positioning", "osc", NULL};
    for (int n = 0; off[n]; n++)
        mpv_set_option_string(h, off[n], "no");
    return h;
}

static mpv_node *pb_field(mpv_node *n, const char *k)
{
    if (!n || n->format != MPV_FORMAT_NODE_MAP)
        return NULL;
    for (int i = 0; i < n->u.list->num; i++)
        if (!strcmp(n->u.list->keys[i], k))
            return &n->u.list->values[i];
    return NULL;
}

// Process CPU time (user + system) in seconds.
static double pb_cpu(void)
{
    struct rusage u;
    getrusage(RUSAGE_SELF, &u);
    return u.ru_utime.tv_sec + u.ru_utime.tv_usec / 1e6 +
           u.ru_stime.tv_sec + u.ru_stime.tv_usec / 1e6;
}

// Event counters of pb_pump: log lines containing needle[i] (up to four,
// NULL-terminated), end-file events (the last reason) and file-loaded events.
struct pb_ev {
    const char *needle[5];
    int hits[4];
    int end_files, end_reason, loaded;
    // The position the first END_FILE reports (mak_position).
    double first_end_pos;
};

// Drains the event queue for up to ms (0: what is there now) into ev.
static void pb_pump(mpv_handle *h, int ms, struct pb_ev *ev)
{
    double until = mt_now() + ms / 1000.0;
    for (;;) {
        double left = until - mt_now();
        mpv_event *e = mpv_wait_event(h, left > 0 ? left : 0);
        if (e->event_id == MPV_EVENT_NONE) {
            if (left <= 0)
                return;
            continue;
        }
        if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *m = e->data;
            for (int i = 0; i < 4 && ev->needle[i]; i++)
                if (strstr(m->text, ev->needle[i]))
                    ev->hits[i]++;
        }
        if (e->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *ef = e->data;
            if (!ev->end_files)
                ev->first_end_pos = ef->mak_position;
            ev->end_files++;
            ev->end_reason = ef->reason;
        }
        if (e->event_id == MPV_EVENT_FILE_LOADED)
            ev->loaded++;
    }
}
