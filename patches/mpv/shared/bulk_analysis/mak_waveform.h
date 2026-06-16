/* MAK_WAVEFORM_PATCH ─── waveform product (min/max amplitude envelope).
 *
 * Owns the visible waveform STATE (`g_wave`) and everything that mutates or
 * reads it: the generation/lifecycle, the three bin arrays, the reader, the
 * decode-progress fraction, and the playback-grown PROGRESSIVE / ROLLING fold
 * (driven by the af-tap, see patch_filter_label_tap.py). The bulk decode that
 * fills it for a complete seekable file is driven by the scan ENGINE
 * (mak_scan.c), which calls the "scan-engine interface" functions below; the
 * engine, not this file, owns the threading and decode.
 *
 * Output is a single fixed-resolution envelope of up to MAK_WAVEFORM_BINS
 * min/max pairs (fewer for very short tracks).
 *
 * The analyzer is gated: OFF by default, runs only while the waveform-enabled
 * flag is set (the loudness scan can also drive the engine via its own flag).
 *
 * References no loudness symbol, so this file compiles and links standalone. */
#ifndef MP_AUDIO_MAK_WAVEFORM_H_
#define MP_AUDIO_MAK_WAVEFORM_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct mpv_node;

#define MAK_WAVEFORM_BINS    2000
#define MAK_WAVEFORM_WORKERS 4

/* ── Public player-facing surface ─────────────────────────────────────────── */

/* Whether a PROGRESSIVE analysis is live and wants per-frame folds from
 * the af-tap dispatcher (checked once per input frame). */
bool mak_waveform_wants_frames(void);

/* True iff the live generation is a playback-grown PROGRESSIVE or ROLLING
 * envelope — a source the bulk path cannot decode up-front. A caller that only
 * wants to ride the decode pass (the offline loudness scan) checks this before
 * (re)starting: restarting such a source would wipe the accumulated envelope
 * for no gain (no full-file pass exists to measure). Reports the structural
 * mode under g_wave_lock REGARDLESS of the waveform-enabled gate; references no
 * loudness symbol. */
bool mak_waveform_is_progressive_live(void);

/* Live generation: the af-tap captures it and passes it back to
 * mak_waveform_fold_samples so a frame from a torn-down chain (the
 * previous track) is dropped instead of folded into the new envelope. The
 * scan engine and the loudness scan also gen-check against this. */
int mak_waveform_current_gen(void);

/* Decode progress [0,1] of an in-flight BULK scan (state DECODING): the
 * fraction of envelope bins the parallel workers have SEALED so far. The
 * offline loudness scan rides the same decode pass and surfaces this as its
 * "scanning" fraction. Returns 1.0 once the bulk envelope is READY, 0
 * otherwise. Reports under g_wave_lock; references no loudness symbol. */
double mak_waveform_decode_fraction(void);

/* Fold [n] mono Float32 samples (already converted + downmixed by the
 * af-tap dispatcher) into the PROGRESSIVE envelope at media time
 * [pts_secs]; [rate] is the frame's sample rate. Pre-DSP, per-bin via the
 * shared kernel — same mapping as the bulk path. No-op unless [gen] is
 * still the live generation. Runs on the core thread (the filter chain),
 * never the AO hot path. */
void mak_waveform_fold_samples(const float *mono, int n, double pts_secs,
                               int rate, int gen);

/* Evict the ROLLING (live) window in lockstep with the demuxer's seekable
 * cache: [begin_secs, end_secs] is the cached range (negative = unknown).
 * Drops only bins older than begin (no longer seekable) and records the
 * absolute span surfaced through waveform-data. No-op outside ROLLING mode.
 * Called from the property getter at the poll cadence. */
void mak_waveform_update_cache_range(double begin_secs, double end_secs);

/* Bumps the generation counter, signalling any in-flight coordinator
 * to bail, and clears the visible state. Idempotent. */
void mak_waveform_stop(void);

/* Enable / disable the analyzer. Disabling also stops any in-flight
 * analysis. Enabling does NOT itself kick a decode — the caller is
 * responsible for calling mak_scan_start() for the loaded file. */
void mak_waveform_set_enabled(bool on);

/* Whether the analyzer is currently enabled. */
bool mak_waveform_is_enabled(void);

/* Builds an MPV_FORMAT_NODE_MAP describing the current state
 * (idle / decoding / ready / failed / progressive / rolling). When data is
 * present, the map carries the per-bin "min"/"max" Float32 byte arrays plus
 * the "filled" mask and decode-progress keys. Always returns 0. */
int mak_waveform_read(struct mpv_node *out, void *parent);

/* ── Interface for the scan engine (mak_scan.c) ───────────────────────────
 * These drive the waveform STATE from the engine. Not part of the public
 * player-facing surface, but declared here so the engine (a separate TU) can
 * call them; g_wave stays private to mak_waveform.c. */

/* Bump the generation, reset the state, mark DECODING. Returns the new gen. */
int  mak_waveform_begin_generation(void);

/* Set the visible state for [gen] iff it is still the current generation. */
void mak_waveform_mark_decoding(int gen);
void mak_waveform_mark_failed(int gen);

/* Arm the playback-grown strategies for a source the bulk path cannot decode
 * up-front (the engine calls these after classification). With no usable
 * duration arm_progressive falls back to FAILED; arm_rolling needs none. */
void mak_waveform_arm_progressive(int gen, double duration_secs);
void mak_waveform_arm_rolling(int gen);

/* Publish a PARTIAL bulk envelope mid-decode: copy each worker region's sealed
 * prefix [bin_start[w], bin_start[w]+cnt[w]) from the engine's source arrays
 * into a g_wave-owned buffer under the lock (allocated on first call), set
 * coverage_bins + DECODING. The caller MUST have ACQUIRE-loaded the per-worker
 * high-waters before computing cnt[] (so [0,cnt) is published-visible on this
 * thread); this copies that sealed, no-longer-written prefix. [src_min] /
 * [src_max] are the contiguous global arrays; [src_filled] is one per-region
 * mask (region w local-indexed, length >= cnt[w]). No-op if [gen] is stale. */
void mak_waveform_publish_partial(int gen, int bins, int64_t duration_us,
                                  int nregions, const int *bin_start,
                                  const int *cnt, const float *src_min,
                                  const float *src_max,
                                  const uint8_t *const *src_filled,
                                  int coverage_bins);

/* Commit the FINAL bulk envelope: free any prior arrays, install [min]/[max]/
 * [filled] into g_wave (ownership transferred on success), mark READY. Returns
 * true iff it took ownership — the caller then NULLs its locals. No-op +
 * false if [gen] is stale (caller keeps + frees its locals). */
bool mak_waveform_commit(int gen, int bins, int64_t duration_us,
                         float *min, float *max, uint8_t *filled,
                         int valid_bins);

/* Drop any partial bulk buffer attached for [gen] (the engine's fail path), so
 * a FAILED state never leaves stale partial data referenced. */
void mak_waveform_drop_partial(int gen);

#endif
