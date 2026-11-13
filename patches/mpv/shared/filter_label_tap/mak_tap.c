/* MAK_TAP_PATCH_V4 ─── per-filter pre / post audio tap.
 *
 * Concurrency model
 * -----------------
 *
 * Producer (writer): the core thread of each mpv instance, which
 *     runs the audio filter chain (mp_filter_graph_run in the
 *     playloop) and calls mak_tap_write() from inside
 *     user_wrapper_process for every frame the active filters
 *     produce. The rings are process-wide, so writers take
 *     g_tap_write_lock: one writer at a time per ring.
 *
 * Consumer (reader): the core thread as well, in the
 *     audio-tap-frames property getter, at the wrapper's polling
 *     cadence (typically 30 Hz). It takes g_tap_write_lock too:
 *     nothing it does runs in real time, and with one player it
 *     shares the writer's thread, so the lock is only ever contended
 *     between players. Holding it, the writer can size a ring for
 *     each new format and set_active can free the rings of the taps
 *     that end (F81), with no reader on a freed buffer.
 *
 * Coordinator: any thread setting / clearing the active-tap list
 *     via mak_tap_set_active(), guarded by a small mutex.
 *
 * Each tap_ring still counts its writes in an atomic sequence
 * (odd while a write runs, even after): the reader returns the even
 * value as the write generation, which the client compares across
 * polls to skip unchanged rings.
 *
 * The slot table itself uses an _Atomic bool per slot for the
 * "used" flag, so find_slot() on the writer's path is a lock-free
 * early exit when nothing is tapped; the writer checks its slot again
 * under g_tap_write_lock. set_active still takes a tiny mutex to
 * serialise concurrent subscriber additions / removals. */
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
#include "osdep/threads.h"

/* The pre-DSP waveform fold feeds the bulk_analysis patch. Without it
 * (DISABLED_PATCHES=bulk_analysis) the tap builds alone and the fold is a
 * no-op. */
#if __has_include("audio/mak_waveform.h")
#include "audio/mak_waveform.h"
#include "audio/mak_wave_fold.h"
#define MAK_TAP_WAVEFORM 1
#else
#define MAK_TAP_WAVEFORM 0
#endif

/* Format-adaptive ring sizing.
 *
 * The ring is allocated dynamically at format-detection time
 * (see mak_tap_write) so a 44.1 kHz mono stream and a 384 kHz
 * 5.1 stream both get a buffer that covers the same number of
 * SECONDS of audio rather than the same number of bytes. The
 * audio thread allocates only when the format changes (rare,
 * about as often as a file load), never in the per-frame hot
 * path.
 *
 * TAP_BUFFER_SECONDS — target coverage in seconds. 3.0 s
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
 * than freezing on a stale slice. */
#define TAP_BUFFER_SECONDS  3.0
#define TAP_MAX_RING_BYTES  (16 * 1024 * 1024)
#define TAP_MAX_CHANNELS    8
/* Scratch space for one frame conversion to interleaved Float32 — */
/* must fit the largest frame the chain may produce. 8K floats =     */
/* 4 K stereo samples or 2 K 4-ch samples, plenty for typical mpv.   */
#define TAP_SCRATCH_FLOATS (8 * 1024)
/* Bound of the reader's snapshot loop. The reader holds
 * g_tap_write_lock, so the sequence is always even there and the loop
 * runs once; the bound only keeps it finite. */
#define TAP_SEQLOCK_MAX_RETRIES 1024

struct tap_ring {
    /* Write count: odd while a write runs, even after. Every access
     * holds g_tap_write_lock, so a reader sees it even; it returns it
     * as the write generation the client compares across polls. */
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
     * orphan-talloc'd (parent NULL) on the first write, and again on a
     * format that needs more, sized to cover TAP_BUFFER_SECONDS at that
     * format and capped at TAP_MAX_RING_BYTES; set_active frees it. Every access holds g_tap_write_lock, so no reader
     * sees a freed buffer.
     *
     * alloc_bytes — total bytes allocated for buf (0 without one).
     * capacity    — frame-aligned working size for the current
     *   (sample_rate, channels): `(alloc_bytes / frame_bytes) *
     *   frame_bytes`. The wrap math (writer + reader) uses capacity,
     *   not alloc_bytes, so the tail (< frame_bytes) is unused. */
    size_t   alloc_bytes;
    size_t   capacity;
    uint8_t *buf;
};

