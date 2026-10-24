/*
 * webio: http, https and makblob read through fetch in the browser.
 * MAK_WEBIO_PATCH_V1
 *
 * Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be
 * found in the LICENSE file of libmpv-scripts.
 *
 * The web build of libmpv-scripts has no sockets and no TLS: the browser
 * does the transport. These protocols take the names http, https and
 * makblob, so every open of FFmpeg comes here, mpv's stream_lavf and the
 * nested opens of the HLS and DASH demuxers alike.
 *
 * Threads. A request runs on one pthread of its own, the net thread, which
 * never blocks: it lives in its JS event loop and runs fetch there
 * (scripts/web/mak_webio.js). The thread that reads (mpv's demuxer or
 * loader, a pthread) waits on a condition variable with short timeouts and
 * checks the interrupt callback between them, so stop and quit never wait
 * for the network. The browser main thread takes no part.
 *
 * Data. Each stream has a ring in wasm memory. The net thread copies the
 * body chunks in (mak_webio_reserve, then mak_webio_commit) and stops
 * reading the body when the ring is full; the reader frees room and wakes
 * it. A seek starts a new request with Range and a new generation: every
 * call of the net thread carries the generation it serves, and one that is
 * stale changes nothing.
 *
 * Lifetime. The reader never frees a stream: close marks it and hands it to
 * the net thread, which aborts the fetch, forgets the stream on the JS side
 * and frees it. The tasks of one stream reach the net thread in the order
 * they were sent.
 *
 * makblob://<rest> reads blob:<rest>, the URL of a File or Blob of the page
 * (mpv only takes URLs with "://").
 */

#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <emscripten/emscripten.h>
#include <emscripten/eventloop.h>
#include <emscripten/proxying.h>

#include "config_components.h"

#include "libavutil/avstring.h"
#include "libavutil/bprint.h"
#include "libavutil/error.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/time.h"
#include "avformat.h"
#include "url.h"

/* Flags of mak_webio_js_start. */
#define WEBIO_F_ICY      1   /* ask for ICY metadata */
#define WEBIO_F_ICY_CORS 2   /* ... from another origin too */
#define WEBIO_F_BLOB     4   /* the URL is a blob: URL */

/* Flags of mak_webio_response. */
#define WEBIO_R_SEEKABLE 1

/* Kinds of mak_webio_end. */
#define WEBIO_END_EOF      0 /* the body ended */
#define WEBIO_END_FETCH    1 /* fetch refused: network, CORS, mixed content */
#define WEBIO_END_HTTP     2 /* an HTTP error status */
#define WEBIO_END_BROKEN   3 /* the body broke off */
#define WEBIO_END_PROTOCOL 4 /* an answer that cannot serve the request */
#define WEBIO_END_RANGE    5 /* 416: the offset is at or past the end */
#define WEBIO_END_NOSEEK   6 /* the server ignored Range on a seek */

enum { WEBIO_CONNECTING, WEBIO_OPEN, WEBIO_EOF, WEBIO_ERROR };

/* How long a read waits for data before it hands back EAGAIN, so that
 * retry_transfer_wrapper checks the interrupt callback (url.h asks 0.1 s). */
#define WEBIO_READ_WAIT_MS 100
/* The poll of the open and of a seek, between two interrupt checks. */
#define WEBIO_OPEN_WAIT_MS 50

typedef struct IcyPacket {
    int64_t at;               /* the stream offset it belongs to */
    char *text;               /* malloc'd by the JS side */
    struct IcyPacket *next;
} IcyPacket;

/* What the reader and the net thread share. The fields under "request"
 * are written before the first task is sent and never after. */
