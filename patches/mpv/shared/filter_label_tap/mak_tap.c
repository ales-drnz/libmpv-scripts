/* MAK_TAP_PATCH_V3 ─── per-filter pre / post audio tap.
 *
 * Concurrency model
 * -----------------
 *
 * Producer (writer): the audio-filter thread, which calls
 *     mak_tap_write() from inside user_wrapper_process for every
 *     frame the active filters produce. The chain is
 *     single-threaded — only one writer at a time per ring.
 *
 * Consumer (reader): the mpv main thread, which drains the ring
 *     via the audio-tap-frames property getter at the wrapper's
 *     polling cadence (typically 30 Hz).
 *
 * Coordinator: any thread setting / clearing the active-tap list
 *     via mak_tap_set_active(), guarded by a small mutex.
 *
 * Hot-path synchronisation uses an SPSC seqlock — the canonical
 * lock-free pattern for real-time audio. The writer never blocks
 * on a reader; the reader retries on contention (rare in practice
 * because writes are short and reads infrequent). Each tap_ring
 * has its own atomic sequence counter:
 *
 *     even = stable     (data may be read)
 *     odd  = writing    (reader must retry)
 *
 * The slot table itself uses an _Atomic bool per slot for the
 * "used" flag, so find_slot() on the audio thread is also
 * lock-free. set_active still takes a tiny mutex to serialise
 * concurrent subscriber additions / removals. */
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "mpv_talloc.h"
#include <mpv/client.h>

#include "audio/aframe.h"
#include "audio/format.h"
#include "audio/mak_tap.h"
#include "audio/mak_waveform.h"
#include "audio/mak_wave_fold.h"
#include "osdep/threads.h"

/* Format-adaptive ring sizing.
 *
 * The ring is allocated dynamically at format-detection time
 * (see mak_tap_write) so a 44.1 kHz mono stream and a 384 kHz
 * 5.1 stream both get a buffer that covers the same number of
 * SECONDS of audio rather than the same number of bytes. This
 * matches the canonical JUCE prepareToPlay model — the audio
 * thread allocates only at format change (rare, equivalent to
 * file load), not in the per-frame hot path.
 *
 * TAP_BUFFER_SECONDS — target coverage in seconds. 3.0 s
 *   matches the iZotope Ozone "Average Time" middle preset and
 *   covers mpv's observed ~1.2 s chain pre-buffer with a 2.5×
 *   safety margin.
 *
 * TAP_MAX_RING_BYTES — per-ring memory cap. 16 MB is enough for
 *   3 s at 384 kHz stereo float (12 MB) but caps the worst case
 *   at 384 kHz 7.1 (1 s coverage) and 768 kHz 7.1 (520 ms). Total
 *   worst case if every slot were active: 8 slots × 2 sides ×
 *   16 MB = 256 MB. Typical case (1 pro window, 48 kHz stereo):
 *   ~2.3 MB total.
 *
 * When the requested PTS-aligned read falls outside the ring's
 * coverage (only possible at the cap, on extreme hi-res), the
 * reader degrades gracefully to "latest available window" rather
 * than freezing on a stale slice — same behaviour every DAW
 * spectrum analyser uses (VLC visual.c, JUCE AudioVisualiser-
 * Component, Voxengo SPAN). */
#define TAP_BUFFER_SECONDS  3.0
#define TAP_MAX_RING_BYTES  (16 * 1024 * 1024)
#define TAP_MAX_CHANNELS    8
/* Scratch space for one frame conversion to interleaved Float32 — */
/* must fit the largest frame the chain may produce. 8K floats =     */
/* 4 K stereo samples or 2 K 4-ch samples, plenty for typical mpv.   */
#define TAP_SCRATCH_FLOATS (8 * 1024)
/* Cap reader spin retries on seqlock contention. With brief
 * writers (~10 µs) and a 30 Hz reader cadence, contention is
 * exceptional; the cap exists only to defend against a runaway
 * writer (e.g. a stalled scheduler) starving the reader
 * forever. On give-up we return whatever the last partial copy
 * read — visually a one-frame glitch, never a crash. */
