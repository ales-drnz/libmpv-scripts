/* MAK_WAVEFORM_PATCH ─── cache-fed analysis of an HTTP file.
 *
 * The bulk decode re-opens the source, so for a remote file it downloaded the
 * whole track a second time while mpv was caching the same bytes. For a
 * seekable network file this engine reads mpv's demuxer cache instead
 * (demux/mak_demux_feed.h): the cached audio packets first, then each new one
 * as mpv downloads it, decoded on a thread of its own and folded into the
 * waveform at the pace of mpv's download.
 *
 * The waveform is PROGRESSIVE while it fills (waveform-data reads it as
 * "decoding"), with the af-tap fold off for the generation, and turns READY when one pass ran from the start of the
 * file to its end without a gap; the loudness scan (when its patch is in)
 * rides the same decode. When the pass cannot be clean (playback started
 * past the start, a seek the cache cannot serve, a track switch, a cut
 * download), the generation is handed to the re-open of mak_scan.c, which
 * downloads the file again as before, so the result is never partial. A
 * stream that cannot seek and tells no length is fed too when the client
 * gives its length (see [hinted] below). */
#ifndef MP_AUDIO_MAK_FEED_H_
#define MP_AUDIO_MAK_FEED_H_

#include <stdbool.h>

struct demuxer;
struct sh_stream;
struct mpv_global;
struct mp_log;
struct mak_scan_track;

/* Starts the cache-fed analysis of [audio] on [demuxer] for waveform
 * generation [gen]. Call on the core thread. Returns false when the demuxer
 * keeps no seekable cache or the stream cannot be decoded; the caller then
 * falls back to re-opening the source. [url], [track] (which stream of [url]
 * [audio] is), [global] and [log] serve the re-open a pass that cannot be
 * clean hands over to.
 *
 * [hinted]: [duration_secs] is the length a client gave for an HTTP stream
 * that cannot seek and tells none (waveform-duration-hint, a transcode).
 * The pass then ends at the first of the end of the stream and that length,
 * so a wrong hint still ends READY: a short one covers the hint and leaves
 * the rest of the stream out, a long one keeps the hinted axis with the
 * bins after the end of the stream trimmed. A pass that cannot be clean is
 * not re-opened (a second request would start a second transcode): the
 * waveform grows from playback on the hinted axis, and the loudness scan
 * reports unavailable. */
bool mak_feed_start(int gen, struct demuxer *demuxer, struct sh_stream *audio,
                    double duration_secs, bool hinted, const char *url,
                    const struct mak_scan_track *track,
                    struct mpv_global *global, struct mp_log *log);

#endif
