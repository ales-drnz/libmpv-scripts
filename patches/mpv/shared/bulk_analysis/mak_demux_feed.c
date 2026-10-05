/* MAK_WAVEFORM_PATCH ─── demuxer packet feed for the bulk analysis.
 * See mak_demux_feed.h. The queue is a singly linked list of items under the
 * feed's own mutex; the demuxer pushes while holding its lock and only ever
 * takes this mutex inside it, the consumer never takes the demuxer's lock,
 * so the two locks have one order. */
#include <stdatomic.h>
#include <stdlib.h>

#include "common/common.h"
#include "osdep/threads.h"
#include "osdep/timer.h"

#include "demux/mak_demux_feed.h"
#include "demux/packet.h"

/* Bytes the queue may hold before new packets are dropped (each drop queues a
 * GAP). The consumer decodes far faster than a network delivers, so this only
 * matters if it stalls; the demuxer's own cache stays the real bound. */
#define MAK_FEED_MAX_BYTES (64 * 1024 * 1024)

struct feed_item {
    enum mak_feed_item kind;
    struct demux_packet *dp;
    struct feed_item *next;
};

struct mak_demux_feed {
    mp_mutex lock;
    mp_cond  wakeup;
    atomic_int refs;
    int stream_index;
    struct feed_item *head, *tail;
    size_t bytes;
    bool consumer_closed;
    bool owner_gone;
    /* Demuxer side only (under the demuxer's lock). */
    const void *last_queue;
    bool any_packet;
    bool gap_pending;
};

static void feed_unref(struct mak_demux_feed *f)
{
    if (atomic_fetch_sub(&f->refs, 1) != 1)
        return;
    struct feed_item *it = f->head;
    while (it) {
        struct feed_item *next = it->next;
        if (it->dp)
            free_demux_packet(it->dp);
        free(it);
        it = next;
    }
    mp_cond_destroy(&f->wakeup);
    mp_mutex_destroy(&f->lock);
    free(f);
}

/* Appends under f->lock. Takes ownership of [dp] (freed on failure). */
static bool append_locked(struct mak_demux_feed *f, enum mak_feed_item kind,
                          struct demux_packet *dp)
{
    struct feed_item *it = calloc(1, sizeof(*it));
    if (!it) {
        if (dp)
            free_demux_packet(dp);
        return false;
    }
    it->kind = kind;
    it->dp = dp;
    if (f->tail)
        f->tail->next = it;
    else
        f->head = it;
    f->tail = it;
    if (dp)
        f->bytes += dp->len;
    mp_cond_signal(&f->wakeup);
    return true;
}

struct mak_demux_feed *mak_demux_feed_new(int stream_index)
{
    struct mak_demux_feed *f = calloc(1, sizeof(*f));
    if (!f)
        return NULL;
    mp_mutex_init(&f->lock);
    mp_cond_init(&f->wakeup);
    atomic_init(&f->refs, 2);   /* demuxer + consumer */
    f->stream_index = stream_index;
    return f;
}

int mak_demux_feed_stream(const struct mak_demux_feed *f)
{
    return f->stream_index;
}

bool mak_demux_feed_push_owned(struct mak_demux_feed *f,
                               struct demux_packet *dp,
                               const void *queue_id, bool bof)
{
    mp_mutex_lock(&f->lock);
    if (f->consumer_closed) {
        mp_mutex_unlock(&f->lock);
        if (dp)
            free_demux_packet(dp);
        return false;
    }
    if (!dp || f->bytes + dp->len > MAK_FEED_MAX_BYTES) {
        /* Out of memory or over budget: the packet is lost, so whatever
         * comes next no longer continues what came before. */
        if (dp)
            free_demux_packet(dp);
        f->gap_pending = true;
        mp_mutex_unlock(&f->lock);
        return true;
    }
    if (queue_id != f->last_queue || f->gap_pending) {
        if (f->any_packet)
            append_locked(f, MAK_FEED_GAP, NULL);
        if (bof)
            append_locked(f, MAK_FEED_BOF, NULL);
        f->last_queue = queue_id;
        f->gap_pending = false;
    }
    f->any_packet = true;
    append_locked(f, MAK_FEED_PACKET, dp);
    mp_mutex_unlock(&f->lock);
    return true;
}

bool mak_demux_feed_push(struct mak_demux_feed *f, struct demux_packet *dp,
                         const void *queue_id, bool bof)
{
    /* A new reference to the packet's data: no copy for an in-memory
     * packet, and the reference outlives the cache pruning it. */
    return mak_demux_feed_push_owned(f, demux_copy_packet(NULL, dp),
                                     queue_id, bof);
}

void mak_demux_feed_mark(struct mak_demux_feed *f, enum mak_feed_item item)
{
    mp_mutex_lock(&f->lock);
    if (!f->consumer_closed)
        append_locked(f, item, NULL);
    mp_mutex_unlock(&f->lock);
}

void mak_demux_feed_owner_release(struct mak_demux_feed *f)
{
    mp_mutex_lock(&f->lock);
    f->owner_gone = true;
    mp_cond_signal(&f->wakeup);
    mp_mutex_unlock(&f->lock);
    feed_unref(f);
}

enum mak_feed_item mak_demux_feed_pop(struct mak_demux_feed *f,
                                      struct demux_packet **out,
                                      int64_t timeout_ns)
{
    *out = NULL;
    int64_t deadline = mp_time_ns() + timeout_ns;
    mp_mutex_lock(&f->lock);
    while (!f->head && !f->owner_gone) {
        int64_t left = deadline - mp_time_ns();
        if (left <= 0) {
            mp_mutex_unlock(&f->lock);
            return MAK_FEED_TIMEOUT;
        }
        mp_cond_timedwait(&f->wakeup, &f->lock, left);
    }
    struct feed_item *it = f->head;
    if (!it) {
        mp_mutex_unlock(&f->lock);
        return MAK_FEED_CLOSED;
    }
    f->head = it->next;
    if (!f->head)
        f->tail = NULL;
    if (it->dp)
        f->bytes -= it->dp->len;
    mp_mutex_unlock(&f->lock);
    enum mak_feed_item kind = it->kind;
    *out = it->dp;
    free(it);
    return kind;
}

void mak_demux_feed_close(struct mak_demux_feed *f)
{
    mp_mutex_lock(&f->lock);
    f->consumer_closed = true;
    struct feed_item *it = f->head;
    f->head = f->tail = NULL;
    f->bytes = 0;
    mp_mutex_unlock(&f->lock);
    while (it) {
        struct feed_item *next = it->next;
        if (it->dp)
            free_demux_packet(it->dp);
        free(it);
        it = next;
    }
    feed_unref(f);
}
