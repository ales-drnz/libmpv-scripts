// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The embedded CA bundle of patch_ffmpeg_embed_cacert.py loads only when
// TLS verification is on (F90). network_test.sh links this against its
// static FFmpeg with --wrap=PEM_read_bio_X509 and
// --wrap=SSL_CTX_set_default_verify_paths, so it counts the PEM roots
// FFmpeg parses and the system stores it loads, and runs it against an
// openssl s_server with a self signed certificate.
//   verify=0: no root parsed and no system store (r17: 121 roots and one
//             store on every handshake).
//   verify=1: the bundle and the system store load and the self signed
//             server is refused; with ca_file set to its certificate it is
//             accepted; an empty ca_file means the bundle again.
//   ca_extra_file (patch_ffmpeg_tls_extra_ca.py): the server's certificate
//             as ca_extra_file opens it with the bundle still loaded, on
//             top of a ca_file too; a missing file leaves the refusal; with
//             verify=0 nothing is read.
//
// Usage: tls_roots_test <port> <server certificate> <other certificate>
#include <stdio.h>
#include <stdlib.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/dict.h>

static long pem_reads, default_paths;
X509 *__real_PEM_read_bio_X509(BIO *bp, X509 **x, pem_password_cb *cb, void *u);
X509 *__wrap_PEM_read_bio_X509(BIO *bp, X509 **x, pem_password_cb *cb, void *u)
{
    X509 *r = __real_PEM_read_bio_X509(bp, x, cb, u);
    if (r)
        pem_reads++;
    return r;
}
int __real_SSL_CTX_set_default_verify_paths(SSL_CTX *ctx);
int __wrap_SSL_CTX_set_default_verify_paths(SSL_CTX *ctx)
{
    default_paths++;
    return __real_SSL_CTX_set_default_verify_paths(ctx);
}

static int open_with(int port, int verify, const char *ca_file,
                     const char *ca_extra_file)
{
    char url[64];
    AVIOContext *io = NULL;
    AVDictionary *opts = NULL;
    snprintf(url, sizeof url, "tls://127.0.0.1:%d", port);
    av_dict_set(&opts, "tls_verify", verify ? "1" : "0", 0);
    if (ca_file)
        av_dict_set(&opts, "ca_file", ca_file, 0);
    if (ca_extra_file)
        av_dict_set(&opts, "ca_extra_file", ca_extra_file, 0);
    int r = avio_open2(&io, url, AVIO_FLAG_READ, NULL, &opts);
    av_dict_free(&opts);
    if (r >= 0)
        avio_closep(&io);
    return r;
}

static int open_once(int port, int verify, const char *ca_file)
{
    return open_with(port, verify, ca_file, NULL);
}

static int fails;
static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fails += !ok;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s <port> <server certificate> <other certificate>\n",
                argv[0]);
        return 2;
    }
    int port = atoi(argv[1]);
    setvbuf(stdout, NULL, _IOLBF, 0);
    avformat_network_init();

    long p0 = pem_reads, d0 = default_paths;
    int r = open_once(port, 0, NULL);
    printf("verify=0: open %d, %ld roots parsed, %ld system stores\n",
           r, pem_reads - p0, default_paths - d0);
    check(r >= 0, "verify=0 opens the self signed server");
    check(pem_reads == p0, "verify=0 parses no embedded root");
    check(default_paths == d0, "verify=0 loads no system store");

    p0 = pem_reads, d0 = default_paths;
    r = open_once(port, 1, NULL);
    printf("verify=1: open %d, %ld roots parsed, %ld system stores\n",
           r, pem_reads - p0, default_paths - d0);
    check(r < 0, "verify=1 refuses the self signed server");
    check(pem_reads - p0 > 100, "verify=1 parses the embedded roots");
    check(default_paths - d0 == 1, "verify=1 loads the system store");

    r = open_once(port, 1, argv[2]);
    check(r >= 0, "verify=1 with ca_file of the server opens");
    p0 = pem_reads;
    r = open_once(port, 1, "");
    printf("verify=1, ca_file \"\": open %d, %ld roots parsed\n", r, pem_reads - p0);
    check(r < 0 && pem_reads - p0 > 100,
          "verify=1 with an empty ca_file uses the bundle and refuses");

    p0 = pem_reads, d0 = default_paths;
    r = open_with(port, 1, NULL, argv[2]);
    printf("verify=1, ca_extra_file: open %d, %ld roots parsed, %ld system stores\n",
           r, pem_reads - p0, default_paths - d0);
    check(r >= 0, "verify=1 with ca_extra_file of the server opens");
    check(pem_reads - p0 > 100 && default_paths - d0 == 1,
          "ca_extra_file keeps the embedded roots and the system store");

    r = open_with(port, 1, argv[3], NULL);
    check(r < 0, "verify=1 with ca_file of another certificate refuses");
    r = open_with(port, 1, argv[3], argv[2]);
    check(r >= 0, "ca_extra_file trusts the server on top of a ca_file too");

    r = open_with(port, 1, NULL, "/nonexistent/extra.pem");
    check(r < 0, "a ca_extra_file that cannot be read leaves the refusal");

    p0 = pem_reads, d0 = default_paths;
    r = open_with(port, 0, NULL, argv[2]);
    check(r >= 0 && pem_reads == p0 && default_paths == d0,
          "verify=0 with ca_extra_file reads nothing");

    avformat_network_deinit();
    if (fails)
        printf("RESULT FAIL (%d)\n", fails);
    else
        printf("RESULT PASS\n");
    return fails ? 1 : 0;
}
