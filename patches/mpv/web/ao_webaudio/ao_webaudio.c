/* MAK_AO_WEBAUDIO_PATCH_V1 ─── ao_webaudio: mpv's audio output in the
 * browser. See patches/mpv/web/patch_ao_webaudio.py in libmpv-scripts for
 * the rationale.
 *
 * A push output: buffer.c's "ao" thread writes interleaved float32 frames
 * into a ring in wasm memory (mak_wa_ring.h), and the "mak-ring"
 * AudioWorkletProcessor of the page reads them on the browser's audio
 * thread. Nothing here waits on the main thread or on the worklet: the ring
 * is the whole interface, so a busy main thread never starves the audio.
 *
 * The format is the device's, like any fixed device: the AudioContext's
 * sample rate and the channel count the page chose, float32. mpv resamples
 * and remixes to it, so the browser never resamples.
 *
 * ao-volume and ao-mute are the gain of the output, applied in the worklet
 * after the PCM tap, where a system mixer would apply them. They live in
 * the webaudio-volume and webaudio-mute options of the core, so an output
 * reopened for the next file starts with them. */
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <emscripten/emscripten.h>

#include "mpv_talloc.h"

#include "audio/format.h"
#include "common/common.h"
#include "common/msg.h"
#include "options/m_config.h"
#include "options/m_option.h"
#include "osdep/threads.h"

#include "ao.h"
#include "internal.h"
#include "mak_wa_ring.h"

struct ao_webaudio_opts {
    int output;
    float volume;
    bool mute;
};

#define OPT_BASE_STRUCT struct ao_webaudio_opts
static const struct m_sub_options ao_webaudio_conf = {
    .opts = (const struct m_option[]) {
        {"webaudio-output", OPT_INT(output), M_RANGE(0, MAK_WA_MAX_OUTPUT)},
        {"webaudio-volume", OPT_FLOAT(volume), M_RANGE(0, 100)},
        {"webaudio-mute", OPT_BOOL(mute)},
        {0}
    },
    .defaults = &(const struct ao_webaudio_opts){
        .volume = 100,
    },
    .size = sizeof(struct ao_webaudio_opts),
};

/* The table the worklet reads. Static, so a worklet that reads a slot
 * after its output closed reads valid memory, and the ring buffers stay
 * with their slot until a bigger one replaces them. */
static struct mak_wa_table mak_wa = {
    .abi = MAK_WA_ABI,
    .slots = MAK_WA_SLOTS,
    .slot_words = MAK_WA_S_WORDS,
};
static float *mak_wa_buf[MAK_WA_SLOTS];
static size_t mak_wa_buf_floats[MAK_WA_SLOTS];
/* Guards the claim and the release of slots. The next claim starts after
 * the last one, so a slot comes back only after the others: a worklet
 * still in a render quantum of a closed slot never sees it reopened. */
static mp_static_mutex mak_wa_lock = MP_STATIC_MUTEX_INITIALIZER;
static bool mak_wa_claimed[MAK_WA_SLOTS];
static int mak_wa_next;

/* The page's glue finds the table here (main thread, once). */
EMSCRIPTEN_KEEPALIVE struct mak_wa_table *mak_wa_table_get(void);
EMSCRIPTEN_KEEPALIVE struct mak_wa_table *mak_wa_table_get(void)
{
    return &mak_wa;
}

struct priv {
    struct mak_wa_slot *slot;
    int index;
    struct m_config_cache *opts_cache;
    struct ao_webaudio_opts *opts;
    uint32_t device_gen;
    bool reload_asked;
};

/* Volume in percent to a gain on the cubic curve of mpv's volume and of
 * PulseAudio, so 50 sounds like half. Mute is a gain of 0. As float bits,
 * the form of the slot's word. */
static uint32_t gain_bits(const struct ao_webaudio_opts *opts)
{
    float v = MPCLAMP(opts->volume, 0, 100) / 100.0f;
    float gain = opts->mute ? 0.0f : v * v * v;
    uint32_t bits;
    memcpy(&bits, &gain, sizeof(bits));
    return bits;
}

static void apply_gain(struct ao *ao)
{
    struct priv *p = ao->priv;
    atomic_store(&p->slot->gain, gain_bits(p->opts));
}

/* A slot and a ring of at least floats samples, or -1. */
static int claim_slot(uint32_t floats)
{
    int found = -1;
    mp_mutex_lock(&mak_wa_lock);
    for (int n = 0; n < MAK_WA_SLOTS; n++) {
        int i = (mak_wa_next + n) % MAK_WA_SLOTS;
        if (!mak_wa_claimed[i]) {
            found = i;
            break;
        }
    }
    if (found >= 0 && mak_wa_buf_floats[found] < floats) {
        float *buf = calloc(floats, sizeof(float));
        if (buf) {
            free(mak_wa_buf[found]);
            mak_wa_buf[found] = buf;
            mak_wa_buf_floats[found] = floats;
        } else {
            found = -1;
        }
    }
    if (found >= 0) {
        mak_wa_claimed[found] = true;
        mak_wa_next = (found + 1) % MAK_WA_SLOTS;
    }
    mp_mutex_unlock(&mak_wa_lock);
    return found;
}

