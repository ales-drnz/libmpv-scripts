// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// duration_estimated_test <mode> <fixtures> <tmpdir>: the property
// duration-estimated, yes when lavf estimated the duration from the bitrate
// (an MP3 without a Xing header, ADTS AAC), so that a client holding the
// length (a server's) can prefer it. r23 has no such property.
//   est      est.mp3 (no Xing header): yes
//   aac      over.aac (ADTS): yes
//   exact    a.flac: no
//   none     no file: unavailable, as duration
//   observe  observed across est.mp3 then a.flac: yes, then no
#include "analysis_test.h"

static int get_flag(mpv_handle *h, int *out)
{
    return mpv_get_property(h, "duration-estimated", MPV_FORMAT_FLAG, out);
}

static void load(mpv_handle *h, const char *dir, const char *name)
{
    char file[1024];
    snprintf(file, sizeof file, "%s/%s", dir, name);
    mt_cmd(h, "loadfile", file, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "%s loaded", name);
}

static void expect(mpv_handle *h, const char *name, int want)
{
    int v = -1;
    int r = get_flag(h, &v);
    double d = -1;
    mt_double(h, "duration", &d);
    mt_check(r >= 0 && v == want, "%s: duration-estimated is %s (%s, duration %.2f s)",
             name, want ? "yes" : "no",
             r < 0 ? mpv_error_string(r) : v ? "yes" : "no", d);
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s est|aac|exact|none|observe <fixtures> <tmpdir>\n",
                argv[0]);
        return 2;
    }
    const char *mode = argv[1], *dir = argv[2];
    mpv_handle *h = an_create();
    mpv_initialize(h);
    mpv_set_property_string(h, "pause", "yes");

    if (!strcmp(mode, "est")) {
        load(h, dir, "est.mp3");
        expect(h, "est.mp3", 1);
    } else if (!strcmp(mode, "aac")) {
        load(h, dir, "over.aac");
        expect(h, "over.aac", 1);
    } else if (!strcmp(mode, "exact")) {
        load(h, dir, "a.flac");
        expect(h, "a.flac", 0);
    } else if (!strcmp(mode, "none")) {
        int v = -1;
        int r = get_flag(h, &v);
        mt_check(r == MPV_ERROR_PROPERTY_UNAVAILABLE,
                 "no file: unavailable (%s)", mpv_error_string(r));
    } else if (!strcmp(mode, "observe")) {
        mt_check(mpv_observe_property(h, 1, "duration-estimated",
                                      MPV_FORMAT_FLAG) >= 0, "observed");
        int seen[4], n = 0;
        char file[1024];
        const char *names[] = {"est.mp3", "a.flac"};
        for (int k = 0; k < 2; k++) {
            snprintf(file, sizeof file, "%s/%s", dir, names[k]);
            mt_cmd(h, "loadfile", file, NULL, NULL);
            double t0 = mt_now();
            int last = -1, loaded = 0;
            while (mt_now() - t0 < 5) {
                mpv_event *e = mpv_wait_event(h, 0.05);
                if (e->event_id == MPV_EVENT_FILE_LOADED)
                    loaded = 1;
                if (e->event_id == MPV_EVENT_PROPERTY_CHANGE) {
                    mpv_event_property *p = e->data;
                    if (p->format == MPV_FORMAT_FLAG)
                        last = *(int *)p->data;
                }
                if (loaded && last >= 0 && mt_now() - t0 > 1)
                    break;
            }
            seen[n++] = last;
        }
        mt_check(seen[0] == 1 && seen[1] == 0,
                 "the change events say yes, then no (%d, %d)", seen[0], seen[1]);
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    mpv_terminate_destroy(h);
    return mt_result();
}
