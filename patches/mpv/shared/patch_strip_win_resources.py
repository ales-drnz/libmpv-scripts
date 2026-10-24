#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Drop the Windows resource compilation from mpv's meson.build.

mpv compiles `osdep/mpv.rc`, which embeds the mpv icon (`etc/mpv-icon.ico`,
~267 KB) + the player manifest + version info into the binary's PE `.rsrc`
section. Those are only meaningful for the mpv.exe *player*; in a libmpv
*library* DLL they are pure dead weight (the host app supplies its own icon
and manifest). Removing the one `sources += windows.compile_resources(...)`
statement drops ~267 KB from each Windows DLL.

No-op on non-Windows (the statement lives inside mpv's `if win32` block and
never runs there), so it is safe to apply unconditionally from
apply_mpv_patches_common. Idempotent. Usage: patch_strip_win_resources.py <mpv_dir>
"""
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = "# MAK_WIN_RESOURCES_STRIPPED"

# The whole `sources += windows.compile_resources('osdep/mpv.rc' ... )`
# statement, tolerant of its multi-line layout / indentation.
STATEMENT = re.compile(
    r"[ \t]*sources \+= windows\.compile_resources\('osdep/mpv\.rc'.*?\)\n",
    re.DOTALL,
)
REPLACEMENT = (
    "    " + MARKER + " — icon/manifest/version dropped for the audio-only DLL\n"
)


def apply(p):
    if p.marked("meson.build"):
        print("Already patched: meson.build (Windows resources)")
        return
    p.regex("meson.build", STATEMENT, REPLACEMENT,
            "compile_resources('osdep/mpv.rc')")


anchor.main(apply, "patch_strip_win_resources", marker=MARKER,
            usage="<mpv_source_dir>")
