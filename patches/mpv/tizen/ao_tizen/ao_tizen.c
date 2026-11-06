/* MAK_AO_TIZEN_PATCH_V1 ─── ao_tizen: mpv's audio output on Tizen, through
 * the audio_out API of capi-media-audio-io. See patches/mpv/tizen/
 * patch_ao_tizen.py in libmpv-scripts for the rationale.
 *
 * A pull output, like ao_audiotrack: a thread of its own reads frames with
 * ao_read_data and hands them to audio_out_write, which blocks while the
 * stream is full. audio_out_write holds the handle's lock for its whole
 * call, so audio_out_pause and audio_out_flush wait for a write in flight,
 * and a write on a paused handle fails. The thread never changes the
 * handle's state: start, reset and set_pause do, from the core.
 *
 * - A chunk read while a pause arrives stays pending and is written first
 *   on the resume, so a pause loses nothing. A reset drops it.
 * - Each reset bumps a generation: a write that was in flight across it
 *   counts for nothing, its frames were flushed.
 * - audio_out has no position or latency query. The frames heard follow the
 *   clock from the last start or resume, so the queue is what was written
 *   past them, never below 0 (an underrun) nor above the frames written.
 *   The latency of the sink after the stream is not seen.
 * - The device takes 8 to 192 kHz, mono or stereo, 16 or 32 bit: mpv
 *   converts the rest. The stream is of the media type, and the playback
 *   focus is the app's to take. */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include <audio_io.h>
#include <sound_manager.h>

#include "mpv_talloc.h"

#include "audio/format.h"
#include "common/common.h"
#include "common/msg.h"
#include "osdep/threads.h"
#include "osdep/timer.h"

#include "ao.h"
#include "internal.h"

// The frames of one write, and how far ahead the stream is filled.
#define CHUNK_MS 20
#define BUFFER_MS 100

enum tz_state { TZ_STOPPED, TZ_PLAYING, TZ_PAUSED };

struct priv {
    audio_out_h out;
    sound_stream_info_h info;
    bool device_paused;         // the handle's state; core thread only

    mp_thread thread;
    bool thread_created;
    mp_mutex lock;
    mp_cond wakeup;
    // Under lock.
    bool terminate;
    enum tz_state state;
    uint64_t generation;        // bumped by every reset
    int pending;                // frames read and not yet written
    int64_t written;            // frames written since the last reset
    int64_t heard_base;         // frames heard at the clock's anchor
    int64_t anchor_ns;          // last start or resume, 0 when paused
    bool warned;                // a failed write was logged

    void *chunk;
    int chunk_samples;
};

static int64_t heard_locked(struct ao *ao, int64_t now)
{
    struct priv *p = ao->priv;
    int64_t heard = p->heard_base;
    if (p->anchor_ns)
        heard += (now - p->anchor_ns) * ao->samplerate / INT64_C(1000000000);
    return MPCLAMP(heard, 0, p->written);
}

// Freezes the frames heard where they are now (a pause, an underrun).
static void anchor_locked(struct ao *ao, int64_t now, bool running)
{
    struct priv *p = ao->priv;
    p->heard_base = heard_locked(ao, now);
    p->anchor_ns = running ? now : 0;
}

static MP_THREAD_VOID playthread(void *arg)
{
    struct ao *ao = arg;
    struct priv *p = ao->priv;
    mp_thread_set_name("ao/tizen");
    mp_mutex_lock(&p->lock);
    while (!p->terminate) {
        if (p->state != TZ_PLAYING) {
            mp_cond_wait(&p->wakeup, &p->lock);
            continue;
        }
        uint64_t gen = p->generation;
        int64_t now = mp_time_ns();
        if (heard_locked(ao, now) >= p->written)
            anchor_locked(ao, now, true);   // dry: the clock starts again
        if (!p->pending) {
            int64_t queued = p->written - heard_locked(ao, now);
            int64_t out = now + MP_TIME_S_TO_NS(queued / (double)ao->samplerate);
            mp_mutex_unlock(&p->lock);
            ao_read_data(ao, &p->chunk, p->chunk_samples, out, NULL, true, false);
            mp_mutex_lock(&p->lock);
            if (gen != p->generation)
                continue;               // reset while reading: dropped
            p->pending = p->chunk_samples;
            if (p->state != TZ_PLAYING)
                continue;               // paused while reading: kept
        }
        int samples = p->pending;
        mp_mutex_unlock(&p->lock);
        int ret = audio_out_write(p->out, p->chunk, samples * ao->sstride);
        mp_mutex_lock(&p->lock);
        if (gen != p->generation)
            continue;                   // flushed by a reset
        if (ret >= 0) {
            p->written += samples;
            p->pending = 0;
            p->warned = false;
        } else if (p->state == TZ_PLAYING) {
            // Not a pause that came first: the device refused. The chunk
            // is tried again, without spinning.
            if (!p->warned)
                MP_WARN(ao, "audio_out_write failed: %d\n", ret);
            p->warned = true;
            mp_cond_timedwait(&p->wakeup, &p->lock, MP_TIME_MS_TO_NS(100));
        }
    }
    mp_mutex_unlock(&p->lock);
    MP_THREAD_RETURN();
}

static void uninit(struct ao *ao)
{
    struct priv *p = ao->priv;
    if (p->thread_created) {
        mp_mutex_lock(&p->lock);
        p->terminate = true;
        p->generation++;
        mp_cond_broadcast(&p->wakeup);
        mp_mutex_unlock(&p->lock);
        // A write in flight returns: the stream keeps playing until the
        // handle goes.
        mp_thread_join(p->thread);
    }
    if (p->out) {
        audio_out_unprepare(p->out);
        audio_out_destroy(p->out);
    }
    if (p->info)
        sound_manager_destroy_stream_information(p->info);
    mp_cond_destroy(&p->wakeup);
    mp_mutex_destroy(&p->lock);
}

