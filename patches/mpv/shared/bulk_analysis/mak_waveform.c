/* MAK_WAVEFORM_PATCH ─── waveform product (min/max amplitude envelope).
 *
 * Owns the visible waveform state `g_wave` and everything that touches it: the
 * generation/lifecycle, the reader, the decode-progress fraction, the
 * playback-grown PROGRESSIVE / ROLLING fold (driven by the af-tap), and the
 * scan-engine interface (begin_generation / mark_* / arm_* / publish_partial /
 * commit / drop_partial) that the bulk engine (mak_scan.c) calls to fill it.
 *
 * References no loudness symbol, so the bulk patch compiles and links
 * standalone. See mak_waveform.h for the API and patch_bulk_analysis.py for the
 * design rationale. */
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include <libavutil/mem.h>

#include "mpv_talloc.h"
#include "osdep/threads.h"
#include <mpv/client.h>

#include "audio/mak_waveform.h"
#include "audio/mak_wave_fold.h"

/* States surfaced through the property — match the C string exactly
 * with the Dart-side enum. */
enum mak_wave_state {
    MAK_WAVE_IDLE        = 0,
    MAK_WAVE_DECODING    = 1,
    MAK_WAVE_READY       = 2,
    MAK_WAVE_FAILED      = 3,
    MAK_WAVE_PROGRESSIVE = 4,  /* network: envelope grown from playback */
    MAK_WAVE_ROLLING     = 5,  /* live: cache-aligned sliding window */
};

static const char *state_string(enum mak_wave_state s)
{
    switch (s) {
        case MAK_WAVE_DECODING:    return "decoding";
        case MAK_WAVE_READY:       return "ready";
        case MAK_WAVE_FAILED:      return "failed";
        case MAK_WAVE_PROGRESSIVE: return "progressive";
        case MAK_WAVE_ROLLING:     return "rolling";
        case MAK_WAVE_IDLE:
        default:                   return "idle";
    }
}

/* Master gate. OFF by default — the analyzer does nothing until a
 * waveform-enabled set lands. */
static atomic_bool g_enabled = false;

struct mak_wave {
    enum mak_wave_state state;
    int64_t  duration_us;
    int      bins;
    /* High-water mark of filled bins. BULK: trims the flat dead tail left
     * when the duration estimate overshoots (VBR / rounded-duration
     * containers). PROGRESSIVE: the furthest bin playback has reached, so
     * the reader emits only what has been played. 0 = "not computed",
     * reader falls back to bins. */
    int      valid_bins;
    /* BULK live publish: count of envelope bins the parallel workers have
     * SEALED so far (union across all worker regions). Drives the decode
     * progress fraction while state == DECODING; not used in other states. */
    int      coverage_bins;
    float   *bins_min;
    float   *bins_max;
    /* Per-bin "has a sample yet" flag. Lets the reader expose "filled" so
     * the UI tells unplayed bins (0) from played-but-silent (1). BULK fills
     * it as each region's bins seal; PROGRESSIVE grows it as the af-tap folds
     * frames. */
    bool     progressive;
    uint8_t *bins_filled;
    double   duration_secs;
    /* ROLLING (true live, unknown duration): a cache-aligned sliding window.
     * Reuses bins_min/max/filled as a LINEAR buffer where index k holds the
     * absolute bin (roll_base_bin + k); valid_bins is the count held. The
     * base advances only when the demuxer evicts that audio from its
     * back-buffer (see mak_waveform_update_cache_range), so a bin is never
     * dropped while it is still seekable. The absolute media span surfaced to
     * the wrapper for placement + seeking is derived in mak_waveform_read
     * straight from the bin grid (roll_base_bin/roll_lead/valid_bins). */
    bool     rolling;
    int64_t  roll_base_bin;
    double   roll_bin_secs;
    /* Generation: bumped on every mak_waveform_begin_generation()/stop(). A
     * coordinator/worker carries its own gen; if g_wave.current_gen drifts
     * past it, it self-cancels on the next sample-boundary check. */
    atomic_int current_gen;
};

/* The lock lives OUTSIDE the state struct on purpose: Darwin's
 * PTHREAD_MUTEX_INITIALIZER carries a non-zero signature, and a single
 * initialized member drags the WHOLE struct out of __bss into __data —
 * every embedded buffer byte then ships as on-disk zeros (~0.5 MiB per
 * Apple slice for the ring structs). A separate statically-initialized
 * lock plus a zero-init struct keeps identical semantics at zero file
 * cost. (ELF/PE are immune: their static lock initializers are all
 * zero.) */
static mp_mutex g_wave_lock = MP_STATIC_MUTEX_INITIALIZER;
static struct mak_wave g_wave;   /* zero-init: state == MAK_WAVE_IDLE */

