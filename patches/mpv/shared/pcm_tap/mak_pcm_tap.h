/* MAK_PCM_TAP_PATCH_V1 ─── public API for the PCM tap.
 *
 * The tap is a process-wide ring buffer that records the most
 * recent ~200 ms of post-DSP audio samples. Producers call
 * mak_pcm_tap_write() from the audio thread; the property getter
 * in player/command.c calls mak_pcm_tap_read() to expose a
 * snapshot to clients via pcm-tap-frame.
 *
 * The writer accepts every PCM format mpv supports (U8 / S16 /
 * S32 / S64 / FLOAT / DOUBLE, packed and planar), converts to
 * interleaved Float32 inline, and skips encoded passthrough
 * formats (AC3 / DTS / TrueHD / etc.) — those are opaque codec
 * bytes, not PCM, and have nothing meaningful to visualise. */
#ifndef MP_AUDIO_OUT_MAK_PCM_TAP_H_
#define MP_AUDIO_OUT_MAK_PCM_TAP_H_

#include <stdbool.h>
#include <stddef.h>

struct ao;
struct mpv_node;

/* Called from ao_post_process_data() in audio/out/ao.c on every
 * AO chunk. No-op when the AO format is not Float32 interleaved. */
void mak_pcm_tap_write(struct ao *ao, void **data, int num_samples);

/* Builds an MPV_FORMAT_NODE_MAP describing the most recent
 * `max_samples` samples (per channel) in the ring. Returns 0 on
 * success and -1 when the ring is empty / the format is unset.
 * Allocates via talloc against `parent`; the caller hands the
 * resulting node to the property machinery, which frees the
 * tree. */
int mak_pcm_tap_read(struct mpv_node *out, int max_samples,
                     void *parent);

#endif