typedef struct WebioStream {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    uint8_t *ring;
    uint32_t cap;             /* a power of two */
    uint32_t rpos, wpos;      /* free running, modulo 2^32 */
    uint32_t gen;
    int state;
    int error;                /* AVERROR in WEBIO_ERROR */
    int status;               /* HTTP status of the last answer */
    int64_t size;             /* -1 when unknown */
    int seekable;
    int want_space;           /* the net thread waits for room */
    int closed;
    int started;              /* a task went to the net thread */
    int64_t req_off;          /* offset of the first byte of the request */
    int64_t data_at;          /* av_gettime_relative() of the last data */
    double ms_headers;        /* fetch to answer, measured by the net thread */
    /* malloc'd by the JS side, freed here */
    char *mime, *location, *icy_headers, *errmsg, *note;
    IcyPacket *icy_head, **icy_tail;
    /* request */
    char *url, *headers;
    int flags;
    int64_t req_end;          /* end_offset, -1 for none */
} WebioStream;

typedef struct WebioContext {
    const AVClass *class;
    WebioStream *s;
    int64_t pos;              /* the offset the next read returns */
    int64_t t_open;
    int first_logged, error_logged, note_logged;
    /* options */
    char *user_agent, *headers, *referer, *cookies;
    int icy, icy_cross_origin;
    char *icy_metadata_headers, *icy_metadata_packet;
    char *mime_type, *location;
    int64_t timeout;
    int seekable;
    int64_t off, end_off;
    int buffer_size;
} WebioContext;

/* The JS side (scripts/web/mak_webio.js), on the net thread. */
extern void mak_webio_js_init(void);
extern void mak_webio_js_start(WebioStream *s, uint32_t gen, const char *url,
                               const char *headers, double off, double end,
                               int flags);
extern void mak_webio_js_space(WebioStream *s);
extern void mak_webio_js_close(WebioStream *s);

/* What the JS side calls, on the net thread (exported to the module). */
int mak_webio_reserve(WebioStream *s, uint32_t gen, uint32_t *at);
void mak_webio_commit(WebioStream *s, uint32_t gen, uint32_t n);
void mak_webio_response(WebioStream *s, uint32_t gen, int status, double size,
                        int flags, char *mime, char *location,
                        char *icy_headers, char *note, double ms);
void mak_webio_icy(WebioStream *s, uint32_t gen, double at, char *text);
void mak_webio_end(WebioStream *s, uint32_t gen, int kind, int status,
                   char *msg);
int mak_webio_live_streams(void);

/* ── net thread ────────────────────────────────────────────────────────── */

static pthread_once_t net_once = PTHREAD_ONCE_INIT;
static pthread_t net_thread;
static pthread_mutex_t net_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t net_cond = PTHREAD_COND_INITIALIZER;
static int net_state;         /* 0 starting, 1 running, -1 failed */
static atomic_int live_streams;

static void *net_main(void *arg)
{
    /* The keepalive keeps the worker in its event loop after the return:
     * the fetches run there, and the tasks of the readers arrive there. */
    emscripten_runtime_keepalive_push();
    mak_webio_js_init();
    pthread_mutex_lock(&net_lock);
    net_state = 1;
    pthread_cond_broadcast(&net_cond);
    pthread_mutex_unlock(&net_lock);
    return NULL;
}

static void net_create(void)
{
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    /* JS callbacks and short C calls only. */
    pthread_attr_setstacksize(&attr, 256 * 1024);
    if (pthread_create(&net_thread, &attr, net_main, NULL)) {
        pthread_mutex_lock(&net_lock);
        net_state = -1;
        pthread_cond_broadcast(&net_cond);
        pthread_mutex_unlock(&net_lock);
    }
    pthread_attr_destroy(&attr);
}

static void deadline_in(struct timespec *ts, int ms)
{
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_nsec += (long)ms * 1000000L;
    ts->tv_sec += ts->tv_nsec / 1000000000L;
    ts->tv_nsec %= 1000000000L;
}

/* A pthread made from a pthread starts once the main thread runs its event
 * loop: wait for it like for the network, interruptible. */