#define TAP_SEQLOCK_MAX_RETRIES 1024

struct tap_ring {
    /* SPSC seqlock — even = stable, odd = writer in progress.
     * Writer increments to odd before any field write, increments
     * back to even after all writes; reader spins until even,
     * snapshots, and validates the seq is unchanged. */
    _Atomic uint_fast32_t seq;

    int     sample_rate;
    int     channels;
    /* Playback PTS (seconds) of the *next-to-be-written* sample,
     * i.e. the time-coordinate of the byte at write_pos. Updated
     * after every successful write. NaN until the first write
     * with a valid frame PTS. */
    double  end_pts_secs;
    size_t  write_pos;     /* next byte to write (wraps) */
    size_t  valid_bytes;   /* total valid bytes in ring */
    /* Allocated and effective capacity in bytes. The buf is
     * orphan-talloc'd (parent NULL) ONCE on the first write that
     * detects a valid format, sized to cover TAP_BUFFER_SECONDS at
     * that format and capped at TAP_MAX_RING_BYTES. After that the
     * buf pointer NEVER changes — set_active doesn't touch it,
     * format changes don't reallocate it. This eliminates the
     * use-after-free window a free / realloc inside the seqlock
     * would otherwise open: the seqlock catches torn DATA but not
     * a torn pointer (the reader's memcpy on the stale ptr would
     * already be reading freed memory by the time the seq mismatch
     * tells it to retry).
     *
     * alloc_bytes — immutable after first alloc, total bytes
     *   actually allocated for buf.
     * capacity    — frame-aligned working size for the current
     *   (sample_rate, channels). Recomputed on every format change
     *   as `(alloc_bytes / frame_bytes) * frame_bytes`. The wrap
     *   math (writer + reader) uses capacity, not alloc_bytes, so
     *   the tail (alloc_bytes - capacity, < frame_bytes) is
     *   harmlessly unused under that format. */
    size_t   alloc_bytes;
    size_t   capacity;
    uint8_t *buf;
};

struct tap_slot {
    /* Atomic so find_slot() can probe without a lock. The audio
     * thread runs find_slot per frame; we want zero overhead
     * when no taps are active. */
    _Atomic bool     used;
    /* Written under activation_lock; read after a `used == true`
     * acquire-load (the release-store on `used` publishes the
     * preceding name write). */
    char             name[64];
    struct tap_ring  pre;
    struct tap_ring  post;
};

static struct {
    /* Serialises set_active / get_active calls — these touch the
     * whole slot table at once and run rarely (on subscriber
     * subscribe / unsubscribe), so a mutex is fine. */
    struct tap_slot  slots[MAK_TAP_MAX];
    /* Single-writer scratch; the audio chain is single-threaded
     * so concurrent writers cannot collide here. */
    float            scratch[TAP_SCRATCH_FLOATS];
} g_tap;
/* The lock lives OUTSIDE the state struct on purpose: Darwin's
 * PTHREAD_MUTEX_INITIALIZER carries a non-zero signature, and a single
 * initialized member drags the WHOLE struct out of __bss into __data —
 * every embedded buffer byte then ships as on-disk zeros (~0.5 MiB per
 * Apple slice for the ring structs). A separate statically-initialized
 * lock plus a zero-init struct keeps identical semantics at zero file
 * cost. (ELF/PE are immune: their static lock initializers are all
 * zero.) */
static mp_mutex g_tap_activation_lock = MP_STATIC_MUTEX_INITIALIZER;

/* Lock-free probe — atomic_load on the slot.used flag (acquire
 * orders the subsequent name read against the matching
 * activation's release-store on used). Returns the slot index
 * or -1 when not active. Hot path on the audio thread. */
