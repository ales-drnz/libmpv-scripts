// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// ao_tizen_test <mode>: white-box test of audio/out/ao_tizen.c, which run.sh
// adds to pristine mpv with patches/mpv/tizen/patch_ao_tizen.py. The
// audio_out calls go to a simulated handle that follows the rules of
// capi-media-audio-io 0.5.39 (Tizen 6.0) the driver depends on: a write
// holds the handle's lock for its whole call and blocks while the stream
// is full; pause, resume and flush take the same lock, so they wait for a
// write in flight; a write on a handle that is not running fails, and so
// does a pause of one that is not running or a resume of one that is not
// paused. A device thread plays the stream at 48 kHz when it runs and logs
// each frame with the time it played it. Each source frame carries its
// index in the left sample, silence is 0.
// The test drives the driver as buffer.c drives a pull output: ao_read_data
// returns nothing while the source underruns, a pause calls set_pause, a
// seek calls reset and then start.
// modes:
//   play      a second of audio, whole and in order
//   pause     pause 0.5 s and resume: no frame lost or repeated
//   seek      pause, reset, resume: nothing from before the seek
//   underrun  the source runs dry for 1 s: no spinning, audio comes back
//   delay     the time ao_read_data is given is when the read's last frame
//             is heard, as buffer.c reads it
//   race      100 pauses and resumes a few ms apart, some between the
//             driver's check and its write: nothing lost or repeated
//   seekrace  30 seeks, some in the middle of a read: nothing from before
//             a seek plays after it
//   refuse    the device refuses writes for 0.5 s: no spinning, nothing
//             lost, no reload
//   fast      the device's clock runs 2% fast: the delay stays right
//   slow      the device's clock runs 2% slow: the delay stays right
//   dead      the device refuses every write: one reload is asked
//   noresume  the device refuses a resume: one reload is asked
//   short     a write takes at most 300 frames: nothing lost or repeated
//   format    the formats and layouts the device is opened with
#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "audio/out/ao_tizen.c"

#define RATE 48000
#define CAP (RATE / 10)          // the stream holds 100 ms
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

// ── simulated audio_out ─────────────────────────────────────────────────

enum { SIM_IDLE, SIM_RUNNING, SIM_PAUSED };

struct audio_io_s {
    int rate, channels;
    audio_sample_type_e type;
    int state;
    bool info;
    pthread_mutex_t handle;     // the lock every call takes, as audio-io does
    int64_t fifo[CAP];
    int head, len;
};

static pthread_mutex_t sim_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sim_cond = PTHREAD_COND_INITIALIZER;
static struct audio_io_s *sim;
static int64_t played[PLAYED_MAX];
static int64_t played_ns[PLAYED_MAX];
static int nplayed;
static atomic_int writes, refused_writes, reads, bad_calls;
static atomic_bool device_quit, device_refuses;
// race: a write is held this long before it takes the handle's lock, as a
// thread descheduled between its check of the state and its call would be.
static atomic_int write_lag_ms;
// short: a write takes at most this many frames, and says how many.
static atomic_int write_max;
// noresume: the next resume fails.
static atomic_bool resume_fails;
// fast, slow: the device's clock against the system's.
static double device_speed = 1.0;
static atomic_int reloads;
// seekrace: a read takes this long, so a reset can come in the middle.
static atomic_int read_lag_ms;
static struct sound_stream_info_s { int unused; } sim_info;

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
            }
            sim->len -= take;
        }
        pthread_cond_broadcast(&sim_cond);
        pthread_mutex_unlock(&sim_lock);
    }
    return NULL;
}

static int bytes_of(audio_sample_type_e type)
{
    return type == AUDIO_SAMPLE_TYPE_S16_LE ? 2 : 4;
}

