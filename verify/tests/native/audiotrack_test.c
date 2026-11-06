// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// audiotrack_test <mode>: white-box test of audio/out/ao_audiotrack.c (F277,
// F278, F276), which run.sh builds from pristine mpv patched with
// patches/mpv/android/patch_audiotrack.py. The JNI calls go to a simulated
// AudioTrack that follows the Android rules the driver depends on:
// a write blocks while the track plays and its buffer is full, a pause or a
// stop interrupts a blocked write (it returns the bytes written so far), a
// write on a paused or stopped track does not block, flush drops the queue
// of a track that is not playing, a dead track fails every write with
// ERROR_DEAD_OBJECT. A device thread plays the queue at 48 kHz and logs the
// frames it plays. Each source frame carries its index in the left sample,
// silence is 0.
// The test drives the driver as buffer.c drives a pull output: ao_read_data
// returns nothing while the player is paused or the source underruns, a pause
// calls set_pause when the driver has it and reset otherwise, a resume calls
// set_pause or start.
// modes:
//   underrun  the source runs dry for 1 s with the track playing (F277)
//   silence   audio-stream-silence and paused for 1 s (F277)
//   dead      the track dies with audioserver (F278)
//   pause     pause 0.5 s and resume: no frame lost (F276)
//   seek      pause, reset (a seek), resume: no frame from before the seek
//   ac3       audio-spdif of AC3: the track opens IEC61937 at 48 kHz, the
//             output rate (control)
//   eac3      audio-spdif of E-AC3, which IEC61937 carries at four times
//             its rate: the track opens at 192 kHz though the output runs
//             at 48 kHz (r22: the driver lowered every rate to the output
//             one, and the track played the bursts at a quarter)
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#include "audio/out/ao_audiotrack.c"

#define RATE 48000
#define FIFO_MAX (1 << 16)
#define PLAYED_MAX (RATE * 20)

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

// ── simulated AudioTrack ────────────────────────────────────────────────

struct sim_track {
    int state;              // 1 stopped, 2 paused, 3 playing
    bool dead, released;
    int64_t fifo[FIFO_MAX];
    int head, len, cap;     // cap in frames
    int64_t consumed;
    unsigned interrupts;
};

static pthread_mutex_t sim_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sim_cond = PTHREAD_COND_INITIALIZER;
static struct sim_track tracks[8];
static int ntracks;
static float *bbuf_addr;
static int frame_bytes = 8;      // float stereo
static int64_t played[PLAYED_MAX];
static int nplayed;
static atomic_int writes, playstate_calls, reload_requests, reads;
static atomic_bool device_quit;
static int dummy_object;

static void *device_thread(void *arg)
{
    (void)arg;
    double last = now_s(), budget = 0;
    while (!atomic_load(&device_quit)) {
        sleep_ms(1);
        double t = now_s();
        budget += (t - last) * RATE;
        last = t;
        int n = (int)budget;
        budget -= n;
        pthread_mutex_lock(&sim_lock);
        for (int i = 0; i < ntracks; i++) {
            struct sim_track *s = &tracks[i];
            if (s->released || s->state != 3)
                continue;
            int take = MPMIN(n, s->len);
            for (int k = 0; k < take; k++) {
                if (nplayed < PLAYED_MAX)
                    played[nplayed++] = s->fifo[s->head];
                s->head = (s->head + 1) % FIFO_MAX;
            }
            s->len -= take;
            s->consumed += take;
        }
        pthread_cond_broadcast(&sim_cond);
        pthread_mutex_unlock(&sim_lock);
    }
    return NULL;
}

static jint sim_write(struct sim_track *s, const float *buf, int bytes)
{
    atomic_fetch_add(&writes, 1);
    pthread_mutex_lock(&sim_lock);
    if (s->dead) {
        pthread_mutex_unlock(&sim_lock);
        return -6;
    }
    int frames = bytes / frame_bytes, done = 0;
    while (done < frames) {
        if (s->len < s->cap) {
            s->fifo[(s->head + s->len) % FIFO_MAX] = (int64_t)buf[done * 2];
            s->len++;
            done++;
            continue;
        }
        if (s->state != 3)
            break;  // not playing: the write does not block
        unsigned seen = s->interrupts;
        pthread_cond_wait(&sim_cond, &sim_lock);
        if (s->interrupts != seen)
            break;  // pause or stop: the write returns what it wrote
    }
    pthread_mutex_unlock(&sim_lock);
    return done * frame_bytes;
}