static void reset_g_wave_locked(void)
{
    if (g_wave.bins_min) {
        av_free(g_wave.bins_min);
        g_wave.bins_min = NULL;
    }
    if (g_wave.bins_max) {
        av_free(g_wave.bins_max);
        g_wave.bins_max = NULL;
    }
    if (g_wave.bins_filled) {
        av_free(g_wave.bins_filled);
        g_wave.bins_filled = NULL;
    }
    g_wave.bins          = 0;
    g_wave.valid_bins    = 0;
    g_wave.coverage_bins = 0;
    g_wave.duration_us   = 0;
    g_wave.progressive   = false;
    g_wave.duration_secs = 0;
    g_wave.rolling        = false;
    g_wave.roll_base_bin  = 0;
    g_wave.roll_bin_secs  = 0;
}

static void set_state_if_current(int gen, enum mak_wave_state s)
{
    mp_mutex_lock(&g_wave_lock);
    if (atomic_load(&g_wave.current_gen) == gen)
        g_wave.state = s;
    mp_mutex_unlock(&g_wave_lock);
}

/* ── scan-engine interface ────────────────────────────────────────────── */

int mak_waveform_begin_generation(void)
{
    /* Bump the generation up front so any in-flight coordinator/workers and
     * af-tap folds from the previous track self-cancel, and reset the visible
     * state to "decoding" so a wrapper polling before the strategy arms does
     * not see a stale "ready" from the previous track. */
    int new_gen = atomic_fetch_add(&g_wave.current_gen, 1) + 1;
    mp_mutex_lock(&g_wave_lock);
    g_wave.state = MAK_WAVE_DECODING;
    reset_g_wave_locked();
    mp_mutex_unlock(&g_wave_lock);
    return new_gen;
}

void mak_waveform_mark_decoding(int gen) { set_state_if_current(gen, MAK_WAVE_DECODING); }
void mak_waveform_mark_failed(int gen)   { set_state_if_current(gen, MAK_WAVE_FAILED); }

/* Arm PROGRESSIVE mode: lay out a fixed bin axis from [duration_secs] and
 * let the af-tap grow the envelope from playback (mak_waveform_fold_samples).
 * Used for sources we cannot parallel-decode (DASH/HLS transcode, live,
 * non-seekable). No-op if a newer generation has started. Without a usable
 * duration there is no axis, so the state goes FAILED. */
void mak_waveform_arm_progressive(int my_gen, double duration_secs)
{
    int pbins = duration_secs > 0 ? (int)(duration_secs / 0.04) : 0;
    if (pbins > MAK_WAVEFORM_BINS) pbins = MAK_WAVEFORM_BINS;
    mp_mutex_lock(&g_wave_lock);
    if (atomic_load(&g_wave.current_gen) != my_gen) {
        mp_mutex_unlock(&g_wave_lock);
        return;
    }
    reset_g_wave_locked();
    if (pbins >= 1) {
        float   *pmin = av_calloc(pbins, sizeof(float));
        float   *pmax = av_calloc(pbins, sizeof(float));
        uint8_t *pfil = av_calloc(pbins, sizeof(uint8_t));
        if (pmin && pmax && pfil) {
            g_wave.bins          = pbins;
            g_wave.valid_bins    = 0;  /* grows via fold high-water */
            g_wave.bins_min      = pmin;
            g_wave.bins_max      = pmax;
            g_wave.bins_filled   = pfil;
            g_wave.duration_secs = duration_secs;
            g_wave.duration_us   = (int64_t)(duration_secs * 1e6);
            g_wave.progressive   = true;
            g_wave.state         = MAK_WAVE_PROGRESSIVE;
        } else {
            if (pmin) av_free(pmin);
            if (pmax) av_free(pmax);
            if (pfil) av_free(pfil);
            g_wave.state = MAK_WAVE_FAILED;
        }
    } else {
        g_wave.state = MAK_WAVE_FAILED;
    }
    mp_mutex_unlock(&g_wave_lock);
}

/* Fixed bin width for the ROLLING (live) window — 40 ms, matching the
 * progressive cadence. MAK_WAVE_ROLL_BIN_US is that same width as an exact
 * integer so the surfaced axis carries no float drift.
 *
 * Cache-driven eviction (mak_waveform_update_cache_range) is the normal way
 * bins leave the window; MAK_WAVE_ROLL_BINS is only a memory backstop against
 * a pathologically large demuxer back-buffer. 131072 bins × 40 ms ≈ 87 min
 * (~1.2 MB across the three arrays) — comfortably past mpv's default 125 MiB
 * back-buffer at typical audio bitrates, so eviction fires first and never
 * drops a still-seekable bin. If the back-buffer is enlarged far beyond that
 * AND the user scrolls past the cap, the oldest bins are dropped silently
 * (graceful: the absolute axis stays consistent). Raise this to cover a
 * deliberately huge back-buffer. */
