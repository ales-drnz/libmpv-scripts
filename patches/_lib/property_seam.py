# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""The property seam of player/command.c, for the mpv patch scripts.

patch_property_seam.py makes the only edits to player/command.c that a
property needs and creates three files next to it, each included once:

    player/mak_property_headers.inc  after `#include "command.h"`
    player/mak_property_getters.inc  just before mp_properties_base[]
    player/mak_property_table.inc    first in mp_properties_base[]

A patch that adds a property puts its headers, its getters and its table
entries in these files, before the end line of each, with headers(),
getters() and table() below. It anchors on the seam's own lines, never on
upstream text, so an mpv update moves none of these anchors. A getter in
mak_property_getters.inc sees every static of command.c defined above the
table, and nothing above the table can name it.

Each call is skipped when the file already carries the patch's marker, as
Patch.edits() does, so a second run changes nothing. The order of the
entries in the table is the order the patches run in: only property-list
shows it (command_init sorts the names).

Kept to Python 3.8: the Linux build image is Ubuntu 20.04.
"""
from __future__ import annotations

# The marker of the seam: in command.c and in the header of each file.
MARKER = 'MAK_PROPERTY_SEAM_V1'

COMMAND = 'player/command.c'
HEADERS = 'player/mak_property_headers.inc'
GETTERS = 'player/mak_property_getters.inc'
TABLE = 'player/mak_property_table.inc'
FILES = (HEADERS, GETTERS, TABLE)

# The end line of each file: a patch inserts its text just before it.
HEADERS_END = '/* MAK_PROPERTY_SEAM_HEADERS_END */\n'
GETTERS_END = '/* MAK_PROPERTY_SEAM_GETTERS_END */\n'
TABLE_END = '    /* MAK_PROPERTY_SEAM_TABLE_END */\n'


def _add(p, rel, end, text, label, marker):
    if not p.exists(rel):
        p.fail(f'{rel} not found: patch_property_seam.py must run first')
        return False
    return p.edits(rel, [(label, end, text + end)], marker)


def headers(p, text, label='property headers', marker=None):
    """Inserts text (its own lines, ending with a newline) at the end of
    mak_property_headers.inc, unless the file carries marker."""
    return _add(p, HEADERS, HEADERS_END, text, label, marker)


def getters(p, text, label='property getters', marker=None):
    """Inserts text (whole functions, ending with a newline) at the end of
    mak_property_getters.inc, unless the file carries marker."""
    return _add(p, GETTERS, GETTERS_END, text, label, marker)


def table(p, text, label='property table', marker=None):
    """Inserts text (entries of mp_properties_base[], ending with a newline)
    at the end of mak_property_table.inc, unless the file carries marker."""
    return _add(p, TABLE, TABLE_END, text, label, marker)

