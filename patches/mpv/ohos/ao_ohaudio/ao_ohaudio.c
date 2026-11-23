/*
 * OHAudio audio output driver.
 *
 * Copyright (C) 2025 Bao Han <erbws@foxmail.com>
 * Copyright (C) 2026 Alessandro Di Ronza <ales.drnz@gmail.com>
 *
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

/* MAK_AO_OHAUDIO_PATCH_V1 ─── ao_ohaudio: mpv's audio output on OpenHarmony
 * and HarmonyOS, through OHAudio. The driver of github.com/ErBWs/mpv
 * (branch feat-ohos-0.41.0), reworked for mpv_audio_kit; see
 * patches/mpv/ohos/patch_ao_ohaudio.py in libmpv-scripts for the rationale.
 *
 * A pull output. OHAudio calls the write callback on a thread of its own
 * (OpenHarmony 7.0, renderer_in_client.cpp): the buffer the callback fills
 * is queued and written to the server after it returns. Flush drops that
 * queue but does not wait for a callback in flight, so a buffer filled
 * across a Flush would be queued after it. So:
 *
 * - Each reset bumps a generation and waits for the callback in flight
 *   before Pause and Flush; a callback whose read crossed a reset returns
 *   AUDIO_DATA_CALLBACK_RESULT_INVALID, and its buffer is dropped.
 * - A pause loses nothing: a buffer filled across it stays queued and plays
 *   on the resume.
 * - The frames heard follow the clock from the last start or resume, held
 *   between 0 and the frames handed out, as in ao_tizen; every 200 ms a
 *   callback reads OH_AudioRenderer_GetTimestamp and sets the clock from
 *   the device's position. Flush resets that position, so the frames heard
 *   after a reset are the position itself; a position that goes back (a
 *   route change) is set against the clock again. A timestamp from before
 *   the last start is stale: the clock alone runs until a newer one.
 * - Start, Pause and Flush are only called under dev_lock: from the core
 *   (start, reset, set_pause) and from the control thread, which starts the
 *   stream again when the system ends an interruption and asks mpv for a
 *   reload when no callback came for a second while playing (a dead
 *   device), or for 3 s after a start (a start that failed; a Bluetooth
 *   output may take more than a second to ask for its first buffer).
 * - The system pauses or stops a stream it interrupts (a call, another
 *   app): the clock is frozen until the resume, the driver's own or the
 *   core's next start. A shared interruption, or the old device gone, asks
 *   the app to pause: only logged, the app's media session decides.
 * - The device takes 14 rates from 8 to 192 kHz, mono or stereo, 16 or 32
 *   bit: another rate plays at the next one up, and mpv converts the rest.
 *   A setter the builder refuses fails the init. The stream is of the
 *   music usage.
 * - One window is left: a callback that returned VALID but whose buffer
 *   OHAudio has not queued yet when a reset checks in_callback: a 20 ms
 *   buffer from before a seek can then play after it. The Pause before the
 *   Flush, a round trip to the audio server, narrows that window.
 * - Only the OHAudio calls of API 12 or older are made (HarmonyOS 5.0 is
 *   API 12): libmpv is linked with -z now, and a newer symbol would stop the
 *   library from loading on an older system. */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>

#include "mpv_talloc.h"

#include "audio/format.h"
#include "common/common.h"
#include "common/msg.h"
#include "osdep/threads.h"
#include "osdep/timer.h"

#include "ao.h"
#include "internal.h"

// How far ahead the stream is filled.
#define BUFFER_MS 100
// How often a callback reads the device's position.
#define QUERY_NS MP_TIME_MS_TO_NS(200)
// A timestamp older than this is not the stream's present.
#define STALE_NS MP_TIME_S_TO_NS(2)
// No callback this long while playing: the device is gone. The first
// callback after a start gets longer: a Bluetooth output takes its time.
#define DEAD_NS MP_TIME_S_TO_NS(1)
#define FIRST_NS MP_TIME_S_TO_NS(3)

enum oh_state { OH_STOPPED, OH_PLAYING, OH_PAUSED };

struct priv {
    OH_AudioStreamBuilder *builder;
    OH_AudioRenderer *renderer;