#define MAK_WAVE_ROLL_BIN_SECS 0.04
#define MAK_WAVE_ROLL_BIN_US   40000   /* 0.04 s, exact — no float rounding */
#define MAK_WAVE_ROLL_BINS     131072

/* Arm ROLLING mode for a true-live source (unknown duration). Unlike
 * PROGRESSIVE — which lays a fixed axis over a known total — this keeps a
 * sliding window of ABSOLUTE media-time bins, retained in lockstep with the
 * demuxer's seekable cache (mak_waveform_update_cache_range). The af-tap
 * grows it via mak_waveform_fold_samples, exactly as progressive does. */
void mak_waveform_arm_rolling(int my_gen)
{
    mp_mutex_lock(&g_wave_lock);
    if (atomic_load(&g_wave.current_gen) != my_gen) {
        mp_mutex_unlock(&g_wave_lock);
        return;
    }
    reset_g_wave_locked();
    const int cap = MAK_WAVE_ROLL_BINS;
    float   *pmin = av_calloc(cap, sizeof(float));
    float   *pmax = av_calloc(cap, sizeof(float));
    uint8_t *pfil = av_calloc(cap, sizeof(uint8_t));
    if (pmin && pmax && pfil) {
        g_wave.bins           = cap;
        g_wave.valid_bins     = 0;
        g_wave.bins_min       = pmin;
        g_wave.bins_max       = pmax;
        g_wave.bins_filled    = pfil;
        g_wave.progressive    = true;   /* shares the af-tap fold path */
        g_wave.rolling        = true;
        g_wave.roll_base_bin  = 0;
        g_wave.roll_bin_secs  = MAK_WAVE_ROLL_BIN_SECS;
        g_wave.duration_secs  = 0;
        g_wave.duration_us    = 0;
        g_wave.state          = MAK_WAVE_ROLLING;
    } else {
        if (pmin) av_free(pmin);
        if (pmax) av_free(pmax);
        if (pfil) av_free(pfil);
        g_wave.state = MAK_WAVE_FAILED;
    }
    mp_mutex_unlock(&g_wave_lock);
}

void mak_waveform_publish_partial(int gen, int bins, int64_t duration_us,
                                  int nregions, const int *bin_start,
                                  const int *cnt, const float *src_min,
                                  const float *src_max,
                                  const uint8_t *const *src_filled,
                                  int coverage_bins)
{
    mp_mutex_lock(&g_wave_lock);
    if (atomic_load(&g_wave.current_gen) != gen) {
        mp_mutex_unlock(&g_wave_lock);
        return;
    }
    /* First call: allocate the g_wave-OWNED partial buffer (begin_generation
     * reset g_wave, so the arrays are NULL). We NEVER alias the engine's worker
     * arrays into g_wave, so reset_g_wave_locked() on the core thread frees
     * only g_wave-owned memory. valid_bins stays 0 so the reader emits the
     * FULL axis and the per-bin mask drives rendering. */
    if (!g_wave.bins_min && !g_wave.bins_max && !g_wave.bins_filled) {
        float   *pmin = av_calloc(bins, sizeof(float));
        float   *pmax = av_calloc(bins, sizeof(float));
        uint8_t *pfil = av_calloc(bins, sizeof(uint8_t));
        if (pmin && pmax && pfil) {
            g_wave.bins          = bins;
            g_wave.valid_bins    = 0;
            g_wave.coverage_bins = 0;
            g_wave.bins_min      = pmin;
            g_wave.bins_max      = pmax;
            g_wave.bins_filled   = pfil;
            g_wave.progressive   = false;
            g_wave.rolling       = false;
            g_wave.duration_us   = duration_us;
            g_wave.state         = MAK_WAVE_DECODING;
        } else {
            if (pmin) av_free(pmin);
            if (pmax) av_free(pmax);
            if (pfil) av_free(pfil);
            mp_mutex_unlock(&g_wave_lock);
            return;   /* alloc failed: skip live surfacing, commit at join */
        }
    }
    /* Copy each region's sealed prefix into the g_wave-owned arrays. The
     * caller's ACQUIRE of the high-waters happened-before this on the same
     * thread, so bins [0,cnt) are visible; the workers only touch indices
     * >= cnt, so no slot is concurrently read and written.
     *
     * Source-array asymmetry: src_min/src_max are the engine's GLOBAL bin
     * arrays (read at +off, the region's global offset), but src_filled[w] is
     * the worker's PER-REGION mask, local-indexed from 0 — both land the same
     * global destination range [off, off+h). */
    if (g_wave.bins == bins && g_wave.bins_min && g_wave.bins_max &&
        g_wave.bins_filled) {
        for (int w = 0; w < nregions; w++) {
            int off = bin_start[w];
            int h   = cnt[w];
            if (h <= 0) continue;
            if (off < 0 || off + h > bins) continue;   /* defensive */
            memcpy(g_wave.bins_min + off, src_min + off,
                   (size_t)h * sizeof(float));
            memcpy(g_wave.bins_max + off, src_max + off,
                   (size_t)h * sizeof(float));
            if (src_filled[w])
                memcpy(g_wave.bins_filled + off, src_filled[w], (size_t)h);
        }
        g_wave.coverage_bins = coverage_bins;
    }
    mp_mutex_unlock(&g_wave_lock);
}