struct tap_slot {
    /* Atomic so find_slot() can probe without a lock. The audio
     * thread runs find_slot per frame; we want zero overhead
     * when no taps are active. */
    _Atomic bool     used;
    /* Hash of the name (tap_name_hash), what find_slot() compares: it
     * probes with no lock, and set_active rewrites the name while a
     * writer that already saw `used` may still be comparing. 0 while the
     * slot has no name. */
    _Atomic uint_fast32_t name_hash;
    /* Written and read under g_tap_write_lock (set_active also holds
     * the activation lock, which is enough for get_active and the
     * reader's snapshot). */
    char             name[64];
    struct tap_ring  pre;
    struct tap_ring  post;
};

static struct {
    /* Serialises set_active / get_active calls — these touch the
     * whole slot table at once and run rarely (on subscriber
     * subscribe / unsubscribe), so a mutex is fine. */
    struct tap_slot  slots[MAK_TAP_MAX];
    /* Conversion scratch and mono downmix, shared by every mpv
     * instance in the process: guarded by g_tap_write_lock. */
    float            scratch[TAP_SCRATCH_FLOATS];
    float            mono[TAP_SCRATCH_FLOATS];
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
/* Guards the rings and the scratch: the writers (each mpv instance runs
 * its audio chain on its own core thread, and two of them tapping the
 * same label, or folding the waveform, share one ring and one scratch),
 * the reader and set_active. Never contended with a single player,
 * whose reader and setter run on its core thread too. Lock order:
 * g_tap_activation_lock before g_tap_write_lock. */
static mp_mutex g_tap_write_lock = MP_STATIC_MUTEX_INITIALIZER;

/* FNV-1a of a label, never 0 (the hash of a slot without a name). */
static uint_fast32_t tap_name_hash(const char *name)
{
    uint_fast32_t h = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++)
        h = ((h ^ *p) * 16777619u) & 0xffffffffu;
    return h ? h : 1;
}

/* Lock-free probe: atomic loads of the slot's used flag and of its
 * name's hash, never the name itself, which set_active may be writing.
 * Returns the index of the slot armed for a label with the hash of
 * [name], or -1. A match is a candidate: the writer compares the name
 * under g_tap_write_lock before it writes. Hot path of every writer. */
static int find_slot(const char *name)
{
    if (!name) return -1;
    uint_fast32_t h = 0;
    for (int i = 0; i < MAK_TAP_MAX; i++) {
        if (!atomic_load_explicit(&g_tap.slots[i].used,
                                  memory_order_acquire))
            continue;
        if (!h)
            h = tap_name_hash(name);
        if (atomic_load_explicit(&g_tap.slots[i].name_hash,
                                 memory_order_acquire) == h)
            return i;
    }
    return -1;
}

/* Reset a ring and free its buffer: the activation path (set_active)
 * clears every slot, and the next write of a tapped label sizes a new
 * buffer for its format. Without this a ring stayed for the life of the
 * process, up to 8 slots x 2 sides x 16 MB = 256 MB (F81). The caller
 * holds g_tap_write_lock, which the writer and the reader take as well,
 * so nobody is inside the buffer. */
static void reset_ring(struct tap_ring *r)
{
    uint_fast32_t s = atomic_load_explicit(&r->seq, memory_order_relaxed);
    atomic_store_explicit(&r->seq, s + 1, memory_order_release);
    talloc_free(r->buf);
    r->buf          = NULL;
    r->alloc_bytes  = 0;
    r->capacity     = 0;
    r->sample_rate  = 0;
    r->channels     = 0;
    r->end_pts_secs = NAN;
    r->write_pos    = 0;
    r->valid_bytes  = 0;
    atomic_store_explicit(&r->seq, s + 2, memory_order_release);
}

