// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// webio_log_test: what patches/ffmpeg/webio/webio_log.h leaves of a URL in
// a log line (F5-14). webio.c runs in the web build only; this builds its
// redaction for the host. r24 logs the URL as it is: the query with the
// session of a music server (Subsonic's u, t and s, an api_key), the
// signed URL of a redirect, and the userinfo when it could not be turned
// into a header.
#include <stdio.h>
#include <string.h>

#include "../../../patches/ffmpeg/webio/webio_log.h"

static int failures;

static void expect(const char *in, const char *want)
{
    char out[256];
    webio_redact(out, sizeof(out), in);
    int ok = !strcmp(out, want);
    printf("%s %s\n     -> %s\n", ok ? "ok  " : "FAIL", in, out);
    if (!ok)
        printf("     want %s\n", want);
    failures += !ok;
}

int main(void)
{
    expect("https://music.example/rest/stream.view?u=joe&t=26719a1196d2a940705a59634eb18eab&s=c19b2d&id=7",
           "https://music.example/rest/stream.view?...");
    expect("https://joe:secret@music.example:4533/a/b.flac",
           "https://music.example:4533/a/b.flac");
    expect("http://joe:p%40ss@h/x?api_key=abc#frag", "http://h/x?...");
    expect("http://h/a@b.flac#t=10", "http://h/a@b.flac#...");
    expect("http://h/plain.flac", "http://h/plain.flac");
    // The messages of mak_webio.js, the URL a word of its own.
    expect("webio: https://h/v?api_key=abc: HTTP 404 Not Found",
           "webio: https://h/v?...: HTTP 404 Not Found");
    expect("webio: https://cdn.example/f?X-Amz-Signature=abc: HTTP 403, asked again at https://h/v?token=xyz",
           "webio: https://cdn.example/f?...: HTTP 403, asked again at https://h/v?...");
    expect("webio: the browser does not send Cookie; webio: https://u:p@h/v?k=1; x",
           "webio: the browser does not send Cookie; webio: https://h/v?...; x");
    expect("webio: blob:https://app.example/7f1c: the blob cannot be read",
           "webio: blob:https://app.example/7f1c: the blob cannot be read");
    expect("webio: the connection broke", "webio: the connection broke");
    // A short buffer ends the line early, terminated.
    char small[16];
    webio_redact(small, sizeof(small), "webio: https://h/v?api_key=abc");
    int ok = strlen(small) == 15 && !strstr(small, "api");
    printf("%s a 16-byte buffer: %s\n", ok ? "ok  " : "FAIL", small);
    failures += !ok;
    printf(failures ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", failures);
    return failures ? 1 : 0;
}
