/*
 * Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Part of FFmpeg once copied into libavformat/, and under its license below.
 */

/*
 * SMB2/3 protocol handler using libsmb2 (LGPL)
 *
 * Copyright (c) 2026 Alessandro Di Ronza
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include <stdint.h>
#include <stddef.h>
#include <time.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include "libavutil/avstring.h"
#include "libavutil/mem.h"
#include "libavutil/opt.h"
#include "libavutil/time.h"
#include "network.h"
#include "url.h"

/* With no "timeout" (mpv's network-timeout 0), the connect still gets this
 * many seconds: negotiate, session setup and tree connect, and a NAS that
 * wakes up. */
#define LIBSMB2_CONNECT_TIMEOUT 30

/* Longest single wait on the socket. The interrupt callback is checked
 * after each one, so a stop is seen within this. */
#define LIBSMB2_SLICE_MS 100

typedef struct {
    const AVClass *class;
    struct smb2_context *smb2;
    struct smb2fh *fh;
    struct smb2dir *dir;
    int64_t filesize;
    int timeout;
    char *password;
    /* The libsmb2 call in flight, filled by libsmb2_cb. */
    int done;
    int status;
    void *data;
    /* A wait gave up with a call in flight: the context is only destroyed. */
    int broken;
} LIBSMB2Context;

static void libsmb2_cb(struct smb2_context *smb2, int status,
                       void *command_data, void *private_data)
{
    LIBSMB2Context *ctx = private_data;
    ctx->done   = 1;
    ctx->status = status;
    ctx->data   = command_data;
}

/* smb2_opendir_async gives its cb_data to the smb2dir, which free()s it,
 * so opendir gets a malloc'ed pointer to the context. */
static void libsmb2_opendir_cb(struct smb2_context *smb2, int status,
                               void *command_data, void *private_data)
{
    libsmb2_cb(smb2, status, command_data, *(LIBSMB2Context **)private_data);
}

/**
 * Run libsmb2's event loop until the call in flight completes, as its sync
 * calls do, but in waits of at most LIBSMB2_SLICE_MS with the interrupt
 * callback checked after each one: a stop or a quit no longer waits for an
 * SMB server that stopped answering. smb2_service runs after every wait,
 * events or not, since it is where libsmb2 expires its requests. deadline
 * (av_gettime_relative() time, 0 for none) bounds the connect.
 * On failure the context is marked broken and never serviced again, so a
 * late reply cannot land in a buffer the caller already took back.
 */
static int libsmb2_wait(URLContext *h, int64_t deadline)
{
    LIBSMB2Context *ctx = h->priv_data;

    while (!ctx->done) {
        struct pollfd pfd = { 0 };
        int ret;

        pfd.fd     = smb2_get_fd(ctx->smb2);
        pfd.events = smb2_which_events(ctx->smb2);
        ret = poll(&pfd, 1, LIBSMB2_SLICE_MS);
        if (ret < 0 && ff_neterrno() != AVERROR(EINTR)) {
            ret = ff_neterrno();
            av_log(h, AV_LOG_ERROR, "SMB2 poll failed: %s\n", av_err2str(ret));
            ctx->broken = 1;
            return ret;
        }
        if (smb2_service(ctx->smb2, ret > 0 ? pfd.revents : 0) < 0) {
            ctx->broken = 1;
            if (ctx->done)
                break;
            av_log(h, AV_LOG_ERROR, "SMB2 connection failed: %s\n",
                   smb2_get_error(ctx->smb2));
            return AVERROR(EIO);
        }
        if (ctx->done)
            break;
        if (ff_check_interrupt(&h->interrupt_callback)) {
            ctx->broken = 1;
            return AVERROR_EXIT;
        }
        if (deadline && av_gettime_relative() > deadline) {
            av_log(h, AV_LOG_ERROR, "SMB2 connect timed out\n");
            ctx->broken = 1;
            return AVERROR(ETIMEDOUT);
        }
    }
    return 0;
}

/* Starts a call with libsmb2_cb as its callback (ret is what the _async
 * function returned) and waits for it. Returns the wait's error, or the
 * call's status. */
static int libsmb2_finish(URLContext *h, int ret, int64_t deadline)
{
    LIBSMB2Context *ctx = h->priv_data;

    if (ret < 0)
        return ret;
    if ((ret = libsmb2_wait(h, deadline)) < 0)
        return ret;
    return ctx->status;
}

