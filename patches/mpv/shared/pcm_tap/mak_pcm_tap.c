/* MAK_PCM_TAP_PATCH_V2 ─── PCM tap: ring buffer for post-DSP audio
 * samples, polled via the pcm-tap-frame property. See
 * patches/mpv/shared/patch_pcm_tap.py in libmpv-scripts for
 * the rationale. */
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "mpv_talloc.h"

#include <mpv/client.h>

#include "audio/format.h"
#include "audio/out/ao.h"
#include "audio/out/internal.h"
#include "audio/out/mak_pcm_tap.h"
#include "osdep/threads.h"
#include "osdep/timer.h"

/* 256 KiB of Float32: ~680 ms at 48 kHz stereo. A read returns at
 * most the latest 4096 frames (32 KB in stereo). The cap is a
 * static upper bound; the valid bytes track what the AO has
 * produced since the last format change or re-arm (`valid_bytes`). */
#define MAK_PCM_TAP_CAPACITY (256 * 1024)

/* Scratch buffer for format conversion. 64K floats = 256 KB —
 * enough for a 32K-sample stereo chunk or an 8K-sample 8-channel
 * chunk. Realistic AO chunks are 1–2K samples × 2–6 channels, so
 * this never overflows in practice; if a producer ever sends a chunk
 * larger than the scratch, convert_to_float drops it whole (returns 0
 * — rare and visually benign, skips the visualizer for one frame). */
#define MAK_PCM_TAP_SCRATCH_FLOATS (64 * 1024)
_Static_assert(MAK_PCM_TAP_SCRATCH_FLOATS * sizeof(float)
                   <= MAK_PCM_TAP_CAPACITY,
               "a converted chunk fits in the ring");

struct mak_pcm_tap {
    uint8_t         buf[MAK_PCM_TAP_CAPACITY];
    float           scratch[MAK_PCM_TAP_SCRATCH_FLOATS];
    size_t          write_pos;     /* next byte to write (wraps) */
    size_t          valid_bytes;   /* total valid bytes in ring */
    int             sample_rate;
    int             channels;
    int64_t         last_pts_ns;   /* mp_time_ns() at last write */
};

/* The lock lives OUTSIDE the state struct on purpose: Darwin's
 * PTHREAD_MUTEX_INITIALIZER carries a non-zero signature, and a single
 * initialized member drags the WHOLE struct out of __bss into __data —
 * every embedded buffer byte then ships as on-disk zeros (~0.5 MiB per
 * Apple slice for the ring structs). A separate statically-initialized
 * lock plus a zero-init struct keeps identical semantics at zero file
 * cost. (ELF/PE are immune: their static lock initializers are all
 * zero.) */
static mp_mutex g_tap_lock = MP_STATIC_MUTEX_INITIALIZER;
static struct mak_pcm_tap g_tap;

/* Activation gate. Every read stamps g_tap_read_ns. The AO-thread
 * write path returns at once until the first read, and again once
 * no read came for g_tap_idle_ns: when the listener goes away
 * (cancel, Player dispose, hot restart) the per-chunk convert and
 * copy stop. The idle span is 4 read periods, at least
 * MAK_PCM_TAP_IDLE_NS, so a slow poll keeps the tap armed. The
 * first read after an idle span re-arms it, and empties the ring if
 * the output wrote audio the tap skipped meanwhile: what the ring
 * held is from before it, maybe from another track. With no audio
 * written (a pause the reader stopped polling through) the ring still
 * ends where the output stands, and the read returns it. */
#define MAK_PCM_TAP_IDLE_NS (INT64_C(2) * 1000000000)
static atomic_int_least64_t g_tap_read_ns;   /* 0: never read */
static atomic_int_least64_t g_tap_idle_ns;
static atomic_bool g_tap_skipped;  /* a write skipped since the last read */

/* Silences the samples that are not finite: a float output can carry the
 * NaN or the infinities of its source, which would reach the reader's
 * FFT. */