static int find_slot(const char *name)
{
    if (!name) return -1;
    for (int i = 0; i < MAK_TAP_MAX; i++) {
        if (atomic_load_explicit(&g_tap.slots[i].used,
                                  memory_order_acquire) &&
            strcmp(g_tap.slots[i].name, name) == 0) {
            return i;
        }
    }
    return -1;
}

/* Reset a ring's metadata. Called by the writer (under seqlock)
 * on format change to discard accumulated samples, and by the
 * activation path (set_active) to clear stale state when a slot
 * is re-armed. The buf pointer + capacity are NOT touched here —
 * those are owned exclusively by the writer (single-thread
 * invariant) and freed/reallocated inside the writer's seqlock.
 * Leaving the buffer alive across activation cycles costs at most
 * 8 slots × 2 sides × 16 MB = 256 MB worst case (typical: a few
 * MB) but eliminates the use-after-free race that would arise if
 * the main thread freed the buffer mid-write. */
static void reset_ring(struct tap_ring *r)
{
    r->sample_rate  = 0;
    r->channels     = 0;
    r->end_pts_secs = NAN;
    r->write_pos    = 0;
    r->valid_bytes  = 0;
    /* seq stays where it is — the seqlock invariant is preserved
     * because the activation_lock barrier orders the next write
     * after this reset. */
}

void mak_tap_set_active(const char *csv)
{
    mp_mutex_lock(&g_tap_activation_lock);

    /* Phase 1: tear down every active slot. Release-store on
     * `used = false` makes the deactivation visible to the
     * audio thread's acquire-load in find_slot. */
    for (int i = 0; i < MAK_TAP_MAX; i++) {
        atomic_store_explicit(&g_tap.slots[i].used, false,
                              memory_order_release);
    }
    /* Phase 2: clear name + ring metadata. Buf pointers stay
     * alive — only the writer (audio thread) touches them, and
     * only inside its seqlock critical section. An in-flight
     * writer that already passed find_slot continues safely
     * against the still-valid buf; its write goes to the now-
     * orphaned ring and the next reader for that slot won't see
     * it (used == false). */
    for (int i = 0; i < MAK_TAP_MAX; i++) {
        g_tap.slots[i].name[0] = 0;
        reset_ring(&g_tap.slots[i].pre);
        reset_ring(&g_tap.slots[i].post);
    }

    if (!csv || !*csv) {
        mp_mutex_unlock(&g_tap_activation_lock);
        return;
    }

    /* Phase 3: parse CSV, populate slots, publish via release-
     * store on `used = true`. Name is written before the publish
     * so an audio thread that sees used==true reads a consistent
     * name. */
    int slot = 0;
    const char *p = csv;
    while (*p && slot < MAK_TAP_MAX) {
        const char *end = strchr(p, ',');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        while (len > 0 && (*p == ' ' || *p == '\t')) { p++; len--; }
        while (len > 0 && (p[len-1] == ' ' || p[len-1] == '\t')) len--;
        if (len > 0 && len < sizeof(g_tap.slots[slot].name)) {
            memcpy(g_tap.slots[slot].name, p, len);
            g_tap.slots[slot].name[len] = 0;
            atomic_store_explicit(&g_tap.slots[slot].used, true,
                                  memory_order_release);
            slot++;
        }
        if (!end) break;
        p = end + 1;
    }
    mp_mutex_unlock(&g_tap_activation_lock);
}

char *mak_tap_get_active(void *parent)
{
    mp_mutex_lock(&g_tap_activation_lock);
    /* Worst case: MAK_TAP_MAX × 64-char names + commas. */
    char *out = talloc_size(parent, MAK_TAP_MAX * 64);
    out[0] = 0;
    bool first = true;
    for (int i = 0; i < MAK_TAP_MAX; i++) {
        if (!atomic_load_explicit(&g_tap.slots[i].used,
                                   memory_order_acquire))
            continue;
        if (!first) strcat(out, ",");
        strcat(out, g_tap.slots[i].name);
        first = false;
    }
    mp_mutex_unlock(&g_tap_activation_lock);
    return out;
}

