/* MAK_LOUDNESS_PATCH ─── offline loudness scan (EBU R128 / BS.1770).
 *
 * Rides the bulk waveform analyzer's decode pass: each bulk worker owns
 * a mak_loud_worker that K-weights the PER-CHANNEL signal (before the
 * waveform's mono downmix), accumulates 100 ms sub-block energies on a
 * global grid, and tracks sample/true peak. The coordinator merges the
 * per-worker slices after the join: BS.1770 gating blocks are 400 ms
 * with 75 % overlap == one new block per 100 ms hop, so concatenating
 * the sub-block arrays and sliding a 4-sub-block window reproduces the
 * EXACT single-pass measurement — no overlap between workers, no
 * mergeable-filter-state problem (the reason ffmpeg's af_ebur128 can't
 * be used here).
 *
 * Worker slice grid: worker w owns sub-blocks k with k*hop inside its
 * [sample_start, sample_end) — contiguous and disjoint across workers
 * by construction. The worker decodes up to mak_loud_worker_decode_end()
 * (its slice end rounded UP to the next hop boundary, ≤ one hop extra)
 * so its trailing sub-block completes. Samples decoded before the first
 * owned sub-block (the keyframe pre-roll the bulk worker already
 * decodes-and-discards) warm up the K-filter and true-peak FIR states
 * without being accumulated.
 *
 * Merge math (ITU-R BS.1770-4 / EBU R128):
 *   momentary blocks  E(k) = sum(sub[k..k+3]) / count(sub[k..k+3])
 *   absolute gate     keep L(k) > -70 LUFS
 *   relative gate     keep L(k) > (mean of abs-gated) - 10 LU
 *   integrated        -0.691 + 10·log10(mean of kept E)
 *   LRA (Tech 3342)   short-term 3 s windows on the same grid, abs gate
 *                     -70, relative gate -20; LRA = p95 - p10
 *   true peak         4-phase polyphase 4× oversampler per channel on
 *                     the raw (pre-K) signal
 *
 * Results surface through the read-only `loudness-scan-data` property,
 * gated by the read-write `loudness-scan-enabled` flag (OFF by
 * default). Sources the bulk path cannot decode up-front (adaptive /
 * live / non-seekable → PROGRESSIVE / ROLLING waveform) report state
 * "unavailable" — live metering via the af chain covers those. */
#ifndef MP_AUDIO_MAK_LOUDNESS_H_
#define MP_AUDIO_MAK_LOUDNESS_H_

#include <stdbool.h>
#include <stdint.h>

struct mpv_node;
struct AVCodecParameters;
struct AVFrame;

/* One BS.1770 gating sub-block per 100 ms; hop in samples is
 * (rate + 5) / 10 so non-multiple-of-10 rates stay consistent. */
#define MAK_LOUD_SUBBLOCK_HOPS_PER_SEC 10

/* Per-worker accumulator (opaque — owned by one bulk worker thread). */
struct mak_loud_worker;

/* The finished output of one worker: weighted K-energy sums and sample
 * counts per owned 100 ms sub-block, placed on the global grid via
 * first_subblock, plus the slice's raw peaks. */
struct mak_loud_slice {
    double  *subblock_sums;   /* channel-weighted K-energy sum per sub-block */
    int64_t *subblock_counts; /* samples accumulated per sub-block */
    int64_t  first_subblock;  /* global index of subblock_sums[0] */
    int      n_subblocks;
    double   sample_peak;     /* linear absolute */
    double   true_peak;       /* linear absolute, 4× oversampled */
};

/* Create the accumulator for a bulk worker covering source samples
 * [slice_sample_start, slice_sample_end). [par] supplies the channel
 * layout and sample format for the internal converter. Returns NULL on
 * allocation/converter failure (the worker then simply skips loudness;
 * the merge degrades to the slices that exist). */
struct mak_loud_worker *mak_loud_worker_create(
    const struct AVCodecParameters *par, int sample_rate,
    int64_t slice_sample_start, int64_t slice_sample_end,
    int64_t total_samples);

/* The sample position the bulk worker must decode up to so the slice's
 * trailing sub-block completes: slice end rounded up to the next hop
 * boundary, clamped to the track total (≤ one hop past sample_end). */
int64_t mak_loud_worker_decode_end(const struct mak_loud_worker *w);

/* Feed one decoded frame whose first sample sits at absolute source
 * position [abs_sample_pos]. Frames before the owned grid warm up the
 * filters without accumulating. Safe to call with any frame from the
 * worker's stream; returns <0 only on conversion failure (sticky — the
 * slice is then marked invalid and the merge ignores it). */
int mak_loud_worker_feed(struct mak_loud_worker *w,
                         const struct AVFrame *frame,
                         int64_t abs_sample_pos);

/* Detach the finished slice (ownership moves to *out) and free the
 * accumulator. Returns false when the slice is invalid (failed feed or
 * empty) — *out is then zeroed and nothing needs freeing. */
bool mak_loud_worker_finish(struct mak_loud_worker *w,
                            struct mak_loud_slice *out);

/* Free an accumulator without extracting its slice (worker error path). */
void mak_loud_worker_destroy(struct mak_loud_worker *w);

/* Free a slice extracted by mak_loud_worker_finish. */
void mak_loud_slice_free(struct mak_loud_slice *s);

/* Merge [n] slices (any order — sorted internally by first_subblock),
 * compute integrated / LRA / peaks and publish the global result.
 * No-op (slices still freed) unless [gen] is still the live waveform
 * generation and the scan flag is on. Always consumes the slices. */
void mak_loudness_publish(struct mak_loud_slice *slices, int n,
                          int sample_rate, int gen);

/* State transitions, all generation-checked and gated on the flag:
 * scanning (a bulk decode started), unavailable (source can only be
 * grown from playback — adaptive/live/non-seekable), failed. */
void mak_loudness_mark_scanning(int gen);
void mak_loudness_mark_unavailable(int gen);
void mak_loudness_mark_failed(int gen);

/* Clear the published result back to idle (stop / disable). */
void mak_loudness_reset(void);

/* The loudness-scan-enabled gate. OFF by default. Disabling clears the
 * published result; it does NOT bump the waveform generation (a
 * concurrent waveform-only scan keeps running). */
void mak_loudness_set_enabled(bool on);
bool mak_loudness_is_enabled(void);

/* Builds an MPV_FORMAT_NODE_MAP:
 *   { state, integrated_lufs, lra_lu, sample_peak, true_peak,
 *     gated_block_count, progress }
 * state ∈ idle | scanning | ready | failed | unavailable. The measurement
 * fields are meaningful only when state == "ready" (otherwise 0). `progress`
 * is the live scan fraction [0,1], meaningful while state == "scanning"
 * (1.0 at "ready", 0 otherwise). Always returns 0. */
int mak_loudness_read(struct mpv_node *out);

#endif