void mak_tap_set_active(const char *csv)
{
    mp_mutex_lock(&g_tap_activation_lock);

    /* Phase 1: tear down every active slot. Release-store on
     * `used = false` makes the deactivation visible to the
     * writers' acquire-load in find_slot. */
    for (int i = 0; i < MAK_TAP_MAX; i++) {
        atomic_store_explicit(&g_tap.slots[i].used, false,
                              memory_order_release);
    }
    /* Phase 2: clear name and ring, its buffer freed. A writer that
     * already passed find_slot waits on g_tap_write_lock and then finds
     * its slot no longer armed for its label: it writes nothing. */
    mp_mutex_lock(&g_tap_write_lock);
    for (int i = 0; i < MAK_TAP_MAX; i++) {
        atomic_store_explicit(&g_tap.slots[i].name_hash, 0,
                              memory_order_release);
        g_tap.slots[i].name[0] = 0;
        reset_ring(&g_tap.slots[i].pre);
        reset_ring(&g_tap.slots[i].post);
    }

    if (!csv || !*csv) {
        mp_mutex_unlock(&g_tap_write_lock);
        mp_mutex_unlock(&g_tap_activation_lock);
        return;
    }

    /* Phase 3: parse CSV, populate slots, publish via release-
     * store on `used = true`. The name and its hash are written
     * before the publish, under g_tap_write_lock, so a writer holding
     * it reads a stable name when it checks its slot again. */
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
            atomic_store_explicit(&g_tap.slots[slot].name_hash,
                                  tap_name_hash(g_tap.slots[slot].name),
                                  memory_order_release);
            atomic_store_explicit(&g_tap.slots[slot].used, true,
                                  memory_order_release);
            slot++;
        }
        if (!end) break;
        p = end + 1;
    }
    mp_mutex_unlock(&g_tap_write_lock);
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
    /* Lock-free fast path on the chain, per frame. With no taps
     * active, every slot.used atomic_load reports false on the
     * first iteration and the function returns ~immediately
     * (no strcmp, no lock). */
    return find_slot(name) >= 0;
}

/* Silences the samples that are not finite: a float source can hold NaN
 * or infinities, which would stay in the ring for the reader's FFT and in
 * a bin of the waveform that grows from playback. */
static void tap_scrub(float *s, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if (!isfinite(s[i]))
            s[i] = 0.0f;
    }
}

/* Convert part of a planar / packed PCM aframe into interleaved Float32,
 * writing into `dst` (capacity `dst_cap` floats). Starts at sample
 * `offset` and converts as many whole samples as fit, so a caller loops
 * over a frame larger than its scratch in chunks instead of dropping the
 * tail. Channels past TAP_MAX_CHANNELS are skipped; packed input keeps
 * the source stride. Returns the number of floats written (a multiple of
 * the output channel count), or 0 at the end of the frame or for an
 * unsupported format. Mirrors mak_pcm_tap.c::convert_to_float. */