static void sim_set_state(struct sim_track *s, const char *what)
{
    pthread_mutex_lock(&sim_lock);
    if (!strcmp(what, "play")) {
        s->state = 3;
    } else if (!strcmp(what, "pause")) {
        if (s->state == 3) {
            s->state = 2;
            s->interrupts++;
        }
    } else if (!strcmp(what, "stop")) {
        s->state = 1;
        s->interrupts++;
    } else if (!strcmp(what, "flush")) {
        if (s->state != 3)
            s->len = 0;
    } else if (!strcmp(what, "release")) {
        s->released = true;
        s->state = 1;
        s->interrupts++;
    }
    pthread_cond_broadcast(&sim_cond);
    pthread_mutex_unlock(&sim_lock);
}

static const struct MPJniField *field_of(const void *id) { return id; }

static bool is_track(jobject o)
{
    return o >= (jobject)&tracks[0] && o < (jobject)&tracks[8];
}

static jobject sim_NewObject(JNIEnv *env, jclass clazz, jmethodID m, ...)
{
    (void)env; (void)m;
    if (strcmp(field_of(clazz)->name, "android/media/AudioTrack"))
        return &dummy_object;
    va_list ap;
    va_start(ap, m);
    jint size;
    if (!strcmp(field_of(m)->signature, "(IIIIIII)V")) {
        for (int i = 0; i < 4; i++)
            (void)va_arg(ap, jint);
        size = va_arg(ap, jint);
    } else {
        (void)va_arg(ap, jobject);
        (void)va_arg(ap, jobject);
        size = va_arg(ap, jint);
    }
    va_end(ap);
    pthread_mutex_lock(&sim_lock);
    struct sim_track *s = &tracks[ntracks++];
    *s = (struct sim_track){.state = 1, .cap = size / frame_bytes};
    pthread_mutex_unlock(&sim_lock);
    printf("     new AudioTrack #%d, %d frames\n", ntracks, s->cap);
    return s;
}

// The rate of the last AudioFormat.Builder.setSampleRate.
static jint builder_rate;

static jobject sim_CallObjectMethod(JNIEnv *env, jobject o, jmethodID m, ...)
{
    (void)env; (void)o;
    if (!strcmp(field_of(m)->name, "setSampleRate")) {
        va_list ap;
        va_start(ap, m);
        builder_rate = va_arg(ap, jint);
        va_end(ap);
    }
    return &dummy_object;
}

static jboolean sim_CallBooleanMethod(JNIEnv *env, jobject o, jmethodID m, ...)
{
    (void)env; (void)o; (void)m;
    return JNI_FALSE;   // getTimestamp: none, the head position is used
}

static jint sim_CallIntMethod(JNIEnv *env, jobject o, jmethodID m, ...)
{
    (void)env;
    const struct MPJniField *f = field_of(m);
    struct sim_track *s = is_track(o) ? o : NULL;
    if (!s)
        return 0;
    if (!strcmp(f->name, "getState"))
        return 1;
    if (!strcmp(f->name, "getPlayState")) {
        atomic_fetch_add(&playstate_calls, 1);
        pthread_mutex_lock(&sim_lock);
        int st = s->state;
        pthread_mutex_unlock(&sim_lock);
        return st;
    }
    if (!strcmp(f->name, "getBufferSizeInFrames"))
        return s->cap;
    if (!strcmp(f->name, "getPlaybackHeadPosition")) {
        pthread_mutex_lock(&sim_lock);
        jint pos = (jint)s->consumed;
        pthread_mutex_unlock(&sim_lock);
        return pos;
    }
    if (!strcmp(f->name, "getLatency"))
        return 0;
    if (!strcmp(f->name, "write")) {
        va_list ap;
        va_start(ap, m);
        jint ret = 0;
        if (!strcmp(f->signature, "(Ljava/nio/ByteBuffer;II)I")) {
            (void)va_arg(ap, jobject);
            jint len = va_arg(ap, jint);
            ret = sim_write(s, bbuf_addr, len);
        } else if (!strcmp(f->signature, "([SIII)I")) {
            // IEC61937 bursts: the spdif modes only open the track.
            (void)va_arg(ap, jobject);
            (void)va_arg(ap, jint);
            ret = va_arg(ap, jint);
        } else {
            printf("FAIL unexpected write %s\n", f->signature);
            failures++;
        }
        va_end(ap);
        return ret;
    }
    printf("FAIL unexpected int method %s\n", f->name);
    failures++;
    return 0;
}

