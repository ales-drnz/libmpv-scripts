/* MAK_PCM_STREAM_PATCH_V2 ─── live PCM input: the mak-pcm://<id> protocol.
 * See mak_pcm.h, and patches/mpv/shared/patch_pcm_stream.py in
 * libmpv-scripts for the rationale.
 *
 * A thin stream over one mak_pcm source: no seek, no size, no buffering of
 * its own (fill_buffer hands over what the FIFO holds, at most what mpv
 * asked for). The bytes are headerless PCM for the rawaudio demuxer, which
 * the app selects with file-local options. mpv's stream cancel (stop,
 * loadfile replace, quit) wakes a blocked read through a private child
 * mp_cancel whose callback pokes the source's condition variable. */
#include <errno.h>
#include <inttypes.h>
#include <stdlib.h>

#include "common/common.h"
#include "common/msg.h"
#include "misc/thread_tools.h"
#include "stream.h"
#include "stream/mak_pcm.h"

struct priv {
    struct mak_pcm_src *src;
    struct mp_cancel *cancel;   /* child of stream->cancel, owns the callback */
};

static bool is_cancelled(void *ctx)
{
    stream_t *s = ctx;
    return mp_cancel_test(s->cancel);
}

static void on_cancel(void *ctx)
{
    /* Runs under mp_cancel's lock; mak_pcm never calls into mp_cancel while
     * holding its own lock, so taking it here cannot deadlock. */
    struct priv *p = ctx;
    mak_pcm_reader_wake(p->src);
}

static int fill_buffer(stream_t *s, void *buffer, int max_len)
{
    struct priv *p = s->priv;
    return mak_pcm_reader_read(p->src, buffer, max_len, is_cancelled, s);
}

static void s_close(stream_t *s)
{
    struct priv *p = s->priv;
    /* Detach the callback first: once the child is gone no trigger can
     * reach the source, then drop the reader reference. */
    TA_FREEP(&p->cancel);
    mak_pcm_reader_close(p->src);
    p->src = NULL;
}

static int open_f(stream_t *stream)
{
    /* The path is the decimal id, nothing else. */
    const char *path = stream->path;
    char *end = NULL;
    errno = 0;
    long long id = (path && *path >= '0' && *path <= '9')
                   ? strtoll(path, &end, 10) : 0;
    if (errno || !end || *end || id <= 0) {
        MP_ERR(stream, "Invalid mak-pcm id: '%s'\n", path ? path : "");
        return STREAM_ERROR;
    }

    struct mak_pcm_src *src = NULL;
    int r = mak_pcm_reader_open(id, &src);
    if (r < 0) {
        MP_ERR(stream, "mak-pcm://%lld %s\n", id,
               r == MAK_PCM_EUNKNOWN ? "does not exist" :
               "was already read, aborted or released (one reader per id)");
        return STREAM_ERROR;
    }

    struct priv *p = talloc_zero(stream, struct priv);
    p->src = src;
    stream->priv = p;

    stream->fill_buffer = fill_buffer;
    stream->close = s_close;
    stream->seekable = false;
    stream->fast_skip = false;
    /* Live: mpv reports demuxer-via-network and the analysis never re-opens
     * it (mak_scan.c also refuses the scheme by name). Not "streaming", so
     * mpv's network cache and its pause-for-cache stay off by default. */
    stream->is_network = true;
    stream->streaming = false;
    stream->demuxer = "rawaudio";

    if (stream->cancel) {
        p->cancel = mp_cancel_new(p);
        mp_cancel_set_parent(p->cancel, stream->cancel);
        /* Calls on_cancel at once if the parent already fired. */
        mp_cancel_set_cb(p->cancel, on_cancel, p);
    }

    MP_VERBOSE(stream, "Reading live PCM source %lld\n", id);
    return STREAM_OK;
}

const stream_info_t stream_info_mak_pcm = {
    .name = "mak-pcm",
    .open = open_f,
    .protocols = (const char *const[]){ "mak-pcm", NULL },
    /* Only a direct loadfile may name an id, never a playlist file. */
    .stream_origin = STREAM_ORIGIN_UNSAFE,
};
