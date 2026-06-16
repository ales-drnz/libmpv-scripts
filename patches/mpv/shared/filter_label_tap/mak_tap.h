/* MAK_TAP_PATCH_V3 ─── public API for the per-filter audio tap.
 *
 * mak_tap maintains a fixed-size table of "active taps" (a tap
 * being a combination of filter name + side). For each active
 * tap, two ring buffers (pre / post) accumulate the most recent
 * ~340 ms of post-conversion Float32 samples plus the playback
 * PTS at the most-recently-written sample. The audio chain
 * calls mak_tap_write() from inside user_wrapper_process for
 * every frame the user filter handles; the call short-circuits
 * when the filter is not in the active set.
 *
 * Reads are aligned to a caller-supplied playback PTS so the
 * visualiser sees the slice of audio that the AO is playing
 * RIGHT NOW, even though the filter chain processes ahead of
 * the AO in bursts. The wrapper passes
 * `playing_audio_pts(mpctx)` from inside the property getter. */
#ifndef MP_AUDIO_MAK_TAP_H_
#define MP_AUDIO_MAK_TAP_H_

#include <stdbool.h>

struct mp_aframe;
struct mpv_node;

#define MAK_TAP_MAX        8
#define MAK_TAP_MAX_SAMPLES 4096

/* Replace the active-taps list with the comma-separated [csv].
 * Empty / NULL clears every tap. Idempotent and threadsafe. */
void mak_tap_set_active(const char *csv);

/* Returns the current CSV. Caller-owned copy via talloc.
 * Returns "" (talloc-allocated) when no tap is active. */
char *mak_tap_get_active(void *parent);

/* Fast-path check used by the wrapper hook. */
bool mak_tap_label_active(const char *name);

/* Append `aframe` to the per-tap ring for `name` on the side
 * indicated by `is_post`. No-op if the label is not active.
 * Encoded passthrough formats (AC3 / DTS / …) are silently
 * skipped. */
void mak_tap_write(const char *name, bool is_post,
                   struct mp_aframe *aframe);

/* MAK_TAP_PATCH_V3 ─── pre-DSP waveform fold. Called from the af chain
 * user_wrapper_process PRE hook for every audio frame; self-gates to
 * the "in" filter and to an active progressive analysis. Converts +
 * mono-downmixes the source frame and folds it into the progressive
 * waveform envelope. */
void mak_waveform_tap_in(const char *name, struct mp_aframe *aframe);

/* Build the audio-tap-frames node tree, returning the slice of
 * samples that ends at `target_pts_secs` for every active tap.
 * `target_pts_secs == NaN` means "return the latest available
 * window" (used when playback PTS is unknown / not playing). */
int mak_tap_read_all(struct mpv_node *out, void *parent,
                     double target_pts_secs);

#endif
