/*
 * Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
 */

/*
 * SMB2/3 protocol handler using libsmb2 (LGPL)
 *
 * Copyright (c) 2026
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
#include "url.h"

typedef struct {
    const AVClass *class;
    struct smb2_context *smb2;
    struct smb2fh *fh;
    struct smb2dir *dir;
    int64_t filesize;
    int timeout;
    char *password;
} LIBSMB2Context;

/**
 * Percent-decode a string in-place (e.g. %26 -> &).
 */
static void percent_decode(char *s)
{
    char *r = s, *w = s;
    while (*r) {
        if (*r == '%' && r[1] && r[2]) {
            char hex[3] = { r[1], r[2], 0 };
            *w++ = (char)strtol(hex, NULL, 16);
            r += 3;
        } else {
            *w++ = *r++;
        }
    }
    *w = '\0';
}

/**
 * Build a cleaned URL with the :password portion stripped out, and
 * extract the password separately (percent-decoded).
 *
 * Input:  smb2://[domain;]user:password@server/share/path
 * Output: clean_url = smb2://[domain;]user@server/share/path
 *         password  = decoded password (caller must av_free)
 */
static char *strip_password_from_url(const char *url, char **out_password)
{
    const char *scheme_end, *auth_start, *at_sign, *colon;
    char *clean;

    *out_password = NULL;

    scheme_end = strstr(url, "://");
    if (!scheme_end)
        return av_strdup(url);
    auth_start = scheme_end + 3;

    /* skip optional domain; prefix */
    {
        const char *semi = strchr(auth_start, ';');
        const char *slash = strchr(auth_start, '/');
        if (semi && (!slash || semi < slash))
            auth_start = semi + 1;
    }

    at_sign = strchr(auth_start, '@');
    if (!at_sign)
        return av_strdup(url);

    colon = strchr(auth_start, ':');
    if (!colon || colon > at_sign)
        return av_strdup(url);

    /* Extract and decode password */
    *out_password = av_strndup(colon + 1, at_sign - colon - 1);
    if (*out_password)
        percent_decode(*out_password);

    /* Build clean URL: everything before ':' + everything from '@' onwards */
    {
        int prefix_len = (int)(colon - url);
        int suffix_len = (int)strlen(at_sign);
        clean = av_malloc(prefix_len + suffix_len + 1);
        if (!clean)
            return NULL;
        memcpy(clean, url, prefix_len);
        memcpy(clean + prefix_len, at_sign, suffix_len);
        clean[prefix_len + suffix_len] = '\0';
    }
    return clean;
}

static av_cold int libsmb2_close(URLContext *h)
{
    LIBSMB2Context *ctx = h->priv_data;
    if (ctx->fh) {
        smb2_close(ctx->smb2, ctx->fh);
        ctx->fh = NULL;
    }
    if (ctx->dir) {
        smb2_closedir(ctx->smb2, ctx->dir);
        ctx->dir = NULL;
    }
    if (ctx->smb2) {
        smb2_disconnect_share(ctx->smb2);
        smb2_destroy_context(ctx->smb2);
        ctx->smb2 = NULL;
    }
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

    if (ctx->timeout > 0)
        smb2_set_timeout(ctx->smb2, ctx->timeout);

    /* Force NTLM authentication — GSSAPI/Kerberos fails in sandboxed apps */
    smb2_set_authentication(ctx->smb2, 1); /* 1 = SMB2_SEC_NTLMSSP */

    /* Strip password from URL before parsing (libsmb2 doesn't handle user:pass@) */
    clean_url = strip_password_from_url(h->filename, &url_password);
    if (!clean_url) {
        ret = AVERROR(ENOMEM);
        goto fail;
    }

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
    if (url->user)
        percent_decode(url->user);
    if (url->domain)
        percent_decode(url->domain);
    if (url->share)
        percent_decode(url->share);
    if (url->path)
        percent_decode(url->path);

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

    ret = smb2_connect_share(ctx->smb2, url->server, url->share, url->user);
    if (ret < 0) {
        av_log(h, AV_LOG_ERROR, "Failed to connect to SMB2 share: %s\n",
               smb2_get_error(ctx->smb2));
        ret = AVERROR(EIO);
        goto fail;
    }

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

    ctx->fh = smb2_open(ctx->smb2, parsed_url->path, access);
    if (!ctx->fh) {
        av_log(h, AV_LOG_ERROR, "SMB2 file open failed: %s\n",
               smb2_get_error(ctx->smb2));
        smb2_destroy_url(parsed_url);
        libsmb2_close(h);
        return AVERROR(EIO);
    }

    if (smb2_fstat(ctx->smb2, ctx->fh, &st) == 0)
        ctx->filesize = st.smb2_size;

    smb2_destroy_url(parsed_url);
    return 0;
}

static int libsmb2_read(URLContext *h, unsigned char *buf, int size)
{
    LIBSMB2Context *ctx = h->priv_data;
    int bytes_read;

    bytes_read = smb2_read(ctx->smb2, ctx->fh, (uint8_t *)buf, (uint32_t)size);
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

    bytes_written = smb2_write(ctx->smb2, ctx->fh, (const uint8_t *)buf, (uint32_t)size);
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
    int ret;

    if ((ret = libsmb2_connect(h, &parsed_url)) < 0)
        return ret;

    ctx->dir = smb2_opendir(ctx->smb2, parsed_url->path);
    smb2_destroy_url(parsed_url);

    if (!ctx->dir) {
        av_log(h, AV_LOG_ERROR, "SMB2 opendir failed: %s\n",
               smb2_get_error(ctx->smb2));
        libsmb2_close(h);
        return AVERROR(EIO);
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
    if (ctx->smb2) {
        smb2_disconnect_share(ctx->smb2);
        smb2_destroy_context(ctx->smb2);
        ctx->smb2 = NULL;
    }
    return 0;
}

#define OFFSET(x) offsetof(LIBSMB2Context, x)
#define D AV_OPT_FLAG_DECODING_PARAM
#define E AV_OPT_FLAG_ENCODING_PARAM
static const AVOption options[] = {
    {"timeout",  "set timeout in ms of socket I/O operations", OFFSET(timeout),  AV_OPT_TYPE_INT,    {.i64 = 0}, 0, INT_MAX, D|E },
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
