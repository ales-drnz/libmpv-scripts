# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Compile osdep/utils-mac.c unconditionally on Darwin.

In upstream mpv, utils-mac.c is only compiled under 'if features["cocoa"]', but
we disable Cocoa (to avoid the swift.h dependency). Without this file the symbols
cfstr_from_cstr / cfstr_get_cstr are left undefined and CoreAudio AO crashes.

Used on macOS and iOS.
"""
import sys
import re

fn = sys.argv[1]  # path to meson.build

with open(fn) as f:
    content = f.read()

if 'utils-mac-unconditional-patched' in content:
    print("Already patched, skipping")
    sys.exit(0)

# Remove 'osdep/utils-mac.c' from the cocoa-conditional block — exactly
# once. A counted assertion turns a future meson reshuffle (where the
# entry moved or vanished) into a hard failure instead of a silent
# partial apply. `[ \t]` (not `\s`) so the class can't span lines.
content, n_removed = re.subn(
    r"^[ \t]+'osdep/utils-mac\.c',\n", "", content, flags=re.MULTILINE)
if n_removed != 1:
    sys.exit(
        f"[patch_utils_mac] expected exactly one 'osdep/utils-mac.c' list "
        f"entry to remove, found {n_removed} — meson.build layout changed"
    )

# Insert it unconditionally inside the canonical Darwin osdep block, right
# after the (unique) timer-darwin source line. Anchoring on this Darwin-
# semantic line keeps the addition in the correct section and decouples it
# from the (unrelated) cocoa dependency declaration.
anchor = "    timer_source = files('osdep/timer-darwin.c')\n"
patch = anchor + (
    "    # utils-mac-unconditional-patched\n"
    "    # Always compile on Darwin: provides cfstr_from_cstr / cfstr_get_cstr\n"
    "    # (needed by ao_coreaudio even when the Cocoa UI is disabled)\n"
    "    sources += files('osdep/utils-mac.c')\n"
)
if anchor not in content:
    sys.exit(
        "[patch_utils_mac] Darwin timer-darwin source anchor not found — "
        "meson.build layout changed"
    )
content = content.replace(anchor, patch, 1)

with open(fn, 'w') as f:
    f.write(content)
print("Patched meson.build: osdep/utils-mac.c compiled unconditionally on Darwin")