static void scrub_floats(float *s, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if (!isfinite(s[i]))
            s[i] = 0.0f;
    }
}

/* Format normalisation: every supported PCM format → interleaved
 * Float32 in `dst`. Returns the number of float samples written
 * (== num_samples * channels), or 0 if the format is unsupported.
 * Per-sample cost is one mul + cast; trivially fast on audio
 * thread budgets. */
static size_t convert_to_float(int format, void **data,
                               int num_samples, int channels,
                               float *dst, size_t dst_capacity)
{
    size_t total = (size_t)num_samples * (size_t)channels;
    if (total == 0 || total > dst_capacity)
        return 0;
    switch (format) {
        case AF_FORMAT_FLOAT: {
            memcpy(dst, data[0], total * sizeof(float));
            scrub_floats(dst, total);
            return total;
        }
        case AF_FORMAT_FLOATP: {
            float **p = (float **)data;
            for (int s = 0; s < num_samples; s++)
                for (int c = 0; c < channels; c++)
                    dst[s * channels + c] = p[c][s];
            scrub_floats(dst, total);
            return total;
        }
        case AF_FORMAT_S16: {
            const int16_t *p = (const int16_t *)data[0];
            const float scale = 1.0f / 32768.0f;
            for (size_t i = 0; i < total; i++)
                dst[i] = (float)p[i] * scale;
            return total;
        }
        case AF_FORMAT_S16P: {
            int16_t **p = (int16_t **)data;
            const float scale = 1.0f / 32768.0f;
            for (int s = 0; s < num_samples; s++)
                for (int c = 0; c < channels; c++)
                    dst[s * channels + c] = (float)p[c][s] * scale;
            return total;
        }
        case AF_FORMAT_S32: {
            const int32_t *p = (const int32_t *)data[0];
            const float scale = 1.0f / 2147483648.0f;
            for (size_t i = 0; i < total; i++)
                dst[i] = (float)p[i] * scale;
            return total;
        }
        case AF_FORMAT_S32P: {
            int32_t **p = (int32_t **)data;
            const float scale = 1.0f / 2147483648.0f;
            for (int s = 0; s < num_samples; s++)
                for (int c = 0; c < channels; c++)
                    dst[s * channels + c] = (float)p[c][s] * scale;
            return total;
        }
        case AF_FORMAT_S64: {
            const int64_t *p = (const int64_t *)data[0];
            /* 1.0 / 9.2233720368547758e18 ≈ float scale for INT64_MAX */
            const float scale = 1.0842021724855044e-19f;
            for (size_t i = 0; i < total; i++)
                dst[i] = (float)p[i] * scale;
            return total;
        }
        case AF_FORMAT_S64P: {
            int64_t **p = (int64_t **)data;
            const float scale = 1.0842021724855044e-19f;
            for (int s = 0; s < num_samples; s++)
                for (int c = 0; c < channels; c++)
                    dst[s * channels + c] = (float)p[c][s] * scale;
            return total;
        }
        case AF_FORMAT_U8: {
            const uint8_t *p = (const uint8_t *)data[0];
            const float scale = 1.0f / 128.0f;
            for (size_t i = 0; i < total; i++)
                dst[i] = ((float)p[i] - 128.0f) * scale;
            return total;
        }
        case AF_FORMAT_U8P: {
            uint8_t **p = (uint8_t **)data;
            const float scale = 1.0f / 128.0f;
            for (int s = 0; s < num_samples; s++)
                for (int c = 0; c < channels; c++)
                    dst[s * channels + c] =
                        ((float)p[c][s] - 128.0f) * scale;
            return total;
        }
        case AF_FORMAT_DOUBLE: {
            const double *p = (const double *)data[0];
            for (size_t i = 0; i < total; i++)
                dst[i] = (float)p[i];
            scrub_floats(dst, total);
            return total;
        }
        case AF_FORMAT_DOUBLEP: {
            double **p = (double **)data;
            for (int s = 0; s < num_samples; s++)
                for (int c = 0; c < channels; c++)
                    dst[s * channels + c] = (float)p[c][s];
            scrub_floats(dst, total);
            return total;
        }
        default:
            return 0;
    }
}

