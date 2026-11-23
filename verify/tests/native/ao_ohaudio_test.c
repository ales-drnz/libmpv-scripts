// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// ao_ohaudio_test <mode>: white-box test of audio/out/ao_ohaudio.c, which
// run.sh adds to pristine mpv with patches/mpv/ohos/patch_ao_ohaudio.py.
// The OHAudio calls go to a simulated renderer that follows the client of
// OpenHarmony 7.0 (multimedia_audio_framework, renderer_in_client*.cpp)
// where the driver depends on it: the write callback runs on a thread of
// its own while the renderer runs, and the buffer it fills is queued after
// it returns, whatever happened meanwhile; INVALID drops it; Flush empties
// the queue and the stream and resets the position, without waiting for a
// callback in flight; Pause keeps what is queued; Start is refused from a
// running renderer, Pause from one that is not running, Flush from one
// never started. A device thread plays the stream at 48 kHz while it runs
// and logs each frame with the time it played it; GetTimestamp gives the
// position and time of the last frame played, only while running. Each
// source frame carries its index in the left sample, silence is 0.
// The test drives the driver as buffer.c drives a pull output: ao_read_data
// pads silence when the source underruns; a pause calls set_pause, a seek
// reset and then start.
// modes:
//   play      a second of audio, whole and in order
//   pause     pause 0.5 s and resume: no frame lost or repeated
//   seek      pause, reset, resume: nothing from before the seek
//   seekrace  30 seeks, each in the middle of a read: nothing from before
//             a seek plays after it
//   delay     the time ao_read_data is given is when the read's last frame
//             is heard, as buffer.c reads it
//   resume    the same, right after a resume from a pause
//   keep      the same after seeks, on a renderer whose Flush keeps the
//             position (one that does not count from 0 again)
//   route     the same after the position goes back to 0 (a route change)
//   fast      the device's clock runs 2% fast: the delay stays right
//   slow      the device's clock runs 2% slow: the delay stays right
//   interrupt the system pauses the stream, then ends the interruption:
//             it plays again, nothing lost, the delay right from the resume
//   stop      the system stops the stream and never resumes it: the next
//             pause and resume of the player plays again
//   shared    a shared interruption: the stream keeps playing
//   error     an error callback: one reload is asked
//   dead      the callbacks stop: one reload is asked
//   nostart   Start fails: one reload is asked
//   release   uninit while a read is in flight: no read starts after it
//   clock     20 hours at 192 kHz without a pause: the frames heard are
//             the clock's
//   stale     a timestamp from before the last start does not set the
//             clock, a newer one does
//   format    the formats and layouts the device is opened with
#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "audio/out/ao_ohaudio.c"
// mt_wait_until, the ceiling of the time rule.
#include "mpv_test.h"

#define RATE 48000
#define FRAME (RATE / 50)        // a callback asks for 20 ms
#define CAP (RATE / 10)          // the server holds 100 ms
#define PLAYED_MAX (RATE * 20)
#define READS_MAX 4096

static int failures;

static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s ", ok ? "ok  " : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    fflush(stdout);
    failures += !ok;
}