/**
 * Percent-decode a string in-place (e.g. %26 -> &). A '%' that is not
 * followed by two hex digits is kept as it is, as ff_urldecode does, so
 * "100% Pure.flac" stays whole. %00 is refused with AVERROR(EINVAL): a
 * NUL would cut the name short and open another file.
 */
static int percent_decode(char *s)
{
    char *r = s, *w = s;
    while (*r) {
        if (*r == '%' && av_isxdigit(r[1]) && av_isxdigit(r[2])) {
            char hex[3] = { r[1], r[2], 0 };
            long c = strtol(hex, NULL, 16);
            if (!c)
                return AVERROR(EINVAL);
            *w++ = (char)c;
            r += 3;
        } else {
            *w++ = *r++;
        }
    }
    *w = '\0';
    return 0;
}

/**
 * Build a cleaned URL with the :password portion stripped out, and
 * extract the password separately (percent-decoded).
 *
 * Input:  smb2://[domain;]user:password@server/share/path
 * Output: clean_url = smb2://[domain;]user@server/share/path
 *         password  = decoded password, NULL when there is none
 *         (caller must av_free both, also on failure)
 * Returns 0, AVERROR(ENOMEM), or AVERROR(EINVAL) for a %00 in the password.
 *
 * Only the authority is read: it ends at the first '/' or '?' after
 * "://", so an '@' or a ':' in the path, a port or an IPv6 host is never
 * taken for credentials. The last '@' of the authority ends the userinfo,
 * and the first ':' in it starts the password. Neither the domain nor the
 * user holds a ':', so a ';' after it belongs to the password.
 */
static int strip_password_from_url(const char *url, char **out_url,
                                   char **out_password)
{
    const char *scheme_end, *auth_start, *auth_end, *at_sign = NULL, *colon, *p;
    char *clean;

    *out_url = NULL;
    *out_password = NULL;

    scheme_end = strstr(url, "://");
    if (!scheme_end)
        goto unchanged;
    auth_start = scheme_end + 3;
    auth_end = auth_start + strcspn(auth_start, "/?");

    for (p = auth_start; p < auth_end; p++)
        if (*p == '@')
            at_sign = p;
    if (!at_sign)
        goto unchanged;

    colon = memchr(auth_start, ':', at_sign - auth_start);
    if (!colon)
        goto unchanged;

    /* Extract and decode password */
    *out_password = av_strndup(colon + 1, at_sign - colon - 1);
    if (!*out_password)
        return AVERROR(ENOMEM);
    if (percent_decode(*out_password) < 0)
        return AVERROR(EINVAL);

    /* Build clean URL: everything before ':' + everything from '@' onwards */
    {
        int prefix_len = (int)(colon - url);
        int suffix_len = (int)strlen(at_sign);
        clean = av_malloc(prefix_len + suffix_len + 1);
        if (!clean)
            return AVERROR(ENOMEM);
        memcpy(clean, url, prefix_len);
        memcpy(clean + prefix_len, at_sign, suffix_len);
        clean[prefix_len + suffix_len] = '\0';
    }
    *out_url = clean;
    return 0;

unchanged:
    *out_url = av_strdup(url);
    return *out_url ? 0 : AVERROR(ENOMEM);
}

/* Disconnects and frees the context. After a broken wait it only frees it,
 * which closes the socket at once; the server drops the session with it. */
static void libsmb2_disconnect(URLContext *h)
{
    LIBSMB2Context *ctx = h->priv_data;

    if (!ctx->smb2)
        return;
    if (!ctx->broken) {
        ctx->done = 0;
        libsmb2_finish(h, smb2_disconnect_share_async(ctx->smb2, libsmb2_cb, ctx), 0);
    }
    smb2_destroy_context(ctx->smb2);
    ctx->smb2 = NULL;
}

static av_cold int libsmb2_close(URLContext *h)
{
    LIBSMB2Context *ctx = h->priv_data;
    if (ctx->fh) {
        /* A broken context still owns the handle: destroy frees it. */
        if (!ctx->broken) {
            ctx->done = 0;
            libsmb2_finish(h, smb2_close_async(ctx->smb2, ctx->fh, libsmb2_cb, ctx), 0);
        }
        ctx->fh = NULL;
    }
    if (ctx->dir) {
        smb2_closedir(ctx->smb2, ctx->dir);
        ctx->dir = NULL;
    }
    libsmb2_disconnect(h);
    return 0;
}