static void sim_CallVoidMethod(JNIEnv *env, jobject o, jmethodID m, ...)
{
    (void)env;
    if (is_track(o))
        sim_set_state(o, field_of(m)->name);
}

static jint sim_CallStaticIntMethod(JNIEnv *env, jclass c, jmethodID m, ...)
{
    (void)env; (void)c;
    const struct MPJniField *f = field_of(m);
    if (!strcmp(f->name, "getNativeOutputSampleRate"))
        return RATE;
    if (!strcmp(f->name, "getMinBufferSize"))
        return 15360;   // 40 ms of float stereo: the driver asks for 80 ms
    return 0;
}

static jlong sim_GetLongField(JNIEnv *env, jobject o, jfieldID f)
{
    (void)env; (void)o; (void)f;
    return 0;
}

static jobject sim_NewGlobalRef(JNIEnv *env, jobject o) { (void)env; return o; }
static void sim_DeleteRef(JNIEnv *env, jobject o) { (void)env; (void)o; }

static jobject sim_NewDirectByteBuffer(JNIEnv *env, void *addr, jlong cap)
{
    (void)env; (void)cap;
    bbuf_addr = addr;
    return &dummy_object;
}

static jshortArray sim_NewShortArray(JNIEnv *env, jsize len)
{
    (void)env; (void)len;
    return &dummy_object;
}

static void sim_SetShortArrayRegion(JNIEnv *env, jshortArray a, jsize start,
                                    jsize len, const jshort *buf)
{
    (void)env; (void)a; (void)start; (void)len; (void)buf;
}

static const struct JNINativeInterface sim_iface = {
    .NewShortArray = sim_NewShortArray,
    .SetShortArrayRegion = sim_SetShortArrayRegion,
    .NewObject = sim_NewObject,
    .CallObjectMethod = sim_CallObjectMethod,
    .CallBooleanMethod = sim_CallBooleanMethod,
    .CallIntMethod = sim_CallIntMethod,
    .CallVoidMethod = sim_CallVoidMethod,
    .CallStaticIntMethod = sim_CallStaticIntMethod,
    .GetLongField = sim_GetLongField,
    .NewGlobalRef = sim_NewGlobalRef,
    .DeleteGlobalRef = sim_DeleteRef,
    .DeleteLocalRef = sim_DeleteRef,
    .NewDirectByteBuffer = sim_NewDirectByteBuffer,
};
static JNIEnv sim_env = &sim_iface;

// ── stubs of the mpv functions the driver calls ─────────────────────────

const m_option_type_t m_option_type_bool, m_option_type_int;   // option table

JNIEnv *mp_jni_get_env(struct mp_log *log) { (void)log; return &sim_env; }
int mp_jni_exception_check(JNIEnv *env, int logging, struct mp_log *log)
{
    (void)env; (void)logging; (void)log;
    return 0;
}