    // Held around every Start, Pause, Flush and Stop, so the control
    // thread's resume never runs between the core's pause and its state.
    mp_mutex dev_lock;

    mp_thread thread;
    bool thread_created;
    mp_mutex lock;
    mp_cond wakeup;
    // Under lock.
    bool terminate;
    enum oh_state state;
    uint64_t generation;        // bumped by every reset
    bool in_callback;           // a callback is between its check and its end
    bool interrupted;           // the system paused or stopped the stream
    bool resume_pending;        // the system ended its interruption
    int64_t written;            // frames handed out since the last reset
    int64_t heard_base;         // frames heard at the clock's anchor
    int64_t anchor_ns;          // last start, resume or sync; 0 when frozen
    int64_t started_ns;         // last start: older timestamps are stale
    bool have_origin;           // the device's position is known
    int64_t origin;             // device position of the epoch's frame 0
    int64_t last_pos;
    int64_t last_query_ns;
    int64_t last_callback_ns;   // while playing; 0 when not watched
    bool fed;                   // a callback came since the last start
    bool reload_asked;
};

static int64_t frames_in(struct ao *ao, int64_t ns)
{
    // Seconds and the rest apart: the product of the whole time overflows
    // after 13 hours at 192 kHz.
    return ns / INT64_C(1000000000) * ao->samplerate +
           ns % INT64_C(1000000000) * ao->samplerate / INT64_C(1000000000);
}

static int64_t heard_locked(struct ao *ao, int64_t now)
{
    struct priv *p = ao->priv;
    int64_t heard = p->heard_base;
    if (p->anchor_ns)
        heard += frames_in(ao, now - p->anchor_ns);
    return MPCLAMP(heard, 0, p->written);
}

// Freezes the frames heard where they are now (a pause, an interruption),
// or starts the clock from there.
static void anchor_locked(struct ao *ao, int64_t now, bool running)
{
    struct priv *p = ao->priv;
    p->heard_base = heard_locked(ao, now);
    p->anchor_ns = running ? now : 0;
}

// Sets the clock from the device: frame pos was heard at ts.
static void sync_locked(struct ao *ao, int64_t pos, int64_t ts, int64_t now)
{
    struct priv *p = ao->priv;
    if (pos < 0 || ts <= 0 || ts > now || now - ts > STALE_NS ||
        ts < p->started_ns || !p->anchor_ns)
        return;
    int64_t dev = pos + frames_in(ao, now - ts);
    if (!p->have_origin || pos < p->last_pos) {
        // After a reset the position starts from 0 (Flush resets it); one
        // past the frames handed out, or one that went back, is set
        // against the clock instead.
        int64_t est = heard_locked(ao, now);
        p->origin = !p->have_origin && dev <= p->written ? 0 : dev - est;
        p->have_origin = true;
    }
    p->last_pos = pos;
    p->heard_base = MPCLAMP(dev - p->origin, 0, p->written);
    p->anchor_ns = now;
}