static int init(struct ao *ao)
{
    struct priv *p = ao->priv;
    mp_mutex_init(&p->lock);
    mp_cond_init(&p->wakeup);

    if (af_fmt_is_spdif(ao->format)) {
        MP_ERR(ao, "no passthrough on audio_out\n");
        goto error;
    }
    int bytes = af_fmt_to_bytes(af_fmt_from_planar(ao->format));
    ao->format = bytes <= 2 && !af_fmt_is_float(ao->format)
                 ? AF_FORMAT_S16 : AF_FORMAT_S32;
    audio_sample_type_e type = ao->format == AF_FORMAT_S16
                               ? AUDIO_SAMPLE_TYPE_S16_LE
                               : AUDIO_SAMPLE_TYPE_S32_LE;

    struct mp_chmap_sel sel = {0};
    mp_chmap_sel_add_map(&sel, &(const struct mp_chmap)MP_CHMAP_INIT_MONO);
    mp_chmap_sel_add_map(&sel, &(const struct mp_chmap)MP_CHMAP_INIT_STEREO);
    if (!ao_chmap_sel_adjust(ao, &sel, &ao->channels))
        goto error;
    audio_channel_e channel = ao->channels.num == 1 ? AUDIO_CHANNEL_MONO
                                                    : AUDIO_CHANNEL_STEREO;

    if (ao->samplerate < 8000 || ao->samplerate > 192000)
        ao->samplerate = 48000;

    int err = audio_out_create_new(ao->samplerate, channel, type, &p->out);
    if (err != AUDIO_IO_ERROR_NONE) {
        p->out = NULL;
        MP_ERR(ao, "audio_out_create_new failed: %d\n", err);
        goto error;
    }
    // The media type routes and scales the stream as media. Without it the
    // stream still plays, with the system's default type.
    err = sound_manager_create_stream_information(SOUND_STREAM_TYPE_MEDIA,
                                                  NULL, NULL, &p->info);
    if (err == SOUND_MANAGER_ERROR_NONE) {
        err = audio_out_set_sound_stream_info(p->out, p->info);
        if (err != AUDIO_IO_ERROR_NONE)
            MP_WARN(ao, "audio_out_set_sound_stream_info failed: %d\n", err);
    } else {
        p->info = NULL;
        MP_WARN(ao, "no media stream information: %d\n", err);
    }
    err = audio_out_prepare(p->out);
    if (err != AUDIO_IO_ERROR_NONE) {
        MP_ERR(ao, "audio_out_prepare failed: %d\n", err);
        goto error;
    }
    // Prepared is running: held paused until start.
    if (audio_out_pause(p->out) == AUDIO_IO_ERROR_NONE)
        p->device_paused = true;

    int sstride = af_fmt_to_bytes(ao->format) * ao->channels.num;
    p->chunk_samples = ao->samplerate * CHUNK_MS / 1000;
    p->chunk = talloc_zero_size(ao, p->chunk_samples * sstride);
    ao->device_buffer = ao->samplerate * BUFFER_MS / 1000;

    if (mp_thread_create(&p->thread, playthread, ao)) {
        MP_ERR(ao, "no thread\n");
        goto error;
    }
    p->thread_created = true;
    return 1;

error:
    uninit(ao);
    return -1;
}

static void device_pause(struct ao *ao, bool paused)
{
    struct priv *p = ao->priv;
    if (p->device_paused == paused)
        return;
    int err = paused ? audio_out_pause(p->out) : audio_out_resume(p->out);
    if (err == AUDIO_IO_ERROR_NONE)
        p->device_paused = paused;
    else
        MP_WARN(ao, "audio_out_%s failed: %d\n", paused ? "pause" : "resume", err);
}

static void reset(struct ao *ao)
{
    struct priv *p = ao->priv;
    mp_mutex_lock(&p->lock);
    p->state = TZ_STOPPED;
    p->generation++;
    p->pending = 0;
    mp_mutex_unlock(&p->lock);
    // Both wait for a write in flight, then drop what it queued.
    device_pause(ao, true);
    audio_out_flush(p->out);
    mp_mutex_lock(&p->lock);
    p->written = 0;
    p->heard_base = 0;
    p->anchor_ns = 0;
    mp_mutex_unlock(&p->lock);
}

static void start(struct ao *ao)
{
    struct priv *p = ao->priv;
    device_pause(ao, false);
    mp_mutex_lock(&p->lock);
    p->state = TZ_PLAYING;
    anchor_locked(ao, mp_time_ns(), true);
    mp_cond_broadcast(&p->wakeup);
    mp_mutex_unlock(&p->lock);
}

static bool set_pause(struct ao *ao, bool paused)
{
    struct priv *p = ao->priv;
    if (paused) {
        mp_mutex_lock(&p->lock);
        p->state = TZ_PAUSED;
        mp_mutex_unlock(&p->lock);
        device_pause(ao, true);
        // Frozen once the device stopped: a write in flight finished first.
        mp_mutex_lock(&p->lock);
        anchor_locked(ao, mp_time_ns(), false);
        mp_mutex_unlock(&p->lock);
    } else {
        start(ao);
    }
    return true;
}

const struct ao_driver audio_out_tizen = {
    .description = "Tizen audio_out",
    .name      = "tizen",
    .init      = init,
    .uninit    = uninit,
    .reset     = reset,
    .start     = start,
    .set_pause = set_pause,
    .priv_size = sizeof(struct priv),
};
