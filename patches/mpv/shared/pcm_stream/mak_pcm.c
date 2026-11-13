/* MAK_PCM_STREAM_PATCH_V2 ─── live PCM input: the source registry and FIFO.
 * See mak_pcm.h, and patches/mpv/shared/patch_pcm_stream.py in
 * libmpv-scripts for the rationale.
 *
 * Locking: ONE process-wide mutex guards the registry and every FIFO. The
 * traffic is a handful of sources written every few tens of ms and read by
 * one demuxer thread each, so a single lock costs nothing measurable and
 * makes the lifetime trivial: a source is only freed under the lock, after
 * it left the registry, when neither the app nor a reader holds it. Each
 * source has its own condition variable on that mutex for its reader.
 *
 * The lock is never held across a call into mpv (mp_cancel included), so an
 * mp_cancel callback may take it: the only order is mp_cancel -> g_lock. */
#include <stdlib.h>
#include <string.h>

#include "osdep/threads.h"

#include "stream/mak_pcm.h"

/* First allocation of a source's ring; it doubles up to the capacity. */
#define MAK_PCM_INITIAL_ALLOC  (64 * 1024)

/* Upper bound on one wait of a blocked reader. The wakes are explicit
 * (write, finish, abort, release, cancel); this only bounds a missed one. */
#define MAK_PCM_WAIT_NS  (250 * 1000 * 1000LL)

struct mak_pcm_src {
    int64_t   id;
    mp_cond   cond;          /* the reader waits on it, under g_lock */

    uint8_t  *buf;           /* ring of alloc bytes, NULL until the first write */
    size_t    alloc;
    size_t    head;          /* read index */
    size_t    len;           /* buffered bytes */
    size_t    cap;           /* soft cap on len */
    int64_t   consumed;      /* bytes the reader took */
    uint64_t  wake_seq;      /* bumped by every wake, read by a waiting reader */

    bool      finished;
    bool      aborted;
    bool      drained;       /* the reader saw the end of a finished source */
    bool      app_held;      /* the app reference (until mak_pcm_release) */
    bool      reader_open;   /* the reader reference */
    bool      reader_seen;   /* a reader opened it once (one reader per id) */
};

/* The lock lives outside any struct so its static initializer keeps the
 * registry itself in .bss (see mak_pcm_tap.c for the Darwin detail). */
static mp_mutex g_lock = MP_STATIC_MUTEX_INITIALIZER;
static struct mak_pcm_src **g_srcs;
static size_t g_num, g_alloc;
static int64_t g_next_id = 1;

/* ── helpers, all under g_lock ──────────────────────────────────────── */

static struct mak_pcm_src *find(int64_t id)
{
    if (id <= 0)
        return NULL;
    for (size_t i = 0; i < g_num; i++) {
        if (g_srcs[i]->id == id)
            return g_srcs[i];
    }
    return NULL;
}

static void wake(struct mak_pcm_src *s)
{
    s->wake_seq++;
    mp_cond_broadcast(&s->cond);
}

static void drop_buffer(struct mak_pcm_src *s)
{
    free(s->buf);
    s->buf = NULL;
    s->alloc = s->head = s->len = 0;
}

/* Frees s when nobody holds it any more. */
static void maybe_free(struct mak_pcm_src *s)
{
    if (s->app_held || s->reader_open)
        return;
    for (size_t i = 0; i < g_num; i++) {
        if (g_srcs[i] == s) {
            g_srcs[i] = g_srcs[--g_num];
            break;
        }
    }
    if (g_num == 0) {
        free(g_srcs);
        g_srcs = NULL;
        g_alloc = 0;
    }
    drop_buffer(s);
    mp_cond_destroy(&s->cond);
    free(s);
}

static void do_abort(struct mak_pcm_src *s)
{
    /* Nothing to cut once the reader saw the end or went away. */
    if (s->drained || (s->reader_seen && !s->reader_open))
        return;
    s->aborted = true;
    drop_buffer(s);
    wake(s);
}

/* Grows the ring to hold at least need bytes, keeping the data in order.
 * Returns false on OOM (the ring is unchanged). */
static bool grow(struct mak_pcm_src *s, size_t need)
{
    if (need <= s->alloc)
        return true;
    size_t n = s->alloc ? s->alloc : MAK_PCM_INITIAL_ALLOC;
    while (n < need)
        n *= 2;
    if (n > s->cap)
        n = s->cap;
    uint8_t *nb = malloc(n);
    if (!nb)
        return false;
    size_t first = s->len;
    if (s->head + first > s->alloc)
        first = s->alloc - s->head;
    if (first)
        memcpy(nb, s->buf + s->head, first);
    if (s->len > first)
        memcpy(nb + first, s->buf, s->len - first);
    free(s->buf);
    s->buf = nb;
    s->alloc = n;
    s->head = 0;
    return true;
}