static double now_s(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void sleep_ms(int ms) { usleep(ms * 1000); }

// ── simulated OHAudio ──────────────────────────────────────────────────

enum { SIM_NEW, SIM_PREPARED, SIM_RUNNING, SIM_STOPPED, SIM_RELEASED, SIM_PAUSED };

struct OH_AudioStreamBuilderStruct {
    int rate, channels, format, usage, latency;
    OH_AudioRenderer_Callbacks callbacks;
    OH_AudioRenderer_OnWriteDataCallback write;
    OH_AudioRenderer_OutputDeviceChangeCallback device;
    void *user;
};

struct OH_AudioRendererStruct {
    struct OH_AudioStreamBuilderStruct b;
    int state;
    int64_t fifo[CAP];
    int head, len;
    int64_t position, ts;       // the last frame played, since the flush
    pthread_t cb_thread;
    bool cb_running;            // between the callback's call and return
};

static pthread_mutex_t sim_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sim_cond = PTHREAD_COND_INITIALIZER;
static struct OH_AudioRendererStruct *sim;
static int64_t played[PLAYED_MAX];
static int64_t played_ns[PLAYED_MAX];
static int nplayed;
static atomic_int reads, bad_calls, reloads, reads_after_uninit, invalid;
static atomic_bool uninit_started;
static atomic_int dev_calls;            // Start, Pause, Flush, Stop at once
static atomic_bool device_quit, callbacks_stop, start_fails;
static atomic_bool flush_keeps_position;
static double device_speed = 1.0;
// seekrace, release: a read takes this long, so a reset can come in the
// middle.
static atomic_int read_lag_ms;

static int bytes_of(int format)
{
    return format == AUDIOSTREAM_SAMPLE_S16LE ? 2 : 4;
}

static void *device_thread(void *arg)
{
    (void)arg;
    double last = now_s(), budget = 0;
    while (!atomic_load(&device_quit)) {
        sleep_ms(1);
        double t = now_s();
        budget += (t - last) * RATE * device_speed;
        last = t;
        int n = (int)budget;
        budget -= n;
        int64_t ns = mp_time_ns();
        pthread_mutex_lock(&sim_lock);
        if (sim && sim->state == SIM_RUNNING) {
            int take = MPMIN(n, sim->len);
            for (int k = 0; k < take; k++) {
                if (nplayed < PLAYED_MAX) {
                    played[nplayed] = sim->fifo[sim->head];
                    played_ns[nplayed++] = ns;
                }
                sim->head = (sim->head + 1) % CAP;
                sim->position++;
            }
            sim->len -= take;
            if (take)
                sim->ts = ns;
        }
        pthread_cond_broadcast(&sim_cond);
        pthread_mutex_unlock(&sim_lock);
    }
    return NULL;
}

// The client's callback loop: while running and the server has room for a
// buffer, the callback fills one, and it is queued after the callback
// returns, whatever the state is then; INVALID drops it.
static void *callback_thread(void *arg)
{
    OH_AudioRenderer *r = arg;
    int stride = bytes_of(r->b.format) * r->b.channels;
    char *buf = malloc(FRAME * stride);
    pthread_mutex_lock(&sim_lock);
    while (r->state != SIM_RELEASED) {
        if (r->state != SIM_RUNNING || CAP - r->len < FRAME ||
            atomic_load(&callbacks_stop)) {
            struct timespec until;
            clock_gettime(CLOCK_REALTIME, &until);
            until.tv_nsec += 2000000;
            if (until.tv_nsec >= 1000000000) {
                until.tv_sec++;
                until.tv_nsec -= 1000000000;
            }
            pthread_cond_timedwait(&sim_cond, &sim_lock, &until);
            continue;
        }
        r->cb_running = true;
        pthread_mutex_unlock(&sim_lock);
        OH_AudioData_Callback_Result res = r->b.write(r, r->b.user, buf, FRAME * stride);
        pthread_mutex_lock(&sim_lock);
        r->cb_running = false;
        if (res == AUDIO_DATA_CALLBACK_RESULT_INVALID) {
            atomic_fetch_add(&invalid, 1);
            continue;
        }
        for (int k = 0; k < FRAME && r->len < CAP; k++) {
            int64_t id = r->b.format == AUDIOSTREAM_SAMPLE_S16LE
                         ? ((int16_t *)buf)[k * r->b.channels]
                         : ((int32_t *)buf)[k * r->b.channels];
            r->fifo[(r->head + r->len) % CAP] = id;
            r->len++;
        }
    }
    pthread_mutex_unlock(&sim_lock);
    free(buf);
    return NULL;
}

OH_AudioStream_Result OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder **builder, OH_AudioStream_Type type)
{
    if (type != AUDIOSTREAM_TYPE_RENDERER)
        atomic_fetch_add(&bad_calls, 1);
    *builder = calloc(1, sizeof(**builder));
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder *b)
{
    free(b);
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetSamplingRate(OH_AudioStreamBuilder *b, int32_t rate)
{
    // The renderer's rates (OHAudioStreamBuilder.cpp): the driver must not
    // ask for another.
    static const int32_t rates[] = {8000, 11025, 12000, 16000, 22050, 24000, 32000,
                                    44100, 48000, 64000, 88200, 96000, 176400, 192000};
    for (size_t i = 0; i < sizeof(rates) / sizeof(rates[0]); i++) {
        if (rates[i] == rate) {
            b->rate = rate;
            return AUDIOSTREAM_SUCCESS;
        }
    }
    atomic_fetch_add(&bad_calls, 1);
    return AUDIOSTREAM_ERROR_INVALID_PARAM;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetChannelCount(OH_AudioStreamBuilder *b, int32_t n)
{
    b->channels = n;
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetSampleFormat(OH_AudioStreamBuilder *b,
                                                            OH_AudioStream_SampleFormat f)
{
    // F32LE is API 17: the driver must not ask for it.
    if (f != AUDIOSTREAM_SAMPLE_S16LE && f != AUDIOSTREAM_SAMPLE_S32LE)
        atomic_fetch_add(&bad_calls, 1);
    b->format = f;
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetEncodingType(OH_AudioStreamBuilder *b,
                                                            OH_AudioStream_EncodingType t)
{
    (void)b;
    if (t != AUDIOSTREAM_ENCODING_TYPE_RAW)
        atomic_fetch_add(&bad_calls, 1);
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetLatencyMode(OH_AudioStreamBuilder *b,
                                                           OH_AudioStream_LatencyMode m)
{
    // A fast stream ignores Flush (FlushAudioStream returns at once).
    if (m != AUDIOSTREAM_LATENCY_MODE_NORMAL)
        atomic_fetch_add(&bad_calls, 1);
    b->latency = m;
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererInfo(OH_AudioStreamBuilder *b,
                                                            OH_AudioStream_Usage usage)
{
    b->usage = usage;
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererCallback(OH_AudioStreamBuilder *b,
                                                                OH_AudioRenderer_Callbacks cbs,
                                                                void *user)
{
    // As OHAudioStreamBuilder.cpp: the combined callbacks, and their write
    // callback until SetRendererWriteDataCallback replaces it.
    b->callbacks = cbs;
    b->write = NULL;
    b->user = user;
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererOutputDeviceChangeCallback(
    OH_AudioStreamBuilder *b, OH_AudioRenderer_OutputDeviceChangeCallback cb, void *user)
{
    b->device = cb;
    if (user != b->user)
        atomic_fetch_add(&bad_calls, 1);
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererWriteDataCallback(
    OH_AudioStreamBuilder *b, OH_AudioRenderer_OnWriteDataCallback cb, void *user)
{
    b->write = cb;
    b->user = user;
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioStreamBuilder_GenerateRenderer(OH_AudioStreamBuilder *b,
                                                             OH_AudioRenderer **out)
{
    if (b->rate < 8000 || b->rate > 192000 || b->channels < 1 || b->channels > 2 || !b->write) {
        atomic_fetch_add(&bad_calls, 1);
        return AUDIOSTREAM_ERROR_INVALID_PARAM;
    }
    OH_AudioRenderer *r = calloc(1, sizeof(*r));
    r->b = *b;
    r->state = SIM_PREPARED;
    pthread_mutex_lock(&sim_lock);
    sim = r;
    pthread_mutex_unlock(&sim_lock);
    pthread_create(&r->cb_thread, NULL, callback_thread, r);
    *out = r;
    return AUDIOSTREAM_SUCCESS;
}

// One renderer call at a time: the driver's dev_lock.
static void dev_enter(void)
{
    if (atomic_fetch_add(&dev_calls, 1))
        atomic_fetch_add(&bad_calls, 1);
}
static void dev_leave(void) { atomic_fetch_sub(&dev_calls, 1); }

OH_AudioStream_Result OH_AudioRenderer_Start(OH_AudioRenderer *r)
{
    dev_enter();
    // The server's answer takes a while.
    sleep_ms(2);
    pthread_mutex_lock(&sim_lock);
    OH_AudioStream_Result ret = AUDIOSTREAM_SUCCESS;
    if (atomic_load(&start_fails))
        ret = AUDIOSTREAM_ERROR_SYSTEM;
    else if (r->state == SIM_PREPARED || r->state == SIM_PAUSED || r->state == SIM_STOPPED)
        r->state = SIM_RUNNING;
    else
        ret = AUDIOSTREAM_ERROR_ILLEGAL_STATE;
    pthread_cond_broadcast(&sim_cond);
    pthread_mutex_unlock(&sim_lock);
    dev_leave();
    return ret;
}
OH_AudioStream_Result OH_AudioRenderer_Pause(OH_AudioRenderer *r)
{
    dev_enter();
    pthread_mutex_lock(&sim_lock);
    OH_AudioStream_Result ret = AUDIOSTREAM_SUCCESS;
    if (r->state == SIM_RUNNING)
        r->state = SIM_PAUSED;
    else
        ret = AUDIOSTREAM_ERROR_ILLEGAL_STATE;
    pthread_cond_broadcast(&sim_cond);
    pthread_mutex_unlock(&sim_lock);
    dev_leave();
    return ret;
}
OH_AudioStream_Result OH_AudioRenderer_Stop(OH_AudioRenderer *r)
{
    dev_enter();
    pthread_mutex_lock(&sim_lock);
    OH_AudioStream_Result ret = AUDIOSTREAM_SUCCESS;
    if (r->state == SIM_RUNNING || r->state == SIM_PAUSED)
        r->state = SIM_STOPPED;
    else
        ret = AUDIOSTREAM_ERROR_ILLEGAL_STATE;
    pthread_cond_broadcast(&sim_cond);
    pthread_mutex_unlock(&sim_lock);
    dev_leave();
    return ret;
}
OH_AudioStream_Result OH_AudioRenderer_Flush(OH_AudioRenderer *r)
{
    dev_enter();
    pthread_mutex_lock(&sim_lock);
    OH_AudioStream_Result ret = AUDIOSTREAM_SUCCESS;
    if (r->state == SIM_RUNNING || r->state == SIM_PAUSED || r->state == SIM_STOPPED) {
        r->len = 0;
        if (!atomic_load(&flush_keeps_position))
            r->position = 0;
    } else {
        ret = AUDIOSTREAM_ERROR_ILLEGAL_STATE;
    }
    pthread_cond_broadcast(&sim_cond);
    pthread_mutex_unlock(&sim_lock);
    dev_leave();
    return ret;
}
OH_AudioStream_Result OH_AudioRenderer_Release(OH_AudioRenderer *r)
{
    pthread_mutex_lock(&sim_lock);
    r->state = SIM_RELEASED;
    pthread_cond_broadcast(&sim_cond);
    pthread_mutex_unlock(&sim_lock);
    pthread_join(r->cb_thread, NULL);
    pthread_mutex_lock(&sim_lock);
    if (sim == r)
        sim = NULL;
    pthread_mutex_unlock(&sim_lock);
    free(r);
    return AUDIOSTREAM_SUCCESS;
}
OH_AudioStream_Result OH_AudioRenderer_GetTimestamp(OH_AudioRenderer *r, clockid_t clock,
                                                    int64_t *pos, int64_t *ts)
{
    if (clock != CLOCK_MONOTONIC)
        atomic_fetch_add(&bad_calls, 1);
    pthread_mutex_lock(&sim_lock);
    OH_AudioStream_Result ret = AUDIOSTREAM_ERROR_ILLEGAL_STATE;
    if (r->state == SIM_RUNNING && r->ts) {
        *pos = r->position;
        *ts = r->ts;
        ret = AUDIOSTREAM_SUCCESS;
    }
    pthread_mutex_unlock(&sim_lock);
    return ret;
}
OH_AudioStream_Result OH_AudioRenderer_GetUnderflowCount(OH_AudioRenderer *r, uint32_t *count)
{
    (void)r;
    *count = 0;
    return AUDIOSTREAM_SUCCESS;
}

// The system's side: what it does to the stream, then the callback.
static void system_interrupt(OH_AudioInterrupt_ForceType type, OH_AudioInterrupt_Hint hint)
{
    pthread_mutex_lock(&sim_lock);
    OH_AudioRenderer *r = sim;
    if (type == AUDIOSTREAM_INTERRUPT_FORCE && r->state == SIM_RUNNING)
        r->state = hint == AUDIOSTREAM_INTERRUPT_HINT_STOP ? SIM_STOPPED : SIM_PAUSED;
    pthread_cond_broadcast(&sim_cond);
    pthread_mutex_unlock(&sim_lock);
    r->b.callbacks.OH_AudioRenderer_OnInterruptEvent(r, r->b.user, type, hint);
}

// ── stubs of the mpv functions the driver calls ─────────────────────────

void mp_msg(struct mp_log *log, int lev, const char *format, ...)
{
    (void)log;
    if (lev > (getenv("VERBOSE") ? MSGL_V : MSGL_INFO))
        return;
    va_list ap;
    va_start(ap, format);
    printf("     [ao] ");
    vprintf(format, ap);
    va_end(ap);
}

int mp_msg_level(struct mp_log *log) { (void)log; return MSGL_V; }

void ao_request_reload(struct ao *ao)
{
    (void)ao;
    atomic_fetch_add(&reloads, 1);
}

int64_t mp_time_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * INT64_C(1000000000) + t.tv_nsec;
}

int af_fmt_to_bytes(int format)
{
    switch (format) {
    case AF_FORMAT_U8: return 1;
    case AF_FORMAT_S16: return 2;
    default: return 4;
    }
}
bool af_fmt_is_float(int format) { return format == AF_FORMAT_FLOAT; }
bool af_fmt_is_spdif(int format) { (void)format; return false; }
int af_fmt_from_planar(int format) { return format; }

void mp_chmap_sel_add_map(struct mp_chmap_sel *s, const struct mp_chmap *map)
{
    (void)s; (void)map;
}

// ao.c's choice from mono and stereo: a layout of more channels is stereo.
bool ao_chmap_sel_adjust(struct ao *ao, const struct mp_chmap_sel *s,
                         struct mp_chmap *map)
{
    (void)ao; (void)s;
    if (map->num != 1)
        *map = (struct mp_chmap)MP_CHMAP_INIT_STEREO;
    return true;
}

// The player side of buffer.c.
static atomic_llong src_next = 1;
static int64_t read_first[READS_MAX], read_out_ns[READS_MAX];

int ao_read_data(struct ao *ao, void **data, int samples, int64_t out_time_ns,
                 bool *eof, bool pad_silence, bool blocking)
{
    (void)eof; (void)pad_silence;
    if (!blocking)
        atomic_fetch_add(&bad_calls, 1);
    int n = atomic_fetch_add(&reads, 1);
    if (atomic_load(&uninit_started))
        atomic_fetch_add(&reads_after_uninit, 1);
    int32_t *f = data[0];
    int64_t id = atomic_fetch_add(&src_next, samples);
    if (n < READS_MAX) {
        read_first[n] = id;
        read_out_ns[n] = out_time_ns;
    }
    for (int pos = 0; pos < samples; pos++)
        f[pos * 2] = f[pos * 2 + 1] = (int32_t)(id + pos);
    if (atomic_load(&read_lag_ms))
        sleep_ms(atomic_load(&read_lag_ms));
    (void)ao;
    return samples;
}

// ── the test ────────────────────────────────────────────────────────────

static struct ao *open_ao(int format, int channels, int rate)
{
    struct ao *ao = talloc_zero(NULL, struct ao);
    ao->driver = &audio_out_ohaudio;
    ao->priv = talloc_zero_size(ao, sizeof(struct priv));
    ao->samplerate = rate;
    ao->format = format;
    // The stub of ao_chmap_sel_adjust reads only the count.
    ao->channels.num = channels;
    if (init(ao) < 0) {
        printf("FAIL init\n");
        exit(1);
    }
    // ao.c sets these after init, from the format the driver chose.
    ao->num_planes = 1;
    ao->sstride = af_fmt_to_bytes(ao->format) * ao->channels.num;
    return ao;
}

static void player_pause(struct ao *ao, bool paused)
{
    ao->driver->set_pause(ao, paused);
}

static void player_seek(struct ao *ao, long long next)
{
    ao->driver->reset(ao);
    atomic_store(&src_next, next);
    ao->driver->start(ao);
}

static int played_count(void)
{
    pthread_mutex_lock(&sim_lock);
    int n = nplayed;
    pthread_mutex_unlock(&sim_lock);
    return n;
}

// Source frames missing, and repeated, between consecutive frames played
// from index from on, and the first one.
static void played_gaps(int from, int64_t *first, int64_t *lost, int64_t *repeated)
{
    int64_t prev = 0;
    *first = *lost = *repeated = 0;
    pthread_mutex_lock(&sim_lock);
    for (int i = from; i < nplayed; i++) {
        int64_t id = played[i];
        if (!id)
            continue;
        if (!*first)
            *first = id;
        if (prev && id > prev + 1)
            *lost += id - prev - 1;
        if (prev && id <= prev)
            *repeated += 1;
        if (getenv("VERBOSE") && prev && id != prev + 1)
            printf("     at %d: %lld then %lld\n", i, (long long)prev, (long long)id);
        prev = id;
    }
    pthread_mutex_unlock(&sim_lock);
}

static void check_whole(int from, const char *what)
{
    int64_t first, lost, repeated;
    played_gaps(from, &first, &lost, &repeated);
    check(lost == 0 && repeated == 0, "%s: no frame lost or repeated (%lld lost, %lld repeated)",
          what, (long long)lost, (long long)repeated);
}

// When frame id was heard, 0 if it was not.
static int64_t heard_at(int64_t id)
{
    int64_t ns = 0;
    pthread_mutex_lock(&sim_lock);
    for (int i = nplayed - 1; i >= 0; i--) {
        if (played[i] == id) {
            ns = played_ns[i];
            break;
        }
    }
    pthread_mutex_unlock(&sim_lock);
    return ns;
}

// For each read whose out_time is from since_ns on, when its last frame
// was heard against the out_time the driver gave (positive: heard later).
static int delay_errors(int64_t since_ns, double *mean, double *worst)
{
    double sum = 0;
    int n = 0, nr = MPMIN(atomic_load(&reads), READS_MAX);
    *worst = 0;
    for (int i = 10; i < nr - 6; i++) {
        if (read_out_ns[i] < since_ns)
            continue;
        int64_t at = heard_at(read_first[i] + FRAME - 1);
        if (!at)
            continue;
        double err = (at - read_out_ns[i]) / 1e6;
        *worst = MPMAX(*worst, fabs(err));
        sum += err;
        n++;
    }
    *mean = n ? sum / n : 0;
    return n;
}

static void check_delay(const char *what, int64_t since, double mean_max, double worst_max)
{
    double mean, worst;
    int n = delay_errors(since, &mean, &worst);
    printf("%s: %d reads, mean error %.1f ms, worst %.1f ms\n", what, n, mean, worst);
    check(n > 20, "%s: reads measured (%d)", what, n);
    check(fabs(mean) < mean_max && worst < worst_max,
          "%s: out_time is when the read's last frame is heard (mean %.1f ms, worst %.1f ms)",
          what, mean, worst);
}

// heard_locked on a clock that ran for hours from one anchor.
static int clock_mode(void)
{
    struct ao *ao = talloc_zero(NULL, struct ao);
    struct priv *p = talloc_zero_size(ao, sizeof(struct priv));
    ao->priv = p;
    ao->samplerate = 192000;
    p->anchor_ns = 1;
    p->written = INT64_MAX;
    int64_t hours = 20;
    int64_t want = hours * 3600 * ao->samplerate + ao->samplerate / 2;
    int64_t got = heard_locked(ao, 1 + MP_TIME_S_TO_NS(hours * 3600) +
                                   MP_TIME_MS_TO_NS(500));
    check(got == want, "20 h at 192 kHz: %lld frames heard (%lld)",
          (long long)want, (long long)got);
    talloc_free(ao);
    return 0;
}

// sync_locked against the last start: the device's timestamps from before
// it are the stream's past (a paused stream's last frame), not its present.
static int stale_mode(void)
{
    struct ao *ao = talloc_zero(NULL, struct ao);
    struct priv *p = talloc_zero_size(ao, sizeof(struct priv));
    ao->priv = p;
    ao->samplerate = RATE;
    int64_t now = MP_TIME_S_TO_NS(100);
    p->written = RATE;
    p->heard_base = RATE / 10;
    p->started_ns = now - MP_TIME_MS_TO_NS(50);
    p->anchor_ns = p->started_ns;
    p->have_origin = true;
    // The frame at RATE / 10 was heard 700 ms ago, before the start.
    sync_locked(ao, RATE / 10, now - MP_TIME_MS_TO_NS(700), now);
    int64_t heard = heard_locked(ao, now);
    check(heard == RATE / 10 + RATE / 20,
          "an old timestamp leaves the clock (%lld frames heard, want %d)",
          (long long)heard, RATE / 10 + RATE / 20);
    // The frame at RATE / 10 + 2000 was heard 10 ms ago, after it.
    sync_locked(ao, RATE / 10 + 2000, now - MP_TIME_MS_TO_NS(10), now);
    heard = heard_locked(ao, now);
    check(heard == RATE / 10 + 2000 + RATE / 100,
          "a newer one sets it (%lld frames heard, want %d)",
          (long long)heard, RATE / 10 + 2000 + RATE / 100);
    talloc_free(ao);
    return 0;
}

static int format_mode(void)
{
    static const struct {
        int format, channels, rate;
        int type;
        int dev_channels, dev_rate;
    } cases[] = {
        {AF_FORMAT_FLOAT, 2, 48000, AUDIOSTREAM_SAMPLE_S32LE, 2, 48000},
        {AF_FORMAT_S16, 1, 44100, AUDIOSTREAM_SAMPLE_S16LE, 1, 44100},
        {AF_FORMAT_U8, 2, 22050, AUDIOSTREAM_SAMPLE_S16LE, 2, 22050},
        {AF_FORMAT_S32, 6, 96000, AUDIOSTREAM_SAMPLE_S32LE, 2, 96000},
        {AF_FORMAT_FLOAT, 2, 4000, AUDIOSTREAM_SAMPLE_S32LE, 2, 8000},
        // Rates the renderer refuses play at the next one up.
        {AF_FORMAT_S16, 2, 37800, AUDIOSTREAM_SAMPLE_S16LE, 2, 44100},
        {AF_FORMAT_FLOAT, 2, 47250, AUDIOSTREAM_SAMPLE_S32LE, 2, 48000},
        {AF_FORMAT_FLOAT, 2, 352800, AUDIOSTREAM_SAMPLE_S32LE, 2, 192000},
    };
    for (size_t i = 0; i < MP_ARRAY_SIZE(cases); i++) {
        struct ao *ao = open_ao(cases[i].format, cases[i].channels, cases[i].rate);
        pthread_mutex_lock(&sim_lock);
        bool ok = sim && sim->b.format == cases[i].type &&
                  sim->b.channels == cases[i].dev_channels &&
                  sim->b.rate == cases[i].dev_rate &&
                  sim->b.usage == AUDIOSTREAM_USAGE_MUSIC &&
                  sim->b.device && sim->b.callbacks.OH_AudioRenderer_OnInterruptEvent &&
                  sim->b.callbacks.OH_AudioRenderer_OnError &&
                  ao->channels.num == cases[i].dev_channels &&
                  ao->samplerate == cases[i].dev_rate;
        int t = sim ? sim->b.format : -1, c = sim ? sim->b.channels : -1;
        pthread_mutex_unlock(&sim_lock);
        check(ok, "case %zu: device format %d, %d channels, %d Hz, music, callbacks", i, t, c,
              ao->samplerate);
        uninit(ao);
        talloc_free(ao);
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s play|pause|seek|seekrace|delay|resume|keep|route|fast|slow|"
                "interrupt|stop|shared|error|dead|nostart|release|clock|stale|format\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    pthread_t dev;
    pthread_create(&dev, NULL, device_thread, NULL);
    if (!strcmp(mode, "format")) {
        format_mode();
        goto end;
    }
    if (!strcmp(mode, "clock")) {
        clock_mode();
        goto end;
    }
    if (!strcmp(mode, "stale")) {
        stale_mode();
        goto end;
    }

    if (!strcmp(mode, "fast"))
        device_speed = 1.02;
    else if (!strcmp(mode, "slow"))
        device_speed = 0.98;
    else if (!strcmp(mode, "keep"))
        atomic_store(&flush_keeps_position, true);
    struct ao *ao = open_ao(AF_FORMAT_FLOAT, 2, RATE);
    sleep_ms(200);
    check(played_count() == 0, "nothing plays before start (%d frames)", played_count());
    if (!strcmp(mode, "nostart"))
        atomic_store(&start_fails, true);
    ao->driver->start(ao);

    if (!strcmp(mode, "nostart")) {
        // Not before 3 s with no first callback, then once.
        sleep_ms(2500);
        check(atomic_load(&reloads) == 0, "no reload within 2.5 s of the start (%d)",
              atomic_load(&reloads));
        mt_wait_until(2, atomic_load(&reloads) >= 1, sleep_ms(1));
        sleep_ms(1000);
        check(atomic_load(&reloads) == 1, "one reload is asked (%d)", atomic_load(&reloads));
        atomic_store(&start_fails, false);
        goto done;
    }
    mt_wait_until(1, played_count() > RATE / 4, sleep_ms(1));
    check(played_count() > RATE / 4, "the stream plays (%d frames)", played_count());

    if (!strcmp(mode, "play")) {
        mt_wait_until(1, played_count() > RATE * 8 / 10, sleep_ms(1));
        check(played_count() > RATE * 8 / 10, "a second of audio (%d frames)", played_count());
        check_whole(0, "play");
    } else if (!strcmp(mode, "pause")) {
        player_pause(ao, true);
        sleep_ms(30);
        int p0 = played_count();
        sleep_ms(500);
        check(played_count() == p0, "nothing plays while paused (%d frames)", played_count() - p0);
        player_pause(ao, false);
        mt_wait_until(1, played_count() > p0 + RATE / 4, sleep_ms(1));
        check(played_count() > p0 + RATE / 4, "the resume plays (%d frames)", played_count() - p0);
        check_whole(0, "across the pause");
    } else if (!strcmp(mode, "seek")) {
        player_pause(ao, true);
        sleep_ms(200);
        ao->driver->reset(ao);
        atomic_store(&src_next, 5000000);
        int at = played_count();
        ao->driver->start(ao);
        mt_wait_until(1, played_count() > at + RATE / 4, sleep_ms(1));
        int old_after = 0;
        pthread_mutex_lock(&sim_lock);
        for (int i = at; i < nplayed; i++)
            old_after += played[i] && played[i] < 5000000;
        pthread_mutex_unlock(&sim_lock);
        int64_t first, lost, repeated;
        played_gaps(at, &first, &lost, &repeated);
        check(old_after == 0, "no frame from before the seek after it (%d)", old_after);
        check(first == 5000000 && lost == 0 && repeated == 0,
              "after the seek the source plays from its start, whole (first %lld, %lld lost)",
              (long long)first, (long long)lost);
    } else if (!strcmp(mode, "seekrace")) {
        // Each seek k plays a source of its own, from k * 10^7 on.
        enum { SEEKS = 30, SPAN = 10000000 };
        int at[SEEKS + 1];
        atomic_store(&read_lag_ms, 10);
        unsigned seed = 2;
        for (int k = 1; k <= SEEKS; k++) {
            ao->driver->reset(ao);
            at[k - 1] = played_count();
            atomic_store(&src_next, (long long)k * SPAN);
            ao->driver->start(ao);
            sleep_ms(15 + rand_r(&seed) % 30);
        }
        mt_wait_until(1, played_count() > at[SEEKS - 1] + RATE / 10, sleep_ms(1));
        at[SEEKS] = played_count();
        int stale = 0;
        pthread_mutex_lock(&sim_lock);
        for (int k = 1; k <= SEEKS; k++) {
            for (int i = at[k - 1]; i < at[k]; i++) {
                int64_t id = played[i];
                stale += id && (id < (int64_t)k * SPAN || id >= (int64_t)(k + 1) * SPAN);
            }
        }
        pthread_mutex_unlock(&sim_lock);
        printf("seekrace: %d buffers dropped as invalid\n", atomic_load(&invalid));
        check(atomic_load(&invalid) > 0, "reads crossed a reset (%d dropped)", atomic_load(&invalid));
        check(stale == 0, "nothing from before a seek after it (%d frames)", stale);
        check(at[SEEKS] > at[SEEKS - 1], "the last source plays (%d frames)",
              at[SEEKS] - at[SEEKS - 1]);
    } else if (!strcmp(mode, "delay")) {
        sleep_ms(1500);
        check_delay("delay", 0, 5, 15);
    } else if (!strcmp(mode, "resume")) {
        sleep_ms(500);
        player_pause(ao, true);
        sleep_ms(700);
        int64_t since = mp_time_ns();
        player_pause(ao, false);
        sleep_ms(1000);
        check_delay("resume", since, 5, 15);
        check_whole(0, "across the pause");
    } else if (!strcmp(mode, "keep") || !strcmp(mode, "route")) {
        sleep_ms(700);
        int64_t since = 0;
        for (int k = 1; k <= 3; k++) {
            if (!strcmp(mode, "keep")) {
                player_seek(ao, (long long)k * 10000000);
            } else {
                // The route changes: the position counts from 0 again.
                pthread_mutex_lock(&sim_lock);
                sim->position = 0;
                pthread_mutex_unlock(&sim_lock);
                sim->b.device(sim, sim->b.user, REASON_NEW_DEVICE_AVAILABLE);
            }
            // The clock alone runs until the next timestamp: the reads
            // after it are the ones measured.
            sleep_ms(400);
            since = mp_time_ns();
            sleep_ms(600);
        }
        check_delay(mode, since, 5, 15);
    } else if (!strcmp(mode, "fast") || !strcmp(mode, "slow")) {
        sleep_ms(2500);
        int64_t since = mp_time_ns();
        sleep_ms(1000);
        // Set from the device every 200 ms: 2% of that between two.
        check_delay(mode, since, 10, 25);
        check_whole(0, mode);
    } else if (!strcmp(mode, "interrupt") || !strcmp(mode, "stop")) {
        bool stop = !strcmp(mode, "stop");
        system_interrupt(AUDIOSTREAM_INTERRUPT_FORCE,
                         stop ? AUDIOSTREAM_INTERRUPT_HINT_STOP : AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
        sleep_ms(30);
        int p0 = played_count();
        sleep_ms(1500);
        check(played_count() == p0, "nothing plays while interrupted (%d frames)",
              played_count() - p0);
        check(atomic_load(&reloads) == 0, "no reload while interrupted (%d)", atomic_load(&reloads));
        // From the resume on: the clock frozen at the interruption is right
        // before the first timestamp after it.
        int64_t since = mp_time_ns();
        if (stop) {
            player_pause(ao, true);
            player_pause(ao, false);
        } else {
            system_interrupt(AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_RESUME);
        }
        mt_wait_until(1, played_count() > p0 + RATE / 4, sleep_ms(1));
        check(played_count() > p0 + RATE / 4, "it plays again (%d frames)", played_count() - p0);
        check_whole(0, "across the interruption");
        sleep_ms(1200);
        check_delay(mode, since, 5, 15);
    } else if (!strcmp(mode, "shared")) {
        system_interrupt(AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
        int p0 = played_count();
        mt_wait_until(1, played_count() > p0 + RATE / 4, sleep_ms(1));
        check(played_count() > p0 + RATE / 4, "the stream keeps playing (%d frames)",
              played_count() - p0);
        check_whole(0, "a shared interruption");
    } else if (!strcmp(mode, "error")) {
        OH_AudioRenderer *r = sim;
        r->b.callbacks.OH_AudioRenderer_OnError(r, r->b.user, AUDIOSTREAM_ERROR_SYSTEM);
        r->b.callbacks.OH_AudioRenderer_OnError(r, r->b.user, AUDIOSTREAM_ERROR_SYSTEM);
        check(atomic_load(&reloads) == 1, "one reload is asked (%d)", atomic_load(&reloads));
    } else if (!strcmp(mode, "dead")) {
        atomic_store(&callbacks_stop, true);
        mt_wait_until(2.5, atomic_load(&reloads) >= 1, sleep_ms(1));
        sleep_ms(1000);
        check(atomic_load(&reloads) == 1, "one reload is asked (%d)", atomic_load(&reloads));
        atomic_store(&callbacks_stop, false);
    } else if (!strcmp(mode, "release")) {
        atomic_store(&read_lag_ms, 50);
        sleep_ms(60);
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }

done:
    atomic_store(&uninit_started, true);
    uninit(ao);
    talloc_free(ao);
    check(atomic_load(&reads_after_uninit) == 0, "no read starts once uninit has (%d)",
          atomic_load(&reads_after_uninit));
    if (strcmp(mode, "dead") && strcmp(mode, "nostart") && strcmp(mode, "error"))
        check(atomic_load(&reloads) == 0, "no reload (%d)", atomic_load(&reloads));
end:
    check(atomic_load(&bad_calls) == 0, "no call against the rules (%d)", atomic_load(&bad_calls));
    atomic_store(&device_quit, true);
    pthread_join(dev, NULL);
    printf(failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", failures);
    return failures ? 1 : 0;
}
