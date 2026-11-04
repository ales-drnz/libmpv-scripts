#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""One place in player/command.c for the properties the patches add.

Every patch that adds a property used to put an include under
`#include "command.h"`, its getters before some getter of mpv and its table
entries after some entry of mp_properties_base[]: three anchors on upstream
text each, any of which an mpv update can move. This patch makes the two
edits of command.c they all need, once, and creates the three files they
now write to instead (see patches/_lib/property_seam.py):

    player/mak_property_headers.inc   included after `#include "command.h"`
    player/mak_property_getters.inc   included just before the table, after
                                      every static of command.c it may use
    player/mak_property_table.inc     included first in the table

Each file ends with an end line that the patches insert before. The seam is
required, not a toggle, and runs before every patch that uses it: with all
the toggles off it only includes three files with nothing in them.

A second run leaves command.c, which carries the marker, and the three
files, which the patches after it may have filled; a file of that name that
does not carry the marker is refused.

Files touched
=============

    player/command.c                  the three includes
    player/mak_property_headers.inc   NEW
    player/mak_property_getters.inc   NEW
    player/mak_property_table.inc     NEW

Usage: patch_property_seam.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402
import property_seam as seam  # noqa: E402

MARKER = seam.MARKER

HEADERS_FILE = (
    '/* ' + MARKER + ' ─── headers of the properties the mak patches add.\n'
    ' * Included by player/command.c after "command.h". Each patch inserts its\n'
    ' * lines before the end line (patches/_lib/property_seam.py). */\n'
    '\n'
    + seam.HEADERS_END
)

GETTERS_FILE = (
    '/* ' + MARKER + ' ─── getters of the properties the mak patches add.\n'
    ' * Included by player/command.c just before mp_properties_base[]: a getter\n'
    ' * sees every static of command.c defined above the table. Each patch\n'
    ' * inserts its functions before the end line\n'
    ' * (patches/_lib/property_seam.py). */\n'
    '\n'
    + seam.GETTERS_END
)

TABLE_FILE = (
    '    /* ' + MARKER + ' ─── entries of mp_properties_base[] the mak\n'
    '     * patches add. Included by player/command.c first in the table. Each\n'
    '     * patch inserts its entries before the end line\n'
    '     * (patches/_lib/property_seam.py). */\n'
    + seam.TABLE_END
)

FILES = [
    (seam.HEADERS, HEADERS_FILE),
    (seam.GETTERS, GETTERS_FILE),
    (seam.TABLE, TABLE_FILE),
]

INCLUDE = '#include "command.h"\n'

INCLUDE_NEW = INCLUDE + (
    '/* ' + MARKER + ' */\n'
    '#include "mak_property_headers.inc"\n'
)

TABLE = 'static const struct m_property mp_properties_base[] = {\n'

TABLE_NEW = (
    '/* ' + MARKER + ' ─── the getters and the table entries of the\n'
    ' * properties the mak patches add. */\n'
    '#include "mak_property_getters.inc"\n'
    + TABLE
    + '#include "mak_property_table.inc"\n'
)


def apply(p):
    for rel, content in FILES:
        if not p.exists(rel):
            p.new_file(rel, content)
        elif not p.marked(rel):
            p.fail(f'{rel}: refusing to overwrite a file this patch did not '
                   f'write')
        # A file of the seam is left as it is: the patches after this one
        # may have filled it.
    p.edits(seam.COMMAND, [
        ('`#include "command.h"`', INCLUDE, INCLUDE_NEW),
        ('mp_properties_base[]', TABLE, TABLE_NEW),
    ])


anchor.main(apply, 'patch_property_seam', marker=MARKER)