bool mak_waveform_commit(int gen, int bins, int64_t duration_us,
                         float *min, float *max, uint8_t *filled,
                         int valid_bins)
{
    bool took = false;
    mp_mutex_lock(&g_wave_lock);
    if (atomic_load(&g_wave.current_gen) == gen) {
        if (g_wave.bins_min) av_free(g_wave.bins_min);
        if (g_wave.bins_max) av_free(g_wave.bins_max);
        if (g_wave.bins_filled) av_free(g_wave.bins_filled);
        g_wave.bins          = bins;
        g_wave.valid_bins    = valid_bins;
        g_wave.coverage_bins = valid_bins;   /* fully covered at READY */
        g_wave.bins_min      = min;
        g_wave.bins_max      = max;
        g_wave.bins_filled   = filled;
        g_wave.duration_us   = duration_us;
        g_wave.state         = MAK_WAVE_READY;
        took = true;
    }
    mp_mutex_unlock(&g_wave_lock);
    return took;
}

void mak_waveform_drop_partial(int gen)
{
    /* The engine's fail path: drop any partial bulk envelope so FAILED never
     * leaves stale partial data referenced. Only our own bulk partial (state
     * DECODING) is dropped; a newer generation has its own buffer and is left
     * alone. The buffer is g_wave-owned, so reset frees it. */
    mp_mutex_lock(&g_wave_lock);
    if (atomic_load(&g_wave.current_gen) == gen &&
        g_wave.state == MAK_WAVE_DECODING)
        reset_g_wave_locked();
    mp_mutex_unlock(&g_wave_lock);
}

/* Evict the rolling window in lockstep with the demuxer's seekable cache:
 * [begin_secs, end_secs] is the cached range (negative = unknown). Drops
 * only bins older than begin (which are no longer seekable), so nothing
 * still reachable by a backward seek is forgotten. Records the absolute
 * span for the reader. No-op outside ROLLING mode. Runs on the core thread
 * from the property getter, at the wrapper's poll cadence. */
void mak_waveform_update_cache_range(double begin_secs, double end_secs)
{
    mp_mutex_lock(&g_wave_lock);
    if (g_wave.rolling && g_wave.state == MAK_WAVE_ROLLING &&
        g_wave.roll_bin_secs > 0 && g_wave.bins > 0 &&
        g_wave.bins_min && g_wave.bins_max && g_wave.bins_filled) {
        const int cap = g_wave.bins;
        if (begin_secs >= 0) {
            int64_t new_base = (int64_t)(begin_secs / g_wave.roll_bin_secs);
            if (new_base > g_wave.roll_base_bin) {
                int64_t shift = new_base - g_wave.roll_base_bin;
                if (shift >= g_wave.valid_bins) {
                    g_wave.valid_bins = 0;
                } else {
                    int keep = g_wave.valid_bins - (int)shift;
                    memmove(g_wave.bins_min, g_wave.bins_min + shift,
                            (size_t)keep * sizeof(float));
                    memmove(g_wave.bins_max, g_wave.bins_max + shift,
                            (size_t)keep * sizeof(float));
                    memmove(g_wave.bins_filled, g_wave.bins_filled + shift,
                            (size_t)keep);
                    g_wave.valid_bins = keep;
                }
                g_wave.roll_base_bin = new_base;
                /* Restore the invariant: bins_filled[k]==0 for k>=valid_bins. */
                memset(g_wave.bins_filled + g_wave.valid_bins, 0,
                       (size_t)(cap - g_wave.valid_bins));
            }
        }
        /* The reported range is derived from the bin grid by the reader
         * (bin-quantized → stable); eviction here only advances the base. The
         * demuxer forward edge (end_secs) is not part of the folded waveform,
         * so it's ignored for the axis. */
        (void)end_secs;
    }
    mp_mutex_unlock(&g_wave_lock);
}