bool mak_tap_label_active(const char *name)
{
    /* Lock-free fast path on the audio thread. With no taps
     * active, every slot.used atomic_load reports false on the
     * first iteration and the function returns ~immediately
     * (no strcmp, no lock). */
    return find_slot(name) >= 0;
}

/* Convert a planar / packed PCM aframe into interleaved Float32,
 * writing into `dst` (capacity `dst_cap` floats). Returns the
 * number of float samples written, or 0 if the format is not
 * supported. Mirrors mak_pcm_tap.c::convert_to_float. */
static size_t convert_aframe(struct mp_aframe *aframe,
                             float *dst, size_t dst_cap,
                             int *out_channels, int *out_rate)
{
    int format   = mp_aframe_get_format(aframe);
    if (!af_fmt_is_pcm(format)) return 0;
    int channels = mp_aframe_get_channels(aframe);
    int rate     = mp_aframe_get_rate(aframe);
    int samples  = mp_aframe_get_size(aframe);
    if (channels <= 0 || rate <= 0 || samples <= 0) return 0;
    if (channels > TAP_MAX_CHANNELS) channels = TAP_MAX_CHANNELS;

    size_t total = (size_t)samples * (size_t)channels;
    if (total == 0 || total > dst_cap) {
        /* truncate to fit */
        samples = (int)(dst_cap / (size_t)channels);
        total   = (size_t)samples * (size_t)channels;
        if (total == 0) return 0;
    }

    uint8_t **data = mp_aframe_get_data_ro(aframe);
    if (!data) return 0;

    *out_channels = channels;
    *out_rate     = rate;

    switch (format) {
        case AF_FORMAT_FLOAT:
            memcpy(dst, data[0], total * sizeof(float));
            return total;
        case AF_FORMAT_FLOATP: {
            float **p = (float **)data;
            for (int s = 0; s < samples; s++)
                for (int c = 0; c < channels; c++)
                    dst[s * channels + c] = p[c][s];
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
            for (int s = 0; s < samples; s++)
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
            for (int s = 0; s < samples; s++)
                for (int c = 0; c < channels; c++)
                    dst[s * channels + c] = (float)p[c][s] * scale;
            return total;
        }
        case AF_FORMAT_S64: {
            const int64_t *p = (const int64_t *)data[0];
            const float scale = 1.0842021724855044e-19f;
            for (size_t i = 0; i < total; i++)
                dst[i] = (float)p[i] * scale;
            return total;
        }
        case AF_FORMAT_S64P: {
            int64_t **p = (int64_t **)data;
            const float scale = 1.0842021724855044e-19f;
            for (int s = 0; s < samples; s++)
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
            for (int s = 0; s < samples; s++)
                for (int c = 0; c < channels; c++)
                    dst[s * channels + c] =
                        ((float)p[c][s] - 128.0f) * scale;
            return total;
        }
        case AF_FORMAT_DOUBLE: {
            const double *p = (const double *)data[0];
            for (size_t i = 0; i < total; i++)
                dst[i] = (float)p[i];
            return total;
        }
        case AF_FORMAT_DOUBLEP: {
            double **p = (double **)data;
            for (int s = 0; s < samples; s++)
                for (int c = 0; c < channels; c++)
                    dst[s * channels + c] = (float)p[c][s];
            return total;
        }
        default:
            return 0;
    }
}

/* MAK_TAP_PATCH_V3 ─── pre-DSP waveform fold from the af chain
 * "in" filter (PRE side). Converts + mono-downmixes the SOURCE frame
 * (pre volume / ReplayGain / EQ — those run later on the AO thread)
 * and folds it into the progressive waveform envelope, per-bin by PTS.
 * Only fires for the "in" filter and only while a progressive analysis
 * is active; for every other filter / state it is one strcmp + one
 * atomic load. Single-threaded core path — reuses g_tap.scratch
 * sequentially with mak_tap_write (never concurrently). */
