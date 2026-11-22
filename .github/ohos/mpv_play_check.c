// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// mpv_play_check <libmpv> <file>: plays <file> through ao_ohaudio with the
// libmpv of the OHOS build, run on the Oniro emulator with hdc shell (no
// HAP, so no signing). <file> is the fixture of make_tone.py: 440 Hz
// for 3 s, then 660 Hz. It plays past 2.5 s, seeks to 3.5 s and plays 1.5
// s more, then quits: check_tone.py reads the emulator's WAV for the 440
// Hz, then the 660 Hz with no 440 after it (a flush that kept old audio).
// Prints MAK_OHOS_NATIVE PASS or FAIL from what mpv says: playback-time,
// current-ao ohaudio, the seek done. The client API is taken with dlsym,
// so the check needs no mpv header.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void *(*create_fn)(void);
typedef int (*init_fn)(void *);
typedef int (*set_option_fn)(void *, const char *, const char *);
typedef int (*command_fn)(void *, const char **);
typedef char *(*get_string_fn)(void *, const char *);
typedef void (*free_fn)(void *);
typedef void (*destroy_fn)(void *);

static get_string_fn get;
static free_fn mpv_free;

static double number(void *mpv, const char *name)
{
    char *s = get(mpv, name);
    double v = s ? atof(s) : -1;
    if (s)
        mpv_free(s);
    return v;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <libmpv> <file>\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    void *lib = dlopen(argv[1], RTLD_NOW);
    if (!lib) {
        printf("MAK_OHOS_NATIVE FAIL dlopen: %s\n", dlerror());
        return 1;
    }
    create_fn create = (create_fn)dlsym(lib, "mpv_create");
    init_fn initialize = (init_fn)dlsym(lib, "mpv_initialize");
    set_option_fn set_option = (set_option_fn)dlsym(lib, "mpv_set_option_string");
    command_fn command = (command_fn)dlsym(lib, "mpv_command");
    get = (get_string_fn)dlsym(lib, "mpv_get_property_string");
    mpv_free = (free_fn)dlsym(lib, "mpv_free");
    destroy_fn destroy = (destroy_fn)dlsym(lib, "mpv_terminate_destroy");
    if (!create || !initialize || !set_option || !command || !get || !mpv_free || !destroy) {
        printf("MAK_OHOS_NATIVE FAIL missing client API symbols\n");
        return 1;
    }
    void *mpv = create();
    set_option(mpv, "config", "no");
    set_option(mpv, "terminal", "yes");
    set_option(mpv, "msg-level", "all=warn,ao=v");
    set_option(mpv, "video", "no");
    set_option(mpv, "ao", "ohaudio");
    set_option(mpv, "audio-fallback-to-null", "no");
    if (initialize(mpv) < 0) {
        printf("MAK_OHOS_NATIVE FAIL mpv_initialize\n");
        return 1;
    }
    const char *load[] = {"loadfile", argv[2], NULL};
    command(mpv, load);

    double t = 0;
    for (int i = 0; i < 150 && t <= 2.5; i++) {
        usleep(100 * 1000);
        t = number(mpv, "playback-time");
    }
    double before = t;
    char *ao = get(mpv, "current-ao");
    char *params = get(mpv, "audio-out-params");
    const char *seek[] = {"seek", "3.5", "absolute+exact", NULL};
    int seek_err = command(mpv, seek);
    double after = 0;
    for (int i = 0; i < 100 && after < 5.0; i++) {
        usleep(100 * 1000);
        after = number(mpv, "playback-time");
    }
    int ok = before > 2.5 && !seek_err && after >= 5.0 && ao && !strcmp(ao, "ohaudio");
    printf("MAK_OHOS_NATIVE %s playback-time=%.2f then %.2f after the seek, current-ao=%s "
           "audio-out-params=%s\n", ok ? "PASS" : "FAIL", before, after, ao ? ao : "-",
           params ? params : "-");
    if (ao)
        mpv_free(ao);
    if (params)
        mpv_free(params);
    destroy(mpv);
    return ok ? 0 : 1;
}
