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


# A missing anchor means the FFmpeg layout changed: the web build would have
# no http at all, so it fails here.
anchor.main(apply, 'patch_ffmpeg_webio', marker=MARKER)