void mak_waveform_tap_in(const char *name, struct mp_aframe *aframe)
{
    if (!name || !aframe) return;
    if (strcmp(name, "in") != 0) return;
    if (!mak_waveform_wants_frames()) return;
    int gen = mak_waveform_current_gen();
    int channels = 0, rate = 0;
    size_t produced = convert_aframe(aframe, g_tap.scratch,
                                     TAP_SCRATCH_FLOATS,
                                     &channels, &rate);
    if (produced == 0 || channels <= 0 || rate <= 0) return;
    int n = (int)(produced / (size_t)channels);
    if (n <= 0) return;
    /* Mono downmix into a process-static buffer (single-threaded core
     * path; n <= TAP_SCRATCH_FLOATS since produced == n * channels). */
    static float mono[TAP_SCRATCH_FLOATS];
    mak_downmix_mono(g_tap.scratch, n, channels, mono);
    mak_waveform_fold_samples(mono, n, mp_aframe_get_pts(aframe),
                              rate, gen);
}

void mak_tap_write(const char *name, bool is_post,
                   struct mp_aframe *aframe)
{
    if (!name || !aframe) return;

    /* Lock-free probe — early-exit when the label is not in
     * the active set (zero atomic-load cost when nothing is
     * being tapped, which is the steady-state). */
    int idx = find_slot(name);
    if (idx < 0) return;
    struct tap_ring *ring = is_post ? &g_tap.slots[idx].post
                                    : &g_tap.slots[idx].pre;

    /* Convert the aframe into the per-process scratch. The
     * audio chain is single-threaded so concurrent writers
     * cannot collide here, and we do this OUTSIDE the seqlock
     * critical section so the conversion (which dominates the
     * write cost) does not delay any concurrent reader. */
    int channels = 0, rate = 0;
    size_t produced = convert_aframe(aframe, g_tap.scratch,
                                     TAP_SCRATCH_FLOATS,
                                     &channels, &rate);
    if (produced == 0 || channels <= 0 || rate <= 0) return;

    /* PTS extraction (also outside seqlock — pure read of frame
     * metadata). */
    int frame_size   = mp_aframe_get_size(aframe);
    double frame_pts = mp_aframe_get_pts(aframe);

    /* SEQLOCK BEGIN — increment to odd, signalling readers to
     * retry. Release ordering ensures all subsequent ring
     * writes are observed AFTER this transition. */
    uint_fast32_t s = atomic_load_explicit(&ring->seq,
                                            memory_order_relaxed);
    atomic_store_explicit(&ring->seq, s + 1, memory_order_release);

    /* First-write allocation. The buf is sized once on the first
     * format we see and STAYS that size for the slot's lifetime.
     * Subsequent format changes (different file, different rate /
     * channels) reuse the same buffer — only the metadata resets.
     *
     * This is the canonical real-time-safe pattern: allocate
     * exactly once, never free during operation, never realloc
     * after the seqlock could be observed by a reader. A free +
     * realloc inside the seqlock would race the reader's memcpy:
     * the reader's seq retry catches torn DATA but not a torn
     * POINTER — by the time the reader's seq mismatch tells it to
     * abort, its memcpy has already touched freed memory.
     *
     * Side effect: if the first format is, say, 48 kHz stereo
     * (1.15 MB for 3 s) and the user later opens a 384 kHz file,
     * coverage shrinks from 3 s to ~96 ms. The soft fallback in
     * build_ring_node degrades to "latest available window"; the
     * visualiser keeps refreshing, just without strict PTS
     * alignment for the few-frame chain pre-buffer phase — same
     * trade-off VLC / JUCE / Voxengo accept. Reverse case (high
     * rate first, low rate later) gives extra headroom for free. */
    /* First-write allocation. Sized once based on the FIRST format
     * we see, capped at TAP_MAX_RING_BYTES. Buf pointer +
     * alloc_bytes are immutable for the rest of the slot's life. */
    if (ring->buf == NULL) {
        size_t frame_bytes = (size_t)channels * sizeof(float);
        size_t needed =
            (size_t)((double)TAP_BUFFER_SECONDS *
                     (double)rate *
                     (double)frame_bytes);
        if (needed > TAP_MAX_RING_BYTES) needed = TAP_MAX_RING_BYTES;
        if (needed < frame_bytes) needed = frame_bytes;

        ring->buf = talloc_size(NULL, needed);
        ring->alloc_bytes = ring->buf ? needed : 0;
    }

