/*
 * Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
 */

/* audio_fallback_test.c — run-time check of the Linux library on a system
 * without PipeWire and PulseAudio (the verify-linux-runtime CI job runs it in
 * a bare debian:11 container with only libasound2).
 *
 * libmpv links both AOs through lazily bound Implib.so stubs, and a stub
 * called without its library aborts the process. This harness walks every
 * path that could reach one:
 *   1. dlopen(RTLD_NOW) + mpv_create + mpv_initialize;
 *   2. reads audio-device-list, which runs each AO's hotplug_init / list_devs;
 *   3. plays a short generated WAV with ao=pipewire,pulse,alsa,null, so the
 *      PipeWire and PulseAudio init are tried first and must fall through.
 * A crash or abort kills the process, which the caller sees as a non-zero
 * exit. Exit code is 0 on success, 1 on any failure.
 *
 * Usage: audio_fallback_test <path-to-libmpv.so> <scratch-wav-path>
 * Build: gcc audio_fallback_test.c -o audio_fallback_test -ldl
 */

#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Minimal libmpv client API surface, resolved via dlsym (see dlopen_test.c). */
typedef struct mpv_handle mpv_handle;
typedef struct {
    int event_id;
    int error;
    uint64_t reply_userdata;
    void *data;
} mpv_event;
typedef struct {
    int reason;
    int error;
} mpv_event_end_file;

enum { EV_NONE = 0, EV_SHUTDOWN = 1, EV_END_FILE = 7, EV_FILE_LOADED = 8 };
enum { END_EOF = 0, END_ERROR = 4 };

static void write_le(FILE *f, uint32_t v, int bytes)
{
    for (int i = 0; i < bytes; i++)
        fputc((v >> (8 * i)) & 0xff, f);
}

/* 0.5 s of a 440 Hz sine, 48 kHz stereo s16. */
static int write_wav(const char *path)
{
    const uint32_t rate = 48000, frames = rate / 2, channels = 2;
    const uint32_t data_bytes = frames * channels * 2;
    FILE *f = fopen(path, "wb");
    if (!f)
        return -1;
    fwrite("RIFF", 1, 4, f); write_le(f, 36 + data_bytes, 4);
    fwrite("WAVEfmt ", 1, 8, f); write_le(f, 16, 4);
    write_le(f, 1, 2); write_le(f, channels, 2); write_le(f, rate, 4);
    write_le(f, rate * channels * 2, 4); write_le(f, channels * 2, 2);
    write_le(f, 16, 2);
    fwrite("data", 1, 4, f); write_le(f, data_bytes, 4);
    for (uint32_t i = 0; i < frames; i++) {
        int16_t s = (int16_t)(8000 * sin(2 * M_PI * 440 * i / rate));
        for (uint32_t c = 0; c < channels; c++)
            write_le(f, (uint16_t)s, 2);
    }
    return fclose(f);
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s <library> <scratch-wav>\n", argv[0]);
        return 1;
    }
    if (write_wav(argv[2]) != 0) {
        fprintf(stderr, "cannot write %s\n", argv[2]);
        return 1;
    }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) {
        fprintf(stderr, "dlopen FAILED: %s\n", dlerror());
        return 1;
    }

    mpv_handle *(*create)(void) = (mpv_handle *(*)(void))dlsym(h, "mpv_create");
    int (*initialize)(mpv_handle *) = (int (*)(mpv_handle *))dlsym(h, "mpv_initialize");
    int (*set_option_string)(mpv_handle *, const char *, const char *) =
        (int (*)(mpv_handle *, const char *, const char *))dlsym(h, "mpv_set_option_string");
    char *(*get_property_string)(mpv_handle *, const char *) =
        (char *(*)(mpv_handle *, const char *))dlsym(h, "mpv_get_property_string");
    int (*command)(mpv_handle *, const char **) =
        (int (*)(mpv_handle *, const char **))dlsym(h, "mpv_command");
    mpv_event *(*wait_event)(mpv_handle *, double) =
        (mpv_event *(*)(mpv_handle *, double))dlsym(h, "mpv_wait_event");
    void (*mpv_free)(void *) = (void (*)(void *))dlsym(h, "mpv_free");
    void (*terminate_destroy)(mpv_handle *) =
        (void (*)(mpv_handle *))dlsym(h, "mpv_terminate_destroy");
    if (!create || !initialize || !set_option_string || !get_property_string ||
        !command || !wait_event || !mpv_free || !terminate_destroy) {
        fprintf(stderr, "dlsym FAILED: a core mpv_* symbol is missing\n");
        return 1;
    }

    mpv_handle *ctx = create();
    if (!ctx) {
        fprintf(stderr, "mpv_create() returned NULL\n");
        return 1;
    }
    set_option_string(ctx, "config", "no");
    set_option_string(ctx, "terminal", "yes");
    set_option_string(ctx, "msg-level", "all=warn,ao=v");
    set_option_string(ctx, "video", "no");
    set_option_string(ctx, "ao", "pipewire,pulse,alsa,null");
    if (initialize(ctx) < 0) {
        fprintf(stderr, "mpv_initialize() FAILED\n");
        return 1;
    }

    char *devices = get_property_string(ctx, "audio-device-list");
    if (!devices) {
        fprintf(stderr, "audio-device-list unavailable\n");
        return 1;
    }
    printf("audio-device-list: %s\n", devices);
    mpv_free(devices);

    const char *cmd[] = {"loadfile", argv[2], NULL};
    if (command(ctx, cmd) < 0) {
        fprintf(stderr, "loadfile FAILED\n");
        return 1;
    }

    /* 0.5 s of audio: 30 s without an end-file is a hang. */
    int failures = 1;
    for (int waited = 0; waited < 300; ) {
        mpv_event *ev = wait_event(ctx, 0.1);
        if (ev->event_id == EV_NONE) {
            waited++;
            continue;
        }
        if (ev->event_id == EV_FILE_LOADED) {
            char *ao = get_property_string(ctx, "current-ao");
            printf("current-ao: %s\n", ao ? ao : "(none)");
            if (ao)
                mpv_free(ao);
        } else if (ev->event_id == EV_END_FILE) {
            mpv_event_end_file *ef = ev->data;
            if (ef->reason == END_EOF) {
                failures = 0;
            } else {
                fprintf(stderr, "playback ended with reason %d, error %d\n",
                        ef->reason, ef->error);
            }
            break;
        } else if (ev->event_id == EV_SHUTDOWN) {
            fprintf(stderr, "core shut down during playback\n");
            break;
        }
    }
    if (failures)
        fprintf(stderr, "no clean end of playback\n");

    terminate_destroy(ctx);
    return failures;
}
