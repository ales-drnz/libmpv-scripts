#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Adds the webio protocols to FFmpeg, for the web build only: http, https and
makblob read through fetch in the browser (webio/webio.c, with its JS side
in scripts/web/mak_webio.js, linked by build_libmpv_web.sh).

Modifies:
  - libavformat/protocols.c (three extern declarations, which configure
                             reads as the protocols webio_http, webio_https
                             and webio_makblob)
  - libavformat/Makefile    (the object)
  - libavformat/hls.c and, with the dash_keepalive patch, dashdec.c: no
    persistent HTTP by default without http.c, and the keep-alive helper
    closes the connection it cannot reuse. It returned an error and left
    *pb open, and the caller opened a new one over it: every segment and
    playlist reload leaked a stream (mpv: "Leaking 3 nested connections").
    fetch keeps the connections alive by itself.

Copies webio/webio.c into libavformat/.

Usage:
    python3 patch_ffmpeg_webio.py <ffmpeg_source_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402

MARKER = 'MAK_WEBIO_PATCH_V1'

PROTOCOLS = 'libavformat/protocols.c'
MAKEFILE = 'libavformat/Makefile'


def apply(p):
    p.edits(PROTOCOLS, [(
        'extern const URLProtocol ff_ipns_gateway_protocol;\n',
        'extern const URLProtocol ff_ipns_gateway_protocol;\n'
        f'/* {MARKER}: http, https and makblob through fetch (web build) */\n'
        'extern const URLProtocol ff_webio_http_protocol;\n'
        'extern const URLProtocol ff_webio_https_protocol;\n'
        'extern const URLProtocol ff_webio_makblob_protocol;\n',
    )])
    p.edits(MAKEFILE, [(
        'OBJS-$(CONFIG_LIBZMQ_PROTOCOL)           += libzmq.o\n',
        'OBJS-$(CONFIG_LIBZMQ_PROTOCOL)           += libzmq.o\n'
        f'# {MARKER}\n'
        'OBJS-$(CONFIG_WEBIO_HTTP_PROTOCOL)       += webio.o\n'
        'OBJS-$(CONFIG_WEBIO_HTTPS_PROTOCOL)      += webio.o\n'
        'OBJS-$(CONFIG_WEBIO_MAKBLOB_PROTOCOL)    += webio.o\n',
    )])
    p.new_file('libavformat/webio.c', p.asset('webio/webio.c'))
    no_keepalive(p, 'libavformat/hls.c')
    # dashdec.c has the helper and the option only with dash_keepalive.
    if p.marked('libavformat/dashdec.c', 'MAK_DASH_KEEPALIVE_V1'):
        no_keepalive(p, 'libavformat/dashdec.c')


KEEPALIVE_STUB = """#if !CONFIG_HTTP_PROTOCOL
    return AVERROR_PROTOCOL_NOT_FOUND;
#else"""
PERSISTENT = """OFFSET(http_persistent), AV_OPT_TYPE_BOOL, {.i64 = 1}, 0, 1, FLAGS },"""


def no_keepalive(p, rel):
    p.edits(rel, [
        ('open_url_keepalive without http.c', KEEPALIVE_STUB,
         f"""#if !CONFIG_HTTP_PROTOCOL
    /* {MARKER}: no request on the same connection without http.c; the
     * caller opens a new one in *pb, so this one must not stay open. */
    ff_format_io_close(s, pb);
    return AVERROR_PROTOCOL_NOT_FOUND;
#else"""),
        ('http_persistent default', PERSISTENT,
         """OFFSET(http_persistent), AV_OPT_TYPE_BOOL, {.i64 = CONFIG_HTTP_PROTOCOL}, 0, 1, FLAGS },"""),
    ])


# A missing anchor means the FFmpeg layout changed: the web build would have
# no http at all, so it fails here.
anchor.main(apply, 'patch_ffmpeg_webio', marker=MARKER)