    /* Format change (or first frame): reset metadata + recompute
     * the frame-aligned wrap budget against the immutable
     * alloc_bytes. The buf pointer is untouched — only metadata
     * changes — so no UAF window opens for the reader. */
    if (ring->channels != channels || ring->sample_rate != rate) {
        size_t frame_bytes = (size_t)channels * sizeof(float);
        size_t cap = (ring->alloc_bytes / frame_bytes) * frame_bytes;
        if (cap == 0) cap = frame_bytes;
        ring->capacity     = cap;
        ring->valid_bytes  = 0;
        ring->write_pos    = 0;
        ring->channels     = channels;
        ring->sample_rate  = rate;
        ring->end_pts_secs = NAN;
    }

    if (ring->buf == NULL || ring->capacity == 0) {
        /* Allocation failed — close the seqlock cleanly and bail.
         * Reader will see valid_bytes==0 and report no data. */
        atomic_store_explicit(&ring->seq, s + 2, memory_order_release);
        return;
    }

    /* Append to the ring with wrap. */
    size_t bytes = produced * sizeof(float);
    if (bytes > ring->capacity) bytes = ring->capacity;
    const uint8_t *src = (const uint8_t *)g_tap.scratch;
    size_t remaining = bytes;
    while (remaining > 0) {
        size_t free_until_end = ring->capacity - ring->write_pos;
        size_t copy = remaining < free_until_end ? remaining
                                                 : free_until_end;
        memcpy(&ring->buf[ring->write_pos], src, copy);
        ring->write_pos = (ring->write_pos + copy) % ring->capacity;
        src += copy;
        remaining -= copy;
    }
    ring->valid_bytes += bytes;
    if (ring->valid_bytes > ring->capacity)
        ring->valid_bytes = ring->capacity;

    /* Advance the playback-PTS coordinate of the ring tail. */
    if (frame_pts > -1e18 && frame_size > 0 && rate > 0) {
        ring->end_pts_secs =
            frame_pts + (double)frame_size / (double)rate;
    } else if (!isnan(ring->end_pts_secs) &&
               rate > 0 && frame_size > 0) {
        ring->end_pts_secs += (double)frame_size / (double)rate;
    }

    /* SEQLOCK END — increment to even, ring is stable again. */
    atomic_store_explicit(&ring->seq, s + 2, memory_order_release);
}

/* Build a {sample_rate, channels, pts_ns, samples} map for `ring`,
 * returning the slice of samples that ENDS at `target_pts_secs`.
 * When `target_pts_secs` is NaN we fall back to the latest
 * window.
 *
 * SPSC-seqlock retry: snapshots the ring fields + memcpy-s the
 * slice in one atomic pass. If the writer interrupts (seq goes
 * odd), retries up to TAP_SEQLOCK_MAX_RETRIES. The byte_array's
 * data buffer is talloc'd once and overwritten on retries — no
 * leak (talloc reuses the slot). */