static jint android_constant(const char *name)
{
    static const struct { const char *name; jint value; } c[] = {
        {"WRITE_BLOCKING", 0}, {"WRITE_NON_BLOCKING", 1},
        {"STATE_INITIALIZED", 1}, {"PLAYSTATE_STOPPED", 1},
        {"PLAYSTATE_PAUSED", 2}, {"PLAYSTATE_PLAYING", 3},
        {"MODE_STREAM", 1}, {"ERROR", -1}, {"ERROR_BAD_VALUE", -2},
        {"ERROR_INVALID_OPERATION", -3}, {"CONTENT_TYPE_MOVIE", 3},
        {"CONTENT_TYPE_MUSIC", 2}, {"USAGE_MEDIA", 1},
        {"ENCODING_PCM_8BIT", 3}, {"ENCODING_PCM_16BIT", 2},
        {"ENCODING_PCM_FLOAT", 4}, {"ENCODING_IEC61937", 13},
        {"CHANNEL_OUT_MONO", 4}, {"CHANNEL_OUT_STEREO", 12},
        {"CHANNEL_OUT_FRONT_CENTER", 16}, {"CHANNEL_OUT_QUAD", 204},
        {"CHANNEL_OUT_5POINT1", 252}, {"CHANNEL_OUT_BACK_CENTER", 1024},
        {"CHANNEL_OUT_7POINT1_SURROUND", 6396}, {"STREAM_MUSIC", 3},
        {"ERROR_DEAD_OBJECT", -6},
    };
    for (size_t n = 0; n < MP_ARRAY_SIZE(c); n++)
        if (!strcmp(c[n].name, name))
            return c[n].value;
    printf("FAIL unknown constant %s\n", name);
    failures++;
    return 0;
}

int mp_jni_init_jfields(JNIEnv *env, void *jfields, const struct MPJniField *map,
                        int global, struct mp_log *log)
{
    (void)env; (void)global; (void)log;
    for (const struct MPJniField *f = map; f->name; f++) {
        void *at = (char *)jfields + f->offset;
        switch (f->type) {
        case MP_JNI_CLASS: *(jclass *)at = (jclass)f; break;
        case MP_JNI_FIELD:
        case MP_JNI_STATIC_FIELD: *(jfieldID *)at = (jfieldID)f; break;
        case MP_JNI_STATIC_FIELD_AS_INT: *(jint *)at = android_constant(f->name); break;
        case MP_JNI_METHOD:
        case MP_JNI_STATIC_METHOD: *(jmethodID *)at = (jmethodID)f; break;
        }
    }
    return 0;
}

int mp_jni_reset_jfields(JNIEnv *env, void *jfields, const struct MPJniField *map,
                         int global, struct mp_log *log)
{
    (void)env; (void)jfields; (void)map; (void)global; (void)log;
    return 0;
}

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

int64_t mp_time_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * INT64_C(1000000000) + t.tv_nsec;
}

uint64_t mp_raw_time_ns(void) { return mp_time_ns(); }

int af_fmt_to_bytes(int format)
{
    return format == AF_FORMAT_FLOAT ? 4 : format == AF_FORMAT_U8 ? 1 : 2;
}
bool af_fmt_is_float(int format) { return format == AF_FORMAT_FLOAT; }
bool af_fmt_is_spdif(int format)
{
    return format >= AF_FORMAT_S_AAC && format <= AF_FORMAT_S_TRUEHD;
}
void af_fill_silence(void *dst, size_t bytes, int format)
{
    memset(dst, format == AF_FORMAT_U8 ? 0x80 : 0, bytes);
}

void mp_chmap_sel_add_map(struct mp_chmap_sel *s, const struct mp_chmap *map)
{
    (void)s; (void)map;
}

bool ao_chmap_sel_adjust(struct ao *ao, const struct mp_chmap_sel *s,
                         struct mp_chmap *map)
{
    (void)ao; (void)s; (void)map;
    return true;
}

void ao_request_reload(struct ao *ao)
{
    (void)ao;
    atomic_fetch_add(&reload_requests, 1);
}

// The player side of buffer.c: paused or dry, there is nothing to read.
static atomic_bool src_paused, src_dry;
static atomic_llong src_next = 1;

int ao_read_data(struct ao *ao, void **data, int samples, int64_t out_time_ns,
                 bool *eof, bool pad_silence, bool blocking)
{
    (void)out_time_ns; (void)eof; (void)blocking;
    atomic_fetch_add(&reads, 1);
    float *f = data[0];
    int pos = 0;
    if (!atomic_load(&src_paused) && !atomic_load(&src_dry)) {
        int64_t id = atomic_fetch_add(&src_next, samples);
        for (; pos < samples; pos++)
            f[pos * 2] = f[pos * 2 + 1] = (float)(id + pos);
    }
    if (pad_silence)
        memset(f + pos * 2, 0, (samples - pos) * ao->sstride);
    return pos;
}

// ── the test ────────────────────────────────────────────────────────────