/* ── exported API ───────────────────────────────────────────────────── */

int64_t mak_pcm_create(int64_t capacity_bytes)
{
    if (capacity_bytes > MAK_PCM_MAX_CAPACITY)
        return MAK_PCM_EINVAL;
    if (capacity_bytes <= 0)
        capacity_bytes = MAK_PCM_DEFAULT_CAPACITY;

    struct mak_pcm_src *s = calloc(1, sizeof(*s));
    if (!s)
        return MAK_PCM_ENOMEM;
    s->cap = (size_t)capacity_bytes;
    s->app_held = true;
    mp_cond_init(&s->cond);

    mp_mutex_lock(&g_lock);
    if (g_num == g_alloc) {
        size_t na = g_alloc ? g_alloc * 2 : 8;
        struct mak_pcm_src **nl = realloc(g_srcs, na * sizeof(*nl));
        if (!nl) {
            mp_mutex_unlock(&g_lock);
            mp_cond_destroy(&s->cond);
            free(s);
            return MAK_PCM_ENOMEM;
        }
        g_srcs = nl;
        g_alloc = na;
    }
    s->id = g_next_id++;
    g_srcs[g_num++] = s;
    int64_t id = s->id;
    mp_mutex_unlock(&g_lock);
    return id;
}

int64_t mak_pcm_write(int64_t id, const uint8_t *data, int64_t len)
{
    if (len < 0 || (len > 0 && !data))
        return MAK_PCM_EINVAL;

    mp_mutex_lock(&g_lock);
    struct mak_pcm_src *s = find(id);
    int64_t r;
    if (!s) {
        r = MAK_PCM_EUNKNOWN;
    } else if (s->finished || s->aborted || !s->app_held ||
               (s->reader_seen && !s->reader_open)) {
        /* A source whose reader went away never plays again: refuse
         * instead of buffering bytes nobody reads. */
        r = MAK_PCM_ECLOSED;
    } else {
        size_t n = (size_t)len;
        if (n > s->cap - s->len)
            n = s->cap - s->len;
        if (n && !grow(s, s->len + n)) {
            /* Accept what fits in the current ring, if anything. */
            n = s->alloc - s->len;
        }
        if (n) {
            size_t tail = (s->head + s->len) % s->alloc;
            size_t first = n;
            if (tail + first > s->alloc)
                first = s->alloc - tail;
            memcpy(s->buf + tail, data, first);
            if (n > first)
                memcpy(s->buf, data + first, n - first);
            s->len += n;
            wake(s);
            r = (int64_t)n;
        } else {
            r = (s->len < s->cap && len > 0) ? MAK_PCM_ENOMEM : 0;
        }
    }
    mp_mutex_unlock(&g_lock);
    return r;
}

int mak_pcm_finish(int64_t id)
{
    mp_mutex_lock(&g_lock);
    struct mak_pcm_src *s = find(id);
    int r = 0;
    if (!s) {
        r = MAK_PCM_EUNKNOWN;
    } else if (s->aborted || !s->app_held) {
        r = MAK_PCM_ECLOSED;
    } else if (!s->finished) {
        s->finished = true;
        wake(s);
    }
    mp_mutex_unlock(&g_lock);
    return r;
}

int mak_pcm_abort(int64_t id)
{
    mp_mutex_lock(&g_lock);
    struct mak_pcm_src *s = find(id);
    int r = 0;
    if (!s) {
        r = MAK_PCM_EUNKNOWN;
    } else {
        do_abort(s);
    }
    mp_mutex_unlock(&g_lock);
    return r;
}

int64_t mak_pcm_buffered(int64_t id)
{
    mp_mutex_lock(&g_lock);
    struct mak_pcm_src *s = find(id);
    int64_t r = s ? (int64_t)s->len : MAK_PCM_EUNKNOWN;
    mp_mutex_unlock(&g_lock);
    return r;
}

int64_t mak_pcm_consumed(int64_t id)
{
    mp_mutex_lock(&g_lock);
    struct mak_pcm_src *s = find(id);
    int64_t r = s ? s->consumed : MAK_PCM_EUNKNOWN;
    mp_mutex_unlock(&g_lock);
    return r;
}

