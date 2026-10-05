/* MAK_WAVEFORM_PATCH ─── cache-fed analysis of a seekable network file.
 *
 * The bulk decode re-opens the source, so for a remote file it downloaded the
 * whole track a second time while mpv was caching the same bytes. For a
 * seekable network file this engine reads mpv's demuxer cache instead
 * (demux/mak_demux_feed.h): the cached audio packets first, then each new one
 * as mpv downloads it, decoded on a thread of its own and folded into the
 * waveform at the pace of mpv's download.
 *
 * The waveform is PROGRESSIVE while it fills, with the af-tap fold off for
 * the generation, and turns READY when the decode ran from the start of the
 * file to its end without a gap. A seek past the cache leaves a gap that fills
 * if mpv later downloads that part. The loudness scan (when its patch is in)
 * rides the same decode and is published only for a gapless pass, otherwise
 * it reports "unavailable", like any playback-grown source. */
#ifndef MP_AUDIO_MAK_FEED_H_
#define MP_AUDIO_MAK_FEED_H_

#include <stdbool.h>

struct demuxer;
struct sh_stream;

/* Starts the cache-fed analysis of [audio] on [demuxer] for waveform
 * generation [gen]. Call on the core thread. Returns false when the demuxer
 * keeps no seekable cache or the stream cannot be decoded; the caller then
 * falls back to re-opening the source. */
bool mak_feed_start(int gen, struct demuxer *demuxer, struct sh_stream *audio,
                    double duration_secs);

#endif
