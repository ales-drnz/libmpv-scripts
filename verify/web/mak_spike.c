/* Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
 *
 * mak_spike.c: the W1 harness of the web build, a libmpv client in C.
 *
 * Built two ways from this one file:
 * - web: linked into spike.mjs by build_libmpv_web.sh with PROXY_TO_PTHREAD,
 *   so main() runs on a pthread and may block in mpv_wait_event; the runner
 *   (run_node.mjs, harness.html) writes the inputs into WasmFS and calls
 *   main;
 * - native: run_native.sh builds it against a released libmpv, for the
 *   decode times to compare with.
 *
 *   mak_spike [-n loops] [-x step]... [-l long_file]... file...
 *
 * -x skips a step: af, analysis or pcm (to see what a number comes from).
 * -a replaces the af chain (default AF_CHAIN below).
 * Every loop creates a core, runs the checks and destroys it. The long files
 * are timed in the first loop only: plain, then through a three filter lavfi
 * chain. Each check prints "ok <name> ..." or "FAIL <name> ...", each measure
 * "measure <key> <value>", and the last line is "RESULT pass=<n> fail=<n>".
 * The exit status is 1 when a check failed.
 */
#include <inttypes.h>
#include <malloc.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <mpv/client.h>

#ifdef __EMSCRIPTEN__
#include <emscripten/heap.h>
#else
#include <sys/resource.h>
#endif

/* The live PCM API of patch_pcm_stream.py (mak_pcm.h is not installed). */
int64_t mak_pcm_create(int64_t capacity_bytes);
int64_t mak_pcm_write(int64_t id, const uint8_t *data, int64_t len);
int mak_pcm_finish(int64_t id);
int mak_pcm_release(int64_t id);

#define AF_CHAIN "lavfi=[equalizer=f=1000:t=q:w=1:g=3],lavfi=[afftdn],lavfi=[loudnorm]"
static const char *g_af = AF_CHAIN;

static int g_pass, g_fail;

static void check(int cond, const char *name, const char *fmt, ...)
{
    printf("%s %s", cond ? "ok" : "FAIL", name);
    if (fmt && fmt[0]) {
        va_list ap;
        va_start(ap, fmt);
        putchar(' ');
        vprintf(fmt, ap);
        va_end(ap);
    }
    putchar('\n');
    fflush(stdout);
    if (cond)
        g_pass++;
    else
        g_fail++;
}