static int net_ready(URLContext *h)
{
    pthread_once(&net_once, net_create);
    pthread_mutex_lock(&net_lock);
    while (!net_state) {
        struct timespec ts;
        deadline_in(&ts, WEBIO_OPEN_WAIT_MS);
        pthread_cond_timedwait(&net_cond, &net_lock, &ts);
        if (!net_state && ff_check_interrupt(&h->interrupt_callback)) {
            pthread_mutex_unlock(&net_lock);
            return AVERROR_EXIT;
        }
    }
    int ok = net_state > 0;
    pthread_mutex_unlock(&net_lock);
    if (!ok)
        av_log(h, AV_LOG_ERROR, "webio: the net thread cannot start\n");
    return ok ? 0 : AVERROR(EAGAIN);
}

static int net_send(void (*fn)(void *), WebioStream *s)
{
    return emscripten_proxy_async(emscripten_proxy_get_system_queue(),
                                  net_thread, fn, s);
}

static void icy_clear(WebioStream *s)
{
    while (s->icy_head) {
        IcyPacket *p = s->icy_head;
        s->icy_head = p->next;
        free(p->text);
        av_free(p);
    }
    s->icy_tail = &s->icy_head;
}

static void stream_free(WebioStream *s)
{
    icy_clear(s);
    free(s->mime);
    free(s->location);
    free(s->icy_headers);
    free(s->errmsg);
    free(s->note);
    av_free(s->url);
    av_free(s->headers);
    av_free(s->ring);
    pthread_cond_destroy(&s->cond);
    pthread_mutex_destroy(&s->lock);
    av_free(s);
    atomic_fetch_sub(&live_streams, 1);
}

/* Net thread tasks. Only start reads the stream: it is sent before close,
 * so the stream is still there. */
static void task_start(void *arg)
{
    WebioStream *s = arg;
    pthread_mutex_lock(&s->lock);
    uint32_t gen = s->gen;
    double off = (double)s->req_off;
    int stale = s->closed;
    pthread_mutex_unlock(&s->lock);
    if (!stale)
        mak_webio_js_start(s, gen, s->url, s->headers, off,
                           (double)s->req_end, s->flags);
}

static void task_space(void *arg)
{
    mak_webio_js_space(arg);
}

static void task_close(void *arg)
{
    mak_webio_js_close(arg);
    stream_free(arg);
}

/* ── called by the JS side, on the net thread ─────────────────────────── */

/* Room for the next chunk: returns the contiguous bytes free and their
 * address in *at, 0 when the ring is full (the reader wakes the net thread
 * once it frees room), -1 when the request is stale or the stream closed. */
EMSCRIPTEN_KEEPALIVE int mak_webio_reserve(WebioStream *s, uint32_t gen,
                                           uint32_t *at)
{
    int n;
    pthread_mutex_lock(&s->lock);
    if (s->closed || gen != s->gen || s->state > WEBIO_OPEN) {
        n = -1;
    } else {
        uint32_t used = s->wpos - s->rpos;
        uint32_t idx = s->wpos & (s->cap - 1);
        n = (int)FFMIN(s->cap - used, s->cap - idx);
        if (!n)
            s->want_space = 1;
        *at = (uint32_t)(uintptr_t)(s->ring + idx);
    }
    pthread_mutex_unlock(&s->lock);
    return n;
}

EMSCRIPTEN_KEEPALIVE void mak_webio_commit(WebioStream *s, uint32_t gen,
                                           uint32_t n)
{
    pthread_mutex_lock(&s->lock);
    if (!s->closed && gen == s->gen && s->state <= WEBIO_OPEN) {
        s->wpos += n;
        s->data_at = av_gettime_relative();
        pthread_cond_broadcast(&s->cond);
    }
    pthread_mutex_unlock(&s->lock);
}

