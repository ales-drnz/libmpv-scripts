/* MAK_WAVEFORM_PATCH_V2 ─── bulk-analysis scan engine: the sources.
 *
 * Opens a source for the coordinator's probe and for each worker: a URL with
 * mpv's network options, or the duplicate of an fd://N descriptor read with
 * pread through an AVIOContext of its own. See mak_scan.c. */
#include "audio/mak_scan_internal.h"

/* ─── descriptor sources ──────────────────────────────────────────────
 * An fd://N or fdclose://N URL (how an Android content:// URI reaches mpv)
 * names a descriptor mpv reads with its own stream layer; FFmpeg cannot
 * open it. mak_scan_start duplicates N on the core thread, and every
 * context here reads the duplicate through an AVIOContext of its own, with
 * pread at a private position: mpv reads N with read and lseek, and a
 * duplicate shares that offset, which a plain read here would move under
 * playback. */
#define MAK_FD_IO_BUF 32768

struct fd_io {
    int     fd;
    int64_t pos;
};

#if MAK_SCAN_FD_IO
static int fd_io_read(void *opaque, uint8_t *buf, int len)
{
    struct fd_io *io = opaque;
    ssize_t r;
    do {
        r = pread(io->fd, buf, len, io->pos);
    } while (r < 0 && errno == EINTR);
    if (r < 0)
        return AVERROR(errno);
    if (r == 0)
        return AVERROR_EOF;
    io->pos += r;
    return (int)r;
}

static int64_t fd_io_seek(void *opaque, int64_t offset, int whence)
{
    struct fd_io *io = opaque;
    struct stat st;
    switch (whence & ~AVSEEK_FORCE) {
    case AVSEEK_SIZE:
        return fstat(io->fd, &st) < 0 ? AVERROR(errno) : st.st_size;
    case SEEK_SET:
        break;
    case SEEK_CUR:
        offset += io->pos;
        break;
    case SEEK_END:
        if (fstat(io->fd, &st) < 0)
            return AVERROR(errno);
        offset += st.st_size;
        break;
    default:
        return AVERROR(EINVAL);
    }
    if (offset < 0)
        return AVERROR(EINVAL);
    io->pos = offset;
    return offset;
}
#endif

/* Closes the duplicate mak_scan_start took of a descriptor source. */
void mak_scan_close_fd(int fd)
{
#if MAK_SCAN_FD_IO
    if (fd >= 0)
        close(fd);
#else
    (void)fd;
#endif
}

/* Frees an AVIOContext mak_scan_open_source made for a descriptor. */
static void free_fd_io(AVIOContext *pb)
{
    if (!pb)
        return;
    av_freep(&pb->buffer);
    av_freep(&pb->opaque);
    avio_context_free(&pb);
}

/* Closes [*fmt], and the descriptor reader mak_scan_open_source gave it: with a
 * caller's AVIOContext, avformat_close_input leaves it open. */
void mak_scan_close_source(AVFormatContext **fmt)
{
    AVIOContext *pb = *fmt && ((*fmt)->flags & AVFMT_FLAG_CUSTOM_IO)
                    ? (*fmt)->pb : NULL;
    avformat_close_input(fmt);
    free_fd_io(pb);
}

/* Open [url] into the pre-allocated [*fmt] with mpv's own network options
 * ([net_opts], NULL for a local path: tls-verify, CA file, headers, user
 * agent, cookies...) so the re-open verifies and authenticates exactly like
 * playback does. FFmpeg's own defaults would skip certificate verification
 * and drop the headers. The 5 s I/O timeout then overrides mpv's
 * network-timeout, bounding a stalled connection as before. With [fd] >= 0
 * the source is that descriptor, read with pread (see above), and [url]
 * only names it. Close with mak_scan_close_source. */
int mak_scan_open_source(AVFormatContext **fmt, const char *url, int fd,
                       const AVDictionary *net_opts)
{
    AVIOContext *pb = NULL;
#if MAK_SCAN_FD_IO
    if (fd >= 0) {
        struct fd_io *io = av_mallocz(sizeof(*io));
        unsigned char *buf = av_malloc(MAK_FD_IO_BUF);
        pb = io && buf ? avio_alloc_context(buf, MAK_FD_IO_BUF, 0, io,
                                            fd_io_read, NULL, fd_io_seek)
                       : NULL;
        if (!pb) {
            av_free(buf);
            av_free(io);
            avformat_free_context(*fmt);
            *fmt = NULL;
            return AVERROR(ENOMEM);
        }
        io->fd = fd;
        pb->seekable = AVIO_SEEKABLE_NORMAL;
        (*fmt)->pb = pb;
        (*fmt)->flags |= AVFMT_FLAG_CUSTOM_IO;
    }
#endif
    AVDictionary *opts = NULL;
    if (net_opts && av_dict_copy(&opts, net_opts, 0) < 0) {
        av_dict_free(&opts);
        avformat_free_context(*fmt);
        *fmt = NULL;
        free_fd_io(pb);
        return AVERROR(ENOMEM);
    }
    av_dict_set(&opts, "rw_timeout", "5000000", 0);  /* 5 s (microseconds) */
    av_dict_set(&opts, "timeout",    "5000000", 0);  /* 5 s (HTTP/TCP) */
    int ret = avformat_open_input(fmt, url, NULL, &opts);
    av_dict_free(&opts);
    /* A failed open frees the context but not a caller's AVIOContext. */
    if (ret < 0)
        free_fd_io(pb);
    return ret;
}