void mak_pcm_tap_write(struct ao *ao, void **data, int num_samples)
{
    if (!ao || !data || num_samples <= 0)
        return;
    /* Skip everything until a client has read the tap, and once no
     * read came for the idle span. Relaxed: a one-chunk delay in
     * seeing a read only blanks one frame, which is imperceptible. */
    int64_t read_ns = atomic_load_explicit(&g_tap_read_ns,
                                           memory_order_relaxed);
    if (!read_ns)
        return;
    if (mp_time_ns() - read_ns >
        atomic_load_explicit(&g_tap_idle_ns, memory_order_relaxed)) {
        atomic_store_explicit(&g_tap_skipped, true, memory_order_relaxed);
        return;
    }
    /* Skip non-PCM (S/PDIF passthrough: AC3, DTS, TrueHD, …):
     * those are opaque codec bytes, not samples we can visualise. */
    if (!af_fmt_is_pcm(ao->format))
        return;
    int channels = ao->channels.num;
    if (channels <= 0)
        return;

    /* Never a wait here: for a pull output this is the device's callback.
     * The reader holds the lock for one copy of its window; a chunk that
     * meets it is dropped, 10 ms the visualizer does not show. */
    if (mp_mutex_trylock(&g_tap_lock) != 0)
        return;

    size_t produced = convert_to_float(ao->format, data, num_samples,
                                       channels, g_tap.scratch,
                                       MAK_PCM_TAP_SCRATCH_FLOATS);
    if (produced == 0) {
        mp_mutex_unlock(&g_tap_lock);
        return;
    }

    /* A new output format starts the ring over: the frames already in it
     * have the old channel count or rate, and the reader would cut them
     * with the new ones. */
    if (g_tap.channels != channels || g_tap.sample_rate != ao->samplerate) {
        g_tap.write_pos   = 0;
        g_tap.valid_bytes = 0;
    }

    g_tap.sample_rate = ao->samplerate;
    g_tap.channels    = channels;
    g_tap.last_pts_ns = mp_time_ns();

    size_t frame_bytes = produced * sizeof(float);

    const uint8_t *src = (const uint8_t *)g_tap.scratch;
    size_t remaining = frame_bytes;
    while (remaining > 0) {
        size_t free_until_end = MAK_PCM_TAP_CAPACITY - g_tap.write_pos;
        size_t copy = remaining < free_until_end ? remaining
                                                 : free_until_end;
        memcpy(&g_tap.buf[g_tap.write_pos], src, copy);
        g_tap.write_pos = (g_tap.write_pos + copy) % MAK_PCM_TAP_CAPACITY;
        src += copy;
        remaining -= copy;
    }
    g_tap.valid_bytes += frame_bytes;
    if (g_tap.valid_bytes > MAK_PCM_TAP_CAPACITY)
        g_tap.valid_bytes = MAK_PCM_TAP_CAPACITY;

    mp_mutex_unlock(&g_tap_lock);
}