/* The answer of the request: the strings are the JS side's to give. */
EMSCRIPTEN_KEEPALIVE void mak_webio_response(WebioStream *s, uint32_t gen,
                                             int status, double size,
                                             int flags, char *mime,
                                             char *location,
                                             char *icy_headers, char *note,
                                             double ms)
{
    pthread_mutex_lock(&s->lock);
    if (s->closed || gen != s->gen || s->state != WEBIO_CONNECTING) {
        pthread_mutex_unlock(&s->lock);
        free(mime);
        free(location);
        free(icy_headers);
        free(note);
        return;
    }
    s->status = status;
    if (size >= 0)
        s->size = (int64_t)size;
    s->seekable = !!(flags & WEBIO_R_SEEKABLE);
    s->ms_headers = ms;
    s->data_at = av_gettime_relative();
#define WEBIO_TAKE(field, v) do { if (v) { free(s->field); s->field = (v); } } while (0)
    WEBIO_TAKE(mime, mime);
    WEBIO_TAKE(location, location);
    WEBIO_TAKE(icy_headers, icy_headers);
    WEBIO_TAKE(note, note);
#undef WEBIO_TAKE
    s->state = WEBIO_OPEN;
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
}

/* An ICY metadata packet found after `at` bytes of this request's data. */
EMSCRIPTEN_KEEPALIVE void mak_webio_icy(WebioStream *s, uint32_t gen,
                                        double at, char *text)
{
    IcyPacket *p = av_mallocz(sizeof(*p));
    pthread_mutex_lock(&s->lock);
    if (!p || s->closed || gen != s->gen) {
        pthread_mutex_unlock(&s->lock);
        av_free(p);
        free(text);
        return;
    }
    p->at = s->req_off + (int64_t)at;
    p->text = text;
    *s->icy_tail = p;
    s->icy_tail = &p->next;
    pthread_mutex_unlock(&s->lock);
}

static int http_error(int status)
{
    switch (status) {
    case 400: return AVERROR_HTTP_BAD_REQUEST;
    case 401: return AVERROR_HTTP_UNAUTHORIZED;
    case 403: return AVERROR_HTTP_FORBIDDEN;
    case 404: return AVERROR_HTTP_NOT_FOUND;
    case 429: return AVERROR_HTTP_TOO_MANY_REQUESTS;
    }
    if (status >= 500)
        return AVERROR_HTTP_SERVER_ERROR;
    return AVERROR_HTTP_OTHER_4XX;
}

/* The end of the request: the body ended (kind 0) or it failed. */
EMSCRIPTEN_KEEPALIVE void mak_webio_end(WebioStream *s, uint32_t gen,
                                        int kind, int status, char *msg)
{
    pthread_mutex_lock(&s->lock);
    if (s->closed || gen != s->gen || s->state > WEBIO_OPEN) {
        pthread_mutex_unlock(&s->lock);
        free(msg);
        return;
    }
    switch (kind) {
    case WEBIO_END_EOF:
    case WEBIO_END_RANGE:
        s->state = WEBIO_EOF;
        break;
    case WEBIO_END_HTTP:
        s->status = status;
        s->error = http_error(status);
        s->state = WEBIO_ERROR;
        break;
    case WEBIO_END_NOSEEK:
        s->error = AVERROR(ENOSYS);
        s->state = WEBIO_ERROR;
        break;
    default:
        s->error = AVERROR(EIO);
        s->state = WEBIO_ERROR;
        break;
    }
    if (msg) {
        free(s->errmsg);
        s->errmsg = msg;
    }
    pthread_cond_broadcast(&s->cond);
    pthread_mutex_unlock(&s->lock);
}

/* Streams not freed yet, for the tests. */
EMSCRIPTEN_KEEPALIVE int mak_webio_live_streams(void)
{
    return atomic_load(&live_streams);
}

/* ── reader side ───────────────────────────────────────────────────────── */