static void build_ring_node(struct mpv_node *out, void *parent_list,
                            struct tap_ring *ring,
                            double target_pts_secs)
{
    struct mpv_node_list *map =
        talloc_zero(parent_list, struct mpv_node_list);
    map->num    = 5;
    map->keys   = talloc_array(map, char *, 5);
    map->values = talloc_array(map, struct mpv_node, 5);

    /* Allocate the byte_array up-front at the maximum window
     * size; we shrink ba->size below if the ring has less. */
    struct mpv_byte_array *ba =
        talloc_zero(map, struct mpv_byte_array);
    size_t max_bytes =
        (size_t)MAK_TAP_MAX_SAMPLES * TAP_MAX_CHANNELS * sizeof(float);
    ba->data = talloc_size(ba, max_bytes);

    int     rate      = 0;
    int     channels  = 0;
    int64_t pts_ns    = 0;
    size_t  bytes     = 0;
    bool    have_data = false;
    /* Write generation = the validated even seq of the snapshot. The
     * writer bumps seq by 2 per completed write and never resets it,
     * so an unchanged seq across polls means identical ring contents.
     * Exposed so the Dart poll loop can skip redundant dispatches
     * during pause / EOF. Read inside the seqlock validation, so it
     * is inherently consistent with the data — no extra tearing. */
    uint_fast32_t gen = 0;

    /* Seqlock snapshot loop. Reader spins while writer holds the
     * seqlock open (odd seq). Retries if the writer raced through
     * the entire critical section while we were copying. */
    int retries = 0;
    while (retries++ < TAP_SEQLOCK_MAX_RETRIES) {
        uint_fast32_t s1 = atomic_load_explicit(&ring->seq,
                                                memory_order_acquire);
        if (s1 & 1u) continue;            /* writer in progress */

        /* Snapshot all metadata + compute slice geometry. The
         * buf pointer is immutable after first allocation (only
         * the writer ever sets it, and only once), so the
         * snapshot can never see a torn buf. The capacity field
         * IS mutated by the writer on format change and is
         * therefore inside the seqlock-protected snapshot — the
         * seq mismatch check below forces a retry if the writer
         * ran a format change between our two seq reads. */
        rate     = ring->sample_rate;
        channels = ring->channels;
        size_t write_pos   = ring->write_pos;
        size_t valid_bytes = ring->valid_bytes;
        size_t capacity    = ring->capacity;
        uint8_t *buf       = ring->buf;
        double end_pts     = ring->end_pts_secs;

        if (rate <= 0 || channels <= 0 || valid_bytes == 0 ||
            capacity == 0 || buf == NULL)
        {
            /* Empty ring → still need to confirm the read was
             * not interrupted before declaring "no data". */
            uint_fast32_t s2 = atomic_load_explicit(
                &ring->seq, memory_order_acquire);
            if (s1 == s2) { have_data = false; gen = s1; break; }
            continue;
        }

        size_t frame_bytes  = (size_t)channels * sizeof(float);
        size_t window_bytes =
            (size_t)MAK_TAP_MAX_SAMPLES * frame_bytes;
        if (window_bytes > valid_bytes) window_bytes = valid_bytes;

        double delta_secs = 0.0;
        if (!isnan(target_pts_secs) && !isnan(end_pts))
            delta_secs = end_pts - target_pts_secs;
        if (delta_secs < 0) delta_secs = 0;

        size_t delta_bytes_unaligned =
            (size_t)(delta_secs * rate * (double)frame_bytes);
        size_t delta_bytes =
            (delta_bytes_unaligned / frame_bytes) * frame_bytes;
        /* Soft fallback: if the requested PTS-aligned slice falls
         * outside the ring's coverage (only possible at the
         * TAP_MAX_RING_BYTES cap, on extreme hi-res), degrade to
         * "latest available window" rather than freezing on stale
         * data or returning empty. Same behaviour as VLC visual.c,
         * JUCE AudioVisualiserComponent, Voxengo SPAN. The visual
         * effect is a brief constant lead during the chain pre-
         * buffer phase, fully resolved within one paint as the AO
         * catches up to the chain. */
        if (delta_bytes + window_bytes > valid_bytes) {
            delta_bytes = 0;
        }

        size_t end_byte =
            (write_pos + capacity - delta_bytes) % capacity;
        size_t start =
            (end_byte + capacity - window_bytes) % capacity;

        /* Copy the slice. If the writer wraps in here, the seq
         * check below catches it and we retry. */
        if (start + window_bytes <= capacity) {
            memcpy(ba->data, &buf[start], window_bytes);
        } else {
            size_t first = capacity - start;
            memcpy(ba->data, &buf[start], first);
            memcpy((char *)ba->data + first, &buf[0],
                   window_bytes - first);
        }

        /* Validate the snapshot — if the writer touched the ring
         * any time during the snapshot, retry. */
        uint_fast32_t s2 = atomic_load_explicit(&ring->seq,
                                                memory_order_acquire);
        if (s1 == s2) {
            bytes = window_bytes;
            if (!isnan(end_pts)) {
                double slice_end_secs = end_pts -
                    ((double)delta_bytes / (double)frame_bytes /
                     (double)rate);
                pts_ns = (int64_t)(slice_end_secs * 1e9);
            }
            have_data = true;
            gen = s1;
            break;
        }
        /* else loop and retry — typical contention is ≤ 1 retry. */
    }

    map->keys[0] = talloc_strdup(map, "sample_rate");
    map->values[0] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = rate};
    map->keys[1] = talloc_strdup(map, "channels");
    map->values[1] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = channels};
    map->keys[2] = talloc_strdup(map, "pts_ns");
    map->values[2] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = pts_ns};

    ba->size = have_data ? bytes : 0;
    map->keys[3] = talloc_strdup(map, "samples");
    map->values[3] = (struct mpv_node){
        .format = MPV_FORMAT_BYTE_ARRAY, .u.ba = ba};

    map->keys[4] = talloc_strdup(map, "seq");
    map->values[4] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = (int64_t)gen};

    *out = (struct mpv_node){
        .format = MPV_FORMAT_NODE_MAP, .u.list = map};
}