static av_cold int libsmb2_connect(URLContext *h, struct smb2_url **out_url)
{
    LIBSMB2Context *ctx = h->priv_data;
    struct smb2_url *url = NULL;
    char *clean_url = NULL;
    char *url_password = NULL;
    int ret;

    ctx->smb2 = smb2_init_context();
    if (!ctx->smb2) {
        av_log(h, AV_LOG_ERROR, "Failed to init SMB2 context\n");
        return AVERROR(ENOMEM);
    }

    /* "timeout" is in microseconds, as for tcp and http (mpv passes
     * network-timeout * 1e6); libsmb2 counts whole seconds. With none,
     * libsmb2 gave the TCP connect only until time() ticked over and the
     * replies no limit: the connect gets LIBSMB2_CONNECT_TIMEOUT, and the
     * calls after it keep no limit, like tcp's rw_timeout. */
    if (ctx->timeout > 0)
        smb2_set_timeout(ctx->smb2,
                         (int)(((int64_t)ctx->timeout + 999999) / 1000000));
    else
        smb2_set_timeout(ctx->smb2, LIBSMB2_CONNECT_TIMEOUT);

    /* Force NTLM authentication — GSSAPI/Kerberos fails in sandboxed apps */
    smb2_set_authentication(ctx->smb2, 1); /* 1 = SMB2_SEC_NTLMSSP */

    /* Strip password from URL before parsing (libsmb2 doesn't handle user:pass@) */
    ret = strip_password_from_url(h->filename, &clean_url, &url_password);
    if (ret == AVERROR(EINVAL))
        av_log(h, AV_LOG_ERROR, "SMB2 URL password holds a %%00 escape\n");
    if (ret < 0)
        goto fail;

    /* libsmb2's parser expects "smb://" not "smb2://" — rewrite the scheme */
    if (!strncmp(clean_url, "smb2://", 7)) {
        memmove(clean_url + 4, clean_url + 5, strlen(clean_url + 5) + 1);
        memcpy(clean_url, "smb:", 4);
    }

    url = smb2_parse_url(ctx->smb2, clean_url);
    av_free(clean_url);
    clean_url = NULL;

    if (!url) {
        av_log(h, AV_LOG_ERROR, "Failed to parse SMB2 URL: %s\n",
               smb2_get_error(ctx->smb2));
        ret = AVERROR(EINVAL);
        goto fail;
    }

    /* smb2_parse_url() only splits on delimiters — it leaves the components
     * percent-ENCODED. Decode them in place (like every other ffmpeg protocol
     * decodes its path) so a properly-encoded smb2:// URL with spaces / accents
     * / reserved chars in the share & path resolves to the real filesystem name
     * instead of failing with STATUS_OBJECT_PATH_NOT_FOUND. The password was
     * already decoded by strip_password_from_url; the server host is left as-is.
     * percent_decode() only shrinks the string, so editing the parser's buffers
     * in place is safe (smb2_destroy_url still frees them). */
    if ((url->user   && percent_decode((char *)url->user)   < 0) ||
        (url->domain && percent_decode((char *)url->domain) < 0) ||
        (url->share  && percent_decode((char *)url->share)  < 0) ||
        (url->path   && percent_decode((char *)url->path)   < 0)) {
        av_log(h, AV_LOG_ERROR, "SMB2 URL holds a %%00 escape\n");
        ret = AVERROR(EINVAL);
        goto fail;
    }

    if (url->user)
        smb2_set_user(ctx->smb2, url->user);
    if (url->domain)
        smb2_set_domain(ctx->smb2, url->domain);

    /* password: AVOption > URL-extracted > none */
    if (ctx->password)
        smb2_set_password(ctx->smb2, ctx->password);
    else if (url_password)
        smb2_set_password(ctx->smb2, url_password);

    av_free(url_password);
    url_password = NULL;

    ctx->done = 0;
    ret = smb2_connect_share_async(ctx->smb2, url->server, url->share, url->user,
                                   libsmb2_cb, ctx);
    ret = libsmb2_finish(h, ret, av_gettime_relative() +
                         (ctx->timeout > 0 ? ctx->timeout
                                           : LIBSMB2_CONNECT_TIMEOUT * INT64_C(1000000)));
    if (ret < 0) {
        if (ret != AVERROR_EXIT && ret != AVERROR(ETIMEDOUT)) {
            av_log(h, AV_LOG_ERROR, "Failed to connect to SMB2 share: %s\n",
                   smb2_get_error(ctx->smb2));
            ret = AVERROR(EIO);
        }
        goto fail;
    }
    /* A request takes its deadline when it is queued, so this clears it
     * only for the requests after the connect. */
    if (ctx->timeout <= 0)
        smb2_set_timeout(ctx->smb2, 0);

    *out_url = url;
    return 0;

fail:
    av_free(clean_url);
    av_free(url_password);
    if (url)
        smb2_destroy_url(url);
    smb2_destroy_context(ctx->smb2);
    ctx->smb2 = NULL;
    return ret;
}