static WebioStream *stream_new(unsigned cap)
{
    WebioStream *s = av_mallocz(sizeof(*s));
    if (!s)
        return NULL;
    s->ring = av_malloc(cap);
    if (!s->ring) {
        av_free(s);
        return NULL;
    }
    s->cap = cap;
    s->size = -1;
    s->req_end = -1;
    s->icy_tail = &s->icy_head;
    pthread_mutex_init(&s->lock, NULL);
    pthread_cond_init(&s->cond, NULL);
    atomic_fetch_add(&live_streams, 1);
    return s;
}

static void stream_close(WebioStream *s)
{
    if (!s)
        return;
    pthread_mutex_lock(&s->lock);
    s->closed = 1;
    s->gen++;
    int started = s->started;
    pthread_mutex_unlock(&s->lock);
    /* Once a task went out, only the net thread may free the stream. */
    if (!started)
        stream_free(s);
    else if (!net_send(task_close, s))
        av_log(NULL, AV_LOG_ERROR, "webio: the net thread is gone, a stream leaks\n");
}

/* Logs what the net thread left for the reader: a warning once per stream,
 * the error once. Lock held. */
static void log_notes(URLContext *h, WebioContext *c, WebioStream *s)
{
    if (s->note && !c->note_logged) {
        c->note_logged = 1;
        av_log(h, AV_LOG_WARNING, "%s\n", s->note);
    }
    if (s->state == WEBIO_ERROR && s->errmsg && !c->error_logged) {
        c->error_logged = 1;
        av_log(h, AV_LOG_ERROR, "%s\n", s->errmsg);
    }
}

/* Waits for the answer of the request in flight. Lock not held. */
static int wait_answer(URLContext *h, WebioContext *c)
{
    WebioStream *s = c->s;
    int64_t deadline = c->timeout > 0 ? av_gettime_relative() + c->timeout
                                      : INT64_MAX;
    int ret = 0;
    pthread_mutex_lock(&s->lock);
    while (s->state == WEBIO_CONNECTING) {
        struct timespec ts;
        deadline_in(&ts, WEBIO_OPEN_WAIT_MS);
        pthread_cond_timedwait(&s->cond, &s->lock, &ts);
        if (s->state != WEBIO_CONNECTING)
            break;
        pthread_mutex_unlock(&s->lock);
        if (ff_check_interrupt(&h->interrupt_callback))
            return AVERROR_EXIT;
        if (av_gettime_relative() > deadline) {
            av_log(h, AV_LOG_ERROR, "webio: no answer within %.1f s\n",
                   c->timeout / 1e6);
            return AVERROR(ETIMEDOUT);
        }
        pthread_mutex_lock(&s->lock);
    }
    log_notes(h, c, s);
    if (s->state == WEBIO_ERROR)
        ret = s->error;
    pthread_mutex_unlock(&s->lock);
    return ret;
}

/* Sends the request of the current generation and waits for its answer. */
static int request(URLContext *h, WebioContext *c)
{
    WebioStream *s = c->s;
    pthread_mutex_lock(&s->lock);
    s->started = 1;
    pthread_mutex_unlock(&s->lock);
    if (!net_send(task_start, s))
        return AVERROR(EAGAIN);
    return wait_answer(h, c);
}

/* The JS side gets one header block, "Name: value" lines, and applies the
 * rules of the browser to it. */
static char *make_headers(WebioContext *c)
{
    AVBPrint bp;
    av_bprint_init(&bp, 0, AV_BPRINT_SIZE_UNLIMITED);
    if (c->headers) {
        av_bprintf(&bp, "%s", c->headers);
        if (bp.len && bp.str[bp.len - 1] != '\n')
            av_bprintf(&bp, "\r\n");
    }
    if (c->user_agent && c->user_agent[0])
        av_bprintf(&bp, "User-Agent: %s\r\n", c->user_agent);
    if (c->referer && c->referer[0])
        av_bprintf(&bp, "Referer: %s\r\n", c->referer);
    char *str = NULL;
    av_bprint_finalize(&bp, &str);
    return str;
}