static size_t convert_aframe(struct mp_aframe *aframe, int offset,
                             float *dst, size_t dst_cap,
                             int *out_channels, int *out_rate)
{
    int format   = mp_aframe_get_format(aframe);
    if (!af_fmt_is_pcm(format)) return 0;
    int src_ch   = mp_aframe_get_channels(aframe);
    int rate     = mp_aframe_get_rate(aframe);
    int samples  = mp_aframe_get_size(aframe);
    if (src_ch <= 0 || rate <= 0 || samples <= 0) return 0;
    if (offset < 0 || offset >= samples) return 0;
    int channels = src_ch > TAP_MAX_CHANNELS ? TAP_MAX_CHANNELS : src_ch;

    samples -= offset;
    size_t fit = dst_cap / (size_t)channels;
    if (fit == 0) return 0;
    if ((size_t)samples > fit) samples = (int)fit;
    size_t total = (size_t)samples * (size_t)channels;

    uint8_t **data = mp_aframe_get_data_ro(aframe);
    if (!data) return 0;

    *out_channels = channels;
    *out_rate     = rate;

    bool planar = af_fmt_is_planar(format);
    size_t base = planar ? (size_t)offset : (size_t)offset * (size_t)src_ch;

#define MAK_TAP_CONV(T, EXPR)                                              \
    do {                                                                   \
        if (planar) {                                                      \
            T **pl = (T **)data;                                           \
            for (int s = 0; s < samples; s++)                              \
                for (int c = 0; c < channels; c++) {                       \
                    T v = pl[c][base + s];                                 \
                    dst[s * channels + c] = (EXPR);                        \
                }                                                          \
        } else {                                                           \
            const T *pk = (const T *)data[0] + base;                       \
            for (int s = 0; s < samples; s++)                              \
                for (int c = 0; c < channels; c++) {                       \
                    T v = pk[(size_t)s * src_ch + c];                      \
                    dst[s * channels + c] = (EXPR);                        \
                }                                                          \
        }                                                                  \
    } while (0)

    switch (af_fmt_from_planar(format)) {
        case AF_FORMAT_FLOAT:
            if (!planar && channels == src_ch) {
                memcpy(dst, (const float *)data[0] + base,
                       total * sizeof(float));
            } else {
                MAK_TAP_CONV(float, v);
            }
            tap_scrub(dst, total);
            return total;
        case AF_FORMAT_S16:
            MAK_TAP_CONV(int16_t, (float)v * (1.0f / 32768.0f));
            return total;
        case AF_FORMAT_S32:
            MAK_TAP_CONV(int32_t, (float)v * (1.0f / 2147483648.0f));
            return total;
        case AF_FORMAT_S64:
            MAK_TAP_CONV(int64_t, (float)v * 1.0842021724855044e-19f);
            return total;
        case AF_FORMAT_U8:
            MAK_TAP_CONV(uint8_t, ((float)v - 128.0f) * (1.0f / 128.0f));
            return total;
        case AF_FORMAT_DOUBLE:
            MAK_TAP_CONV(double, (float)v);
            tap_scrub(dst, total);
            return total;
        default:
            return 0;
    }
#undef MAK_TAP_CONV
}

/* MAK_TAP_PATCH_V4 ─── pre-DSP waveform fold from the af chain
 * "in" filter (PRE side). Converts + mono-downmixes the SOURCE frame
 * (pre volume / ReplayGain / EQ — those run later on the AO thread)
 * and folds it into the progressive waveform envelope, per-bin by PTS.
 * Only fires for the "in" filter and only while a progressive analysis
 * is active; for every other filter / state it is one strcmp + one
 * atomic load. The scratch buffers are shared by every mpv instance in
 * the process, so the conversion runs under g_tap_write_lock. A frame
 * larger than the scratch is folded in chunks. */
void mak_waveform_tap_in(const char *name, struct mp_aframe *aframe)
{
#if !MAK_TAP_WAVEFORM
    (void)name;
    (void)aframe;
#else
    if (!name || !aframe) return;
    if (strcmp(name, "in") != 0) return;
    if (!mak_waveform_wants_frames()) return;
    int gen = mak_waveform_current_gen();
    double pts = mp_aframe_get_pts(aframe);
    mp_mutex_lock(&g_tap_write_lock);
    int offset = 0;
    for (;;) {
        int channels = 0, rate = 0;
        size_t produced = convert_aframe(aframe, offset, g_tap.scratch,
                                         TAP_SCRATCH_FLOATS,
                                         &channels, &rate);
        if (produced == 0 || channels <= 0 || rate <= 0) break;
        int n = (int)(produced / (size_t)channels);
        if (n <= 0) break;
        mak_downmix_mono(g_tap.scratch, n, channels, g_tap.mono);
        mak_waveform_fold_samples(g_tap.mono, n,
                                  pts + (double)offset / (double)rate,
                                  rate, gen);
        offset += n;
    }
    mp_mutex_unlock(&g_tap_write_lock);
#endif
}

/* Append `bytes` from `src` to the ring with wrap. Caller holds the
 * seqlock open and g_tap_write_lock. */