static struct ao *open_ao(bool silence)
{
    struct ao *ao = talloc_zero(NULL, struct ao);
    ao->driver = &audio_out_audiotrack;
    ao->priv = talloc_zero_size(ao, sizeof(struct priv));
    ((struct priv *)ao->priv)->cfg_pcm_float = true;
    ao->samplerate = RATE;
    ao->format = AF_FORMAT_FLOAT;
    ao->channels = (struct mp_chmap)MP_CHMAP_INIT_STEREO;
    ao->num_planes = 1;
    ao->sstride = frame_bytes;
    ao->stream_silence = silence;
    if (init(ao) < 0) {
        printf("FAIL init\n");
        exit(1);
    }
    return ao;
}

// buffer.c's pause and resume of a pull output (ao_set_paused).
static void player_pause(struct ao *ao, bool paused)
{
    if (getenv("VERBOSE")) {
        pthread_mutex_lock(&sim_lock);
        printf("     %s: queue %d, played %d, last %lld\n", paused ? "pause" : "resume",
               tracks[0].len, nplayed, nplayed ? (long long)played[nplayed - 1] : 0LL);
        pthread_mutex_unlock(&sim_lock);
    }
    atomic_store(&src_paused, paused);
    if (ao->driver->set_pause)
        ao->driver->set_pause(ao, paused);
    else if (paused)
        ao->driver->reset(ao);
    else
        ao->driver->start(ao);
}

static int played_count(void)
{
    pthread_mutex_lock(&sim_lock);
    int n = nplayed;
    pthread_mutex_unlock(&sim_lock);
    return n;
}

