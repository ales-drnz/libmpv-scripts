// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// prefetch_hook_test <mode> <fixtures> <tmpdir>: the on_prefetch hook of the
// playlist prefetch (F9, F241). Plays a.flac with b.flac next and prefetch
// on; the client gets on_prefetch for b while a plays and does <mode>:
//   stall       F9: holds the hook 1.5 s. a plays on: time-pos advances at
//               least 1.2 s. r19 ran the on_load hook of b there and pumped
//               mp_idle, which feeds no audio: time-pos stood still.
//   transition  F9: a2.flac (2 s) first, the hook of b held 4 s. b starts
//               within 0.5 s of the end of a, with its own on_load, while
//               the hook is held. That cancels the hook: prefetch-state is
//               idle, prefetch-open-filename unavailable and not writable,
//               and the late continue opens nothing.
//   rewrite     the hook sets prefetch-open-filename to c.flac: the prefetch
//               opens c, and the transition, whose on_load sets the same
//               URL, uses it (prefetch-state used, c plays).
//   props       during the hook path, filename, stream-open-filename,
//               media-title and duration are a's, prefetch-open-filename and
//               prefetch-playlist-entry-id b's; after the continue
//               prefetch-open-filename is unavailable and not writable.
//   clear       playlist-clear during the hook: prefetch-state goes idle
//               with the hook still held, the continue opens nothing, and no
//               entry is used after it was freed.
//   stop        stop during the hook: the player goes idle without waiting
//               for the hook, and the late continue opens nothing.
//   destroy     mpv_terminate_destroy with the hook held: no leak.
//   noclient    no client on on_prefetch: the prefetch opens at once, and
//               on_load runs once per entry (F241: r19 also ran it for the
//               prefetch, with file-local-options of the playing entry).
//   repeat      a, b, c; playlist-next with the hook of b held. b plays,
//               but its prefetch of c sends no hook until the cancelled one
//               is continued; then it comes, for c, with the same id.
// With PREFETCH_HOOK=on_load the client takes the on_load that r19 ran for
// b while a played as the prefetch hook, to see stall and transition fail
// on r19.
#include "mpv_test.h"

// The prefetch hook is the on_load of r19 (PREFETCH_HOOK=on_load).
static int old_hook;

struct pf {
    mpv_handle *h;
    int loaded, ended, idle;
    double t_loaded[4], t_ended[4], t_idle;
    int prefetch_hooks;     // prefetch hooks seen
    int loads;              // on_load hooks seen (not the prefetch one)
    int loads_held;         // of which while a prefetch hook was held
    uint64_t held;          // the prefetch hook held, 0 for none
    uint64_t last_id;       // id of the last prefetch hook
    double t_held;
    char url[2][1024];      // prefetch-open-filename at the first two
    const char *load_url;   // on_load after the first sets this URL
};

// Handles one event, waiting up to s seconds. Every hook is continued at
// once, except a prefetch hook when hold is set and none is held: that one
// stays held until pf_release.
static void pf_pump(struct pf *p, double s, int hold)
{
    mpv_event *e = mpv_wait_event(p->h, s);
    switch (e->event_id) {
    case MPV_EVENT_FILE_LOADED:
        if (p->loaded < 4)
            p->t_loaded[p->loaded] = mt_now();
        p->loaded++;
        break;
    case MPV_EVENT_END_FILE:
        if (p->ended < 4)
            p->t_ended[p->ended] = mt_now();
        p->ended++;
        break;
    case MPV_EVENT_IDLE:
        p->idle++;
        p->t_idle = mt_now();
        break;
    case MPV_EVENT_HOOK: {
        mpv_event_hook *hk = e->data;
        // r19: the on_load of the next entry while the current one plays.
        int prefetch = strcmp(hk->name, "on_prefetch") == 0 ||
            (old_hook && strcmp(hk->name, "on_load") == 0 && p->loaded > p->ended);
        if (prefetch) {
            char *u = mt_str(p->h, "prefetch-open-filename");
            if (p->prefetch_hooks < 2)
                snprintf(p->url[p->prefetch_hooks], sizeof p->url[0], "%s", u ? u : "");
            printf("prefetch hook %s #%d id %llu url %s\n", hk->name,
                   p->prefetch_hooks + 1, (unsigned long long)hk->id, u ? u : "<none>");
            mpv_free(u);
            p->prefetch_hooks++;
            p->last_id = hk->id;
            if (hold && !p->held) {
                p->held = hk->id;
                p->t_held = mt_now();
                break;
            }
        } else if (strcmp(hk->name, "on_load") == 0) {
            p->loads++;
            if (p->held)
                p->loads_held++;
            if (p->load_url && p->loads > 1)
                mpv_set_property_string(p->h, "stream-open-filename", p->load_url);
        }
        mpv_hook_continue(p->h, hk->id);
        break;
    }
    default:
        break;
    }
}