static void ring_append(struct tap_ring *ring, const uint8_t *src,
                        size_t bytes)
{
    if (bytes > ring->capacity) {
        /* Only the newest `capacity` bytes survive anyway. */
        src += bytes - ring->capacity;
        bytes = ring->capacity;
    }
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
}

void mak_tap_write(const char *name, bool is_post,
                   struct mp_aframe *aframe)
{
    if (!name || !aframe) return;

    /* Lock-free probe — early-exit when the label is not in
     * the active set (zero atomic-load cost when nothing is
     * being tapped, which is the steady-state). */
    if (find_slot(name) < 0) return;

    /* The rings and the scratch are process-wide, but every mpv
     * instance runs its own audio chain. Two players tapping the same
     * label would otherwise write one ring from two threads. One
     * player never contends on this lock: its reader runs on the same
     * thread. */
    mp_mutex_lock(&g_tap_write_lock);

    /* The slot is looked up by name here, under the lock set_active
     * changes the names under: the one the probe found may have been
     * torn down, or armed for another label, while this writer waited
     * (and its hash is only a hint). Writing there would put this
     * label's audio in another label's ring, or a buffer nothing frees
     * in a slot nobody taps. */
    int idx = -1;
    for (int i = 0; i < MAK_TAP_MAX && idx < 0; i++) {
        if (atomic_load_explicit(&g_tap.slots[i].used, memory_order_relaxed) &&
            strcmp(g_tap.slots[i].name, name) == 0)
            idx = i;
    }
    if (idx < 0) {
        mp_mutex_unlock(&g_tap_write_lock);
        return;
    }
    struct tap_ring *ring = is_post ? &g_tap.slots[idx].post
                                    : &g_tap.slots[idx].pre;

    int channels = 0, rate = 0;
    size_t produced = convert_aframe(aframe, 0, g_tap.scratch,
                                     TAP_SCRATCH_FLOATS,
                                     &channels, &rate);
    if (produced == 0 || channels <= 0 || rate <= 0) {
        mp_mutex_unlock(&g_tap_write_lock);
        return;
    }

    /* PTS extraction (pure read of frame metadata). */
    int frame_size   = mp_aframe_get_size(aframe);
    double frame_pts = mp_aframe_get_pts(aframe);

    /* Write count to odd: a write runs (see struct tap_ring). */
    uint_fast32_t s = atomic_load_explicit(&ring->seq,
                                            memory_order_relaxed);
    atomic_store_explicit(&ring->seq, s + 1, memory_order_release);

    /* Format change (or first frame): a buffer that covers
     * TAP_BUFFER_SECONDS of this format, capped at TAP_MAX_RING_BYTES,
     * and the frame-aligned wrap budget against it. The buffer was sized
     * once, on the first format, and kept: an 8 kHz mono file first left
     * 0.25 s for a 48 kHz stereo one, and build_ring_node fell back to
     * the latest window, the overlay ahead of the sound (F81). It only
     * grows: a smaller format keeps it, with more than TAP_BUFFER_SECONDS,
     * so two players tapping one label at two formats do not allocate it
     * again at every frame; set_active frees it. The reader holds
     * g_tap_write_lock too, so a new buffer never pulls one from under
     * its memcpy. */
    if (ring->channels != channels || ring->sample_rate != rate ||
        ring->buf == NULL) {
        size_t frame_bytes = (size_t)channels * sizeof(float);
        size_t needed =
            (size_t)((double)TAP_BUFFER_SECONDS *
                     (double)rate *
                     (double)frame_bytes);
        if (needed > TAP_MAX_RING_BYTES) needed = TAP_MAX_RING_BYTES;
        if (needed < frame_bytes) needed = frame_bytes;
        if (needed > ring->alloc_bytes || ring->buf == NULL) {
            talloc_free(ring->buf);
            ring->buf = talloc_size(NULL, needed);
            ring->alloc_bytes = ring->buf ? needed : 0;
        }
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
        mp_mutex_unlock(&g_tap_write_lock);
        return;
    }

