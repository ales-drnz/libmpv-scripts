// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// playlist_prev_test.exe <libmpv dll> <work dir>: playlist-prev-playlist
// between two playlist files on Windows (patch_playlist_prev_dos_path.py).
// A Windows program: run_wine.sh builds it with mingw and runs it under
// Wine against a built DLL. It needs no mpv header, the functions come from
// GetProcAddress as in verify/winload_test.c.
//
// mpv's playlist_get_first_in_same_playlist() appended "/" to its copy of
// the playlist's path, which may move the string, then on Windows appended
// "\\" through the pointer to the old block: a write to freed memory, an
// abort on the canary of mpv's allocator when the block had moved. Whether
// it moves depends on the length of the path, so the test runs the command
// with playlist names of 1 to 40 characters, each in a fresh core:
//   a<name>.m3u holds a1.wav and a2.wav, b<name>.m3u holds b1.wav; with
//   b1.wav playing, playlist-prev-playlist must load a1.wav, the first
//   entry of the playlist before, and the process must still be there.
// It prints RESULT PASS and exits 0; a crash is the exit code Wine gives.
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct mpv_handle mpv_handle;
typedef struct {
    int event_id, error;
    uint64_t reply_userdata;
    void *data;
} mpv_event;
enum { EVENT_SHUTDOWN = 1, EVENT_END_FILE = 7, EVENT_FILE_LOADED = 8 };

static mpv_handle *(__cdecl *p_create)(void);
static int (__cdecl *p_initialize)(mpv_handle *);
static int (__cdecl *p_set_option_string)(mpv_handle *, const char *, const char *);
static int (__cdecl *p_command)(mpv_handle *, const char **);
static mpv_event *(__cdecl *p_wait_event)(mpv_handle *, double);
static char *(__cdecl *p_get_property_string)(mpv_handle *, const char *);
static void (__cdecl *p_free)(void *);
static void (__cdecl *p_terminate_destroy)(mpv_handle *);

static int failures;

static void check(int ok, const char *what, const char *detail)
{
    if (!ok) {
        printf("FAIL %s (%s)\n", what, detail ? detail : "");
        fflush(stdout);
        failures++;
    }
}

// 0.1 s of silence, 8 kHz mono 16-bit.
static void write_wav(const char *path)
{
    static const unsigned char head[44] = {
        'R','I','F','F', 0x64,0x06,0,0, 'W','A','V','E', 'f','m','t',' ',
        16,0,0,0, 1,0, 1,0, 0x40,0x1F,0,0, 0x80,0x3E,0,0, 2,0, 16,0,
        'd','a','t','a', 0x40,0x06,0,0};
    static const unsigned char zero[1600];
    FILE *f = fopen(path, "wb");
    if (!f)
        return;
    fwrite(head, 1, sizeof head, f);
    fwrite(zero, 1, sizeof zero, f);
    fclose(f);
}

static void write_text(const char *path, const char *text)
{
    FILE *f = fopen(path, "wb");
    if (!f)
        return;
    fputs(text, f);
    fclose(f);
}

static int wait_loaded(mpv_handle *h)
{
    for (int i = 0; i < 200; i++) {
        mpv_event *e = p_wait_event(h, 0.05);
        if (e->event_id == EVENT_FILE_LOADED)
            return 1;
        if (e->event_id == EVENT_SHUTDOWN)
            return 0;
    }
    return 0;
}

static int ends_with(const char *s, const char *tail)
{
    size_t a = s ? strlen(s) : 0, b = strlen(tail);
    return a >= b && !strcmp(s + a - b, tail);
}

// One core: a<name>.m3u then b<name>.m3u, back from b1.wav.
static void run(const char *dir, const char *name)
{
    char a[MAX_PATH * 2], b[MAX_PATH * 2], label[96];
    snprintf(a, sizeof a, "%s\\a%s.m3u", dir, name);
    snprintf(b, sizeof b, "%s\\b%s.m3u", dir, name);
    snprintf(label, sizeof label, "name of %d characters", (int)strlen(name) + 1);
    write_text(a, "a1.wav\r\na2.wav\r\n");
    write_text(b, "b1.wav\r\n");

    mpv_handle *h = p_create();
    if (!h) {
        check(0, "mpv_create", label);
        return;
    }
    const char *opts[][2] = {{"ao", "null"}, {"vid", "no"}, {"pause", "yes"},
        {"idle", "yes"}, {"load-scripts", "no"}, {"osc", "no"},
        {"terminal", "no"}, {"config", "no"}};
    for (size_t i = 0; i < sizeof opts / sizeof opts[0]; i++)
        p_set_option_string(h, opts[i][0], opts[i][1]);
    check(p_initialize(h) >= 0, "mpv_initialize", label);

    const char *load_a[] = {"loadfile", a, NULL};
    const char *load_b[] = {"loadfile", b, "append", NULL};
    const char *to_b[] = {"playlist-play-index", "2", NULL};
    const char *prev[] = {"playlist-prev-playlist", NULL};
    check(p_command(h, load_a) >= 0 && wait_loaded(h), "the first playlist loads", label);
    check(p_command(h, load_b) >= 0, "the second playlist is appended", label);
    check(p_command(h, to_b) >= 0 && wait_loaded(h), "its entry loads", label);
    char *path = p_get_property_string(h, "path");
    char *from = p_get_property_string(h, "playlist-path");
    check(ends_with(path, "b1.wav") && ends_with(from, ".m3u"),
          "b1.wav of the second playlist is playing", path);
    p_free(path);
    p_free(from);

    check(p_command(h, prev) >= 0, "playlist-prev-playlist", label);
    check(wait_loaded(h), "a file loads after it", label);
    path = p_get_property_string(h, "path");
    char *pos = p_get_property_string(h, "playlist-pos");
    check(ends_with(path, "a1.wav") && pos && !strcmp(pos, "0"),
          "the first entry of the first playlist is playing", path);
    p_free(path);
    p_free(pos);
    p_terminate_destroy(h);
}

#define NEED(var, name) \
    if (!(var = (void *)GetProcAddress(dll, name))) { \
        printf("FAIL no %s in the DLL\n", name); return 1; }

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <libmpv dll> <work dir>\n", argv[0]);
        return 2;
    }
    HMODULE dll = LoadLibraryA(argv[1]);
    if (!dll) {
        printf("FAIL LoadLibrary: error %lu\n", (unsigned long)GetLastError());
        return 1;
    }
    NEED(p_create, "mpv_create");
    NEED(p_initialize, "mpv_initialize");
    NEED(p_set_option_string, "mpv_set_option_string");
    NEED(p_command, "mpv_command");
    NEED(p_wait_event, "mpv_wait_event");
    NEED(p_get_property_string, "mpv_get_property_string");
    NEED(p_free, "mpv_free");
    NEED(p_terminate_destroy, "mpv_terminate_destroy");

    char dir[MAX_PATH], file[MAX_PATH * 2];
    if (!GetFullPathNameA(argv[2], sizeof dir, dir, NULL)) {
        printf("FAIL no such dir %s\n", argv[2]);
        return 1;
    }
    const char *wavs[] = {"a1.wav", "a2.wav", "b1.wav"};
    for (int i = 0; i < 3; i++) {
        snprintf(file, sizeof file, "%s\\%s", dir, wavs[i]);
        write_wav(file);
    }

    char name[64] = "";
    for (int n = 0; n < 40; n++) {
        run(dir, name);
        name[n] = 'x';
        name[n + 1] = 0;
    }
    printf("     40 playlist names, in %s\n", dir);
    printf(failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", failures);
    fflush(stdout);
    return failures ? 1 : 0;
}