static int pf_release(struct pf *p)
{
    int r = mpv_hook_continue(p->h, p->held);
    p->held = 0;
    return r;
}

static int pf_is(struct pf *p, const char *name, const char *want)
{
    char *v = mt_str(p->h, name);
    int ok = v && strcmp(v, want) == 0;
    mpv_free(v);
    return ok;
}

// The error of reading a string property, 0 when it reads.
static int pf_get_err(struct pf *p, const char *name)
{
    char *v = NULL;
    int r = mpv_get_property(p->h, name, MPV_FORMAT_STRING, &v);
    mpv_free(v);
    return r;
}

// Pumps events until cond holds or secs pass.
#define PF_WAIT(p, secs, hold, cond) \
    for (double t_ = mt_now(); !(cond) && mt_now() - t_ < (secs);) \
        pf_pump(p, 0.05, hold)

static void pf_seek_end(struct pf *p, double left)
{
    double d = -1;
    mt_double(p->h, "duration", &d);
    char pos[32];
    snprintf(pos, sizeof pos, "%f", d - left);
    mt_cmd(p->h, "seek", pos, "absolute", NULL);
}

// After a cancelled hook came back: nothing opened for it.
static void pf_nothing_opened(struct pf *p, const char *b, int b_plays)
{
    mt_check(pf_is(p, "prefetch-state", "idle"), "prefetch-state stays idle");
    int n = mt_fd_open(b);
    mt_check(n == b_plays, "b open %d time(s), want %d", n, b_plays);
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s stall|transition|rewrite|props|clear|stop|destroy|"
                "noclient|repeat <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    old_hook = getenv("PREFETCH_HOOK") && strcmp(getenv("PREFETCH_HOOK"), "on_load") == 0;
    char a[1024], b[1024], c[1024];
    snprintf(a, sizeof a, "%s/%s", argv[2],
             strcmp(mode, "transition") == 0 ? "a2.flac" : "a.flac");
    snprintf(b, sizeof b, "%s/b.flac", argv[2]);
    snprintf(c, sizeof c, "%s/c.flac", argv[2]);

    struct pf p = {.h = mt_create()};
    mpv_initialize(p.h);
    if (strcmp(mode, "noclient") != 0)
        mpv_hook_add(p.h, 0, "on_prefetch", 0);
    mpv_hook_add(p.h, 0, "on_load", 0);
    mt_cmd(p.h, "loadfile", a, NULL, NULL);
    mt_cmd(p.h, "loadfile", b, "append", NULL);
    if (strcmp(mode, "repeat") == 0)
        mt_cmd(p.h, "loadfile", c, "append", NULL);

    if (strcmp(mode, "noclient") == 0) {
        PF_WAIT(&p, 10, 0, p.loaded >= 1);
        PF_WAIT(&p, 3, 0, pf_is(&p, "prefetch-state", "ready"));
        mt_check(pf_is(&p, "prefetch-state", "ready"), "the prefetch of b is ready while a plays");
        mt_check(mt_fd_open(b) > 0, "the prefetch holds b open");
        mt_check(p.loads == 1, "on_load ran for a only (%d on_load)", p.loads);
        pf_seek_end(&p, 1.0);
        PF_WAIT(&p, 10, 0, p.loaded >= 2);
        mt_check(p.loaded >= 2, "b loaded");
        mt_check(pf_is(&p, "prefetch-state", "used"), "the transition used the prefetch");
        mt_check(p.loads == 2, "one on_load per entry (%d)", p.loads);
        mpv_terminate_destroy(p.h);
        return mt_result();
    }

    PF_WAIT(&p, 20, 1, p.held);
    mt_check(p.held, "the prefetch hook of b came while a plays");
    if (!p.held) {
        mpv_terminate_destroy(p.h);
        return mt_result();
    }

    if (strcmp(mode, "stall") == 0) {
        double tp0 = -1, tp1 = -1;
        mt_double(p.h, "time-pos", &tp0);
        while (mt_now() - p.t_held < 1.5)
            pf_pump(&p, 0.05, 1);
        mt_double(p.h, "time-pos", &tp1);
        mt_check(tp1 - tp0 >= 1.2, "a played on during the 1.5 s hold (time-pos %.2f to %.2f)",
                 tp0, tp1);
        pf_release(&p);
        PF_WAIT(&p, 5, 0, pf_is(&p, "prefetch-state", "ready"));
        mt_check(pf_is(&p, "prefetch-state", "ready"), "the prefetch of b opened after the hook");
    } else if (strcmp(mode, "transition") == 0) {
        int after_b = 0;
        while (mt_now() - p.t_held < 4.0) {
            pf_pump(&p, 0.05, 1);
            if (p.loaded >= 2 && !after_b) {
                after_b = 1;
                mt_check(pf_is(&p, "prefetch-state", "idle"),
                         "the transition cancelled the prefetch (prefetch-state idle)");
                int r = pf_get_err(&p, "prefetch-open-filename");
                mt_check(r == MPV_ERROR_PROPERTY_UNAVAILABLE,
                         "prefetch-open-filename unavailable after the cancel (%s)",
                         mpv_error_string(r));
                r = mpv_set_property_string(p.h, "prefetch-open-filename", c);
                mt_check(r < 0, "prefetch-open-filename not writable after the cancel (%s)",
                         mpv_error_string(r));
            }
        }
        double late = p.loaded >= 2 ? p.t_loaded[1] - p.t_loaded[0] - 2.0 : 99;
        mt_check(p.loaded >= 2 && late <= 0.5,
                 "b started within 0.5 s of the end of a (%.2f s after it)", late);
        mt_check(p.loads_held == 1, "b had its own on_load while the hook was held (%d)",
                 p.loads_held);
        int r = pf_release(&p);
        mt_check(r >= 0, "the late continue is accepted (%s)", mpv_error_string(r));
        while (mt_now() - p.t_held < 4.5)
            pf_pump(&p, 0.05, 1);
        mt_check(p.prefetch_hooks == 1, "no other prefetch hook (%d)", p.prefetch_hooks);
        mt_check(mt_str_is(p.h, "path", b), "b still plays");
        pf_nothing_opened(&p, b, 1);
    } else if (strcmp(mode, "rewrite") == 0) {
        mt_check(strcmp(p.url[0], b) == 0, "prefetch-open-filename is b at the hook (%s)",
                 p.url[0]);
        int r = mpv_set_property_string(p.h, "prefetch-open-filename", c);
        mt_check(r >= 0, "the hook rewrites prefetch-open-filename (%s)", mpv_error_string(r));
        mt_check(mt_str_is(p.h, "prefetch-open-filename", c), "prefetch-open-filename reads c");
        p.load_url = c;
        pf_release(&p);
        PF_WAIT(&p, 5, 0, pf_is(&p, "prefetch-state", "ready"));
        mt_check(pf_is(&p, "prefetch-state", "ready"), "the prefetch of c is ready");
        mt_check(mt_fd_open(c) > 0 && mt_fd_open(b) == 0, "the prefetch opened c, not b");
        pf_seek_end(&p, 1.0);
        PF_WAIT(&p, 10, 0, p.loaded >= 2);
        double d = -1;
        mt_double(p.h, "duration", &d);
        mt_check(d > 29 && d < 31, "after the transition c plays (duration %.2f)", d);
        mt_check(pf_is(&p, "prefetch-state", "used"), "the transition used the prefetched c");
    } else if (strcmp(mode, "props") == 0) {
        double tp = -1, d = -1;
        int r = mt_double(p.h, "time-pos", &tp);
        mt_check(r >= 0 && tp >= 0, "time-pos of a during the hook (%s)", mpv_error_string(r));
        r = mt_double(p.h, "duration", &d);
        mt_check(r >= 0 && d > 59 && d < 61, "duration is a's (%.2f)", d);
        mt_check(mt_str_is(p.h, "path", a), "path is a's");
        mt_check(mt_str_is(p.h, "filename", "a.flac"), "filename is a's");
        mt_check(mt_str_is(p.h, "stream-open-filename", a), "stream-open-filename is a's");
        mt_check(mt_str_is(p.h, "media-title", "Track A"), "media-title is a's");
        mt_check(mt_str_is(p.h, "prefetch-open-filename", b), "prefetch-open-filename is b");
        int64_t id = -1, want = -2;
        mt_int(p.h, "playlist/1/id", &want);
        r = mt_int(p.h, "prefetch-playlist-entry-id", &id);
        mt_check(r >= 0 && id == want, "prefetch-playlist-entry-id is b's (%lld, want %lld, %s)",
                 (long long)id, (long long)want, mpv_error_string(r));
        pf_release(&p);
        pf_pump(&p, 0.2, 0);
        r = pf_get_err(&p, "prefetch-open-filename");
        mt_check(r == MPV_ERROR_PROPERTY_UNAVAILABLE,
                 "prefetch-open-filename unavailable after the hook (%s)", mpv_error_string(r));
        r = pf_get_err(&p, "prefetch-playlist-entry-id");
        mt_check(r == MPV_ERROR_PROPERTY_UNAVAILABLE,
                 "prefetch-playlist-entry-id unavailable after the hook (%s)",
                 mpv_error_string(r));
        r = mpv_set_property_string(p.h, "prefetch-open-filename", c);
        mt_check(r < 0, "prefetch-open-filename not writable after the hook (%s)",
                 mpv_error_string(r));
    } else if (strcmp(mode, "clear") == 0) {
        mt_check(mt_cmd(p.h, "playlist-clear", NULL, NULL, NULL) >= 0,
                 "playlist-clear during the hook");
        PF_WAIT(&p, 1, 1, pf_is(&p, "prefetch-state", "idle"));
        mt_check(pf_is(&p, "prefetch-state", "idle"), "prefetch-state idle with the hook held");
        int r = mpv_set_property_string(p.h, "prefetch-open-filename", c);
        mt_check(r < 0, "prefetch-open-filename not writable after the clear (%s)",
                 mpv_error_string(r));
        r = pf_release(&p);
        mt_check(r >= 0, "the late continue is accepted (%s)", mpv_error_string(r));
        PF_WAIT(&p, 0.5, 1, 0);
        mt_check(mt_str_is(p.h, "path", a), "a still plays");
        pf_nothing_opened(&p, b, 0);
    } else if (strcmp(mode, "stop") == 0) {
        int idle = p.idle;
        double t = mt_now();
        mt_cmd(p.h, "stop", NULL, NULL, NULL);
        PF_WAIT(&p, 3, 1, p.idle > idle);
        mt_check(p.idle > idle && p.t_idle - t < 0.5,
                 "idle within 0.5 s of the stop with the hook held (%.2f s)",
                 p.idle > idle ? p.t_idle - t : -1);
        mt_check(pf_is(&p, "prefetch-state", "idle"), "prefetch-state idle after the stop");
        int r = mpv_set_property_string(p.h, "prefetch-open-filename", c);
        mt_check(r < 0, "prefetch-open-filename not writable after the stop (%s)",
                 mpv_error_string(r));
        r = pf_release(&p);
        mt_check(r >= 0, "the late continue is accepted (%s)", mpv_error_string(r));
        PF_WAIT(&p, 0.5, 1, 0);
        pf_nothing_opened(&p, b, 0);
    } else if (strcmp(mode, "destroy") == 0) {
        double t = mt_now();
        mpv_terminate_destroy(p.h);
        mt_check(mt_now() - t < 5, "destroyed with the hook held in %.2f s", mt_now() - t);
        return mt_result();
    } else if (strcmp(mode, "repeat") == 0) {
        uint64_t first = p.held;
        mt_cmd(p.h, "playlist-next", NULL, NULL, NULL);
        PF_WAIT(&p, 5, 1, p.loaded >= 2);
        mt_check(p.loaded >= 2, "b started with the hook held");
        double t = mt_now();
        PF_WAIT(&p, 1.0, 1, mt_now() - t >= 1.0);
        mt_check(p.prefetch_hooks == 1, "no hook for the prefetch of c while b's is held (%d)",
                 p.prefetch_hooks);
        mt_check(pf_is(&p, "prefetch-state", "idle"), "prefetch-state idle");
        int r = mpv_set_property_string(p.h, "prefetch-open-filename", c);
        mt_check(r < 0, "prefetch-open-filename not writable (%s)", mpv_error_string(r));
        pf_release(&p);
        PF_WAIT(&p, 3, 1, p.prefetch_hooks >= 2);
        mt_check(p.prefetch_hooks == 2, "the hook of c came after the continue (%d)",
                 p.prefetch_hooks);
        mt_check(p.last_id == first, "with the id of the first (%llu, %llu)",
                 (unsigned long long)p.last_id, (unsigned long long)first);
        mt_check(strcmp(p.url[1], c) == 0, "prefetch-open-filename is c (%s)", p.url[1]);
        if (p.held)
            pf_release(&p);
        PF_WAIT(&p, 5, 0, pf_is(&p, "prefetch-state", "ready"));
        mt_check(pf_is(&p, "prefetch-state", "ready"), "the prefetch of c is ready");
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    if (p.held)
        pf_release(&p);
    mpv_terminate_destroy(p.h);
    return mt_result();
}