static av_cold int libsmb2_open(URLContext *h, const char *url, int flags)
{
    LIBSMB2Context *ctx = h->priv_data;
    struct smb2_url *parsed_url = NULL;
    struct smb2_stat_64 st;
    int access, ret;

    ctx->fh = NULL;
    ctx->filesize = -1;

    if ((ret = libsmb2_connect(h, &parsed_url)) < 0)
        return ret;

    if ((flags & AVIO_FLAG_WRITE) && (flags & AVIO_FLAG_READ))
        access = O_RDWR;
    else if (flags & AVIO_FLAG_WRITE)
        access = O_WRONLY | O_CREAT;
    else
        access = O_RDONLY;

    ctx->done = 0;
    ctx->data = NULL;
    ret = smb2_open_async(ctx->smb2, parsed_url->path, access, libsmb2_cb, ctx);
    ret = libsmb2_finish(h, ret, 0);
    smb2_destroy_url(parsed_url);
    if (ret < 0 || !ctx->data) {
        if (ret != AVERROR_EXIT)
            av_log(h, AV_LOG_ERROR, "SMB2 file open failed: %s\n",
                   smb2_get_error(ctx->smb2));
        libsmb2_close(h);
        return ret == AVERROR_EXIT ? ret : AVERROR(EIO);
    }
    ctx->fh = ctx->data;

    /* The size is optional, unless the wait itself was cut short. */
    ctx->done = 0;
    ret = smb2_fstat_async(ctx->smb2, ctx->fh, &st, libsmb2_cb, ctx);
    ret = libsmb2_finish(h, ret, 0);
    if (ctx->broken) {
        libsmb2_close(h);
        return ret == AVERROR_EXIT ? ret : AVERROR(EIO);
    }
    if (ret == 0)
        ctx->filesize = st.smb2_size;

    return 0;
}

static int libsmb2_read(URLContext *h, unsigned char *buf, int size)
{
    LIBSMB2Context *ctx = h->priv_data;
    int bytes_read;

    if (ctx->broken)
        return AVERROR(EIO);
    ctx->done = 0;
    bytes_read = smb2_read_async(ctx->smb2, ctx->fh, (uint8_t *)buf, (uint32_t)size,
                                 libsmb2_cb, ctx);
    bytes_read = libsmb2_finish(h, bytes_read, 0);
    if (bytes_read == AVERROR_EXIT)
        return bytes_read;
    if (bytes_read < 0) {
        av_log(h, AV_LOG_ERROR, "SMB2 read error: %s\n",
               smb2_get_error(ctx->smb2));
        return AVERROR(EIO);
    }

    return bytes_read ? bytes_read : AVERROR_EOF;
}

static int libsmb2_write(URLContext *h, const unsigned char *buf, int size)
{
    LIBSMB2Context *ctx = h->priv_data;
    int bytes_written;

    if (ctx->broken)
        return AVERROR(EIO);
    ctx->done = 0;
    bytes_written = smb2_write_async(ctx->smb2, ctx->fh, (const uint8_t *)buf,
                                     (uint32_t)size, libsmb2_cb, ctx);
    bytes_written = libsmb2_finish(h, bytes_written, 0);
    if (bytes_written == AVERROR_EXIT)
        return bytes_written;
    if (bytes_written < 0) {
        av_log(h, AV_LOG_ERROR, "SMB2 write error: %s\n",
               smb2_get_error(ctx->smb2));
        return AVERROR(EIO);
    }

    return bytes_written;
}

static int64_t libsmb2_seek(URLContext *h, int64_t pos, int whence)
{
    LIBSMB2Context *ctx = h->priv_data;
    int64_t newpos;

    if (whence == AVSEEK_SIZE) {
        if (ctx->filesize == -1) {
            av_log(h, AV_LOG_ERROR, "SMB2 seek: filesize unknown\n");
            return AVERROR(EIO);
        }
        return ctx->filesize;
    }

    newpos = smb2_lseek(ctx->smb2, ctx->fh, pos, whence, NULL);
    if (newpos < 0) {
        av_log(h, AV_LOG_ERROR, "SMB2 seek error: %s\n",
               smb2_get_error(ctx->smb2));
        return AVERROR(EIO);
    }

    return newpos;
}