static int init(struct ao *ao)
{
    struct priv *p = ao->priv;
    uint32_t rate = atomic_load(&mak_wa.rate);
    uint32_t chans = atomic_load(&mak_wa.channels);
    if (!rate || !chans || chans > MP_NUM_CHANNELS) {
        MP_ERR(ao, "No AudioContext: the page has not set up web audio "
                   "(makWebAudio.init).\n");
        return -1;
    }

    p->opts_cache = m_config_cache_alloc(ao, ao->global, &ao_webaudio_conf);
    p->opts = p->opts_cache->opts;
    p->device_gen = atomic_load(&mak_wa.device_gen);

    ao->samplerate = rate;
    ao->format = AF_FORMAT_FLOAT;
    struct mp_chmap map;
    mp_chmap_from_channels(&map, chans);
    struct mp_chmap_sel sel = {.tmp = ao};
    mp_chmap_sel_add_map(&sel, &map);
    if (!ao_chmap_sel_adjust(ao, &sel, &ao->channels))
        ao->channels = map;

    // The ring holds audio-buffer (0.2 s by default) in whole quanta, in
    // twice as many slots (mak_wa_ring.h: room after a reset).
    uint32_t cap = ceil(ao->def_buffer * rate / MAK_WA_QUANTUM);
    cap = MPMAX(cap, 8) * MAK_WA_QUANTUM;
    uint32_t size = MAK_WA_QUANTUM;
    while (size < 2 * cap)
        size *= 2;

    p->index = claim_slot(size * chans);
    if (p->index < 0) {
        MP_ERR(ao, "No free web audio slot (%d outputs open).\n", MAK_WA_SLOTS);
        return -1;
    }
    p->slot = &mak_wa.slot[p->index];
    mak_wa_open(p->slot, p->opts->output, mak_wa_buf[p->index], cap, size,
                chans, gain_bits(p->opts));

    ao->device_buffer = cap;
    MP_VERBOSE(ao, "output %d, slot %d, %u frames (ring of %u).\n",
               p->opts->output, p->index, cap, size);
    return 0;
}

static void uninit(struct ao *ao)
{
    struct priv *p = ao->priv;
    if (!p->slot)
        return;
    mak_wa_close(p->slot);
    mp_mutex_lock(&mak_wa_lock);
    mak_wa_claimed[p->index] = false;
    mp_mutex_unlock(&mak_wa_lock);
    p->slot = NULL;
}

static void reset(struct ao *ao)
{
    struct priv *p = ao->priv;
    atomic_store(&p->slot->started, 0);
    atomic_store(&p->slot->paused, 0);
    mak_wa_flush(p->slot);
}

static void start(struct ao *ao)
{
    struct priv *p = ao->priv;
    atomic_store(&p->slot->started, 1);
}

// The worklet keeps the frames and plays silence; a resume goes on at once.
static bool set_pause(struct ao *ao, bool paused)
{
    struct priv *p = ao->priv;
    atomic_store(&p->slot->paused, paused);
    return true;
}

static bool audio_write(struct ao *ao, void **data, int samples)
{
    struct priv *p = ao->priv;
    // buffer.c writes at most the free space get_state reported.
    mak_wa_write(p->slot, data[0], samples);
    return true;
}

static void get_state(struct ao *ao, struct mp_pcm_state *state)
{
    struct priv *p = ao->priv;
    struct mak_wa_slot *s = p->slot;

    // A new AudioContext (another rate) or channel count: reopen.
    if (!p->reload_asked && atomic_load(&mak_wa.device_gen) != p->device_gen) {
        p->reload_asked = true;
        MP_VERBOSE(ao, "The web audio device changed, reopening.\n");
        ao_request_reload(ao);
    }
    if (m_config_cache_update(p->opts_cache))
        apply_gain(ao);

    uint32_t queued = mak_wa_queued(s);
    state->free_samples = mak_wa_free(s);
    state->queued_samples = queued;
    state->delay = queued / (double)ao->samplerate +
                   atomic_load(&mak_wa.latency_us) / 1e6;
    // A suspended AudioContext reads nothing: the output stays "playing"
    // with a full ring, and the position waits with it.
    state->playing = atomic_load(&s->started) && queued > 0;
}

static int control(struct ao *ao, enum aocontrol cmd, void *arg)
{
    struct priv *p = ao->priv;
    switch (cmd) {
    case AOCONTROL_GET_VOLUME:
        *(float *)arg = p->opts->volume;
        return CONTROL_OK;
    case AOCONTROL_SET_VOLUME:
        p->opts->volume = MPCLAMP(*(float *)arg, 0, 100);
        m_config_cache_write_opt(p->opts_cache, &p->opts->volume);
        apply_gain(ao);
        return CONTROL_OK;
    case AOCONTROL_GET_MUTE:
        *(bool *)arg = p->opts->mute;
        return CONTROL_OK;
    case AOCONTROL_SET_MUTE:
        p->opts->mute = *(bool *)arg;
        m_config_cache_write_opt(p->opts_cache, &p->opts->mute);
        apply_gain(ao);
        return CONTROL_OK;
    }
    return CONTROL_UNKNOWN;
}

const struct ao_driver audio_out_webaudio = {
    .description = "Web Audio (AudioWorklet)",
    .name      = "webaudio",
    .init      = init,
    .uninit    = uninit,
    .reset     = reset,
    .start     = start,
    .set_pause = set_pause,
    .write     = audio_write,
    .get_state = get_state,
    .control   = control,
    .priv_size = sizeof(struct priv),
    .global_opts = &ao_webaudio_conf,
};