int audio_out_create_new(int rate, audio_channel_e channel,
                         audio_sample_type_e type, audio_out_h *output)
{
    if (rate < 8000 || rate > 192000 ||
        (channel != AUDIO_CHANNEL_MONO && channel != AUDIO_CHANNEL_STEREO) ||
        (type != AUDIO_SAMPLE_TYPE_S16_LE && type != AUDIO_SAMPLE_TYPE_S32_LE))
        return AUDIO_IO_ERROR_INVALID_PARAMETER;
    struct audio_io_s *s = calloc(1, sizeof(*s));
    s->rate = rate;
    s->channels = channel == AUDIO_CHANNEL_MONO ? 1 : 2;
    s->type = type;
    pthread_mutex_init(&s->handle, NULL);
    pthread_mutex_lock(&sim_lock);
    sim = s;
    pthread_mutex_unlock(&sim_lock);
    *output = s;
    return AUDIO_IO_ERROR_NONE;
}

int audio_out_destroy(audio_out_h s)
{
    pthread_mutex_lock(&sim_lock);
    if (s->state != SIM_IDLE)
        atomic_fetch_add(&bad_calls, 1);    // unprepare comes first
    sim = NULL;
    pthread_mutex_unlock(&sim_lock);
    pthread_mutex_destroy(&s->handle);
    free(s);
    return AUDIO_IO_ERROR_NONE;
}

int audio_out_set_sound_stream_info(audio_out_h s, sound_stream_info_h info)
{
    s->info = info == &sim_info;
    return AUDIO_IO_ERROR_NONE;
}

// Moves the handle from state <from> to <to> under its lock.
static int sim_state(audio_out_h s, int from, int to, int err, bool flush)
{
    pthread_mutex_lock(&s->handle);
    pthread_mutex_lock(&sim_lock);
    int ret = AUDIO_IO_ERROR_NONE;
    if (from >= 0 && s->state != from) {
        ret = err;
    } else if (flush) {
        if (s->state == SIM_IDLE)
            ret = err;
        else
            s->len = 0;
    } else {
        s->state = to;
    }
    pthread_cond_broadcast(&sim_cond);
    pthread_mutex_unlock(&sim_lock);
    pthread_mutex_unlock(&s->handle);
    return ret;
}

int audio_out_prepare(audio_out_h s)
{
    return sim_state(s, SIM_IDLE, SIM_RUNNING, AUDIO_IO_ERROR_INVALID_STATE, false);
}
int audio_out_unprepare(audio_out_h s)
{
    return sim_state(s, -1, SIM_IDLE, 0, false);
}
int audio_out_pause(audio_out_h s)
{
    return sim_state(s, SIM_RUNNING, SIM_PAUSED, AUDIO_IO_ERROR_INVALID_STATE, false);
}
int audio_out_resume(audio_out_h s)
{
    if (atomic_exchange(&resume_fails, false))
        return AUDIO_IO_ERROR_INVALID_OPERATION;
    return sim_state(s, SIM_PAUSED, SIM_RUNNING, AUDIO_IO_ERROR_INVALID_STATE, false);
}
int audio_out_flush(audio_out_h s)
{
    return sim_state(s, -1, 0, AUDIO_IO_ERROR_INVALID_STATE, true);
}

int audio_out_write(audio_out_h s, void *buffer, unsigned int length)
{
    atomic_fetch_add(&writes, 1);
    if (atomic_load(&write_lag_ms))
        sleep_ms(atomic_load(&write_lag_ms));
    pthread_mutex_lock(&s->handle);
    pthread_mutex_lock(&sim_lock);
    int frame = bytes_of(s->type) * s->channels;
    int frames = length / frame, done = 0, ret;
    if (atomic_load(&write_max))
        frames = MPMIN(frames, atomic_load(&write_max));
    if (s->state != SIM_RUNNING || atomic_load(&device_refuses)) {
        atomic_fetch_add(&refused_writes, 1);
        ret = AUDIO_IO_ERROR_INVALID_OPERATION;
        goto out;
    }
    while (done < frames) {
        if (s->len < CAP) {
            int64_t id = s->type == AUDIO_SAMPLE_TYPE_S16_LE
                         ? ((int16_t *)buffer)[done * s->channels]
                         : ((int32_t *)buffer)[done * s->channels];
            s->fifo[(s->head + s->len) % CAP] = id;
            s->len++;
            done++;
            continue;
        }
        // Full: wait for room, as audio-io does (it fails after 5 s).
        struct timespec until;
        clock_gettime(CLOCK_REALTIME, &until);
        until.tv_sec += 5;
        if (pthread_cond_timedwait(&sim_cond, &sim_lock, &until)) {
            ret = AUDIO_IO_ERROR_INVALID_OPERATION;
            goto out;
        }
    }
    ret = done * frame;
out:
    pthread_mutex_unlock(&sim_lock);
    pthread_mutex_unlock(&s->handle);
    return ret;
}

