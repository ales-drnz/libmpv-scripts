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
import sys, os, re, shutil


# Idempotency marker — re-running the build pipeline against the same
# extracted ffmpeg tree is safe.
MARKER = 'MAK_LIBSMB2_PATCH_V1'


def patch_configure(path):
    with open(path) as f:
        text = f.read()

    if MARKER in text:
        print(f'Already patched: {path}')
        return

    # 1. Add help text after the libsmbclient line.
    text = text.replace(
        '  --enable-libsmbclient    enable Samba protocol via libsmbclient [no]',
        '  --enable-libsmbclient    enable Samba protocol via libsmbclient [no]\n'
        '  --enable-libsmb2         enable SMB2/3 protocol via libsmb2 [no]'
    )

    # 2. Add libsmb2 to EXTERNAL_LIBRARY_LIST (NOT GPL — libsmb2 is LGPL)
    #    Insert after the line containing 'libsmbclient' inside
    #    EXTERNAL_LIBRARY_GPLV3_LIST, but we need the NON-GPL list.
    #    Find the EXTERNAL_LIBRARY_LIST block and add libsmb2.
    #    The safest approach: add it right after 'libshine' or similar entry
    #    that is in EXTERNAL_LIBRARY_LIST (not GPL).
    # Add libsmb2 to EXTERNAL_LIBRARY_LIST (NOT GPL — libsmb2 is LGPL)
    if '    libsmb2\n' not in text:
        text = text.replace(
            '    libshine\n',
            '    libshine\n    libsmb2\n'
        )

    # 3. Add protocol dependency (NOT gpl — this is the key difference).
    #    The MARKER bash comment alongside the dep declaration is what the
    #    early-return at the top of patch_configure() greps for.
    smbclient_dep = 'libsmbclient_protocol_deps="libsmbclient gplv3"'
    if 'libsmb2_protocol_deps' not in text:
        text = text.replace(
            smbclient_dep,
            smbclient_dep + '\n# ' + MARKER + '\n' +
            'libsmb2_protocol_deps="libsmb2"'
        )

    # 4. Add pkg-config check after the libsmbclient check
    smbclient_check = 'enabled libsmbclient'
    idx = text.find(smbclient_check)
    if idx != -1 and 'enabled libsmb2' not in text:
        # Find the end of the libsmbclient check block (next blank line or next 'enabled')
        end_idx = text.find('\n\n', idx)
        if end_idx == -1:
            end_idx = text.find('\nenabled ', idx + len(smbclient_check))
        if end_idx != -1:
            insert = ('\nenabled libsmb2           && { check_pkg_config libsmb2 libsmb2 '
                      'smb2/libsmb2.h smb2_init_context ||\n'
                      '                               require libsmb2 smb2/libsmb2.h '
                      'smb2_init_context -lsmb2; }')
            text = text[:end_idx] + insert + text[end_idx:]

    with open(path, 'w') as f:
        f.write(text)
    print(f"Patched: {path}")


def patch_makefile(path):
    with open(path) as f:
        text = f.read()

    if 'CONFIG_LIBSMB2_PROTOCOL' in text:
        print(f"Already patched: {path}")
        return

    # Add after libsmbclient line (use regex for flexible whitespace)
    text = re.sub(
        r'(OBJS-\$\(CONFIG_LIBSMBCLIENT_PROTOCOL\)\s+\+= libsmbclient\.o)',
        r'\1\nOBJS-$(CONFIG_LIBSMB2_PROTOCOL)              += libsmb2.o',
        text
    )

    with open(path, 'w') as f:
        f.write(text)
    print(f"Patched: {path}")


def patch_protocols(path):
    with open(path) as f:
        text = f.read()

    if 'ff_libsmb2_protocol' in text:
        print(f"Already patched: {path}")
        return

    # Add extern declaration after libsmbclient
    text = text.replace(
        'extern const URLProtocol ff_libsmbclient_protocol;',
        'extern const URLProtocol ff_libsmbclient_protocol;\n'
        'extern const URLProtocol ff_libsmb2_protocol;'
    )

    with open(path, 'w') as f:
        f.write(text)
    print(f"Patched: {path}")


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <ffmpeg_src_dir> <libsmb2_c_path>")
        sys.exit(1)

    ffmpeg_dir = sys.argv[1]
    libsmb2_c = sys.argv[2]

    patch_configure(os.path.join(ffmpeg_dir, 'configure'))
    patch_makefile(os.path.join(ffmpeg_dir, 'libavformat', 'Makefile'))
    patch_protocols(os.path.join(ffmpeg_dir, 'libavformat', 'protocols.c'))

    # Copy libsmb2.c into libavformat/
    dest = os.path.join(ffmpeg_dir, 'libavformat', 'libsmb2.c')
    shutil.copy2(libsmb2_c, dest)
    print(f"Copied: {libsmb2_c} -> {dest}")


if __name__ == '__main__':
    main()