/* ── public entry points ─────────────────────────────────────────── */

void mak_waveform_stop(void)
{
    int new_gen = atomic_fetch_add(&g_wave.current_gen, 1) + 1;
    mp_mutex_lock(&g_wave_lock);
    g_wave.state = MAK_WAVE_IDLE;
    reset_g_wave_locked();
    mp_mutex_unlock(&g_wave_lock);
    (void)new_gen;
}

void mak_waveform_set_enabled(bool on)
{
    atomic_store(&g_enabled, on);
    /* Turning the gate off also cancels any in-flight analysis and
     * clears the visible state. */
    if (!on)
        mak_waveform_stop();
}

bool mak_waveform_is_enabled(void)
{
    return atomic_load(&g_enabled);
}

/* Whether a PROGRESSIVE analysis is live and wants per-frame folds from
 * the af-tap dispatcher. Cheap gate checked once per input frame. */
bool mak_waveform_wants_frames(void)
{
    if (!atomic_load(&g_enabled)) return false;
    mp_mutex_lock(&g_wave_lock);
    bool want = g_wave.progressive &&
                (g_wave.state == MAK_WAVE_PROGRESSIVE ||
                 g_wave.state == MAK_WAVE_ROLLING);
    mp_mutex_unlock(&g_wave_lock);
    return want;
}

/* Whether the live generation is a PLAYBACK-GROWN envelope (PROGRESSIVE or
 * ROLLING) — a source the bulk path cannot decode up-front (network adaptive /
 * non-seekable, or a coordinator-classified local-adaptive playlist). A fresh
 * scan on such a source can only re-arm an empty axis and re-grow it from the
 * current playhead, so it would WIPE the accumulated envelope while producing
 * nothing a one-shot decode could not. A caller that merely wants to ride the
 * decode pass (the offline loudness scan) checks this first and skips the
 * restart when it is true. Reports the structural MODE under g_wave_lock;
 * unlike mak_waveform_wants_frames() it is NOT gated on g_enabled, so a
 * loudness-only session — which never folds (wants_frames stays false) yet is
 * still PROGRESSIVE/ROLLING — classifies correctly. References no loudness
 * symbol, so the bulk patch still compiles and links standalone. */
bool mak_waveform_is_progressive_live(void)
{
    mp_mutex_lock(&g_wave_lock);
    bool live = g_wave.progressive &&
                (g_wave.state == MAK_WAVE_PROGRESSIVE ||
                 g_wave.state == MAK_WAVE_ROLLING);
    mp_mutex_unlock(&g_wave_lock);
    return live;
}

/* Live generation, captured at the af-tap call site and handed back to
 * mak_waveform_fold_samples so a frame from a torn-down chain (the
 * previous track) is dropped instead of folded into the new envelope. */
int mak_waveform_current_gen(void)
{
    return atomic_load(&g_wave.current_gen);
}

/* Decode progress [0,1] of an in-flight BULK scan, for the loudness reader to
 * surface as its "scanning" fraction (both ride the same decode pass). The
 * sealed-bin fraction while DECODING, 1.0 once the envelope is READY (so the
 * brief window between the waveform commit and the loudness merge still reads
 * ~done), 0 otherwise. References no loudness symbol. */
double mak_waveform_decode_fraction(void)
{
    double f = 0.0;
    mp_mutex_lock(&g_wave_lock);
    if (g_wave.state == MAK_WAVE_DECODING && g_wave.bins > 0)
        f = (double)g_wave.coverage_bins / (double)g_wave.bins;
    else if (g_wave.state == MAK_WAVE_READY)
        f = 1.0;
    mp_mutex_unlock(&g_wave_lock);
    if (f < 0.0) f = 0.0;
    if (f > 1.0) f = 1.0;
    return f;
}

/* Fold [n] mono Float32 samples — already converted + downmixed by the
 * af-tap dispatcher — into the PROGRESSIVE envelope, per-bin by source
 * position. The first sample is at media time [pts_secs]; [rate] is the
 * frame's sample rate (sample j sits at pts_secs + j/rate). Binning goes
 * through the shared kernel (same mapping as the bulk path); a run-walk
 * reduces each contiguous same-bin run to one min/max widen. [gen] must
 * still be current or the frame is dropped. Grows the high-water
 * valid_bins so the reader emits only what playback has reached. */