static void export_string(char **dst, const char *src)
{
    av_freep(dst);
    if (src)
        *dst = av_strdup(src);
}

static int webio_open(URLContext *h, const char *uri, int flags)
{
    WebioContext *c = h->priv_data;
    const char *rest;
    int ret;

    if (flags & AVIO_FLAG_WRITE)
        return AVERROR(ENOSYS);
    c->t_open = av_gettime_relative();
    if ((ret = net_ready(h)) < 0)
        return ret;

    unsigned cap = 1u << 16;
    while (cap < (unsigned)c->buffer_size && cap < (1u << 26))
        cap <<= 1;
    WebioStream *s = c->s = stream_new(cap);
    if (!s)
        return AVERROR(ENOMEM);

    if (av_strstart(uri, "makblob://", &rest)) {
        s->url = av_asprintf("blob:%s", rest);
        s->flags |= WEBIO_F_BLOB;
    } else {
        s->url = av_strdup(uri);
    }
    s->headers = make_headers(c);
    if (!s->url || !s->headers) {
        stream_close(s);
        c->s = NULL;
        return AVERROR(ENOMEM);
    }
    if (c->icy)
        s->flags |= WEBIO_F_ICY;
    if (c->icy_cross_origin)
        s->flags |= WEBIO_F_ICY_CORS;
    if (c->cookies && c->cookies[0])
        av_log(h, AV_LOG_VERBOSE, "webio: cookies are the browser's, the option is not sent\n");
    s->req_off = c->pos = c->off;
    if (c->end_off > c->off)
        s->req_end = c->end_off;

    if ((ret = request(h, c)) < 0) {
        stream_close(s);
        c->s = NULL;
        return ret;
    }

    pthread_mutex_lock(&s->lock);
    h->is_streamed = !s->seekable || !c->seekable;
    export_string(&c->mime_type, s->mime);
    export_string(&c->location, s->location ? s->location : uri);
    export_string(&c->icy_metadata_headers, s->icy_headers);
    av_log(h, AV_LOG_INFO, "webio: %s: HTTP %d in %.1f ms, size %"PRId64"%s\n",
           s->location ? s->location : s->url, s->status, s->ms_headers,
           s->size, h->is_streamed ? ", not seekable" : "");
    pthread_mutex_unlock(&s->lock);
    return 0;
}

/* Lock held: the ICY packets whose offset the reader reached. */
static void icy_apply(WebioContext *c, WebioStream *s)
{
    while (s->icy_head && s->icy_head->at <= c->pos) {
        IcyPacket *p = s->icy_head;
        s->icy_head = p->next;
        if (!s->icy_head)
            s->icy_tail = &s->icy_head;
        export_string(&c->icy_metadata_packet, p->text);
        free(p->text);
        av_free(p);
    }
}

