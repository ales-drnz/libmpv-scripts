/* MAK_WAVEFORM_PATCH_V2 ─── the parts of the bulk-analysis scan engine.
 *
 * mak_scan.c is the coordinator and the public entry points, mak_scan_worker.c
 * the decode of one worker's slice, mak_scan_source.c the opening of a source
 * (a URL, or a descriptor read through pread). This header holds what they
 * share: the worker's slice, the high-water slot it publishes through, and the
 * functions one part calls in another. Not an API: only these three include it. */
#ifndef MPV_MAK_SCAN_INTERNAL_H
#define MPV_MAK_SCAN_INTERNAL_H

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#define MAK_SCAN_FD_IO 1
#else
#define MAK_SCAN_FD_IO 0
#endif

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#include "common/msg.h"
#include "demux/demux.h"
#include "demux/stheader.h"
#include "osdep/threads.h"
#include "osdep/timer.h"
#include "stream/stream.h"

#include "audio/mak_feed.h"
#if __has_include("audio/mak_loudness.h")
#include "audio/mak_loudness.h"
#endif
#include "audio/mak_scan.h"
#include "audio/mak_wave_fold.h"
#include "audio/mak_waveform.h"

/* Sample budget per worker cancellation check. 4096 samples is
 * ~85 ms at 48 kHz — short enough that a stale worker exits within
 * ~85 ms of the new file landing. */
#define MAK_WAVE_CANCEL_CHECK_INTERVAL 4096

/* ─── live incremental publish ────────────────────────────────────────
 * Cadence of the coordinator's publish loop. 100 ms ≈ 10 Hz: comfortably
 * above the wrapper's poll cadence so every poll sees fresh coverage, far
 * below a spin so the g_wave_lock churn is negligible against a multi-second
 * decode. The loop also breaks as soon as every worker is done, so a short
 * track never waits a full interval. */
#define MAK_WAVE_PUBLISH_INTERVAL_NS (100 * 1000 * 1000LL)

/* One per-worker high-water, on its own cache line so a worker's hot-path
 * release store never false-shares with another worker's line.
 *   hw   = count of LOCAL bins the worker has SEALED (advanced strictly PAST,
 *          so they can no longer widen) — monotone, the bin currently being
 *          widened is never included.
 *   done = set once the worker has exited its decode (covers every exit path),
 *          the race-free liveness signal the coordinator polls instead of the
 *          plain `status` field.
 * The coordinator RELEASE-pairs: it ACQUIRE-loads hw/done, so the worker's
 * plain writes to bins [0, hw) are visible (happens-before) before the
 * coordinator copies that sealed prefix out. _Alignas(64) on the first member
 * forces 64-byte struct alignment AND a 64-byte stride; the static assert
 * makes the one-cache-line layout load-bearing. */
struct mak_wave_hw {
    _Alignas(64) _Atomic int hw;    /* sealed LOCAL bins, monotone        */
    _Atomic int              done;  /* 1 once the worker exits its decode  */
    char _pad[64 - 2 * sizeof(_Atomic int)];
};
_Static_assert(sizeof(struct mak_wave_hw) == 64,
               "mak_wave_hw must occupy exactly one cache line");

/* ─── per-worker slice ────────────────────────────────────────────── */

struct worker_chunk {
    int      my_gen;
    /* The coordinator's fail flag: stops the worker like a new generation,
     * without superseding the current one. Outlives the worker (joined). */
    const atomic_bool *abort;
    /* Points at the coordinator's per-worker high-water slot (NULL ⇒ the
     * worker does not publish live, e.g. a future caller that omits it). */
    struct mak_wave_hw *hwslot;
    const char *url;             /* shared, owned by coordinator */
    /* The coordinator's duplicate of an fd://N source, read with pread
     * (see open_source), or -1 to open [url]. */
    int      fd;
    /* mpv's network options for the re-open (shared, read-only, owned by the
     * coordinator; NULL for a local path). */
    const AVDictionary *net_opts;
    int      audio_idx;
    enum AVCodecID codec_id;
    AVCodecParameters *codecpar; /* shared, used to init each ctx */
    int      sample_rate;
    int64_t  total_samples;
    int64_t  sample_start;       /* inclusive, in source sample-frame units */
    int64_t  sample_end;         /* exclusive */
    /* The first sample this worker must place, the earlier of its loudness
     * slice and its first bin, and one past the last, the first sample of the
     * next worker's first bin. A worker decodes [need_start, wave_end) at
     * least; what it decodes around that is pre-roll. */
    int64_t  need_start;
    int64_t  wave_end;
    int64_t  time_base_num;
    int64_t  time_base_den;
    /* The source's timestamp at playback time 0, in samples (see
     * mak_scan_track.start_secs): positions are timestamps less this. */
    int64_t  start_samples;
    /* Output slice. total_bins is the global envelope size; the
     * worker writes only [bin_start, bin_end) — disjoint by
     * construction. out_min / out_max / out_sq / out_n point into the
     * coordinator's global arrays (out_sq and out_n are each bin's sum of
     * squares and sample count, for the RMS). bins_filled has length
     * bin_end - bin_start. */
    int      total_bins;
    int      bin_start;          /* inclusive */
    int      bin_end;            /* exclusive */
    float   *out_min;
    float   *out_max;
    double  *out_sq;
    uint32_t *out_n;
    uint8_t *bins_filled;
    int      status;             /* 0 = ok */
};

/* ─── shared between the parts ───────────────────────────────────────
 * The descriptor and source helpers (mak_scan_source.c), the worker thread
 * (mak_scan_worker.c) and the coordinator's generation-abort callback, which
 * every probe of a generation polls (mak_scan.c). */
void mak_scan_close_fd(int fd);
void mak_scan_close_source(AVFormatContext **fmt);
int mak_scan_open_source(AVFormatContext **fmt, const char *url, int fd,
                       const AVDictionary *net_opts);
MP_THREAD_VOID mak_scan_worker_thread(void *p);
int mak_scan_interrupt_cb(void *opaque);

#endif
