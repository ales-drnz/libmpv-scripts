/* MAK_PCM_STREAM_PATCH_V2 ─── live PCM input: the mak-pcm://<id> stream.
 *
 * An app feeds raw PCM bytes as they arrive (a network TTS, a synth, a
 * capture) and mpv plays them through its rawaudio demuxer, with no temp
 * file, socket or client callback on an mpv thread. Each id is one source:
 * a growable byte FIFO with a soft capacity, written by the app through the
 * exported C API below and read by exactly one mpv stream.
 *
 * The id space is process wide (every mpv handle in the process shares it)
 * and ids are never reused. All exported calls are thread safe, never block
 * and return quickly. Negative returns are the MAK_PCM_E* codes.
 *
 * Lifetime: a source holds one app reference (dropped by mak_pcm_release)
 * and, once a stream opened it, one reader reference (dropped when mpv
 * closes the stream). Its memory goes when both are gone. A source released
 * before it was finished is aborted. */
#ifndef MAK_PCM_H_
#define MAK_PCM_H_

#include <stdbool.h>
#include <stdint.h>

#include <mpv/client.h>   /* MPV_EXPORT */

#define MAK_PCM_EUNKNOWN  (-1)  /* no such id (never created, or freed) */
#define MAK_PCM_EINVAL    (-2)  /* invalid argument */
#define MAK_PCM_ECLOSED   (-3)  /* finished, aborted, released, or reader gone */
#define MAK_PCM_ENOMEM    (-4)  /* out of memory */

#define MAK_PCM_STATE_OPEN      0  /* open, waiting for a reader */
#define MAK_PCM_STATE_READING   1  /* a stream reads it */
#define MAK_PCM_STATE_FINISHED  2  /* input closed, maybe still draining */
#define MAK_PCM_STATE_DRAINED   3  /* the reader saw the end */
#define MAK_PCM_STATE_ABORTED   4  /* aborted (or released unfinished) */
#define MAK_PCM_STATE_CLOSED    5  /* the reader closed before the end */

#define MAK_PCM_DEFAULT_CAPACITY  (8 * 1024 * 1024)
#define MAK_PCM_MAX_CAPACITY      (1024 * 1024 * 1024)

/* ── exported C API ─────────────────────────────────────────────────── */

/* New empty source open for writing. capacity_bytes is a soft cap on the
 * buffered bytes; <= 0 means MAK_PCM_DEFAULT_CAPACITY. Returns the id (> 0)
 * or MAK_PCM_EINVAL (above MAK_PCM_MAX_CAPACITY) or MAK_PCM_ENOMEM. */
MPV_EXPORT int64_t mak_pcm_create(int64_t capacity_bytes);

/* Copies up to the free space and returns the bytes accepted (0..len). */
MPV_EXPORT int64_t mak_pcm_write(int64_t id, const uint8_t *data, int64_t len);

/* End of input: the reader drains the buffer, then sees the end of file. */
MPV_EXPORT int mak_pcm_finish(int64_t id);

/* Drops the buffer; the reader sees the end of file at once. */
MPV_EXPORT int mak_pcm_abort(int64_t id);

MPV_EXPORT int64_t mak_pcm_buffered(int64_t id);
MPV_EXPORT int64_t mak_pcm_consumed(int64_t id);
MPV_EXPORT int mak_pcm_state(int64_t id);

/* The app lets go of the id. Aborts a source that was never finished. */
MPV_EXPORT int mak_pcm_release(int64_t id);

/* Aborts and releases every source (player dispose, hot restart). */
MPV_EXPORT void mak_pcm_release_all(void);

/* ── reader side, internal to libmpv (stream_mak_pcm.c) ─────────────── */

struct mak_pcm_src;

/* Claims the one reader slot of id. Returns 0 and the source, or a
 * MAK_PCM_E* code: unknown, already read (now or before), aborted or
 * released ids are refused. */
int mak_pcm_reader_open(int64_t id, struct mak_pcm_src **out);

/* Returns 1..max bytes, or 0 at the end (finished and drained, or aborted).
 * Blocks while the buffer is empty and the input open. cancelled(ctx) is
 * polled without the lock after every wake; when it returns true the read
 * returns 0 at once. */
int mak_pcm_reader_read(struct mak_pcm_src *src, void *buf, int max,
                        bool (*cancelled)(void *ctx), void *ctx);

/* Wakes a blocked read so it polls its cancelled() again. Safe from any
 * thread, including an mp_cancel callback. */
void mak_pcm_reader_wake(struct mak_pcm_src *src);

/* Drops the reader reference; frees the source if the app released it. */
void mak_pcm_reader_close(struct mak_pcm_src *src);

#endif