int mak_pcm_tap_read(struct mpv_node *out, int max_samples)
{
    /* The property machinery frees the returned tree: it is rooted at
     * NULL (talloc_zero(NULL, ...)), as in
     * mp_property_embedded_cover_art_data. */
    if (!out || max_samples <= 0)
        return -1;

    int64_t now  = mp_time_ns();
    int64_t prev = atomic_exchange_explicit(&g_tap_read_ns, now,
                                            memory_order_relaxed);
    int64_t idle = atomic_load_explicit(&g_tap_idle_ns,
                                        memory_order_relaxed);
    bool skipped = atomic_exchange_explicit(&g_tap_skipped, false,
                                            memory_order_relaxed);
    bool rearm = !prev || now - prev > idle;
    int64_t next_idle = prev ? 4 * (now - prev) : 0;
    if (next_idle < MAK_PCM_TAP_IDLE_NS)
        next_idle = MAK_PCM_TAP_IDLE_NS;
    atomic_store_explicit(&g_tap_idle_ns, next_idle, memory_order_relaxed);

    /* The lock is held twice, each time for a few loads or one copy, and
     * never across an allocation: the output's thread drops its chunk
     * when it meets this lock (see mak_pcm_tap_write), and before that it
     * waited for the allocator here. First the format, to size the
     * window. */
    mp_mutex_lock(&g_tap_lock);

    /* Audio went by uncopied during the idle span: start over, so the
     * reader never gets a window from before it. */
    if (rearm && skipped) {
        g_tap.write_pos   = 0;
        g_tap.valid_bytes = 0;
    }

    int channels = g_tap.channels;
    int rate     = g_tap.sample_rate;
    size_t valid = g_tap.valid_bytes;
    mp_mutex_unlock(&g_tap_lock);
    if (channels <= 0 || rate <= 0 || valid == 0)
        return -1;

    size_t frame_bytes  = (size_t)channels * sizeof(float);
    size_t window_bytes = (size_t)max_samples * frame_bytes;
    if (window_bytes > MAK_PCM_TAP_CAPACITY)
        window_bytes = MAK_PCM_TAP_CAPACITY;

    /* Build the MAP_NODE tree. Top-level list rooted at NULL —
     * children parented to it so the entire tree frees via a
     * single talloc_free chain when mpv_free_node_contents runs. */
    struct mpv_node_list *list =
        talloc_zero(NULL, struct mpv_node_list);
    list->num    = 4;
    list->keys   = talloc_array(list, char *, 4);
    list->values = talloc_array(list, struct mpv_node, 4);
    list->keys[0] = talloc_strdup(list, "sample_rate");
    list->keys[1] = talloc_strdup(list, "channels");
    list->keys[2] = talloc_strdup(list, "pts_ns");
    list->keys[3] = talloc_strdup(list, "samples");

    struct mpv_byte_array *ba =
        talloc_zero(list, struct mpv_byte_array);
    ba->data = talloc_size(ba, window_bytes);

    /* Then the copy. The output may have changed format in between (the
     * ring started over with another frame size): this read has no
     * window, the next one is sized for the new format. */
    mp_mutex_lock(&g_tap_lock);
    if (g_tap.channels != channels || g_tap.sample_rate != rate ||
        g_tap.valid_bytes == 0) {
        mp_mutex_unlock(&g_tap_lock);
        talloc_free(list);
        return -1;
    }
    int64_t pts = g_tap.last_pts_ns;
    if (window_bytes > g_tap.valid_bytes)
        window_bytes = g_tap.valid_bytes;
    window_bytes -= window_bytes % frame_bytes;
    ba->size = window_bytes;

    /* Most-recent window ends at write_pos (exclusive). Walk back
     * window_bytes with wrap. */
    size_t start = (g_tap.write_pos + MAK_PCM_TAP_CAPACITY - window_bytes)
                       % MAK_PCM_TAP_CAPACITY;
    if (start + window_bytes <= MAK_PCM_TAP_CAPACITY) {
        memcpy(ba->data, &g_tap.buf[start], window_bytes);
    } else {
        size_t first = MAK_PCM_TAP_CAPACITY - start;
        memcpy(ba->data, &g_tap.buf[start], first);
        memcpy((char *)ba->data + first, &g_tap.buf[0],
               window_bytes - first);
    }

    mp_mutex_unlock(&g_tap_lock);

    list->values[0] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = rate};
    list->values[1] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = channels};
    list->values[2] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = pts};
    list->values[3] = (struct mpv_node){
        .format = MPV_FORMAT_BYTE_ARRAY, .u.ba = ba};

    *out = (struct mpv_node){
        .format = MPV_FORMAT_NODE_MAP, .u.list = list};
    return 0;
}
