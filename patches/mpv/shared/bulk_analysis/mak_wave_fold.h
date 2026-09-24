/* MAK_WAVEFORM_PATCH ─── shared min/max/energy-per-bin kernel.
 *
 * Used by the bulk parallel decode AND the progressive pre-DSP fold, so
 * the two envelopes are produced by identical math (same downmix, same
 * bin mapping, same seed/widen rule) and converge bin-for-bin over the
 * region both have seen. Besides min/max each bin keeps a sum of squares
 * and a sample count, so the reader can surface a per-bin RMS. No state —
 * pure helpers, safe from any thread.
 */
#ifndef MP_AUDIO_MAK_WAVE_FOLD_H_
#define MP_AUDIO_MAK_WAVE_FOLD_H_

#include <math.h>
#include <stdint.h>
#include <stddef.h>

/* Fold sample [s] into one bin's cells. First touch seeds min==max==s and
 * marks the bin filled; later touches only widen. [bfilled] lets a reader
 * tell "not yet seen" (0) from "seen, and silent" (1, min~=max~=0) — the
 * progressive path needs this so unplayed bins aren't drawn as real zeros. */
static inline void mak_fold_bin(float s, float *bmin, float *bmax,
                                uint8_t *bfilled)
{
    if (!*bfilled) {
        *bmin = s;
        *bmax = s;
        *bfilled = 1;
    } else {
        if (s < *bmin) *bmin = s;
        if (s > *bmax) *bmax = s;
    }
}

/* Fold one contiguous same-bin RUN into a bin: its extremes [rmin]/[rmax],
 * its sum of squares [sq] and its sample count [n]. A bin's first touch
 * (bfilled == 0) also restarts its energy, so a slot reused by the rolling
 * window never carries a stale sum. A re-fold of audio already seen (a
 * progressive seek back) adds to both sum and count, so their ratio stays a
 * fair mean square. */
static inline void mak_fold_run(float rmin, float rmax, double sq, uint32_t n,
                                float *bmin, float *bmax, double *bsq,
                                uint32_t *bn, uint8_t *bfilled)
{
    if (!*bfilled) {
        *bsq = 0.0;
        *bn  = 0;
    }
    mak_fold_bin(rmin, bmin, bmax, bfilled);
    mak_fold_bin(rmax, bmin, bmax, bfilled);
    *bsq += sq;
    *bn  += n;
}

/* Per-bin RMS from its energy cells; 0 for a bin with no samples. */
static inline float mak_bin_rms(double sq, uint32_t n)
{
    return n ? (float)sqrt(sq / (double)n) : 0.0f;
}

/* Canonical absolute-sample -> bin mapping. Identical denominator for both
 * paths (total_samples derived once from the container), so a given sample
 * lands in the same bin regardless of who folds it. Clamped to [0,bins). */
static inline int64_t mak_sample_to_bin(int64_t abs_sample, int bins,
                                        int64_t total_samples)
{
    if (total_samples <= 0 || bins <= 0)
        return 0;
    int64_t b = abs_sample * (int64_t)bins / total_samples;
    if (b < 0)
        b = 0;
    if (b >= bins)
        b = bins - 1;
    return b;
}

/* Average-downmix [n_per_ch] frames of INTERLEAVED float ([ch] channels)
 * into mono [dst]. Conversion to interleaved float is the caller's job
 * (bulk via swresample, progressive via the af-tap convert path) — this
 * is only the channel fold, so both paths get the exact same mono signal. */
static inline void mak_downmix_mono(const float *interleaved, int n_per_ch,
                                    int ch, float *dst)
{
    if (ch <= 1) {
        for (int i = 0; i < n_per_ch; i++)
            dst[i] = interleaved[i];
        return;
    }
    const float inv = 1.0f / (float)ch;
    for (int i = 0; i < n_per_ch; i++) {
        const float *base = interleaved + (size_t)i * ch;
        float acc = 0.0f;
        for (int c = 0; c < ch; c++)
            acc += base[c];
        dst[i] = acc * inv;
    }
}

#endif
