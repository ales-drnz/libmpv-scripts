// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// chapter_list_test <mode> <fixtures> <tmpdir>: a chapter seek, then a
// shorter chapter-list (mp_property_chapter_metadata read past the array).
//   meta     [0 15 30 45] on sine60, chapter 3, then [0 10]: chapter-metadata
//            is chapter 1's
//   index    the same, then chapter is 1 (the position's), not 3
//   observe  chapter-metadata observed, as the kit does; the same sequence
//   kit      the kit test: [0 3], chapter 1, [], then [0] with
//            chapter-metadata observed: it reads Intro
//   same     [0 15 30 45], chapter 2, the same list again: chapter stays 2
//            (control, green before and after)
#include "playback_test.h"

static const char *titles[] = {"A", "B", "C", "D"};

static int set_chapters(mpv_handle *h, const double *t, int n)
{
    mpv_node items[8], vals[8][2];
    mpv_node_list maps[8];
    char *keys[2] = {"time", "title"};
    for (int i = 0; i < n; i++) {
        vals[i][0] = (mpv_node){.format = MPV_FORMAT_DOUBLE, .u.double_ = t[i]};
        vals[i][1] = (mpv_node){.format = MPV_FORMAT_STRING,
                                .u.string = (char *)titles[i]};
        maps[i] = (mpv_node_list){.num = 2, .values = vals[i], .keys = keys};
        items[i] = (mpv_node){.format = MPV_FORMAT_NODE_MAP, .u.list = &maps[i]};
    }
    mpv_node_list arr = {.num = n, .values = items};
    mpv_node root = {.format = MPV_FORMAT_NODE_ARRAY, .u.list = &arr};
    int r = mpv_set_property(h, "chapter-list", MPV_FORMAT_NODE, &root);
    if (r < 0)
        printf("     set chapter-list: %s\n", mpv_error_string(r));
    return r;
}

static int set_chapter(mpv_handle *h, int64_t k)
{
    int r = mpv_set_property(h, "chapter", MPV_FORMAT_INT64, &k);
    if (r < 0)
        printf("     set chapter %lld: %s\n", (long long)k, mpv_error_string(r));
    return r;
}

// Waits until time-pos >= t (a ceiling of 5 s, mt_ceil).
static int wait_pos(mpv_handle *h, double t, struct pb_ev *ev)
{
    double p = -1;
    mt_wait_until(5, mt_double(h, "time-pos", &p) >= 0 && p >= t,
                  pb_pump(h, 20, ev));
    if (p >= t)
        return 1;
    printf("     time-pos %.3f, want %.3f\n", p, t);
    return 0;
}

// Sets the chapter list, then waits until the observer of chapter-metadata
// got the change: the core read the property for it.
static void set_observed(mpv_handle *h, const double *t, int n,
                         struct pb_ev *ev)
{
    pb_pump(h, 0, ev);
    int c0 = ev->changes;
    set_chapters(h, t, n);
    mt_wait_until(1, ev->changes > c0, pb_pump(h, 10, ev));
    mt_check(ev->changes > c0, "the observer got the list of %d", n);
}

// chapter-metadata's title, or "<unavailable>" (caller frees nothing).
static void meta_title(mpv_handle *h, char *out, size_t size)
{
    mpv_node n;
    if (mpv_get_property(h, "chapter-metadata", MPV_FORMAT_NODE, &n) < 0) {
        snprintf(out, size, "<unavailable>");
        return;
    }
    mpv_node *f = pb_field(&n, "title");
    snprintf(out, size, "%s", f && f->format == MPV_FORMAT_STRING ? f->u.string : "<none>");
    mpv_free_node_contents(&n);
}

int main(int argc, char **argv)
{
    if (argc < 4)
        return 2;
    const char *mode = argv[1], *fx = argv[2];
    int m_meta = !strcmp(mode, "meta"), m_index = !strcmp(mode, "index"),
        m_observe = !strcmp(mode, "observe"), m_kit = !strcmp(mode, "kit"),
        m_same = !strcmp(mode, "same");
    if (!(m_meta || m_index || m_observe || m_kit || m_same)) {
        printf("unknown mode %s\n", mode);
        return 2;
    }
    char path[4096];
    snprintf(path, sizeof path, "%s/sine60.flac", fx);

    mpv_handle *h = pb_create();
    mpv_set_option_string(h, "keep-open", "yes");
    if (mpv_initialize(h) < 0)
        return 2;
    if (m_observe || m_kit)
        mpv_observe_property(h, 1, "chapter-metadata", MPV_FORMAT_NODE);
    struct pb_ev ev = {.end_reason = -1};
    mt_cmd(h, "loadfile", path, NULL, NULL);
    mt_wait_until(5, ev.loaded, pb_pump(h, 20, &ev));
    mt_check(ev.loaded == 1, "sine60.flac loaded");

    char title[64];
    int64_t ch = -9;
    if (m_kit) {
        const double two[] = {0, 3}, one[] = {0};
        set_chapters(h, two, 2);
        set_chapter(h, 1);
        mt_check(wait_pos(h, 2.9, &ev), "chapter 1 reached");
        set_observed(h, NULL, 0, &ev);
        set_observed(h, one, 1, &ev);
        meta_title(h, title, sizeof title);
        mt_check(!strcmp(title, "A"), "chapter-metadata is the one chapter's (%s)",
                 title);
    } else if (m_same) {
        const double four[] = {0, 15, 30, 45};
        set_chapters(h, four, 4);
        set_chapter(h, 2);
        mt_check(wait_pos(h, 29.9, &ev), "chapter 2 reached");
        set_chapters(h, four, 4);
        pb_pump(h, 100, &ev);
        mt_int(h, "chapter", &ch);
        meta_title(h, title, sizeof title);
        mt_check(ch == 2 && !strcmp(title, "C"),
                 "the same list keeps chapter 2 (chapter %lld, title %s)",
                 (long long)ch, title);
    } else {
        const double four[] = {0, 15, 30, 45}, two[] = {0, 10};
        set_chapters(h, four, 4);
        set_chapter(h, 3);
        mt_check(wait_pos(h, 44.9, &ev), "chapter 3 reached");
        if (m_observe) {
            set_observed(h, two, 2, &ev);
        } else {
            set_chapters(h, two, 2);
            pb_pump(h, 300, &ev);
        }
        if (m_index) {
            mt_int(h, "chapter", &ch);
            mt_check(ch == 1, "chapter is the position's in the new list (%lld)",
                     (long long)ch);
        } else {
            meta_title(h, title, sizeof title);
            mt_check(!strcmp(title, "B"), "chapter-metadata is chapter 1's (%s)",
                     title);
        }
    }
    mpv_terminate_destroy(h);
    return mt_result();
}
