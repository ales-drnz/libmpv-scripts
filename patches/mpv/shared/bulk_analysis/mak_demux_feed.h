/* MAK_WAVEFORM_PATCH ─── demuxer packet feed for the bulk analysis.
 *
 * A side consumer of mpv's demuxer cache, modelled on `dump-cache`: when the
 * analysis of a seekable network file attaches, the cached packets of the
 * audio stream are queued first, then every new one the demuxer adds. The
 * analysis decodes them on its own thread instead of downloading the file a
 * second time. It never takes the user's dump slot and never changes what
 * playback reads.
 *
 * The feed is shared by two owners, each holding one reference: the demuxer
 * (pushes under its own lock, drops its reference when it is freed) and the
 * consumer (pops, drops its reference when done). Whoever drops last frees
 * it. Each queued packet is a new reference to the cached data, so in memory
 * nothing is copied; a packet the disk cache holds is read back at attach.
 *
 * Markers between packets tell the consumer what it cannot see from the
 * timestamps alone: BOF (the next packet starts the file), GAP (packets
 * before and after are not contiguous: another cached range, a seek past the
 * cache, a dropped packet) and EOF (the demuxer reached the end of the
 * stream). */
#ifndef MP_DEMUX_MAK_DEMUX_FEED_H_
#define MP_DEMUX_MAK_DEMUX_FEED_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct demuxer;
struct demux_packet;
struct sh_stream;

struct mak_demux_feed;

enum mak_feed_item {
    MAK_FEED_PACKET,    /* *out holds a packet the consumer now owns */
    MAK_FEED_BOF,       /* the following packets start at the file's start */
    MAK_FEED_GAP,       /* the following packets do not continue the last */
    MAK_FEED_EOF,       /* the stream ended after the last packet */
    MAK_FEED_CLOSED,    /* the demuxer is gone and the queue is drained */
    MAK_FEED_TIMEOUT,   /* nothing arrived within the timeout */
};

/* Attach a feed of [sh]'s packets to [demuxer] (implemented in demux.c, so
 * it can walk the cache). Call on the core thread. Returns NULL when the
 * demuxer keeps no seekable cache, since there would be nothing to replay
 * and the live packets alone would only arrive at the readahead pace. A feed
 * already attached to the demuxer is closed first. Packet timestamps are the
 * demuxer's own, before playback's start time offset, like the ones the bulk
 * decode reads from the file. */
struct mak_demux_feed *mak_demux_feed_attach(struct demuxer *demuxer,
                                             struct sh_stream *sh);

/* Consumer side. Waits up to [timeout_ns] for the next item. */
enum mak_feed_item mak_demux_feed_pop(struct mak_demux_feed *f,
                                      struct demux_packet **out,
                                      int64_t timeout_ns);

/* Consumer side: stop receiving and drop the consumer's reference. Queued
 * packets are freed; the demuxer side lets go of the feed at its next push. */
void mak_demux_feed_close(struct mak_demux_feed *f);

/* ── demux.c side, all called with the demuxer's lock held ───────────── */

struct mak_demux_feed *mak_demux_feed_new(int stream_index);

/* The demuxer's stream index this feed carries. */
int mak_demux_feed_stream(const struct mak_demux_feed *f);

/* Queue a new reference to [dp]. [queue_id] identifies the cache queue the
 * packet went to: a change of queue queues a GAP first. [bof] is set when the
 * packet is the first of a queue that starts the file. Returns false when the
 * consumer has closed the feed: the caller then detaches it with
 * mak_demux_feed_owner_release. */
bool mak_demux_feed_push(struct mak_demux_feed *f, struct demux_packet *dp,
                         const void *queue_id, bool bof);

/* Queue a packet the caller already copied (the cache replay), taking
 * ownership of it. */
bool mak_demux_feed_push_owned(struct mak_demux_feed *f,
                               struct demux_packet *dp,
                               const void *queue_id, bool bof);

/* Queue a marker. */
void mak_demux_feed_mark(struct mak_demux_feed *f, enum mak_feed_item item);

/* The demuxer is going away, or detaches the feed: drop its reference. */
void mak_demux_feed_owner_release(struct mak_demux_feed *f);

#endif
