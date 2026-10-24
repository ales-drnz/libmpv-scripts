# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Compile osdep/utils-mac.c unconditionally on Darwin.

In upstream mpv, utils-mac.c is only compiled under 'if features["cocoa"]', but
we disable Cocoa (to avoid the swift.h dependency). Without this file the symbols
cfstr_from_cstr / cfstr_get_cstr are left undefined and CoreAudio AO crashes.

Used on macOS and iOS.
"""
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = 'utils-mac-unconditional-patched'

# Inserted unconditionally inside the canonical Darwin osdep block, right
# after the (unique) timer-darwin source line. Anchoring on this Darwin-
# semantic line keeps the addition in the correct section and decouples it
# from the (unrelated) cocoa dependency declaration.
ANCHOR = "    timer_source = files('osdep/timer-darwin.c')\n"
PATCH = ANCHOR + (
    "    # " + MARKER + "\n"
    "    # Always compile on Darwin: provides cfstr_from_cstr / cfstr_get_cstr\n"
    "    # (needed by ao_coreaudio even when the Cocoa UI is disabled)\n"
    "    sources += files('osdep/utils-mac.c')\n"
)


def apply(p, meson):
    if p.marked(meson):
        print('Already patched, skipping')
        return
    # Remove 'osdep/utils-mac.c' from the cocoa-conditional block, exactly
    # once. `[ \t]` (not `\s`) so the class can't span lines.
    p.regex(meson, r"^[ \t]+'osdep/utils-mac\.c',\n", '',
            'osdep/utils-mac.c list entry', flags=re.MULTILINE)
    p.edit(meson, ANCHOR, PATCH, 'Darwin timer-darwin source')


anchor.main(apply, 'patch_utils_mac', marker=MARKER,
            usage='<mpv meson.build>', file_arg=True)
