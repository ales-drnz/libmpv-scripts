/* MAK_WAVEFORM_PATCH ─── demuxer packet feed for the bulk analysis.
 *
 * A side consumer of mpv's demuxer cache, modelled on `dump-cache`: when the
 * analysis of a seekable network file attaches, it copies the cached
 * packets of the audio stream first, a batch at a time on its own thread,
 * then takes every new one the demuxer queues for it. The
 * analysis decodes them on its own thread instead of downloading the file a
 * second time. It never takes the user's dump slot and never changes what
 * playback reads.
 *
 * The feed is shared by two owners, each holding one reference: the demuxer
 * (pushes under its own lock, drops its reference when it is freed) and the
 * consumer (pops, drops its reference when done). Whoever drops last frees
 * it. Each packet is a new reference to the cached data, so in memory
 * nothing is copied (a cache on disk is not fed).
 *
 * Markers between packets tell the consumer what it cannot see from the
 * timestamps alone: BOF (the next packet starts the file), GAP (packets
 * before and after are not contiguous: another cached range, any low-level
 * seek of the demuxer, a dropped packet, a deselected stream, a cache that
 * stopped reading ahead) and EOF (the demuxer reached the end of the
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
    MAK_FEED_REPLAYED,  /* the cache replay is over: pop the rest */
};

/* The demuxer's half of the replay below: a lock and a pointer to the
 * demuxer that its teardown clears, so a consumer replaying from another
 * thread never touches a freed demuxer. One per demuxer, shared by its
 * feeds, each holding a reference. */
struct mak_feed_guard;

/* Where the consumer is in the cache it replays (see mak_demux_feed_replay).
 * Read and written by the consumer under the guard and the demuxer's lock,
 * and set up by the attach before the consumer starts. */
struct mak_feed_replay {
    struct mak_feed_guard *guard;
    void *queue;                  /* the struct demux_queue replayed */
    struct demux_packet *next;    /* the next packet to copy */
    uint64_t next_cum;            /* its cum_pos in the queue */
    uint64_t end_cum;             /* the queue's end at attach */
    bool active;                  /* packets left to replay */
    bool bof;                     /* the first one starts the file */
    bool eof;                     /* the replay reached the end of file */
    int64_t stream_size;          /* the file's size at attach, or -1 */
    /* The end of file came from a read error and not the real end
     * (demux-side, patch_read_error.py; always false without it). Set
     * under the demuxer's lock before the end of file reaches the consumer,
     * at attach or with the end itself. */
    bool read_error;
};

/* Attach a feed of [sh]'s packets to [demuxer] (implemented in demux.c, so
 * it can walk the cache). Call on the core thread. Returns NULL, and the
 * caller re-opens the file instead, when the feed could not cover it whole:
 * no seekable cache, the cache on disk, a file known to be larger than the
 * forward cache, a timeline (EDL, ordered chapters), or a cache range being
 * filled that does not start the file. However long the cache already is,
 * the consumer copies it a batch at a time (mak_demux_feed_replay). The
 * demuxer cuts the feed later if its read-ahead stops before the end, or if
 * the cache of a file of unknown size fills up. A feed
 * already attached to the demuxer is closed first. Packet timestamps are the
 * demuxer's own, before playback's start time offset, like the ones the bulk
 * decode reads from the file. */
struct mak_demux_feed *mak_demux_feed_attach(struct demuxer *demuxer,
                                             struct sh_stream *sh);

/* Consumer side, before popping: copy up to [max] of the packets the cache
 * held at attach into [out] (*n of them, the consumer owns them). Each
 * call holds the demuxer's lock for one batch only, so a long cache never
 * stalls the core thread or the demuxer, and only one batch of copies is
 * alive at once. Returns MAK_FEED_PACKET with packets, MAK_FEED_BOF once
 * before the first packet when it starts the file, MAK_FEED_EOF when the
 * cache ended with the file, MAK_FEED_GAP when the replay can no longer
 * continue (a seek, packets pruned before they were copied, the feed cut or
 * detached), MAK_FEED_CLOSED when the demuxer is gone, and
 * MAK_FEED_REPLAYED when it is done: the consumer then pops the packets the
 * demuxer read after the attach (implemented in demux.c). */
enum mak_feed_item mak_demux_feed_replay(struct mak_demux_feed *f,
                                         struct demux_packet **out, int max,
                                         int *n);

/* Consumer side. Waits up to [timeout_ns] for the next item. Once the
 * demuxer is gone the queue is drained only if it holds an EOF (a complete
 * pass); otherwise it is dropped and MAK_FEED_CLOSED returned at once. */
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

/* Queue a new reference to a packet the demuxer just read. [queue_id]
 * identifies the cache queue the packet went to: a change of queue queues a
 * GAP first. [bof] is set only when the packet is the first one of a queue
 * that starts the file. Over MAK_FEED_MAX_BYTES, counted with each packet's
 * own memory as the demuxer counts it, the packet is dropped and a GAP
 * queued. Returns false when the consumer has closed the feed: the caller
 * then detaches it with mak_demux_feed_owner_release. */
bool mak_demux_feed_push(struct mak_demux_feed *f, struct demux_packet *dp,
                         const void *queue_id, bool bof);

/* The replay state of [f] (see struct mak_feed_replay). */
struct mak_feed_replay *mak_demux_feed_replay_state(struct mak_demux_feed *f);

/* Set up at attach: when the replay of [queue_id] has packets ([replayed]),
 * the packets queued from now on continue it, so the first one queues no
 * GAP and no BOF. */
void mak_demux_feed_continue(struct mak_demux_feed *f, const void *queue_id,
                             bool replayed);

/* Whether the feed was cut or closed by the consumer. */
bool mak_demux_feed_ended(struct mak_demux_feed *f);

/* The guard of a demuxer, created at its first attach with [owner] its
 * demux_internal. kill() clears the owner under the guard's lock, at the
 * demuxer's teardown, and drops the demuxer's reference; lock() returns the
 * owner (NULL once killed) with the guard locked until unlock(). */
struct mak_feed_guard *mak_feed_guard_new(void *owner);
void mak_feed_guard_ref(struct mak_feed_guard *g);
void mak_feed_guard_unref(struct mak_feed_guard *g);
void mak_feed_guard_kill(struct mak_feed_guard *g);
void *mak_feed_guard_lock(struct mak_feed_guard *g);
void mak_feed_guard_unlock(struct mak_feed_guard *g);

/* Queue a marker. */
void mak_demux_feed_mark(struct mak_demux_feed *f, enum mak_feed_item item);

/* The demuxer is about to read from another position (any low-level seek: a
 * seek past the cache, a cache range resumed or joined, a track refresh).
 * Once a packet went out, nothing read after it can be trusted to continue
 * it, so the feed is cut (see mak_demux_feed_cut); before the first packet
 * the next one still decides, through [bof], whether the pass starts the
 * file. */
void mak_demux_feed_seek(struct mak_demux_feed *f);

/* The pass can no longer cover the file at the pace of the download (the
 * fed stream was deselected, or the cache stopped reading ahead): queue a GAP
 * now, so the consumer hands over to the re-open without waiting for the next
 * packet, and take no more packets. The next push returns false. */
void mak_demux_feed_cut(struct mak_demux_feed *f);

/* The demuxer is going away, or detaches the feed: drop its reference. */
void mak_demux_feed_owner_release(struct mak_demux_feed *f);

#endif