// Frames missing between consecutive source frames played from index from.
static int64_t played_gaps(int from, int64_t *first)
{
    int64_t lost = 0, prev = 0;
    *first = 0;
    pthread_mutex_lock(&sim_lock);
    for (int i = from; i < nplayed; i++) {
        int64_t id = played[i];
        if (!id)
            continue;
        if (!*first)
            *first = id;
        if (prev && id != prev + 1) {
            lost += id - prev - 1;
            if (getenv("VERBOSE"))
                printf("     gap at %d: %lld then %lld\n", i, (long long)prev, (long long)id);
        }
        prev = id;
    }
    pthread_mutex_unlock(&sim_lock);
    return lost;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s underrun|silence|dead|pause|seek\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    if (!strcmp(mode, "ac3") || !strcmp(mode, "eac3")) {
        // audio-spdif: ad_spdif gives IEC61937 stereo at the rate of the
        // bursts, four times the codec's for E-AC3.
        bool eac3 = !strcmp(mode, "eac3");
        int rate = eac3 ? RATE * 4 : RATE;
        struct ao *ao = talloc_zero(NULL, struct ao);
        ao->driver = &audio_out_audiotrack;
        ao->priv = talloc_zero_size(ao, sizeof(struct priv));
        ao->samplerate = rate;
        ao->format = eac3 ? AF_FORMAT_S_EAC3 : AF_FORMAT_S_AC3;
        ao->channels = (struct mp_chmap)MP_CHMAP_INIT_STEREO;
        ao->num_planes = 1;
        ao->sstride = 4;
        atomic_store(&src_dry, true);
        check(init(ao) >= 0, "the IEC61937 track opens");
        struct priv *p = ao->priv;
        check(p->format == 13, "IEC61937 encoding (%d)", p->format);
        check(ao->samplerate == rate && p->samplerate == rate,
              "the bursts keep their rate %d (ao %d, track %d)", rate,
              ao->samplerate, p->samplerate);
        check(builder_rate == rate, "the AudioFormat has rate %d (%d)", rate,
              builder_rate);
        uninit(ao);
        talloc_free(ao);
        printf(failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", failures);
        return failures ? 1 : 0;
    }
    printf("driver: set_pause %s\n", audio_out_audiotrack.set_pause ? "yes" : "no");
    pthread_t dev;
    pthread_create(&dev, NULL, device_thread, NULL);
    bool silence = !strcmp(mode, "silence");
    struct ao *ao = open_ao(silence);
    ao->driver->start(ao);
    sleep_ms(500);
    check(played_count() > RATE / 4, "the track plays (%d frames in 0.5 s)", played_count());

    if (!strcmp(mode, "underrun") || !strcmp(mode, "silence")) {
        if (silence)
            atomic_store(&src_paused, true);    // stream silence: no reset
        else
            atomic_store(&src_dry, true);       // underrun: no reset either
        sleep_ms(100);
        int r0 = atomic_load(&reads), p0 = played_count();
        sleep_ms(1000);
        int r = atomic_load(&reads) - r0, p = played_count() - p0;
        printf("1 s with no audio: %d reads, %d frames played\n", r, p);
        check(r <= 300, "the thread waits instead of spinning (%d reads in 1 s)", r);
        if (silence)
            check(p >= RATE * 8 / 10, "the track is fed silence (%d frames in 1 s)", p);
        atomic_store(&src_paused, false);
        atomic_store(&src_dry, false);
        int resume = played_count();
        double t0 = now_s();
        int64_t first = 0;
        while (now_s() - t0 < 1.0) {
            played_gaps(resume, &first);
            if (first)
                break;
            sleep_ms(1);
        }
        double took = now_s() - t0;
        check(first && took < 0.25, "audio comes back (%.0f ms)", took * 1000);
    } else if (!strcmp(mode, "dead")) {
        int w0 = atomic_load(&writes);
        pthread_mutex_lock(&sim_lock);
        tracks[0].dead = true;
        pthread_mutex_unlock(&sim_lock);
        sleep_ms(1000);
        int w = atomic_load(&writes) - w0;
        pthread_mutex_lock(&sim_lock);
        int n = ntracks, st = tracks[ntracks - 1].state;
        pthread_mutex_unlock(&sim_lock);
        printf("after the death: %d writes, %d tracks, last state %d, %d reloads\n",
               w, n, st, atomic_load(&reload_requests));
        check(atomic_load(&reload_requests) == 1,
              "the output asks mpv for a reload once (%d)", atomic_load(&reload_requests));
        check(w <= 2, "no write loop on the dead track (%d writes)", w);
        check(n == 1 || st == 3, "no silent track left behind (tracks %d, state %d)", n, st);
    } else if (!strcmp(mode, "pause") || !strcmp(mode, "seek")) {
        int from = played_count() - 1;    // the last frame before the pause
        player_pause(ao, true);
        sleep_ms(500);
        if (!strcmp(mode, "seek")) {
            ao->driver->reset(ao);              // ao_reset while paused
            atomic_store(&src_next, 5000000);   // the source after the seek
            atomic_store(&src_paused, false);
            int at = played_count();            // the track was flushed
            ao->driver->start(ao);              // resume after a reset
            sleep_ms(500);
            int64_t first = 0;
            int old_after = 0;
            pthread_mutex_lock(&sim_lock);
            for (int i = at; i < nplayed; i++)
                old_after += played[i] && played[i] < 5000000;
            pthread_mutex_unlock(&sim_lock);
            int64_t lost = played_gaps(at, &first);
            check(old_after == 0, "no frame from before the seek after it (%d)", old_after);
            check(first == 5000000 && lost == 0,
                  "after the seek the source plays from its start, whole (first %lld, %lld lost)",
                  (long long)first, (long long)lost);
        } else {
            player_pause(ao, false);
            sleep_ms(500);
            if (getenv("VERBOSE")) {
                pthread_mutex_lock(&sim_lock);
                printf("     after resume: state %d, queue %d, played %d, last %lld, writes %d, reads %d\n",
                       tracks[0].state, tracks[0].len, nplayed,
                       nplayed ? (long long)played[nplayed - 1] : 0LL,
                       atomic_load(&writes), atomic_load(&reads));
                pthread_mutex_unlock(&sim_lock);
            }
            int64_t first = 0;
            int64_t lost = played_gaps(from, &first);
            printf("across the pause: %lld frames lost (%.0f ms)\n",
                   (long long)lost, lost * 1000.0 / RATE);
            check(lost == 0, "a pause loses no audio (%lld frames lost)", (long long)lost);
        }
    }

    uninit(ao);
    talloc_free(ao);
    atomic_store(&device_quit, true);
    pthread_join(dev, NULL);
    printf(failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", failures);
    return failures ? 1 : 0;
}