static void measure(const char *key, double v)
{
    printf("measure %s %.3f\n", key, v);
    fflush(stdout);
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

/* Bytes the allocator hands out right now, and the size of the heap. */
static double heap_in_use(void)
{
#if defined(__GLIBC__)
    return (double)mallinfo2().uordblks;
#else
    return (double)mallinfo().uordblks;
#endif
}

static double heap_size(void)
{
#ifdef __EMSCRIPTEN__
    return (double)emscripten_get_heap_size();
#else
    return 0;
#endif
}

/* The most memory the process held: dlmalloc's max footprint on the web
 * (thread stacks included, they come from malloc), the peak RSS natively. */
static double peak_memory(void)
{
#ifdef __EMSCRIPTEN__
    return (double)mallinfo().usmblks;
#else
    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    return ru.ru_maxrss * 1024.0;
#endif
}

struct run {
    mpv_handle *h;
    int hooks;          /* on_load hooks seen and continued */
    char hook_file[256];
    int file_loaded;
    int got_end;
    int end_reason, end_error;
    int logs;
    int prop_changes;
    double duration_seen; /* last value of the observed duration */
    /* The first audio-params of the entry with a sample rate (observed:
     * mpv sets them when the decoder has output, after FILE_LOADED). */
    int64_t ap_rate, ap_chans;
    char ap_format[32];
};

static mpv_node *node_get(mpv_node *map, const char *key);

static void on_event(struct run *r, mpv_event *ev)
{
    switch (ev->event_id) {
    case MPV_EVENT_HOOK: {
        mpv_event_hook *hk = ev->data;
        if (strcmp(hk->name, "on_load") == 0) {
            char *f = mpv_get_property_string(r->h, "stream-open-filename");
            snprintf(r->hook_file, sizeof(r->hook_file), "%s", f ? f : "");
            mpv_free(f);
            r->hooks++;
        }
        mpv_hook_continue(r->h, hk->id);
        break;
    }
    case MPV_EVENT_FILE_LOADED:
        r->file_loaded = 1;
        break;
    case MPV_EVENT_END_FILE: {
        mpv_event_end_file *ef = ev->data;
        r->end_reason = ef->reason;
        r->end_error = ef->error;
        r->got_end = 1;
        break;
    }
    case MPV_EVENT_LOG_MESSAGE: {
        mpv_event_log_message *m = ev->data;
        if (++r->logs <= 30)
            printf("log [%s] %s: %s", m->level, m->prefix, m->text);
        break;
    }
    case MPV_EVENT_PROPERTY_CHANGE: {
        mpv_event_property *p = ev->data;
        r->prop_changes++;
        if (strcmp(p->name, "duration") == 0 && p->format == MPV_FORMAT_DOUBLE)
            r->duration_seen = *(double *)p->data;
        if (strcmp(p->name, "audio-params") == 0 && p->format == MPV_FORMAT_NODE &&
            r->ap_rate == 0) {
            mpv_node *n, *ap = p->data;
            if ((n = node_get(ap, "samplerate")) && n->format == MPV_FORMAT_INT64)
                r->ap_rate = n->u.int64;
            if ((n = node_get(ap, "channel-count")) && n->format == MPV_FORMAT_INT64)
                r->ap_chans = n->u.int64;
            if ((n = node_get(ap, "format")) && n->format == MPV_FORMAT_STRING)
                snprintf(r->ap_format, sizeof(r->ap_format), "%s", n->u.string);
        }
        break;
    }
    default:
        break;
    }
}

/* Dispatches events until pred(r) holds or timeout_ms passes. */
static int pump_until(struct run *r, int (*pred)(struct run *), double timeout_ms)
{
    double t0 = now_ms();
    while (!pred(r)) {
        double left = timeout_ms - (now_ms() - t0);
        if (left <= 0)
            return 0;
        mpv_event *ev = mpv_wait_event(r->h, left > 200 ? 0.2 : left / 1e3);
        if (ev->event_id != MPV_EVENT_NONE)
            on_event(r, ev);
    }
    return 1;
}

static int is_loaded(struct run *r) { return r->file_loaded || r->got_end; }
static int is_ended(struct run *r) { return r->got_end; }

static void reset_entry(struct run *r)
{
    r->file_loaded = r->got_end = 0;
    r->end_reason = r->end_error = -1;
    r->ap_rate = r->ap_chans = 0;
    r->ap_format[0] = '\0';
}

static int cmd(mpv_handle *h, const char **args)
{
    int err = mpv_command(h, args);
    if (err < 0)
        printf("command %s: %s\n", args[0], mpv_error_string(err));
    return err;
}

/* A node map lookup; NULL when absent. */
static mpv_node *node_get(mpv_node *map, const char *key)
{
    if (map->format != MPV_FORMAT_NODE_MAP)
        return NULL;
    for (int i = 0; i < map->u.list->num; i++)
        if (strcmp(map->u.list->keys[i], key) == 0)
            return &map->u.list->values[i];
    return NULL;
}

static const char *base_name(const char *p)
{
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

/* Loads path and decodes it to the end with ao=null; checks the hook, the
 * reason and the properties read at FILE_LOADED. Returns the wall time from
 * the loadfile command to END_FILE, or -1. */
static double decode_file(struct run *r, const char *path, const char *tag,
                          int check_props)
{
    char name[300];
    reset_entry(r);
    int hooks0 = r->hooks;
    double t0 = now_ms();
    const char *args[] = {"loadfile", path, NULL};
    if (cmd(r->h, args) < 0) {
        check(0, tag, "loadfile %s", path);
        return -1;
    }
    if (!pump_until(r, is_loaded, 20000)) {
        check(0, tag, "no FILE_LOADED for %s", path);
        return -1;
    }
    double dur = 0;
    char codec[64] = "?", fmt[64] = "?";
    int e1 = -1;
    if (check_props && r->file_loaded) {
        e1 = mpv_get_property(r->h, "duration", MPV_FORMAT_DOUBLE, &dur);
        char *c = mpv_get_property_string(r->h, "audio-codec-name");
        char *f = mpv_get_property_string(r->h, "file-format");
        snprintf(codec, sizeof(codec), "%s", c ? c : "?");
        snprintf(fmt, sizeof(fmt), "%s", f ? f : "?");
        mpv_free(c);
        mpv_free(f);
    }
    if (!pump_until(r, is_ended, 120000)) {
        check(0, tag, "no END_FILE for %s", path);
        return -1;
    }
    double ms = now_ms() - t0;
    if (check_props) {
        snprintf(name, sizeof(name), "%s.props", tag);
        check(e1 >= 0 && dur > 0 && r->ap_rate > 0 && r->ap_chans > 0, name,
              "%s duration=%.3f codec=%s format=%s audio-params=%" PRId64 "Hz/%" PRId64 "ch/%s",
              base_name(path), dur, codec, fmt, r->ap_rate, r->ap_chans, r->ap_format);
    }
    snprintf(name, sizeof(name), "%s.eof", tag);
    check(r->end_reason == MPV_END_FILE_REASON_EOF, name, "%s reason=%d error=%s in %.1f ms",
          base_name(path), r->end_reason,
          r->end_error < 0 ? mpv_error_string(r->end_error) : "none", ms);
    snprintf(name, sizeof(name), "%s.hook", tag);
    check(r->hooks == hooks0 + 1 && strcmp(r->hook_file, path) == 0, name,
          "on_load %d time(s), stream-open-filename=%s", r->hooks - hooks0, r->hook_file);
    return r->end_reason == MPV_END_FILE_REASON_EOF ? ms : -1;
}

/* Polls a node property until its "state" reads `want` (or timeout). */
static int poll_state(struct run *r, const char *prop, const char *want,
                      double timeout_ms, mpv_node *out)
{
    double t0 = now_ms();
    while (now_ms() - t0 < timeout_ms) {
        mpv_node n;
        if (mpv_get_property(r->h, prop, MPV_FORMAT_NODE, &n) >= 0) {
            mpv_node *s = node_get(&n, "state");
            if (s && s->format == MPV_FORMAT_STRING && strcmp(s->u.string, want) == 0) {
                *out = n;
                return 1;
            }
            mpv_free_node_contents(&n);
        }
        mpv_event *ev = mpv_wait_event(r->h, 0.02);
        if (ev->event_id != MPV_EVENT_NONE)
            on_event(r, ev);
    }
    return 0;
}

/* The bulk waveform and the loudness scan of patch_bulk_analysis.py and
 * patch_loudness_scan.py on one paused file: a coordinator and up to four
 * decode workers, each a pthread of its own. */
static void check_analysis(struct run *r, const char *path)
{
    mpv_set_property_string(r->h, "pause", "yes");
    mpv_set_property_string(r->h, "waveform-enabled", "yes");
    mpv_set_property_string(r->h, "loudness-scan-enabled", "yes");
    reset_entry(r);
    double t0 = now_ms();
    const char *args[] = {"loadfile", path, NULL};
    cmd(r->h, args);
    if (!pump_until(r, is_loaded, 20000) || !r->file_loaded) {
        check(0, "waveform", "no FILE_LOADED for %s", path);
        return;
    }
    mpv_node n;
    if (poll_state(r, "waveform-data", "ready", 20000, &n)) {
        mpv_node *mx = node_get(&n, "max");
        mpv_node *tb = node_get(&n, "total_bins");
        int64_t bins = mx && mx->format == MPV_FORMAT_BYTE_ARRAY ? (int64_t)(mx->u.ba->size / sizeof(float)) : 0;
        float peak = 0;
        for (int64_t i = 0; i < bins; i++)
            peak = fmaxf(peak, ((float *)mx->u.ba->data)[i]);
        check(bins > 0 && peak > 0.01f, "waveform", "%s ready in %.1f ms, %" PRId64 " bins (total_bins %" PRId64 "), peak %.3f",
              base_name(path), now_ms() - t0, bins,
              tb && tb->format == MPV_FORMAT_INT64 ? tb->u.int64 : -1, peak);
        mpv_free_node_contents(&n);
    } else {
        check(0, "waveform", "%s never ready", base_name(path));
    }
    if (poll_state(r, "loudness-scan-data", "ready", 20000, &n)) {
        mpv_node *i = node_get(&n, "integrated_lufs");
        mpv_node *tp = node_get(&n, "true_peak");
        double lufs = i && i->format == MPV_FORMAT_DOUBLE ? i->u.double_ : NAN;
        check(isfinite(lufs) && lufs < 0, "loudness-scan", "%s integrated %.2f LUFS, true peak %.3f",
              base_name(path), lufs, tp && tp->format == MPV_FORMAT_DOUBLE ? tp->u.double_ : NAN);
        mpv_free_node_contents(&n);
    } else {
        check(0, "loudness-scan", "%s never ready", base_name(path));
    }
    char *aos = mpv_get_property_string(r->h, "audio-output-state");
    check(aos != NULL, "audio-output-state", "%s", aos ? aos : "(unavailable)");
    mpv_free(aos);
    const char *stop[] = {"stop", NULL};
    cmd(r->h, stop);
    pump_until(r, is_ended, 5000);
    mpv_set_property_string(r->h, "waveform-enabled", "no");
    mpv_set_property_string(r->h, "loudness-scan-enabled", "no");
    mpv_set_property_string(r->h, "pause", "no");
}

/* Two seconds of a 440 Hz tone through mak-pcm://, as PcmSource plays it. */
static void check_pcm(struct run *r)
{
    const int rate = 48000, chans = 2, frames = rate * 2;
    int16_t *buf = malloc((size_t)frames * chans * sizeof(int16_t));
    for (int i = 0; i < frames; i++)
        for (int c = 0; c < chans; c++)
            buf[i * chans + c] = (int16_t)(8000 * sin(2 * M_PI * 440 * i / rate));
    int64_t id = mak_pcm_create(0);
    int64_t len = (int64_t)frames * chans * sizeof(int16_t);
    int64_t wrote = id > 0 ? mak_pcm_write(id, (const uint8_t *)buf, len) : -1;
    free(buf);
    mak_pcm_finish(id);
    char url[64];
    snprintf(url, sizeof(url), "mak-pcm://%" PRId64, id);
    reset_entry(r);
    int hooks0 = r->hooks;
    const char *args[] = {"loadfile", url, "replace", "-1",
        "demuxer=rawaudio,demuxer-rawaudio-format=s16le,demuxer-rawaudio-rate=48000,"
        "demuxer-rawaudio-channels=2,cache-pause=no,demuxer-termination-timeout=0,"
        "demuxer-seekable-cache=no,gapless-audio=no", NULL};
    double t0 = now_ms();
    cmd(r->h, args);
    int ended = pump_until(r, is_ended, 20000);
    check(id > 0 && wrote == len && ended && r->end_reason == MPV_END_FILE_REASON_EOF &&
          r->hooks == hooks0 + 1, "pcm-stream",
          "id %" PRId64 ", %" PRId64 " of %" PRId64 " bytes, reason=%d in %.1f ms",
          id, wrote, len, r->end_reason, now_ms() - t0);
    mak_pcm_release(id);
}

static mpv_handle *make_core(double *init_ms)
{
    double t0 = now_ms();
    mpv_handle *h = mpv_create();
    if (!h)
        return NULL;
    mpv_set_option_string(h, "ao", "null");
    mpv_set_option_string(h, "ao-null-untimed", "yes");
    mpv_set_option_string(h, "vid", "no");
    mpv_set_option_string(h, "audio-display", "no");
    mpv_set_option_string(h, "idle", "yes");
    mpv_set_option_string(h, "config", "no");
    int err = mpv_initialize(h);
    *init_ms = now_ms() - t0;
    if (err < 0) {
        printf("mpv_initialize: %s\n", mpv_error_string(err));
        mpv_terminate_destroy(h);
        return NULL;
    }
    return h;
}

int main(int argc, char **argv)
{
    int loops = 1;
    const char *longs[8];
    int nlong = 0;
    const char *files[32];
    int nfiles = 0;
    int skip_af = 0, skip_analysis = 0, skip_pcm = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-n") == 0 && i + 1 < argc)
            loops = atoi(argv[++i]);
        else if (strcmp(argv[i], "-x") == 0 && i + 1 < argc) {
            const char *x = argv[++i];
            skip_af |= strcmp(x, "af") == 0;
            skip_analysis |= strcmp(x, "analysis") == 0;
            skip_pcm |= strcmp(x, "pcm") == 0;
        } else if (strcmp(argv[i], "-a") == 0 && i + 1 < argc) {
            g_af = argv[++i];
        } else if (strcmp(argv[i], "-l") == 0 && i + 1 < argc && nlong < 8)
            longs[nlong++] = argv[++i];
        else if (nfiles < 32)
            files[nfiles++] = argv[i];
    }
    printf("spike: %d loop(s), %d file(s), %d long file(s)\n", loops, nfiles, nlong);

    double in_use_after[64] = {0};
    for (int loop = 0; loop < loops && loop < 64; loop++) {
        double t_loop = now_ms(), init_ms = 0;
        struct run r = {0};
        r.h = make_core(&init_ms);
        if (!r.h) {
            check(0, "create", "loop %d", loop);
            break;
        }
        if (loop == 0) {
            measure("mpv_create_initialize_ms", init_ms);
            char *v = mpv_get_property_string(r.h, "mpv-version");
            char *fv = mpv_get_property_string(r.h, "ffmpeg-version");
            check(v && strncmp(v, "mpv v0.41.0", 11) == 0, "mpv-version", "%s, ffmpeg %s",
                  v ? v : "?", fv ? fv : "?");
            mpv_free(v);
            mpv_free(fv);
        }
        mpv_request_log_messages(r.h, "warn");
        mpv_observe_property(r.h, 1, "duration", MPV_FORMAT_DOUBLE);
        mpv_observe_property(r.h, 3, "audio-params", MPV_FORMAT_NODE);
        mpv_hook_add(r.h, 2, "on_load", 0);

        for (int i = 0; i < nfiles; i++)
            decode_file(&r, files[i], "decode", 1);
        check(r.duration_seen > 0 && r.prop_changes > 0, "observe",
              "%d property changes, last duration %.3f", r.prop_changes, r.duration_seen);

        /* The af chain on the first file, read back from the property. */
        if (nfiles > 0 && !skip_af) {
            mpv_set_property_string(r.h, "af", g_af);
            char *af = mpv_get_property_string(r.h, "af");
            double ms = decode_file(&r, files[0], "af", 0);
            char *af_after = mpv_get_property_string(r.h, "af");
            check(ms > 0 && af && af[0] && af_after && strcmp(af, af_after) == 0,
                  "af-chain", "%s", af_after ? af_after : "?");
            mpv_free(af);
            mpv_free(af_after);
            mpv_set_property_string(r.h, "af", "");
        }
        if (nfiles > 0 && !skip_analysis)
            check_analysis(&r, files[0]);
        if (!skip_pcm)
            check_pcm(&r);

        if (loop == 0) {
            for (int i = 0; i < nlong; i++) {
                const char *b = base_name(longs[i]);
                char key[128];
                double ms = decode_file(&r, longs[i], "long", 0);
                /* The observer keeps the last duration that was available:
                 * the one of the file that just ended. */
                double dur = r.duration_seen;
                snprintf(key, sizeof(key), "duration_s.%s", b);
                measure(key, dur);
                snprintf(key, sizeof(key), "decode_ms.%s", b);
                measure(key, ms);
                snprintf(key, sizeof(key), "realtime_x.%s", b);
                measure(key, ms > 0 ? dur * 1e3 / ms : 0);

                if (skip_af)
                    continue;
                mpv_set_property_string(r.h, "af", g_af);
                double fms = decode_file(&r, longs[i], "long-af", 0);
                mpv_set_property_string(r.h, "af", "");
                snprintf(key, sizeof(key), "decode_af_ms.%s", b);
                measure(key, fms);
                snprintf(key, sizeof(key), "realtime_af_x.%s", b);
                measure(key, fms > 0 ? dur * 1e3 / fms : 0);
            }
        }

        double t_destroy = now_ms();
        mpv_terminate_destroy(r.h);
        double destroy_ms = now_ms() - t_destroy;
        in_use_after[loop] = heap_in_use();
        printf("loop %d: %.1f ms, init %.1f ms, destroy %.1f ms, logs %d, heap in use %.0f, heap size %.0f\n",
               loop, now_ms() - t_loop, init_ms, destroy_ms, r.logs, in_use_after[loop], heap_size());
        fflush(stdout);
        if (loop == 0)
            measure("terminate_destroy_ms", destroy_ms);
    }
    if (loops >= 3) {
        /* Loop 0 warms caches and pools; compare the second loop with the
         * last one. Natively glibc's mallinfo2 sees the main arena only, so
         * there it is a number, not a check. */
        double a = in_use_after[1], b = in_use_after[loops - 1];
#ifdef __EMSCRIPTEN__
        check(b <= a * 1.10, "memory", "in use after loop 1 %.0f, after loop %d %.0f (%+.1f%%)",
              a, loops - 1, b, a > 0 ? (b - a) * 100 / a : 0);
#else
        printf("memory (main arena only) in use after loop 1 %.0f, after loop %d %.0f\n",
               a, loops - 1, b);
#endif
    }
    measure("heap_size_end", heap_size());
    measure("peak_memory_bytes", peak_memory());
    printf("RESULT pass=%d fail=%d\n", g_pass, g_fail);
    fflush(stdout);
#ifdef __EMSCRIPTEN__
    /* The lines of this pthread reach the page through the main thread;
     * without a pause the runtime exits before the last ones arrive. */
    usleep(300 * 1000);
#endif
    return g_fail ? 1 : 0;
}
