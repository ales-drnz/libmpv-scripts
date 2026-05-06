/*
 * Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
 */

/* winload_test.c — Layer 14 (load + behavioural test) helper for Windows
 * DLLs.
 *
 * Compiled with the cross-mingw toolchain in the build container, then run
 * via Wine inside the same container. LoadLibraryW is the Win32 equivalent
 * of dlopen(RTLD_NOW): the loader resolves every imported symbol up-front
 * against the DLL's IAT (Import Address Table), so a missing symbol or a
 * missing system DLL trips the load and we get GetLastError() back.
 *
 * Beyond the load test it creates an mpv handle, initialises it headless
 * (null audio, no video), and reads back two of our PATCHED observable
 * properties — proving the patched property getters RUN under Wine and
 * return the right value, not merely that their strings are compiled in.
 * A vanilla / mis-patched DLL returns NULL for these and fails here.
 *
 * Usage: winload_test.exe <path-to-libmpv.dll>
 *
 * Cross-compile: x86_64-w64-mingw32-gcc winload_test.c -o winload_test.exe
 * Run:           wine64 winload_test.exe libmpv_windows-x86_64.dll
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>

/* Minimal libmpv client API surface, resolved via GetProcAddress so this
 * harness needs no mpv headers and no import-library dependency. mpv uses
 * the C calling convention (cdecl) on Windows. */
typedef struct mpv_handle mpv_handle;
typedef mpv_handle *(__cdecl *fn_create)(void);
typedef int   (__cdecl *fn_initialize)(mpv_handle *);
typedef int   (__cdecl *fn_set_option_string)(mpv_handle *, const char *, const char *);
typedef char *(__cdecl *fn_get_property_string)(mpv_handle *, const char *);
typedef void  (__cdecl *fn_free)(void *);
typedef void  (__cdecl *fn_terminate_destroy)(mpv_handle *);

static const char *kPatchedProps[][2] = {
    {"audio-output-state", "closed"}, /* patch_audio_output_state */
    {"prefetch-state",     "idle"},   /* patch_prefetch_state     */
};

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <library.dll>\n", argv[0]);
        return 1;
    }
    HMODULE h = LoadLibraryA(argv[1]);
    if (!h) {
        DWORD err = GetLastError();
        fprintf(stderr, "LoadLibrary FAILED: error 0x%08lx\n", (unsigned long)err);
        return 1;
    }

    fn_create              mpv_create              = (fn_create)             GetProcAddress(h, "mpv_create");
    fn_initialize          mpv_initialize          = (fn_initialize)         GetProcAddress(h, "mpv_initialize");
    fn_set_option_string   mpv_set_option_string   = (fn_set_option_string)  GetProcAddress(h, "mpv_set_option_string");
    fn_get_property_string mpv_get_property_string = (fn_get_property_string)GetProcAddress(h, "mpv_get_property_string");
    fn_free                mpv_free                = (fn_free)               GetProcAddress(h, "mpv_free");
    fn_terminate_destroy   mpv_terminate_destroy   = (fn_terminate_destroy)  GetProcAddress(h, "mpv_terminate_destroy");

    if (!mpv_create || !mpv_initialize || !mpv_set_option_string ||
        !mpv_get_property_string || !mpv_free || !mpv_terminate_destroy) {
        fprintf(stderr, "GetProcAddress FAILED: a core mpv_* symbol is missing\n");
        FreeLibrary(h);
        return 1;
    }

    mpv_handle *ctx = mpv_create();
    if (!ctx) {
        fprintf(stderr, "mpv_create() returned NULL\n");
        FreeLibrary(h);
        return 1;
    }

    /* Headless: no config, no terminal, null audio out, no video. */
    mpv_set_option_string(ctx, "config", "no");
    mpv_set_option_string(ctx, "terminal", "no");
    mpv_set_option_string(ctx, "ao", "null");
    mpv_set_option_string(ctx, "video", "no");
    mpv_set_option_string(ctx, "msg-level", "all=no");

    int rc = mpv_initialize(ctx);
    if (rc < 0) {
        fprintf(stderr, "mpv_initialize() FAILED: rc=%d\n", rc);
        mpv_terminate_destroy(ctx);
        FreeLibrary(h);
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
    FreeLibrary(h);
    return failures ? 1 : 0;
}