static int webio_read(URLContext *h, unsigned char *buf, int size)
{
    WebioContext *c = h->priv_data;
    WebioStream *s = c->s;
    int n, wake = 0;

    pthread_mutex_lock(&s->lock);
    uint32_t avail = s->wpos - s->rpos;
    if (!avail && s->state <= WEBIO_OPEN) {
        struct timespec ts;
        deadline_in(&ts, WEBIO_READ_WAIT_MS);
        pthread_cond_timedwait(&s->cond, &s->lock, &ts);
        avail = s->wpos - s->rpos;
    }
    if (avail) {
        n = (int)FFMIN(avail, (uint32_t)size);
        uint32_t idx = s->rpos & (s->cap - 1);
        uint32_t first = FFMIN((uint32_t)n, s->cap - idx);
        memcpy(buf, s->ring + idx, first);
        memcpy(buf + first, s->ring, n - first);
        s->rpos += n;
        c->pos += n;
        icy_apply(c, s);
        if (s->want_space && s->cap - (s->wpos - s->rpos) >= s->cap / 2) {
            s->want_space = 0;
            wake = 1;
        }
    } else if (s->state == WEBIO_EOF) {
        n = AVERROR_EOF;
    } else if (s->state == WEBIO_ERROR) {
        n = s->error;
    } else if (c->timeout > 0 &&
               av_gettime_relative() - s->data_at > c->timeout) {
        av_log(h, AV_LOG_ERROR, "webio: no data for %.1f s\n", c->timeout / 1e6);
        n = AVERROR(ETIMEDOUT);
    } else {
        n = AVERROR(EAGAIN);
    }
    log_notes(h, c, s);
    pthread_mutex_unlock(&s->lock);

    if (wake)
        net_send(task_space, s);
    if (n > 0 && !c->first_logged) {
        c->first_logged = 1;
        av_log(h, AV_LOG_INFO, "webio: first bytes %.1f ms after the open\n",
               (av_gettime_relative() - c->t_open) / 1000.0);
    }
    return n;
}

static int64_t webio_seek(URLContext *h, int64_t pos, int whence)
{
    WebioContext *c = h->priv_data;
    WebioStream *s = c->s;
    int64_t target;

    pthread_mutex_lock(&s->lock);
    int64_t size = s->size;
    int seekable = s->seekable && c->seekable;
    pthread_mutex_unlock(&s->lock);

    whence &= ~AVSEEK_FORCE;
    switch (whence) {
    case AVSEEK_SIZE:
        return size >= 0 ? size : AVERROR(ENOSYS);
    case SEEK_SET:
        target = pos;
        break;
    case SEEK_CUR:
        target = c->pos + pos;
        break;
    case SEEK_END:
        if (size < 0)
            return AVERROR(ENOSYS);
        target = size + pos;
        break;
    default:
        return AVERROR(EINVAL);
    }
    if (target < 0)
        return AVERROR(EINVAL);
    if (target == c->pos)
        return target;

    pthread_mutex_lock(&s->lock);
    /* Forward into what is already in the ring: skip, no request. */
    uint32_t avail = s->wpos - s->rpos;
    if (target > c->pos && target - c->pos <= avail) {
        s->rpos += (uint32_t)(target - c->pos);
        c->pos = target;
        icy_apply(c, s);
        int wake = s->want_space && s->cap - (s->wpos - s->rpos) >= s->cap / 2;
        if (wake)
            s->want_space = 0;
        pthread_mutex_unlock(&s->lock);
        if (wake)
            net_send(task_space, s);
        return target;
    }
    if (!seekable) {
        pthread_mutex_unlock(&s->lock);
        return AVERROR(ENOSYS);
    }
    s->gen++;
    s->rpos = s->wpos = 0;
    s->want_space = 0;
    s->req_off = target;
    icy_clear(s);
    c->pos = target;
    c->error_logged = 0;
    if (size >= 0 && target >= size) {
        /* At or past the end: nothing to ask for. */
        s->state = WEBIO_EOF;
        pthread_mutex_unlock(&s->lock);
        return target;
    }
    s->state = WEBIO_CONNECTING;
    pthread_mutex_unlock(&s->lock);

    int ret = request(h, c);
    if (ret < 0) {
        pthread_mutex_lock(&s->lock);
        if (s->state == WEBIO_CONNECTING) {
            /* Interrupted or timed out: the answer that comes later is
             * stale, and the reads fail like the seek did. */
            s->gen++;
            s->error = ret;
            s->state = WEBIO_ERROR;
        }
        pthread_mutex_unlock(&s->lock);
        return ret;
    }
    return target;
}

static int webio_close(URLContext *h)
{
    WebioContext *c = h->priv_data;
    stream_close(c->s);
    c->s = NULL;
    return 0;
}