static OH_AudioData_Callback_Result on_write(OH_AudioRenderer *renderer,
                                             void *user, void *data,
                                             int32_t bytes)
{
    struct ao *ao = user;
    struct priv *p = ao->priv;
    int samples = bytes > 0 ? bytes / ao->sstride : 0;

    mp_mutex_lock(&p->lock);
    int64_t now = mp_time_ns();
    if (p->terminate || p->state != OH_PLAYING || !samples) {
        mp_mutex_unlock(&p->lock);
        if (bytes > 0)
            memset(data, 0, bytes);
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }
    uint64_t gen = p->generation;
    p->in_callback = true;
    p->last_callback_ns = now;
    p->fed = true;
    if (p->interrupted) {
        // The stream runs again: the system resumed it.
        p->interrupted = false;
        p->started_ns = now;
        anchor_locked(ao, now, true);
    }
    bool query = !p->last_query_ns || now - p->last_query_ns >= QUERY_NS;
    if (query)
        p->last_query_ns = now;
    mp_mutex_unlock(&p->lock);

    int64_t pos = 0, ts = 0;
    bool got = query &&
        OH_AudioRenderer_GetTimestamp(renderer, CLOCK_MONOTONIC, &pos, &ts) ==
            AUDIOSTREAM_SUCCESS;

    mp_mutex_lock(&p->lock);
    now = mp_time_ns();
    if (got && gen == p->generation)
        sync_locked(ao, pos, ts, now);
    if (heard_locked(ao, now) >= p->written)
        anchor_locked(ao, now, true);   // dry: the clock starts again
    // When the buffer's last frame is heard, as buffer.c reads it.
    int64_t queued = p->written - heard_locked(ao, now) + samples;
    int64_t out = now + MP_TIME_S_TO_NS(queued / (double)ao->samplerate);
    mp_mutex_unlock(&p->lock);

    // Blocking: buffer.c calls start, reset and set_pause of a pull output
    // outside its lock, and this callback holds neither lock here.
    void *planes[1] = {data};
    ao_read_data(ao, planes, samples, out, NULL, true, true);
    if (bytes > samples * ao->sstride)
        memset((char *)data + samples * ao->sstride, 0, bytes - samples * ao->sstride);

    mp_mutex_lock(&p->lock);
    p->in_callback = false;
    mp_cond_broadcast(&p->wakeup);
    bool valid = gen == p->generation && !p->terminate;
    if (valid)
        p->written += samples;
    mp_mutex_unlock(&p->lock);
    return valid ? AUDIO_DATA_CALLBACK_RESULT_VALID
                 : AUDIO_DATA_CALLBACK_RESULT_INVALID;
}

// The write callback of OH_AudioRenderer_Callbacks, which
// OH_AudioStreamBuilder_SetRendererWriteDataCallback replaces: only
// there for the systems that would call it anyway.
static int32_t on_write_legacy(OH_AudioRenderer *renderer, void *user,
                               void *data, int32_t bytes)
{
    (void)renderer; (void)user;
    if (bytes > 0)
        memset(data, 0, bytes);
    return 0;
}

static int32_t on_interrupt(OH_AudioRenderer *renderer, void *user,
                            OH_AudioInterrupt_ForceType type,
                            OH_AudioInterrupt_Hint hint)
{
    (void)renderer;
    struct ao *ao = user;
    struct priv *p = ao->priv;
    mp_mutex_lock(&p->lock);
    switch (hint) {
    case AUDIOSTREAM_INTERRUPT_HINT_PAUSE:
    case AUDIOSTREAM_INTERRUPT_HINT_STOP:
        if (type == AUDIOSTREAM_INTERRUPT_FORCE) {
            // The system paused or stopped the stream itself.
            MP_INFO(ao, "interrupted by the system (hint %d)\n", hint);
            if (!p->interrupted)
                anchor_locked(ao, mp_time_ns(), false);
            p->interrupted = true;
            p->resume_pending = false;
        } else {
            MP_WARN(ao, "the system asks to pause (hint %d)\n", hint);
        }
        break;
    case AUDIOSTREAM_INTERRUPT_HINT_RESUME:
        if (p->interrupted && p->state == OH_PLAYING) {
            p->resume_pending = true;
            mp_cond_broadcast(&p->wakeup);
        }
        break;
    default:
        MP_VERBOSE(ao, "interrupt hint %d\n", hint);
        break;
    }
    mp_mutex_unlock(&p->lock);
    return 0;
}

static int32_t on_error(OH_AudioRenderer *renderer, void *user,
                        OH_AudioStream_Result error)
{
    (void)renderer;
    struct ao *ao = user;
    struct priv *p = ao->priv;
    MP_ERR(ao, "renderer error %d, reopening\n", error);
    mp_mutex_lock(&p->lock);
    bool ask = !p->reload_asked && !p->terminate;
    p->reload_asked = true;
    mp_mutex_unlock(&p->lock);
    if (ask)
        ao_request_reload(ao);
    return 0;
}

static void on_device_change(OH_AudioRenderer *renderer, void *user,
                             OH_AudioStream_DeviceChangeReason reason)
{
    (void)renderer;
    struct ao *ao = user;
    // The stream follows the new route by itself. The old device gone asks
    // the app to pause: its media session decides.
    if (reason == REASON_OLD_DEVICE_UNAVAILABLE)
        MP_WARN(ao, "the output device is gone\n");
    else
        MP_VERBOSE(ao, "output device changed (reason %d)\n", reason);
}

