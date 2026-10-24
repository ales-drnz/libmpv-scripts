#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Patches FFmpeg source tree to add --enable-libsmb2 support.

Modifies:
  - configure            (add option, dep, pkg-config check)
  - libavformat/Makefile (add object)
  - libavformat/protocols.c (add extern declaration)

Also copies libsmb2.c into libavformat/.

Usage:
    python3 patch_ffmpeg_libsmb2.py <ffmpeg_source_dir> <libsmb2_c_path>
"""
import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402


# Idempotency marker — re-running the build pipeline against the same
# extracted ffmpeg tree is safe.
MARKER = 'MAK_LIBSMB2_PATCH_V1'

CONFIGURE = 'configure'
MAKEFILE = 'libavformat/Makefile'
PROTOCOLS = 'libavformat/protocols.c'


def patch_configure(p):
    if p.marked(CONFIGURE):
        print(f'Already patched: {CONFIGURE}')
        return

    # 1. Add help text after the libsmbclient line.
    help_line = '  --enable-libsmbclient    enable Samba protocol via libsmbclient [no]'
    p.edit(CONFIGURE, help_line,
           help_line + '\n'
           '  --enable-libsmb2         enable SMB2/3 protocol via libsmb2 [no]')

    # 2. Add libsmb2 to EXTERNAL_LIBRARY_LIST (NOT GPL — libsmb2 is LGPL),
    #    right after 'libshine', which is in that list and not in a GPL one.
    if '    libsmb2\n' not in p.text(CONFIGURE):
        p.edit(CONFIGURE, '    libshine\n', '    libshine\n    libsmb2\n')

    # 3. Add protocol dependency (NOT gpl — this is the key difference).
    #    The MARKER bash comment alongside the dep declaration is what the
    #    check at the top of patch_configure() greps for.
    smbclient_dep = 'libsmbclient_protocol_deps="libsmbclient gplv3"'
    if 'libsmb2_protocol_deps' not in p.text(CONFIGURE):
        p.edit(CONFIGURE, smbclient_dep,
               smbclient_dep + '\n# ' + MARKER + '\n' +
               'libsmb2_protocol_deps="libsmb2"')

    # 4. Add pkg-config check after the libsmbclient check
    smbclient_check = 'enabled libsmbclient'
    text = p.text(CONFIGURE)
    if 'enabled libsmb2' not in text and p.find(CONFIGURE, smbclient_check):
        idx = text.find(smbclient_check)
        # Find the end of the libsmbclient check block (next blank line or next 'enabled')
        end_idx = text.find('\n\n', idx)
        if end_idx == -1:
            end_idx = text.find('\nenabled ', idx + len(smbclient_check))
        if end_idx == -1:
            p.fail(f'{CONFIGURE}: end of the libsmbclient check block not found')
            return
        insert = ('\nenabled libsmb2           && { check_pkg_config libsmb2 libsmb2 '
                  'smb2/libsmb2.h smb2_init_context ||\n'
                  '                               require libsmb2 smb2/libsmb2.h '
                  'smb2_init_context -lsmb2; }')
        p.write(CONFIGURE, text[:end_idx] + insert + text[end_idx:])


def patch_makefile(p):
    if 'CONFIG_LIBSMB2_PROTOCOL' in p.text(MAKEFILE):
        print(f'Already patched: {MAKEFILE}')
        return
    # Add after libsmbclient line (use regex for flexible whitespace)
    p.regex(MAKEFILE,
            r'(OBJS-\$\(CONFIG_LIBSMBCLIENT_PROTOCOL\)\s+\+= libsmbclient\.o)',
            r'\1\nOBJS-$(CONFIG_LIBSMB2_PROTOCOL)              += libsmb2.o',
            'libsmbclient.o OBJS line')


def patch_protocols(p):
    if 'ff_libsmb2_protocol' in p.text(PROTOCOLS):
        print(f'Already patched: {PROTOCOLS}')
        return
    # Add extern declaration after libsmbclient
    p.edit(PROTOCOLS,
           'extern const URLProtocol ff_libsmbclient_protocol;',
           'extern const URLProtocol ff_libsmbclient_protocol;\n'
           'extern const URLProtocol ff_libsmb2_protocol;')


def apply(p, libsmb2_c):
    patch_configure(p)
    patch_makefile(p)
    patch_protocols(p)
    # Copy libsmb2.c into libavformat/.
    if not os.path.isfile(libsmb2_c):
        p.fail(f'libsmb2.c not found: {libsmb2_c}')
        return
    with open(libsmb2_c, encoding='utf-8') as f:
        p.new_file('libavformat/libsmb2.c', f.read(), force=True)


# A missing or repeated anchor means the FFmpeg layout changed, and a silent
# no-op would build without SMB.
anchor.main(apply, 'patch_ffmpeg_libsmb2', marker=MARKER,
            usage='<ffmpeg_src_dir> <libsmb2_c_path>', nargs=2)
