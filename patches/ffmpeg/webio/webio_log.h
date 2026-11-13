/* MAK_WEBIO_PATCH_V2: what webio.c writes of a URL to the log.
 *
 * A log line is kept, shown and sent around: it must not carry what a URL
 * holds of a secret. That is its userinfo ("user:password@") and its query,
 * where the music servers put the session (Subsonic's u, t and s, an
 * api_key, the signature of a redirect to a CDN). The scheme, the host and
 * the path stay, which is what tells the requests apart. */
#ifndef AVFORMAT_WEBIO_LOG_H
#define AVFORMAT_WEBIO_LOG_H

#include <stddef.h>
#include <string.h>

/* Copies [msg] to [dst] ([size] bytes, always terminated) with every URL in
 * it (a word with "://") cut down: the userinfo dropped, the query replaced
 * with "?..." and the fragment with "#...". The messages come from webio.c
 * and from mak_webio.js, which write a URL as a word of its own, followed
 * by a space, a ':' or a ';': that mark is kept. */
static void webio_redact(char *dst, size_t size, const char *msg)
{
    size_t o = 0;
    if (!size)
        return;
/* [ch] is read once, also when the buffer is full. */
#define WEBIO_PUT(ch) do { char c_ = (ch); if (o + 1 < size) dst[o++] = c_; } while (0)
    for (const char *p = msg ? msg : ""; *p;) {
        if (strncmp(p, "://", 3) != 0) {
            WEBIO_PUT(*p++);
            continue;
        }
        WEBIO_PUT(*p++); WEBIO_PUT(*p++); WEBIO_PUT(*p++);
        const char *end = p + strcspn(p, " \t\r\n");
        const char *auth_end = p + strcspn(p, "/?# \t\r\n");
        for (const char *q = p; q < auth_end; q++) {
            if (*q == '@')
                p = q + 1;
        }
        while (p < end && *p != '?' && *p != '#')
            WEBIO_PUT(*p++);
        if (p < end) {
            WEBIO_PUT(*p);
            WEBIO_PUT('.'); WEBIO_PUT('.'); WEBIO_PUT('.');
            if (strchr(":;,)", end[-1]) && end - 1 > p)
                WEBIO_PUT(end[-1]);
            p = end;
        }
    }
#undef WEBIO_PUT
    dst[o] = 0;
}

#endif