static MP_THREAD_VOID control_thread(void *arg)
{
    struct ao *ao = arg;
    struct priv *p = ao->priv;
    mp_thread_set_name("ao/ohaudio");
    mp_mutex_lock(&p->lock);
    while (!p->terminate) {
        if (p->resume_pending) {
            p->resume_pending = false;
            mp_mutex_unlock(&p->lock);
            mp_mutex_lock(&p->dev_lock);
            mp_mutex_lock(&p->lock);
            // Not if the core paused, reset or started it meanwhile.
            bool resume = p->interrupted && p->state == OH_PLAYING && !p->terminate;
            mp_mutex_unlock(&p->lock);
            OH_AudioStream_Result ret = resume ? OH_AudioRenderer_Start(p->renderer)
                                               : AUDIOSTREAM_SUCCESS;
            mp_mutex_lock(&p->lock);
            if (resume && ret == AUDIOSTREAM_SUCCESS) {
                int64_t now = mp_time_ns();
                p->interrupted = false;
                p->started_ns = now;
                p->last_callback_ns = now;
                p->fed = false;
                anchor_locked(ao, now, true);
                MP_INFO(ao, "resumed after the interruption\n");
            } else if (resume) {
                MP_WARN(ao, "OH_AudioRenderer_Start failed: %d\n", ret);
            }
            mp_mutex_unlock(&p->dev_lock);
            continue;
        }
        int64_t now = mp_time_ns();
        int64_t limit = p->fed ? DEAD_NS : FIRST_NS;
        if (p->state == OH_PLAYING && !p->interrupted && p->last_callback_ns &&
            now - p->last_callback_ns >= limit && !p->reload_asked)
        {
            MP_ERR(ao, "no data asked for %d s, reopening\n", p->fed ? 1 : 3);
            p->reload_asked = true;
            ao_request_reload(ao);
        }
        mp_cond_timedwait(&p->wakeup, &p->lock, MP_TIME_MS_TO_NS(100));
    }
    mp_mutex_unlock(&p->lock);
    MP_THREAD_RETURN();
}

static void uninit(struct ao *ao)
{
    struct priv *p = ao->priv;
    mp_mutex_lock(&p->lock);
    p->terminate = true;
    p->generation++;
    mp_cond_broadcast(&p->wakeup);
    mp_mutex_unlock(&p->lock);
    if (p->thread_created)
        mp_thread_join(p->thread);
    if (p->renderer) {
        // A callback in flight ends first: it reads from the ao.
        mp_mutex_lock(&p->lock);
        while (p->in_callback)
            mp_cond_wait(&p->wakeup, &p->lock);
        mp_mutex_unlock(&p->lock);
        uint32_t underflows;
        if (OH_AudioRenderer_GetUnderflowCount(p->renderer, &underflows) ==
            AUDIOSTREAM_SUCCESS)
            MP_VERBOSE(ao, "%u underflows\n", underflows);
        OH_AudioRenderer_Stop(p->renderer);
        OH_AudioRenderer_Release(p->renderer);
        p->renderer = NULL;
    }
    if (p->builder) {
        OH_AudioStreamBuilder_Destroy(p->builder);
        p->builder = NULL;
    }
    mp_cond_destroy(&p->wakeup);
    mp_mutex_destroy(&p->lock);
    mp_mutex_destroy(&p->dev_lock);
}

// The rates OHAudio's renderer takes (OHAudioStreamBuilder.cpp, the
// renderer's supported sampling rates); SetSamplingRate refuses the rest.
static const int device_rates[] = {
    8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000,
    64000, 88200, 96000, 176400, 192000,
};

// The first rate the device takes at or above [rate], so mpv resamples up
// and nothing is lost: 37800 Hz plays at 44100 Hz.
static int device_rate(int rate)
{
    for (size_t i = 0; i < MP_ARRAY_SIZE(device_rates); i++) {
        if (device_rates[i] >= rate)
            return device_rates[i];
    }
    return device_rates[MP_ARRAY_SIZE(device_rates) - 1];
}