int mak_tap_read_all(struct mpv_node *out, void *parent,
                     double target_pts_secs)
{
    (void)parent;
    if (!out) return -1;

    /* Brief activation_lock just to capture a stable snapshot of
     * which slots are active + their names. Per-ring data is
     * read lock-free below via the seqlock pattern, so a long
     * memcpy of audio samples never blocks the audio thread. */
    mp_mutex_lock(&g_tap_activation_lock);
    int      idx_buf[MAK_TAP_MAX];
    char    *name_buf[MAK_TAP_MAX];
    int      active_count = 0;
    for (int i = 0; i < MAK_TAP_MAX; i++) {
        if (!atomic_load_explicit(&g_tap.slots[i].used,
                                   memory_order_acquire))
            continue;
        idx_buf[active_count]  = i;
        name_buf[active_count] = strdup(g_tap.slots[i].name);
        active_count++;
    }
    mp_mutex_unlock(&g_tap_activation_lock);

    struct mpv_node_list *root =
        talloc_zero(NULL, struct mpv_node_list);
    root->num    = active_count;
    root->keys   = talloc_array(root, char *, active_count);
    root->values = talloc_array(root, struct mpv_node, active_count);

    for (int j = 0; j < active_count; j++) {
        int i = idx_buf[j];
        root->keys[j] = talloc_strdup(root, name_buf[j]);
        free(name_buf[j]);

        struct mpv_node_list *sides =
            talloc_zero(root, struct mpv_node_list);
        sides->num    = 2;
        sides->keys   = talloc_array(sides, char *, 2);
        sides->values = talloc_array(sides, struct mpv_node, 2);
        sides->keys[0] = talloc_strdup(sides, "pre");
        build_ring_node(&sides->values[0], sides,
                        &g_tap.slots[i].pre, target_pts_secs);
        sides->keys[1] = talloc_strdup(sides, "post");
        build_ring_node(&sides->values[1], sides,
                        &g_tap.slots[i].post, target_pts_secs);
        root->values[j] = (struct mpv_node){
            .format = MPV_FORMAT_NODE_MAP, .u.list = sides};
    }

    *out = (struct mpv_node){
        .format = MPV_FORMAT_NODE_MAP, .u.list = root};
    return 0;
}
