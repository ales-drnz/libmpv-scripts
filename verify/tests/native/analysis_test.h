// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Helpers of the analysis tests (waveform and loudness). Reuses the check
// and result helpers of mpv_test.h.
#include "mpv_test.h"

// mpv handle for the analysis tests: null audio output, no video, no
// builtin scripts, no prefetch.
static mpv_handle *an_create(void)
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

static mpv_node *an_field(mpv_node *n, const char *k)
{
    if (!n || n->format != MPV_FORMAT_NODE_MAP)
        return NULL;
    for (int i = 0; i < n->u.list->num; i++)
        if (!strcmp(n->u.list->keys[i], k))
            return &n->u.list->values[i];
    return NULL;
}

static void an_flag(mpv_handle *h, const char *name, int on)
{
    int v = on;
    int r = mpv_set_property(h, name, MPV_FORMAT_FLAG, &v);
    if (r < 0)
        printf("     set %s: %s\n", name, mpv_error_string(r));
}

// One snapshot of waveform-data.
struct an_wave {
    char state[32];
    int64_t duration_us, coverage, total_bins;
    int bins, filled;     // bins emitted, bins with filled == 1
    float *min, *max;     // malloc'ed, bins long (NULL without data)
    unsigned char *fill;
};

static void an_wave_free(struct an_wave *w)
{
    free(w->min);
    free(w->max);
    free(w->fill);
    memset(w, 0, sizeof(*w));
}

static int an_wave_read(mpv_handle *h, struct an_wave *w)
{
    memset(w, 0, sizeof(*w));
    mpv_node n;
    if (mpv_get_property(h, "waveform-data", MPV_FORMAT_NODE, &n) < 0) {
        snprintf(w->state, sizeof w->state, "<error>");
        return -1;
    }
    mpv_node *f = an_field(&n, "state");
    snprintf(w->state, sizeof w->state, "%s",
             f && f->format == MPV_FORMAT_STRING ? f->u.string : "?");
    f = an_field(&n, "duration_us");
    w->duration_us = f && f->format == MPV_FORMAT_INT64 ? f->u.int64 : -1;
    f = an_field(&n, "coverage_bins");
    w->coverage = f && f->format == MPV_FORMAT_INT64 ? f->u.int64 : -1;
    f = an_field(&n, "total_bins");
    w->total_bins = f && f->format == MPV_FORMAT_INT64 ? f->u.int64 : -1;
    mpv_node *mn = an_field(&n, "min"), *mx = an_field(&n, "max"),
             *fl = an_field(&n, "filled");
    if (fl && fl->format == MPV_FORMAT_BYTE_ARRAY && fl->u.ba->size > 0) {
        w->bins = fl->u.ba->size;
        w->fill = malloc(w->bins);
        memcpy(w->fill, fl->u.ba->data, w->bins);
        for (int i = 0; i < w->bins; i++)
            w->filled += w->fill[i] != 0;
        if (mn && mx && mn->format == MPV_FORMAT_BYTE_ARRAY &&
            mn->u.ba->size == (size_t)w->bins * 4 && mx->u.ba->size == (size_t)w->bins * 4) {
            w->min = malloc(w->bins * 4);
            w->max = malloc(w->bins * 4);
            memcpy(w->min, mn->u.ba->data, w->bins * 4);
            memcpy(w->max, mx->u.ba->data, w->bins * 4);
        }
    }
    mpv_free_node_contents(&n);
    return 0;
}

// One snapshot of loudness-scan-data.
struct an_loud {
    char state[32];
    double integrated, progress;
};

static int an_loud_read(mpv_handle *h, struct an_loud *l)
{
    memset(l, 0, sizeof(*l));
    mpv_node n;
    if (mpv_get_property(h, "loudness-scan-data", MPV_FORMAT_NODE, &n) < 0) {
        snprintf(l->state, sizeof l->state, "<error>");
        return -1;
    }
    mpv_node *f = an_field(&n, "state");
    snprintf(l->state, sizeof l->state, "%s",
             f && f->format == MPV_FORMAT_STRING ? f->u.string : "?");
    f = an_field(&n, "integrated_lufs");
    l->integrated = f && f->format == MPV_FORMAT_DOUBLE ? f->u.double_ : -999;
    f = an_field(&n, "progress");
    l->progress = f && f->format == MPV_FORMAT_DOUBLE ? f->u.double_ : -1;
    mpv_free_node_contents(&n);
    return 0;
}

static int an_final_wave(const char *s)
{
    return !strcmp(s, "ready") || !strcmp(s, "failed");
}

static int an_final_loud(const char *s)
{
    return !strcmp(s, "ready") || !strcmp(s, "failed") ||
           !strcmp(s, "unavailable");
}

// Drains events for [secs] seconds; returns the number of [id] seen. A
// fixed window (rule 2 of mpv_test.h): for a check that something does not
// happen, once what it follows was waited on. Not scaled.
static int an_pump(mpv_handle *h, double secs, mpv_event_id id)
{
    int seen = 0;
    double t0 = mt_now();
    while (mt_now() - t0 < secs) {
        mpv_event *e = mpv_wait_event(h, 0.02);
        if (e->event_id == id)
            seen++;
    }
    return seen;
}

// Waits up to mt_ceil([secs]) for an event [id]; returns 1 if it came.
static int an_wait_event(mpv_handle *h, mpv_event_id id, double secs)
{
    double t0 = mt_now(), max = mt_ceil(secs);
    while (mt_now() - t0 < max) {
        mpv_event *e = mpv_wait_event(h, 0.05);
        if (e->event_id == id)
            return 1;
    }
    return 0;
}

// Polls the waveform (want_wave) and the loudness (want_loud) every 20 ms
// until both are final or mt_ceil([secs]) pass. Leaves the last snapshots
// in w and l.
static void an_wait_final(mpv_handle *h, int want_wave, int want_loud,
                          double secs, struct an_wave *w, struct an_loud *l)
{
    double t0 = mt_now(), max = mt_ceil(secs);
    memset(w, 0, sizeof(*w));
    memset(l, 0, sizeof(*l));
    while (1) {
        mpv_wait_event(h, 0.02);
        an_wave_free(w);
        an_wave_read(h, w);
        an_loud_read(h, l);
        int done = (!want_wave || an_final_wave(w->state)) &&
                   (!want_loud || an_final_loud(l->state));
        if (done || mt_now() - t0 > max)
            break;
    }
    printf("     after %.2f s: waveform %s (%d of %d bins filled), loudness %s (%.2f LUFS)\n",
           mt_now() - t0, w->state, w->filled, w->bins, l->state, l->integrated);
}

// Established TCP connections of this machine whose remote port is [port]:
// the client side of every connection to a test server on 127.0.0.1:port.
static int an_tcp_conns(int port)
{
    FILE *f = fopen("/proc/net/tcp", "r");
    if (!f)
        return -1;
    char line[512];
    int n = 0;
    if (!fgets(line, sizeof line, f)) {
        fclose(f);
        return -1;
    }
    while (fgets(line, sizeof line, f)) {
        unsigned rport = 0, st = 0;
        char local[64], remote[64];
        if (sscanf(line, " %*d: %63s %63s %x", local, remote, &st) != 3)
            continue;
        char *c = strchr(remote, ':');
        if (!c || sscanf(c + 1, "%x", &rport) != 1)
            continue;
        if (rport == (unsigned)port && st == 1)
            n++;
    }
    fclose(f);
    return n;
}