void mak_waveform_fold_samples(const float *mono, int n, double pts_secs,
                               int rate, int gen)
{
    if (!mono || n <= 0 || rate <= 0) return;
    if (!(pts_secs >= 0)) return;            /* also rejects NaN */
    mp_mutex_lock(&g_wave_lock);
    const bool live_gen = atomic_load(&g_wave.current_gen) == gen;
    if (live_gen && g_wave.progressive && g_wave.bins > 0 &&
        g_wave.bins_min && g_wave.bins_max && g_wave.bins_filled) {
        if (g_wave.rolling && g_wave.state == MAK_WAVE_ROLLING &&
            g_wave.roll_bin_secs > 0) {
            /* ROLLING: absolute media-time bins into the linear sliding
             * window. Invariant: bins_filled[k]==0 for k >= valid_bins, so a
             * first touch always seeds; eviction (memmove + memset) keeps it. */
            const double bs  = g_wave.roll_bin_secs;
            const int    cap = g_wave.bins;
            int i = 0;
            while (i < n) {
                int64_t ab = (int64_t)((pts_secs + (double)i / rate) / bs);
                if (ab < g_wave.roll_base_bin) { i++; continue; }
                int64_t local = ab - g_wave.roll_base_bin;
                /* Backstop: slide the window forward if it would overflow
                 * capacity (the demuxer normally evicts well before this). */
                if (local >= cap) {
                    int64_t shift = local - (cap - 1);
                    if (shift >= g_wave.valid_bins) {
                        g_wave.valid_bins = 0;
                    } else {
                        int keep = g_wave.valid_bins - (int)shift;
                        memmove(g_wave.bins_min, g_wave.bins_min + shift,
                                (size_t)keep * sizeof(float));
                        memmove(g_wave.bins_max, g_wave.bins_max + shift,
                                (size_t)keep * sizeof(float));
                        memmove(g_wave.bins_filled, g_wave.bins_filled + shift,
                                (size_t)keep);
                        g_wave.valid_bins = keep;
                    }
                    g_wave.roll_base_bin += shift;
                    memset(g_wave.bins_filled + g_wave.valid_bins, 0,
                           (size_t)(cap - g_wave.valid_bins));
                    local -= shift;
                }
                const int li = (int)local;
                float rmin = mono[i];
                float rmax = mono[i];
                int j = i + 1;
                while (j < n &&
                       (int64_t)((pts_secs + (double)j / rate) / bs) == ab) {
                    if (mono[j] < rmin) rmin = mono[j];
                    if (mono[j] > rmax) rmax = mono[j];
                    j++;
                }
                mak_fold_bin(rmin, &g_wave.bins_min[li], &g_wave.bins_max[li],
                             &g_wave.bins_filled[li]);
                mak_fold_bin(rmax, &g_wave.bins_min[li], &g_wave.bins_max[li],
                             &g_wave.bins_filled[li]);
                if (li + 1 > g_wave.valid_bins)
                    g_wave.valid_bins = li + 1;
                i = j;
            }
        } else if (g_wave.state == MAK_WAVE_PROGRESSIVE &&
                   g_wave.duration_secs > 0) {
            const int     bins  = g_wave.bins;
            const int64_t total = (int64_t)(g_wave.duration_secs * rate);
            const int64_t base  = (int64_t)llround(pts_secs * rate);
            int i = 0;
            while (i < n) {
                int64_t b = mak_sample_to_bin(base + i, bins, total);
                float rmin = mono[i];
                float rmax = mono[i];
                int j = i + 1;
                while (j < n &&
                       mak_sample_to_bin(base + j, bins, total) == b) {
                    if (mono[j] < rmin) rmin = mono[j];
                    if (mono[j] > rmax) rmax = mono[j];
                    j++;
                }
                mak_fold_bin(rmin, &g_wave.bins_min[b], &g_wave.bins_max[b],
                             &g_wave.bins_filled[b]);
                mak_fold_bin(rmax, &g_wave.bins_min[b], &g_wave.bins_max[b],
                             &g_wave.bins_filled[b]);
                if ((int)b + 1 > g_wave.valid_bins)
                    g_wave.valid_bins = (int)b + 1;
                i = j;
            }
        }
    }
    mp_mutex_unlock(&g_wave_lock);
}