static int init(struct ao *ao)
{
    struct priv *p = ao->priv;
    mp_mutex_init(&p->dev_lock);
    mp_mutex_init(&p->lock);
    mp_cond_init(&p->wakeup);

    if (af_fmt_is_spdif(ao->format)) {
        MP_ERR(ao, "no passthrough on OHAudio\n");
        goto error;
    }
    int bytes = af_fmt_to_bytes(af_fmt_from_planar(ao->format));
    ao->format = bytes <= 2 && !af_fmt_is_float(ao->format)
                 ? AF_FORMAT_S16 : AF_FORMAT_S32;
    OH_AudioStream_SampleFormat format = ao->format == AF_FORMAT_S16
                                         ? AUDIOSTREAM_SAMPLE_S16LE
                                         : AUDIOSTREAM_SAMPLE_S32LE;

    struct mp_chmap_sel sel = {0};
    mp_chmap_sel_add_map(&sel, &(const struct mp_chmap)MP_CHMAP_INIT_MONO);
    mp_chmap_sel_add_map(&sel, &(const struct mp_chmap)MP_CHMAP_INIT_STEREO);
    if (!ao_chmap_sel_adjust(ao, &sel, &ao->channels))
        goto error;

    ao->samplerate = device_rate(ao->samplerate);

    OH_AudioStream_Result res =
        OH_AudioStreamBuilder_Create(&p->builder, AUDIOSTREAM_TYPE_RENDERER);
    if (res != AUDIOSTREAM_SUCCESS) {
        p->builder = NULL;
        MP_ERR(ao, "OH_AudioStreamBuilder_Create failed: %d\n", res);
        goto error;
    }
    res = OH_AudioStreamBuilder_SetSamplingRate(p->builder, ao->samplerate);
    if (res != AUDIOSTREAM_SUCCESS && ao->samplerate != 48000) {
        MP_WARN(ao, "%d Hz refused (%d), 48000 Hz instead\n", ao->samplerate, res);
        ao->samplerate = 48000;
        res = OH_AudioStreamBuilder_SetSamplingRate(p->builder, ao->samplerate);
    }
    if (res == AUDIOSTREAM_SUCCESS)
        res = OH_AudioStreamBuilder_SetChannelCount(p->builder, ao->channels.num);
    if (res == AUDIOSTREAM_SUCCESS)
        res = OH_AudioStreamBuilder_SetSampleFormat(p->builder, format);
    if (res != AUDIOSTREAM_SUCCESS) {
        MP_ERR(ao, "%d Hz, %d channels, format %d refused: %d\n", ao->samplerate,
               ao->channels.num, format, res);
        goto error;
    }
    OH_AudioStreamBuilder_SetEncodingType(p->builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetRendererInfo(p->builder, AUDIOSTREAM_USAGE_MUSIC);
    OH_AudioStreamBuilder_SetLatencyMode(p->builder, AUDIOSTREAM_LATENCY_MODE_NORMAL);
    // The interrupt and error callbacks of API 10, then the write callback
    // of API 12, which replaces the one of the struct and may drop a
    // buffer (OHAudioStreamBuilder.cpp keeps the others).
    OH_AudioRenderer_Callbacks callbacks = {
        .OH_AudioRenderer_OnWriteData = on_write_legacy,
        .OH_AudioRenderer_OnInterruptEvent = on_interrupt,
        .OH_AudioRenderer_OnError = on_error,
    };
    res = OH_AudioStreamBuilder_SetRendererCallback(p->builder, callbacks, ao);
    if (res == AUDIOSTREAM_SUCCESS)
        res = OH_AudioStreamBuilder_SetRendererWriteDataCallback(p->builder, on_write, ao);
    if (res != AUDIOSTREAM_SUCCESS) {
        MP_ERR(ao, "no renderer callbacks: %d\n", res);
        goto error;
    }
    OH_AudioStreamBuilder_SetRendererOutputDeviceChangeCallback(p->builder,
                                                                on_device_change, ao);

    // ao->sstride is set by ao.c after init, from the format chosen here;
    // the callback reads it, and comes only after a Start.
    res = OH_AudioStreamBuilder_GenerateRenderer(p->builder, &p->renderer);
    if (res != AUDIOSTREAM_SUCCESS) {
        p->renderer = NULL;
        MP_ERR(ao, "OH_AudioStreamBuilder_GenerateRenderer failed: %d\n", res);
        goto error;
    }
    ao->device_buffer = ao->samplerate * BUFFER_MS / 1000;

    if (mp_thread_create(&p->thread, control_thread, ao)) {
        MP_ERR(ao, "no thread\n");
        goto error;
    }
    p->thread_created = true;
    return 1;

error:
    uninit(ao);
    return -1;
}

// Pause, with dev_lock held.
static void device_pause(struct ao *ao)
{
    struct priv *p = ao->priv;
    OH_AudioStream_Result res = OH_AudioRenderer_Pause(p->renderer);
    // Refused when not running: never started, or paused by the system.
    if (res != AUDIOSTREAM_SUCCESS)
        MP_VERBOSE(ao, "OH_AudioRenderer_Pause: %d\n", res);
}

static void reset(struct ao *ao)
{
    struct priv *p = ao->priv;
    mp_mutex_lock(&p->dev_lock);
    mp_mutex_lock(&p->lock);
    p->state = OH_STOPPED;
    p->generation++;
    p->resume_pending = false;
    p->last_callback_ns = 0;
    // A buffer filled across the Flush would be queued after it.
    while (p->in_callback)
        mp_cond_wait(&p->wakeup, &p->lock);
    mp_mutex_unlock(&p->lock);
    device_pause(ao);
    OH_AudioStream_Result res = OH_AudioRenderer_Flush(p->renderer);
    if (res != AUDIOSTREAM_SUCCESS)
        MP_VERBOSE(ao, "OH_AudioRenderer_Flush: %d\n", res);
    mp_mutex_lock(&p->lock);
    p->written = 0;
    p->heard_base = 0;
    p->anchor_ns = 0;
    p->have_origin = false;
    p->last_pos = 0;
    p->last_query_ns = 0;
    p->interrupted = false;
    mp_mutex_unlock(&p->lock);
    mp_mutex_unlock(&p->dev_lock);
}

static void start(struct ao *ao)
{
    struct priv *p = ao->priv;
    mp_mutex_lock(&p->dev_lock);
    mp_mutex_lock(&p->lock);
    int64_t now = mp_time_ns();
    p->state = OH_PLAYING;
    p->interrupted = false;
    p->resume_pending = false;
    p->started_ns = now;
    p->last_query_ns = 0;
    // Watched from now: a Start that fails is a dead device too.
    p->last_callback_ns = now;
    p->fed = false;
    p->reload_asked = false;
    anchor_locked(ao, now, true);
    mp_cond_broadcast(&p->wakeup);
    mp_mutex_unlock(&p->lock);
    OH_AudioStream_Result res = OH_AudioRenderer_Start(p->renderer);
    if (res != AUDIOSTREAM_SUCCESS)
        MP_WARN(ao, "OH_AudioRenderer_Start failed: %d\n", res);
    mp_mutex_unlock(&p->dev_lock);
}

static bool set_pause(struct ao *ao, bool paused)
{
    struct priv *p = ao->priv;
    if (!paused) {
        start(ao);
        return true;
    }
    mp_mutex_lock(&p->dev_lock);
    mp_mutex_lock(&p->lock);
    p->state = OH_PAUSED;
    p->resume_pending = false;
    p->last_callback_ns = 0;
    mp_mutex_unlock(&p->lock);
    device_pause(ao);
    // Frozen once the device stopped.
    mp_mutex_lock(&p->lock);
    anchor_locked(ao, mp_time_ns(), false);
    mp_mutex_unlock(&p->lock);
    mp_mutex_unlock(&p->dev_lock);
    return true;
}

const struct ao_driver audio_out_ohaudio = {
    .description = "OHAudio (OpenHarmony, HarmonyOS)",
    .name      = "ohaudio",
    .init      = init,
    .uninit    = uninit,
    .reset     = reset,
    .start     = start,
    .set_pause = set_pause,
    .priv_size = sizeof(struct priv),
};