int sound_manager_create_stream_information(sound_stream_type_e type,
                                            sound_stream_focus_state_changed_cb cb,
                                            void *user_data,
                                            sound_stream_info_h *info)
{
    (void)cb; (void)user_data;
    if (type != SOUND_STREAM_TYPE_MEDIA)
        atomic_fetch_add(&bad_calls, 1);
    *info = &sim_info;
    return SOUND_MANAGER_ERROR_NONE;
}

int sound_manager_destroy_stream_information(sound_stream_info_h info)
{
    (void)info;
    return SOUND_MANAGER_ERROR_NONE;
}

// ── stubs of the mpv functions the driver calls ─────────────────────────

void mp_msg(struct mp_log *log, int lev, const char *format, ...)
{
    (void)log;
    if (lev > (getenv("VERBOSE") ? MSGL_V : MSGL_WARN))
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

// The player side of buffer.c: dry, there is nothing to read.
static atomic_bool src_dry;
static atomic_llong src_next = 1;
static int64_t read_first[READS_MAX], read_out_ns[READS_MAX];

int ao_read_data(struct ao *ao, void **data, int samples, int64_t out_time_ns,
                 bool *eof, bool pad_silence, bool blocking)
{
    (void)eof; (void)blocking;
    int n = atomic_fetch_add(&reads, 1);
    int32_t *f = data[0];
    int pos = 0;
    if (!atomic_load(&src_dry)) {
        int64_t id = atomic_fetch_add(&src_next, samples);
        if (n < READS_MAX) {
            read_first[n] = id;
            read_out_ns[n] = out_time_ns;
        }
        for (; pos < samples; pos++)
            f[pos * 2] = f[pos * 2 + 1] = (int32_t)(id + pos);
        if (atomic_load(&read_lag_ms))
            sleep_ms(atomic_load(&read_lag_ms));
    }
    if (pad_silence)
        memset(f + pos * 2, 0, (samples - pos) * ao->sstride);
    return pos;
}

// ── the test ────────────────────────────────────────────────────────────

static struct ao *open_ao(int format, int channels, int rate)
{
    struct ao *ao = talloc_zero(NULL, struct ao);
    ao->driver = &audio_out_tizen;
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

static int played_count(void)
{
    pthread_mutex_lock(&sim_lock);
    int n = nplayed;
    pthread_mutex_unlock(&sim_lock);
    return n;
}

// Source frames missing, and repeated, between consecutive frames played
// from index from on.
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
    for (int i = 0; i < nplayed; i++) {
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
    for (int i = 10; i < nr - 10; i++) {
        if (read_out_ns[i] < since_ns)
            continue;
        int64_t at = heard_at(read_first[i] + RATE * CHUNK_MS / 1000 - 1);
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

static int format_mode(void)
{
    static const struct {
        int format, channels, rate;
        audio_sample_type_e type;
        int dev_channels, dev_rate;
    } cases[] = {
        {AF_FORMAT_FLOAT, 2, 48000, AUDIO_SAMPLE_TYPE_S32_LE, 2, 48000},
        {AF_FORMAT_S16, 1, 44100, AUDIO_SAMPLE_TYPE_S16_LE, 1, 44100},
        {AF_FORMAT_U8, 2, 22050, AUDIO_SAMPLE_TYPE_S16_LE, 2, 22050},
        {AF_FORMAT_S32, 6, 96000, AUDIO_SAMPLE_TYPE_S32_LE, 2, 96000},
        {AF_FORMAT_FLOAT, 2, 4000, AUDIO_SAMPLE_TYPE_S32_LE, 2, 48000},
    };
    for (size_t i = 0; i < MP_ARRAY_SIZE(cases); i++) {
        struct ao *ao = open_ao(cases[i].format, cases[i].channels, cases[i].rate);
        pthread_mutex_lock(&sim_lock);
        bool ok = sim && sim->type == cases[i].type &&
                  sim->channels == cases[i].dev_channels &&
                  sim->rate == cases[i].dev_rate && sim->info &&
                  ao->channels.num == cases[i].dev_channels &&
                  ao->samplerate == cases[i].dev_rate;
        int t = sim ? sim->type : -1, c = sim ? sim->channels : -1;
        pthread_mutex_unlock(&sim_lock);
        check(ok, "case %zu: device type %#x, %d channels, %d Hz", i, t, c, ao->samplerate);
        uninit(ao);
        talloc_free(ao);
    }
    check(atomic_load(&bad_calls) == 0, "every handle unprepared before destroy, media type (%d bad)",
          atomic_load(&bad_calls));
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s play|pause|seek|underrun|delay|race|seekrace|refuse|fast|slow|dead|noresume|short|format\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    pthread_t dev;
    pthread_create(&dev, NULL, device_thread, NULL);
    if (!strcmp(mode, "format")) {
        format_mode();
        goto done;
    }

    if (!strcmp(mode, "fast"))
        device_speed = 1.02;
    else if (!strcmp(mode, "slow"))
        device_speed = 0.98;
    else if (!strcmp(mode, "short"))
        atomic_store(&write_max, 300);
    struct ao *ao = open_ao(AF_FORMAT_FLOAT, 2, RATE);
    sleep_ms(200);
    check(played_count() == 0, "nothing plays before start (%d frames)", played_count());
    ao->driver->start(ao);
    sleep_ms(500);
    check(played_count() > RATE / 4, "the stream plays (%d frames in 0.5 s)", played_count());

    if (!strcmp(mode, "play")) {
        sleep_ms(500);
        check(played_count() > RATE * 8 / 10, "a second of audio (%d frames)", played_count());
        check_whole(0, "play");
    } else if (!strcmp(mode, "pause")) {
        player_pause(ao, true);
        int p0 = played_count();
        sleep_ms(500);
        check(played_count() == p0, "nothing plays while paused (%d frames)", played_count() - p0);
        player_pause(ao, false);
        sleep_ms(500);
        check(played_count() > p0 + RATE / 4, "the resume plays (%d frames)", played_count() - p0);
        check_whole(0, "across the pause");
    } else if (!strcmp(mode, "seek")) {
        player_pause(ao, true);
        sleep_ms(200);
        ao->driver->reset(ao);
        atomic_store(&src_next, 5000000);
        int at = played_count();
        ao->driver->start(ao);
        sleep_ms(500);
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
    } else if (!strcmp(mode, "underrun")) {
        atomic_store(&src_dry, true);
        sleep_ms(100);
        int r0 = atomic_load(&reads);
        sleep_ms(1000);
        int r = atomic_load(&reads) - r0;
        check(r <= 100, "the thread waits instead of spinning (%d reads in 1 s)", r);
        int resume = played_count();
        atomic_store(&src_dry, false);
        double t0 = now_s();
        int64_t first = 0, lost, repeated;
        while (now_s() - t0 < 1.0) {
            played_gaps(resume, &first, &lost, &repeated);
            if (first)
                break;
            sleep_ms(1);
        }
        double took = now_s() - t0;
        check(first && took < 0.25, "audio comes back (%.0f ms)", took * 1000);
    } else if (!strcmp(mode, "delay")) {
        sleep_ms(1500);
        // Each read after the stream filled.
        double mean, worst;
        int n = delay_errors(0, &mean, &worst);
        printf("delay: %d reads, mean error %.1f ms, worst %.1f ms\n", n, mean, worst);
        check(n > 40, "reads measured (%d)", n);
        check(fabs(mean) < 5 && worst < 15,
              "out_time is when the read's last frame is heard (mean %.1f ms, worst %.1f ms)",
              mean, worst);
    } else if (!strcmp(mode, "fast") || !strcmp(mode, "slow")) {
        // 3 s at 2% off is 60 ms: the reads of the last second.
        sleep_ms(2500);
        int64_t since = mp_time_ns();
        sleep_ms(1000);
        double mean, worst;
        int n = delay_errors(since, &mean, &worst);
        printf("%s: %d reads, mean error %.1f ms, worst %.1f ms\n", mode, n, mean, worst);
        check(n > 20, "reads measured (%d)", n);
        check(fabs(mean) < 10 && worst < 25,
              "the delay follows the device's clock (mean %.1f ms, worst %.1f ms)",
              mean, worst);
        check_whole(0, mode);
    } else if (!strcmp(mode, "dead") || !strcmp(mode, "noresume")) {
        if (!strcmp(mode, "dead")) {
            atomic_store(&device_refuses, true);
        } else {
            player_pause(ao, true);
            atomic_store(&resume_fails, true);
            player_pause(ao, false);
        }
        sleep_ms(2500);
        check(atomic_load(&reloads) == 1, "one reload is asked (%d)",
              atomic_load(&reloads));
        atomic_store(&device_refuses, false);
    } else if (!strcmp(mode, "short")) {
        sleep_ms(1000);
        check(played_count() > RATE, "the stream plays (%d frames)", played_count());
        check_whole(0, "short writes");
    } else if (!strcmp(mode, "race")) {
        atomic_store(&write_lag_ms, 5);
        unsigned seed = 1;
        for (int i = 0; i < 100; i++) {
            player_pause(ao, true);
            sleep_ms(3 + rand_r(&seed) % 12);
            player_pause(ao, false);
            sleep_ms(3 + rand_r(&seed) % 12);
        }
        sleep_ms(300);
        printf("race: %d writes, %d refused\n", atomic_load(&writes), atomic_load(&refused_writes));
        check(atomic_load(&refused_writes) > 0,
              "pauses came between a check and its write (%d refused)",
              atomic_load(&refused_writes));
        check_whole(0, "100 pauses");
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
        sleep_ms(200);
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
        check(stale == 0, "nothing from before a seek after it (%d frames)", stale);
        check(at[SEEKS] > at[SEEKS - 1], "the last source plays (%d frames)",
              at[SEEKS] - at[SEEKS - 1]);
    } else if (!strcmp(mode, "refuse")) {
        atomic_store(&device_refuses, true);
        int w0 = atomic_load(&writes);
        sleep_ms(500);
        int w = atomic_load(&writes) - w0;
        check(w <= 10, "a refusing device is not spun on (%d writes in 0.5 s)", w);
        atomic_store(&device_refuses, false);
        int p0 = played_count();
        sleep_ms(500);
        check(played_count() > p0 + RATE / 4, "the stream plays again (%d frames)",
              played_count() - p0);
        check_whole(0, "across the refusal");
        check(atomic_load(&reloads) == 0, "no reload for a short refusal (%d)",
              atomic_load(&reloads));
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }

    uninit(ao);
    talloc_free(ao);
    check(atomic_load(&bad_calls) == 0, "unprepared before destroy (%d bad calls)",
          atomic_load(&bad_calls));
done:
    atomic_store(&device_quit, true);
    pthread_join(dev, NULL);
    printf(failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", failures);
    return failures ? 1 : 0;
}