    /* Append the whole frame, converting it in scratch-sized chunks
     * so frames larger than the scratch (FLAC blocks of 4608 stereo
     * samples, AC3 5.1) keep every sample and the PTS stays aligned. */
    int offset = 0;
    while (produced > 0) {
        ring_append(ring, (const uint8_t *)g_tap.scratch,
                    produced * sizeof(float));
        offset += (int)(produced / (size_t)channels);
        int ch2 = 0, rate2 = 0;
        produced = convert_aframe(aframe, offset, g_tap.scratch,
                                  TAP_SCRATCH_FLOATS, &ch2, &rate2);
    }

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
    mp_mutex_unlock(&g_tap_write_lock);
}

/* Build a {sample_rate, channels, pts_ns, samples} map for `ring`,
 * returning the slice of samples that ENDS at `target_pts_secs`.
 * When `target_pts_secs` is NaN we fall back to the latest
 * window.
 *
 * The caller holds g_tap_write_lock: the snapshot of the ring
 * fields and the memcpy of the slice see no writer. */
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

    /* Snapshot loop: runs once, the caller holding g_tap_write_lock
     * (see TAP_SEQLOCK_MAX_RETRIES). */
    int retries = 0;
    while (retries++ < TAP_SEQLOCK_MAX_RETRIES) {
        uint_fast32_t s1 = atomic_load_explicit(&ring->seq,
                                                memory_order_acquire);
        if (s1 & 1u) continue;            /* writer in progress */

        /* Snapshot all metadata + compute slice geometry. The
         * caller holds g_tap_write_lock, so no writer and no
         * set_active runs here: the seq check below now only
         * returns the even write generation. */
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

        /* Clamped before the cast: a ring nothing writes any more keeps
         * an old end, and its distance in bytes from the playhead can
         * pass what a size_t holds (three hours at 48 kHz stereo where
         * it has 32 bits). Past the ring it is the fallback below. */
        double delta_bytes_f = delta_secs * rate * (double)frame_bytes;
        size_t delta_bytes_unaligned = delta_bytes_f < (double)valid_bytes
            ? (size_t)delta_bytes_f : valid_bytes;
        size_t delta_bytes =
            (delta_bytes_unaligned / frame_bytes) * frame_bytes;
        /* Soft fallback: if the requested PTS-aligned slice falls
         * outside the ring's coverage (only possible at the
         * TAP_MAX_RING_BYTES cap, on extreme hi-res), degrade to
         * "latest available window" rather than freezing on stale
         * data or returning empty. The visual effect is a brief
         * constant lead during the chain pre-buffer phase, fully
         * resolved within one paint as the AO catches up to the
         * chain. */
        if (delta_bytes + window_bytes > valid_bytes) {
            delta_bytes = 0;
        }

        size_t end_byte =
            (write_pos + capacity - delta_bytes) % capacity;
        size_t start =
            (end_byte + capacity - window_bytes) % capacity;

        /* Copy the slice. */
        if (start + window_bytes <= capacity) {
            memcpy(ba->data, &buf[start], window_bytes);
        } else {
            size_t first = capacity - start;
            memcpy(ba->data, &buf[start], first);
            memcpy((char *)ba->data + first, &buf[0],
                   window_bytes - first);
        }

        /* The generation of the snapshot. */
        uint_fast32_t s2 = atomic_load_explicit(&ring->seq,
                                                memory_order_acquire);
        if (s1 == s2) {
            bytes = window_bytes;
            if (!isnan(end_pts)) {
                double slice_end_secs = end_pts -
                    ((double)delta_bytes / (double)frame_bytes /
                     (double)rate);
                /* A timestamp no int64 of nanoseconds holds reads 0. */
                if (fabs(slice_end_secs) < 9e9)
                    pts_ns = (int64_t)(slice_end_secs * 1e9);
            }
            have_data = true;
            gen = s1;
            break;
        }
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
     * which slots are active + their names. The rings are read below
     * under g_tap_write_lock, which keeps their buffers in place
     * (F81). */
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

    mp_mutex_lock(&g_tap_write_lock);
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
    mp_mutex_unlock(&g_tap_write_lock);

    *out = (struct mpv_node){
        .format = MPV_FORMAT_NODE_MAP, .u.list = root};
    return 0;
}