int mak_waveform_read(struct mpv_node *out, void *parent)
{
    (void)parent;
    if (!out) return -1;

    mp_mutex_lock(&g_wave_lock);
    enum mak_wave_state state = g_wave.state;
    int64_t duration_us = g_wave.duration_us;
    int64_t range_start_us = 0;
    int64_t range_end_us   = 0;
    int     roll_lead      = 0;  /* ROLLING: leading not-yet-filled bins to skip */
    bool    has_data    = (state == MAK_WAVE_READY ||
                           state == MAK_WAVE_PROGRESSIVE ||
                           state == MAK_WAVE_ROLLING ||
                           /* BULK mid-decode: the live publish loop has
                            * attached a partial g_wave-owned buffer. valid_bins
                            * is 0, so the snapshot below emits the full axis and
                            * the per-bin "filled" mask marks the sealed bins. */
                           (state == MAK_WAVE_DECODING && g_wave.bins_min));
    /* Live decode progress for the new property keys (snapshot under the lock). */
    int     snap_coverage   = g_wave.coverage_bins;
    int     snap_total_bins = g_wave.bins;

    /* ROLLING has no total. The axis is derived straight from the bin grid so
     * it is bin-quantized and stable across polls: the surfaced window starts
     * at the first FILLED bin (roll_base_bin + roll_lead) and spans the held
     * bins, each MAK_WAVE_ROLL_BIN_US wide. Integer math (no float * 1e6)
     * guarantees duration_us == held*BIN_US exactly and duration/bins == 0.04
     * in the wrapper — no rounding drift.
     *
     * No start-time rebase is needed: mpv applies its ts_offset
     * (= -demuxer->start_time under the default --rebase-start-time) on the
     * demuxer OUTPUT — to both the packets fed to the decoder (demux.c
     * dequeue_packet) and the seek ranges from demux_get_reader_state — so
     * the af-tap frame PTS that build these bins, the cache begin/end that
     * evict them, and the wrapper playhead (time-pos) are ALL already on the
     * same rebased timeline. The bin grid therefore matches time-pos directly.
     * The demuxer's cache begin/end are used only to evict, never the axis. */
    if (state == MAK_WAVE_ROLLING) {
        /* Skip leading not-yet-filled bins. The demuxer's seekable-range begin
         * can sit a bin or two before the first audio we have actually folded
         * (e.g. AAC decoder delay ≈ 0.05 s), which would otherwise render as an
         * empty gap at the window's left edge. Anchor the surfaced window at
         * the first filled bin; interior gaps (filled==0) are kept as-is. */
        if (g_wave.bins_filled) {
            while (roll_lead < g_wave.valid_bins &&
                   !g_wave.bins_filled[roll_lead])
                roll_lead++;
        }
        int held = g_wave.valid_bins - roll_lead;
        if (held < 0) held = 0;
        range_start_us =
            (g_wave.roll_base_bin + roll_lead) * MAK_WAVE_ROLL_BIN_US;
        range_end_us =
            (g_wave.roll_base_bin + g_wave.valid_bins) * MAK_WAVE_ROLL_BIN_US;
        duration_us = (int64_t)held * MAK_WAVE_ROLL_BIN_US;
    }

    /* Snapshot the bin data so the lock can be released before we
     * touch talloc (which can call into the allocator). */
    int      snap_bins = 0;
    float   *snap_min  = NULL;
    float   *snap_max  = NULL;
    uint8_t *snap_fill = NULL;

    if (has_data) {
        /* ROLLING emits exactly the held window [0, valid_bins) — that IS the
         * cached span, placed in absolute time via range_*_us. BULK trims to
         * valid_bins — drops the flat dead tail left by a duration overshoot.
         * PROGRESSIVE and BULK-while-DECODING must emit the FULL bin axis: the
         * not-yet-filled bins (filled == 0) are what lets the renderer map the
         * covered region and draw the rest as a baseline. So trim for ROLLING
         * and BULK-READY (valid_bins set), full axis otherwise.
         *
         * ROLLING anchors the surfaced window at the first FILLED bin: roll_lead
         * leading empties were counted above, so emit exactly the held span
         * [roll_lead, valid_bins) and shift the copy by off == roll_lead so the
         * emitted bins line up with range_start_us (held * BIN == duration_us,
         * one bin == 0.04 s exactly). Interior gaps (filled==0 past roll_lead)
         * are preserved. BULK/PROGRESSIVE start at bin 0 (off == 0). */
        int off = g_wave.rolling ? roll_lead : 0;
        int b = g_wave.rolling
                ? (g_wave.valid_bins - roll_lead)
                : ((!g_wave.progressive &&
                    g_wave.valid_bins > 0 && g_wave.valid_bins <= g_wave.bins)
                   ? g_wave.valid_bins : g_wave.bins);
        if (b > 0 && g_wave.bins_min && g_wave.bins_max) {
            snap_min  = av_malloc((size_t)b * sizeof(float));
            snap_max  = av_malloc((size_t)b * sizeof(float));
            snap_fill = av_malloc((size_t)b);   /* one byte per bin */
            if (snap_min && snap_max && snap_fill) {
                memcpy(snap_min, g_wave.bins_min + off, (size_t)b * sizeof(float));
                memcpy(snap_max, g_wave.bins_max + off, (size_t)b * sizeof(float));
                /* "filled" lets the UI tell "not yet covered" (0) from
                 * "covered + silent" (1). All paths track it per bin now
                 * (BULK fills it as each region seals), so copy it through;
                 * fall back to all-1 only if somehow absent. */
                if (g_wave.bins_filled)
                    memcpy(snap_fill, g_wave.bins_filled + off, (size_t)b);
                else
                    memset(snap_fill, 1, (size_t)b);
                snap_bins = b;
            }
        }
    }
    mp_mutex_unlock(&g_wave_lock);

    /* Decode progress [0,1]: the sealed-bin fraction while DECODING, 1.0 once
     * READY, 0 otherwise. Mirrors mak_waveform_decode_fraction(). */
    double progress = 0.0;
    if (state == MAK_WAVE_DECODING && snap_total_bins > 0)
        progress = (double)snap_coverage / (double)snap_total_bins;
    else if (state == MAK_WAVE_READY)
        progress = 1.0;
    if (progress < 0.0) progress = 0.0;
    if (progress > 1.0) progress = 1.0;

    bool emit_data = has_data && snap_min && snap_max && snap_fill &&
                     snap_bins > 0;

    /* Top-level map:
     * { state, duration_us, min, max, filled, range_start_us, range_end_us,
     *   coverage_bins, total_bins, progress }.
     * The range_* keys carry the absolute media placement of a ROLLING
     * window; they are 0 for the other states. */
    struct mpv_node_list *list = talloc_zero(NULL, struct mpv_node_list);
    list->num    = 10;
    list->keys   = talloc_array(list, char *, 10);
    list->values = talloc_array(list, struct mpv_node, 10);

    list->keys[0] = talloc_strdup(list, "state");
    list->values[0] = (struct mpv_node){
        .format = MPV_FORMAT_STRING,
        .u.string = talloc_strdup(list, state_string(state))};
    list->keys[1] = talloc_strdup(list, "duration_us");
    list->values[1] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = duration_us};

    struct mpv_byte_array *ba_min = talloc_zero(list, struct mpv_byte_array);
    struct mpv_byte_array *ba_max = talloc_zero(list, struct mpv_byte_array);
    if (emit_data) {
        size_t bytes = (size_t)snap_bins * sizeof(float);
        ba_min->data = talloc_size(ba_min, bytes);
        ba_min->size = bytes;
        memcpy(ba_min->data, snap_min, bytes);
        ba_max->data = talloc_size(ba_max, bytes);
        ba_max->size = bytes;
        memcpy(ba_max->data, snap_max, bytes);
    }
    list->keys[2] = talloc_strdup(list, "min");
    list->values[2] = (struct mpv_node){
        .format = MPV_FORMAT_BYTE_ARRAY, .u.ba = ba_min};
    list->keys[3] = talloc_strdup(list, "max");
    list->values[3] = (struct mpv_node){
        .format = MPV_FORMAT_BYTE_ARRAY, .u.ba = ba_max};

    struct mpv_byte_array *ba_fill = talloc_zero(list, struct mpv_byte_array);
    if (emit_data) {
        ba_fill->data = talloc_size(ba_fill, (size_t)snap_bins);
        ba_fill->size = (size_t)snap_bins;
        memcpy(ba_fill->data, snap_fill, (size_t)snap_bins);
    }
    list->keys[4] = talloc_strdup(list, "filled");
    list->values[4] = (struct mpv_node){
        .format = MPV_FORMAT_BYTE_ARRAY, .u.ba = ba_fill};

    list->keys[5] = talloc_strdup(list, "range_start_us");
    list->values[5] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = range_start_us};
    list->keys[6] = talloc_strdup(list, "range_end_us");
    list->values[6] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = range_end_us};

    /* Live BULK decode progress. coverage_bins / total_bins is the sealed-bin
     * fraction (4 worker regions fill in parallel); progress mirrors it as a
     * convenience double (1.0 at ready). All 0 / 1.0 outside DECODING. */
    list->keys[7] = talloc_strdup(list, "coverage_bins");
    list->values[7] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = snap_coverage};
    list->keys[8] = talloc_strdup(list, "total_bins");
    list->values[8] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = snap_total_bins};
    list->keys[9] = talloc_strdup(list, "progress");
    list->values[9] = (struct mpv_node){
        .format = MPV_FORMAT_DOUBLE, .u.double_ = progress};

    if (snap_min)  av_free(snap_min);
    if (snap_max)  av_free(snap_max);
    if (snap_fill) av_free(snap_fill);

    *out = (struct mpv_node){
        .format = MPV_FORMAT_NODE_MAP, .u.list = list};
    return 0;
}
