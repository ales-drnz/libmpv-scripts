#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
"""
Adds the TLS option ``ca_extra_file`` to FFmpeg's OpenSSL backend: a PEM
file of certificates trusted ON TOP of the roots in use, where ``ca_file``
replaces them.

``ca_file`` (mpv's ``tls-ca-file``) loads its file in place of the embedded
Mozilla roots and the system store. An app that streams from both a home
server with a self-signed certificate (or a private CA) and the public
internet cannot use it: with the server's certificate as ``ca_file``, every
public ``https://`` source fails. ``ca_extra_file`` keeps the roots and adds
the file to the same X509 store, so that server is trusted and the others
are verified as before. A self-signed certificate in the store is a trust
anchor of its own, and the host name is still checked against it.

The option rides mpv's ``stream-lavf-o`` (``ca_extra_file=<path>``), which
http passes down to tls in its chained options, and which the analysis of
mpv_audio_kit (mak_scan) copies for its re-opens. Read only when the peer is
verified: with ``tls_verify`` off nothing is loaded. A file that cannot be
read is logged as an error and the handshake goes on with the roots alone,
as for ``ca_file``.

Modifies:
  - libavformat/tls.h         (TLSShared.ca_extra_file, the client option)
  - libavformat/tls_openssl.c (load it after the roots, before the verify)
  - libavformat/rtsp.h, rtsp.c (the other user of FF_TLS_CLIENT_OPTIONS:
                               its tls_opts get the field, and pass it on to
                               tls as they pass ca_file)

Independent of patch_ffmpeg_embed_cacert.py: it anchors after
openssl_init_ca_key_cert, whichever roots that loaded.

Usage:
    python3 patch_ffmpeg_tls_extra_ca.py <ffmpeg_source_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402

MARKER = 'MAK_TLS_EXTRA_CA_V1'

TLS_H = 'libavformat/tls.h'
TLS = 'libavformat/tls_openssl.c'
RTSP_H = 'libavformat/rtsp.h'
RTSP = 'libavformat/rtsp.c'


def apply(p):
    if all(p.marked(f) for f in (TLS_H, TLS, RTSP_H, RTSP)):
        print('Already patched: %s, %s, %s, %s' % (TLS_H, TLS, RTSP_H, RTSP))
        return
    p.edits(TLS_H, [
        ('TLSShared ca_file field',
         '    char *ca_file;\n',
         '    char *ca_file;\n'
         '    /* ' + MARKER + ': trusted on top of the roots in use. */\n'
         '    char *ca_extra_file;\n'),
        ('cafile client option',
         '    {"cafile",     "Certificate Authority database file", '
         'offsetof(pstruct, options_field . ca_file),   AV_OPT_TYPE_STRING, '
         '.flags = TLS_OPTFL }, \\\n',
         '    {"cafile",     "Certificate Authority database file", '
         'offsetof(pstruct, options_field . ca_file),   AV_OPT_TYPE_STRING, '
         '.flags = TLS_OPTFL }, \\\n'
         '    {"ca_extra_file", "Certificates trusted on top of the default '
         'roots (' + MARKER + ')", '
         'offsetof(pstruct, options_field . ca_extra_file), '
         'AV_OPT_TYPE_STRING, .flags = TLS_OPTFL }, \\\n'),
    ], marker=MARKER)
    p.edits(TLS, [
        ('after openssl_init_ca_key_cert',
         '    ret = openssl_init_ca_key_cert(h);\n'
         '    if (ret < 0) goto fail;\n',
         '    ret = openssl_init_ca_key_cert(h);\n'
         '    if (ret < 0) goto fail;\n'
         '    /* ' + MARKER + ': ca_extra_file joins the roots loaded above,\n'
         '     * where ca_file replaces them. Read only when the peer is\n'
         '     * verified, as the roots are. */\n'
         '    if (s->verify && s->ca_extra_file && s->ca_extra_file[0] &&\n'
         '        !SSL_CTX_load_verify_locations(c->ctx, s->ca_extra_file, NULL))\n'
         '        av_log(h, AV_LOG_ERROR, "ca_extra_file %s: %s\\n",\n'
         '               s->ca_extra_file, openssl_get_error(c));\n'),
    ], marker=MARKER)
    p.edits(RTSP_H, [
        ('RTSPState tls_opts',
         '    struct {\n'
         '        char *ca_file;\n'
         '        int verify;\n',
         '    struct {\n'
         '        char *ca_file;\n'
         '        char *ca_extra_file; /* ' + MARKER + ' */\n'
         '        int verify;\n'),
    ], marker=MARKER)
    p.edits(RTSP, [
        ('copy_tls_opts_dict',
         '    ERR_RET(av_dict_set(dict, "ca_file", rt->tls_opts.ca_file, 0));\n',
         '    ERR_RET(av_dict_set(dict, "ca_file", rt->tls_opts.ca_file, 0));\n'
         '    /* ' + MARKER + ' */\n'
         '    ERR_RET(av_dict_set(dict, "ca_extra_file", rt->tls_opts.ca_extra_file, 0));\n'),
    ], marker=MARKER)


anchor.main(apply, 'patch_ffmpeg_tls_extra_ca', marker=MARKER,
            usage='<ffmpeg_src_dir>')