int mak_pcm_state(int64_t id)
{
    mp_mutex_lock(&g_lock);
    struct mak_pcm_src *s = find(id);
    int r;
    if (!s)                                 r = MAK_PCM_EUNKNOWN;
    else if (s->drained)                    r = MAK_PCM_STATE_DRAINED;
    else if (s->aborted)                    r = MAK_PCM_STATE_ABORTED;
    else if (s->reader_seen && !s->reader_open) r = MAK_PCM_STATE_CLOSED;
    else if (s->finished)                   r = MAK_PCM_STATE_FINISHED;
    else if (s->reader_open)                r = MAK_PCM_STATE_READING;
    else                                    r = MAK_PCM_STATE_OPEN;
    mp_mutex_unlock(&g_lock);
    return r;
}

int mak_pcm_release(int64_t id)
{
    mp_mutex_lock(&g_lock);
    struct mak_pcm_src *s = find(id);
    int r = 0;
    if (!s) {
        r = MAK_PCM_EUNKNOWN;
    } else if (!s->app_held) {
        r = MAK_PCM_ECLOSED;
    } else {
        if (!s->finished)
            do_abort(s);
        s->app_held = false;
        wake(s);
        maybe_free(s);
    }
    mp_mutex_unlock(&g_lock);
    return r;
}

void mak_pcm_release_all(void)
{
    mp_mutex_lock(&g_lock);
    /* maybe_free reorders the array: walk it from the end. */
    for (size_t i = g_num; i-- > 0;) {
        if (i >= g_num)
            continue;
        struct mak_pcm_src *s = g_srcs[i];
        do_abort(s);
        if (s->app_held) {
            s->app_held = false;
            maybe_free(s);
        }
    }
    mp_mutex_unlock(&g_lock);
}

/* ── reader side ────────────────────────────────────────────────────── */

int mak_pcm_reader_open(int64_t id, struct mak_pcm_src **out)
{
    *out = NULL;
    mp_mutex_lock(&g_lock);
    struct mak_pcm_src *s = find(id);
    int r = 0;
    if (!s) {
        r = MAK_PCM_EUNKNOWN;
    } else if (s->reader_seen || s->aborted || !s->app_held) {
        r = MAK_PCM_ECLOSED;
    } else {
        s->reader_seen = true;
        s->reader_open = true;
        *out = s;
    }
    mp_mutex_unlock(&g_lock);
    return r;
}

int mak_pcm_reader_read(struct mak_pcm_src *s, void *buf, int max,
                        bool (*cancelled)(void *ctx), void *ctx)
{
    if (max <= 0)
        return 0;
    mp_mutex_lock(&g_lock);
    for (;;) {
        if (s->len) {
            size_t n = (size_t)max < s->len ? (size_t)max : s->len;
            size_t first = n;
            if (s->head + first > s->alloc)
                first = s->alloc - s->head;
            memcpy(buf, s->buf + s->head, first);
            if (n > first)
                memcpy((uint8_t *)buf + first, s->buf, n - first);
            s->head = (s->head + n) % s->alloc;
            s->len -= n;
            s->consumed += (int64_t)n;
            mp_mutex_unlock(&g_lock);
            return (int)n;
        }
        if (s->aborted)
            break;
        if (s->finished) {
            s->drained = true;
            /* A drained ring is never written again: let it go now. */
            drop_buffer(s);
            break;
        }
        /* Poll the cancel without the lock, then wait unless something
         * happened meanwhile (wake_seq moved): no wake is ever lost. */
        uint64_t seq = s->wake_seq;
        mp_mutex_unlock(&g_lock);
        if (cancelled && cancelled(ctx))
            return 0;
        mp_mutex_lock(&g_lock);
        if (s->wake_seq == seq && !s->len && !s->aborted && !s->finished)
            mp_cond_timedwait(&s->cond, &g_lock, MAK_PCM_WAIT_NS);
    }
    mp_mutex_unlock(&g_lock);
    return 0;
}

void mak_pcm_reader_wake(struct mak_pcm_src *s)
{
    mp_mutex_lock(&g_lock);
    wake(s);
    mp_mutex_unlock(&g_lock);
}

void mak_pcm_reader_close(struct mak_pcm_src *s)
{
    mp_mutex_lock(&g_lock);
    s->reader_open = false;
    if (!s->drained && !s->aborted)
        drop_buffer(s);   /* closed early: nobody reads it any more */
    wake(s);
    maybe_free(s);
    mp_mutex_unlock(&g_lock);
}