#define OFFSET(x) offsetof(WebioContext, x)
#define D AV_OPT_FLAG_DECODING_PARAM
#define E AV_OPT_FLAG_ENCODING_PARAM

/* The names of http.c, so mpv and the demuxers pass them as they do. */
static const AVOption webio_options[] = {
    { "seekable", "control seekability of connection", OFFSET(seekable), AV_OPT_TYPE_BOOL, { .i64 = -1 }, -1, 1, D },
    { "headers", "set custom HTTP headers (the browser drops the ones fetch forbids)", OFFSET(headers), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, D },
    { "user_agent", "User-Agent, sent where the browser lets it through", OFFSET(user_agent), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, D },
    { "referer", "referrer of the request (same origin only)", OFFSET(referer), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, D },
    { "cookies", "ignored: the browser keeps the cookies", OFFSET(cookies), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, D },
    { "icy", "request ICY metadata", OFFSET(icy), AV_OPT_TYPE_BOOL, { .i64 = 1 }, 0, 1, D },
    { "icy_cross_origin", "request ICY metadata from another origin too (CORS preflight)", OFFSET(icy_cross_origin), AV_OPT_TYPE_BOOL, { .i64 = 0 }, 0, 1, D },
    { "icy_metadata_headers", "return ICY metadata headers", OFFSET(icy_metadata_headers), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, AV_OPT_FLAG_EXPORT },
    { "icy_metadata_packet", "return current ICY metadata packet", OFFSET(icy_metadata_packet), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, AV_OPT_FLAG_EXPORT },
    { "mime_type", "export the MIME type", OFFSET(mime_type), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, AV_OPT_FLAG_EXPORT | AV_OPT_FLAG_READONLY },
    { "location", "the actual location of the data received", OFFSET(location), AV_OPT_TYPE_STRING, { .str = NULL }, 0, 0, D | E },
    { "timeout", "no answer or no data for this long fails the read, in microseconds", OFFSET(timeout), AV_OPT_TYPE_INT64, { .i64 = -1 }, -1, INT64_MAX, D },
    { "offset", "initial byte offset", OFFSET(off), AV_OPT_TYPE_INT64, { .i64 = 0 }, 0, INT64_MAX, D },
    { "end_offset", "try to limit the request to bytes preceding this offset", OFFSET(end_off), AV_OPT_TYPE_INT64, { .i64 = 0 }, 0, INT64_MAX, D },
    { "webio_buffer", "read-ahead ring of each stream, in bytes", OFFSET(buffer_size), AV_OPT_TYPE_INT, { .i64 = 1 << 20 }, 1 << 16, 1 << 26, D },
    { NULL }
};

#define WEBIO_PROTOCOL(sym, proto)                                           \
static const AVClass webio_##sym##_class = {                                 \
    .class_name = proto,                                                     \
    .item_name  = av_default_item_name,                                      \
    .option     = webio_options,                                             \
    .version    = LIBAVUTIL_VERSION_INT,                                     \
};                                                                           \
const URLProtocol ff_webio_##sym##_protocol = {                              \
    .name              = proto,                                              \
    .url_open          = webio_open,                                         \
    .url_read          = webio_read,                                         \
    .url_seek          = webio_seek,                                         \
    .url_close         = webio_close,                                        \
    .priv_data_size    = sizeof(WebioContext),                               \
    .priv_data_class   = &webio_##sym##_class,                               \
    .flags             = URL_PROTOCOL_FLAG_NETWORK,                          \
    .default_whitelist = "http,https,makblob,crypto,data",                   \
};

#if CONFIG_WEBIO_HTTP_PROTOCOL
WEBIO_PROTOCOL(http, "http")
#endif
#if CONFIG_WEBIO_HTTPS_PROTOCOL
WEBIO_PROTOCOL(https, "https")
#endif
#if CONFIG_WEBIO_MAKBLOB_PROTOCOL
WEBIO_PROTOCOL(makblob, "makblob")
#endif
