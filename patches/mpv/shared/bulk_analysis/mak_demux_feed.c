/* MAK_WAVEFORM_PATCH_V2 ─── demuxer packet feed for the bulk analysis.
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
    size_t size;        /* what [dp] counts in the budget */
    struct feed_item *next;
};

struct mak_feed_guard {
    mp_mutex lock;
    atomic_int refs;
    void *owner;        /* NULL once the demuxer is gone */
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
    bool gone_checked;  /* pop looked for an EOF after owner_gone */
    bool cut;           /* a GAP ends the pass: no more packets */
    /* Demuxer side only (under the demuxer's lock). */
    const void *last_queue;
    bool any_packet;
    bool gap_pending;
    /* Consumer side, see mak_demux_feed_replay(). */
    struct mak_feed_replay replay;
};

struct mak_feed_guard *mak_feed_guard_new(void *owner)
{
    struct mak_feed_guard *g = calloc(1, sizeof(*g));
    if (!g)
        return NULL;
    mp_mutex_init(&g->lock);
    atomic_init(&g->refs, 1);   /* the demuxer's */
    g->owner = owner;
    return g;
}

void mak_feed_guard_ref(struct mak_feed_guard *g)
{
    atomic_fetch_add(&g->refs, 1);
}

void mak_feed_guard_unref(struct mak_feed_guard *g)
{
    if (!g || atomic_fetch_sub(&g->refs, 1) != 1)
        return;
    mp_mutex_destroy(&g->lock);
    free(g);
}

void mak_feed_guard_kill(struct mak_feed_guard *g)
{
    /* Waits for a replay batch in progress: after this no consumer reaches
     * the demuxer through the guard. */
    mp_mutex_lock(&g->lock);
    g->owner = NULL;
    mp_mutex_unlock(&g->lock);
    mak_feed_guard_unref(g);
}

void *mak_feed_guard_lock(struct mak_feed_guard *g)
{
    mp_mutex_lock(&g->lock);
    return g->owner;
}

void mak_feed_guard_unlock(struct mak_feed_guard *g)
{
    mp_mutex_unlock(&g->lock);
}

static void free_items(struct feed_item *it)
{
    while (it) {
        struct feed_item *next = it->next;
        if (it->dp)
            free_demux_packet(it->dp);
        free(it);
        it = next;
    }
}

static void feed_unref(struct mak_demux_feed *f)
{
    if (atomic_fetch_sub(&f->refs, 1) != 1)
        return;
    free_items(f->head);
    mak_feed_guard_unref(f->replay.guard);
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
    it->size = dp ? demux_packet_estimate_total_size(dp) : 0;
    if (f->tail)
        f->tail->next = it;
    else
        f->head = it;
    f->tail = it;
    f->bytes += it->size;
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

struct mak_feed_replay *mak_demux_feed_replay_state(struct mak_demux_feed *f)
{
    return &f->replay;
}

void mak_demux_feed_continue(struct mak_demux_feed *f, const void *queue_id,
                             bool replayed)
{
    if (!replayed)
        return;   /* the first push decides, with its BOF */
    mp_mutex_lock(&f->lock);
    f->last_queue = queue_id;
    f->any_packet = true;
    mp_mutex_unlock(&f->lock);
}

bool mak_demux_feed_ended(struct mak_demux_feed *f)
{
    mp_mutex_lock(&f->lock);
    bool ended = f->cut || f->consumer_closed;
    mp_mutex_unlock(&f->lock);
    return ended;
}

static bool push_owned(struct mak_demux_feed *f, struct demux_packet *dp,
                       const void *queue_id, bool bof)
{
    mp_mutex_lock(&f->lock);
    if (f->consumer_closed || f->cut) {
        mp_mutex_unlock(&f->lock);
        if (dp)
            free_demux_packet(dp);
        return false;
    }
    if (!dp || f->bytes + demux_packet_estimate_total_size(dp) >
                   MAK_FEED_MAX_BYTES) {
        /* Out of memory or over budget: the packet is lost, so whatever
         * comes next no longer continues what came before. */
        if (dp)
            free_demux_packet(dp);
        f->gap_pending = true;
        mp_mutex_unlock(&f->lock);
        return true;
    }
    /* An item that cannot be queued (out of memory) leaves a hole the
     * consumer must not decode across: the gap stays pending, as for a
     * packet over the budget above. */
    bool lost = false;
    if (queue_id != f->last_queue || f->gap_pending) {
        if (f->any_packet)
            lost |= !append_locked(f, MAK_FEED_GAP, NULL);
        if (bof)
            lost |= !append_locked(f, MAK_FEED_BOF, NULL);
        f->last_queue = queue_id;
        f->gap_pending = false;
    }
    f->any_packet = true;
    lost |= !append_locked(f, MAK_FEED_PACKET, dp);
    if (lost)
        f->gap_pending = true;
    mp_mutex_unlock(&f->lock);
    return true;
}

bool mak_demux_feed_push(struct mak_demux_feed *f, struct demux_packet *dp,
                         const void *queue_id, bool bof)
{
    /* A new reference to the packet's data: no copy for an in-memory
     * packet, and the reference outlives the cache pruning it. */
    struct demux_packet *copy = demux_copy_packet(NULL, dp);
    /* add_packet_locked() gives an audio packet without pts its dts only
     * after this point; the cached copies the replay reads already have it. */
    if (copy && copy->pts == MP_NOPTS_VALUE)
        copy->pts = copy->dts;
    return push_owned(f, copy, queue_id, bof);
}

void mak_demux_feed_mark(struct mak_demux_feed *f, enum mak_feed_item item)
{
    mp_mutex_lock(&f->lock);
    if (!f->consumer_closed && !f->cut)
        append_locked(f, item, NULL);
    mp_mutex_unlock(&f->lock);
}

static void cut_locked(struct mak_demux_feed *f)
{
    if (f->consumer_closed || f->cut)
        return;
    append_locked(f, MAK_FEED_GAP, NULL);
    f->cut = true;
}

void mak_demux_feed_seek(struct mak_demux_feed *f)
{
    mp_mutex_lock(&f->lock);
    if (f->any_packet)
        cut_locked(f);
    else
        f->gap_pending = true;
    mp_mutex_unlock(&f->lock);
}

void mak_demux_feed_cut(struct mak_demux_feed *f)
{
    mp_mutex_lock(&f->lock);
    cut_locked(f);
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
    if (f->owner_gone && !f->gone_checked) {
        /* The demuxer went away (stop, next file). Without an EOF in the
         * queue the pass can never complete, so decoding the rest (up to
         * MAK_FEED_MAX_BYTES of a file no longer playing) is wasted work:
         * drop it and report CLOSED now. A queued EOF means the download
         * finished, so that pass is still drained to the end. */
        f->gone_checked = true;
        bool has_eof = false;
        for (struct feed_item *q = f->head; q; q = q->next) {
            if (q->kind == MAK_FEED_EOF) {
                has_eof = true;
                break;
            }
        }
        if (!has_eof) {
            struct feed_item *drop = f->head;
            f->head = f->tail = NULL;
            f->bytes = 0;
            mp_mutex_unlock(&f->lock);
            free_items(drop);
            return MAK_FEED_CLOSED;
        }
    }
    struct feed_item *it = f->head;
    if (!it) {
        mp_mutex_unlock(&f->lock);
        return MAK_FEED_CLOSED;
    }
    f->head = it->next;
    if (!f->head)
        f->tail = NULL;
    f->bytes -= it->size;
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
    free_items(it);
    feed_unref(f);
}
