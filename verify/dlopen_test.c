/*
 * Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
 */

/* dlopen_test.c — Layer 14 (load + behavioural test) helper for
 * verify_binaries.sh.
 *
 * Loads a .so/.dylib via dlopen(RTLD_NOW). With RTLD_NOW the dynamic linker
 * resolves EVERY undefined symbol immediately — same behaviour the user's
 * Flutter app has at startup. If any symbol is unresolved, dlopen() returns
 * NULL and dlerror() reports the offending symbol name.
 *
 * Then it goes one step further than a pure load test: it actually creates
 * an mpv handle, initialises it headless (no audio/video output), and reads
 * back two of our PATCHED observable properties. This proves the patched
 * property getters RUN at runtime and return the right value — not merely
 * that their name strings are compiled into the binary (which Layer 3
 * already checks statically). A vanilla / mis-patched build returns NULL
 * for these properties and fails here. Runs on every platform via
 * qemu-user-static, so the patched runtime behaviour is validated for
 * foreign-arch Linux/Android binaries too, on a single host.
 *
 * Exit code is 0 on success, 1 on any failure.
 *
 * Usage: dlopen_test <path-to-libmpv.so>
 *
 * Linux/Android: gcc -ldl dlopen_test.c -o dlopen_test
 * macOS:         clang dlopen_test.c -o dlopen_test
 */

#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* Minimal libmpv client API surface, resolved via dlsym so this harness
 * needs no mpv headers and no link-time dependency on libmpv. */
typedef struct mpv_handle mpv_handle;
typedef mpv_handle *(*fn_create)(void);
typedef int   (*fn_initialize)(mpv_handle *);
typedef int   (*fn_set_option_string)(mpv_handle *, const char *, const char *);
typedef char *(*fn_get_property_string)(mpv_handle *, const char *);
typedef void  (*fn_free)(void *);
typedef void  (*fn_terminate_destroy)(mpv_handle *);

/* (property name, expected value on a freshly-initialised handle with no
 * file loaded). Each exercises a different patch family. */
static const char *kPatchedProps[][2] = {
    {"audio-output-state", "closed"}, /* patch_audio_output_state */
    {"prefetch-state",     "idle"},   /* patch_prefetch_state     */
};

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <library>\n", argv[0]);
        return 1;
    }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) {
        fprintf(stderr, "dlopen FAILED: %s\n", dlerror());
        return 1;
    }

    fn_create              mpv_create              = (fn_create)             dlsym(h, "mpv_create");
    fn_initialize          mpv_initialize          = (fn_initialize)         dlsym(h, "mpv_initialize");
    fn_set_option_string   mpv_set_option_string   = (fn_set_option_string)  dlsym(h, "mpv_set_option_string");
    fn_get_property_string mpv_get_property_string = (fn_get_property_string)dlsym(h, "mpv_get_property_string");
    fn_free                mpv_free                = (fn_free)               dlsym(h, "mpv_free");
    fn_terminate_destroy   mpv_terminate_destroy   = (fn_terminate_destroy)  dlsym(h, "mpv_terminate_destroy");

    if (!mpv_create || !mpv_initialize || !mpv_set_option_string ||
        !mpv_get_property_string || !mpv_free || !mpv_terminate_destroy) {
        fprintf(stderr, "dlsym FAILED: a core mpv_* symbol is missing\n");
        dlclose(h);
        return 1;
    }

    mpv_handle *ctx = mpv_create();
    if (!ctx) {
        fprintf(stderr, "mpv_create() returned NULL\n");
        dlclose(h);
        return 1;
    }

    /* Headless: no config, no terminal, null audio out, no video. Keeps
     * init from touching real hardware under qemu/Wine. */
    mpv_set_option_string(ctx, "config", "no");
    mpv_set_option_string(ctx, "terminal", "no");
    mpv_set_option_string(ctx, "ao", "null");
    mpv_set_option_string(ctx, "video", "no");
    mpv_set_option_string(ctx, "msg-level", "all=no");

    int rc = mpv_initialize(ctx);
    if (rc < 0) {
        fprintf(stderr, "mpv_initialize() FAILED: rc=%d\n", rc);
        mpv_terminate_destroy(ctx);
        dlclose(h);
        return 1;
    }

    int failures = 0;
    for (size_t i = 0; i < sizeof(kPatchedProps) / sizeof(kPatchedProps[0]); i++) {
        const char *name = kPatchedProps[i][0];
        const char *want = kPatchedProps[i][1];
        char *got = mpv_get_property_string(ctx, name);
        if (!got) {
            fprintf(stderr, "patched property '%s' unavailable at runtime "
                            "(patch missing or getter failed)\n", name);
            failures++;
            continue;
        }
        if (strcmp(got, want) != 0) {
            fprintf(stderr, "patched property '%s' returned '%s', expected '%s'\n",
                    name, got, want);
            failures++;
        }
        mpv_free(got);
    }

    mpv_terminate_destroy(ctx);
    dlclose(h);
    return failures ? 1 : 0;
}
