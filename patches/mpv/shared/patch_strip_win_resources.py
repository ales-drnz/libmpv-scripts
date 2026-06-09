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
import os
import re
import sys

MARKER = "# MAK_WIN_RESOURCES_STRIPPED"


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: patch_strip_win_resources.py <mpv_source_dir>")
    mb = os.path.join(sys.argv[1], "meson.build")
    with open(mb, encoding="utf-8") as f:
        text = f.read()

    if MARKER in text:
        print("Already patched: meson.build (Windows resources)")
        return

    # Match the whole `sources += windows.compile_resources('osdep/mpv.rc' ... )`
    # statement, tolerant of its multi-line layout / indentation.
    pat = re.compile(
        r"[ \t]*sources \+= windows\.compile_resources\('osdep/mpv\.rc'.*?\)\n",
        re.DOTALL,
    )
    new_text, n = pat.subn(
        "    " + MARKER + " — icon/manifest/version dropped for the audio-only DLL\n",
        text, count=1)
    if n != 1:
        raise SystemExit(
            "patch_strip_win_resources: compile_resources('osdep/mpv.rc') anchor "
            "not found in meson.build — mpv source layout changed.")

    with open(mb, "w", encoding="utf-8") as f:
        f.write(new_text)
    print("Patched: meson.build (dropped Windows icon/manifest/version resources)")


if __name__ == "__main__":
    main()