static int libsmb2_open_dir(URLContext *h)
{
    LIBSMB2Context *ctx = h->priv_data;
    struct smb2_url *parsed_url = NULL;
    LIBSMB2Context **token;
    int ret;

    if ((ret = libsmb2_connect(h, &parsed_url)) < 0)
        return ret;

    /* calloc, not av_malloc: libsmb2 frees it, and on an early failure it
     * may already have (a leak only if its own calloc failed). */
    token = calloc(1, sizeof(*token));
    if (!token) {
        smb2_destroy_url(parsed_url);
        libsmb2_close(h);
        return AVERROR(ENOMEM);
    }
    *token = ctx;
    ctx->done = 0;
    ctx->data = NULL;
    ret = smb2_opendir_async(ctx->smb2, parsed_url->path, libsmb2_opendir_cb, token);
    ret = libsmb2_finish(h, ret, 0);
    smb2_destroy_url(parsed_url);
    ctx->dir = ret < 0 ? NULL : ctx->data;

    if (!ctx->dir) {
        if (ret != AVERROR_EXIT)
            av_log(h, AV_LOG_ERROR, "SMB2 opendir failed: %s\n",
                   smb2_get_error(ctx->smb2));
        libsmb2_close(h);
        return ret == AVERROR_EXIT ? ret : AVERROR(EIO);
    }

    return 0;
}

static int libsmb2_read_dir(URLContext *h, AVIODirEntry **next)
{
    LIBSMB2Context *ctx = h->priv_data;
    struct smb2dirent *dirent;
    AVIODirEntry *entry;

    do {
        dirent = smb2_readdir(ctx->smb2, ctx->dir);
    } while (dirent && (!strcmp(dirent->name, ".") || !strcmp(dirent->name, "..")));

    if (!dirent) {
        *next = NULL;
        return 0;
    }

    *next = entry = ff_alloc_dir_entry();
    if (!entry)
        return AVERROR(ENOMEM);

    entry->name = av_strdup(dirent->name);
    if (!entry->name) {
        av_freep(next);
        return AVERROR(ENOMEM);
    }

    switch (dirent->st.smb2_type) {
    case SMB2_TYPE_DIRECTORY:
        entry->type = AVIO_ENTRY_DIRECTORY;
        break;
    case SMB2_TYPE_FILE:
        entry->type = AVIO_ENTRY_FILE;
        break;
    case SMB2_TYPE_LINK:
    default:
        entry->type = AVIO_ENTRY_UNKNOWN;
        break;
    }

    entry->size = dirent->st.smb2_size;
    entry->modification_timestamp = INT64_C(1000000) * dirent->st.smb2_mtime;
    entry->access_timestamp       = INT64_C(1000000) * dirent->st.smb2_atime;

    return 0;
}

static int libsmb2_close_dir(URLContext *h)
{
    LIBSMB2Context *ctx = h->priv_data;
    if (ctx->dir) {
        smb2_closedir(ctx->smb2, ctx->dir);
        ctx->dir = NULL;
    }
    libsmb2_disconnect(h);
    return 0;
}

#define OFFSET(x) offsetof(LIBSMB2Context, x)
#define D AV_OPT_FLAG_DECODING_PARAM
#define E AV_OPT_FLAG_ENCODING_PARAM
static const AVOption options[] = {
    {"timeout",  "set timeout in microseconds of socket I/O operations", OFFSET(timeout),  AV_OPT_TYPE_INT,    {.i64 = 0}, 0, INT_MAX, D|E },
    {"password", "set SMB2 password",                          OFFSET(password), AV_OPT_TYPE_STRING, {0},        0, 0,       D|E },
    {NULL}
};

static const AVClass libsmb2_context_class = {
    .class_name     = "libsmb2",
    .item_name      = av_default_item_name,
    .option         = options,
    .version        = LIBAVUTIL_VERSION_INT,
};

const URLProtocol ff_libsmb2_protocol = {
    .name                = "smb2",
    .url_open            = libsmb2_open,
    .url_read            = libsmb2_read,
    .url_write           = libsmb2_write,
    .url_seek            = libsmb2_seek,
    .url_close           = libsmb2_close,
    .url_open_dir        = libsmb2_open_dir,
    .url_read_dir        = libsmb2_read_dir,
    .url_close_dir       = libsmb2_close_dir,
    .priv_data_size      = sizeof(LIBSMB2Context),
    .priv_data_class     = &libsmb2_context_class,
    .flags               = URL_PROTOCOL_FLAG_NETWORK,
};
