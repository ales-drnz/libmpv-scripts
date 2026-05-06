# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Make the win32-desktop system libs optional for MinGW cross-compile.

The MinGW sysroot does not always expose these Windows system libraries
in a way meson's cc.find_library() can locate, so we mark them
`required: false` and pass them explicitly via c_link_args /
cpp_link_args instead (see WIN_SYS_LIBS in build_libmpv_windows.sh).

The rewrite is restricted to an explicit allow-list of the win32-desktop
libs. A blanket `cc.find_library()` sweep would also rewrite unrelated
calls — `android`, `atomic`, `m`, `rt`, `OpenSLES`, `EGL`, `windowsapp` —
which live behind their own platform guards and must not be made
optional here.
"""
import sys
import re

fn = sys.argv[1]  # path to meson.build
with open(fn) as f:
    content = f.read()

# The win32-desktop system libs meson probes with cc.find_library() (mpv
# meson.build, `if features['win32-desktop']` block). Includes pathcch.
WIN32_DESKTOP_LIBS = [
    "avrt", "dwmapi", "gdi32", "imm32", "ntdll", "ole32",
    "pathcch", "shcore", "user32", "uuid", "uxtheme", "version",
]

# Idempotent: if the first lib is already optional, the patch ran before.
if "cc.find_library('avrt', required: false)" in content:
    print(f"Nothing to patch in {fn} (already patched)")
    sys.exit(0)

hits = 0
for lib in WIN32_DESKTOP_LIBS:
    content, n = re.subn(
        rf"cc\.find_library\('{lib}'\)",
        f"cc.find_library('{lib}', required: false)",
        content,
    )
    hits += n

# Fail loud if the block was restructured: a partial match would otherwise
# ship a meson.build where some win32 imports were never made optional,
# deferring the failure to the link line and masking the anchor drift.
if hits < 10:
    sys.exit(
        f"[patch_windows_deps] expected >= 10 win32-desktop find_library "
        f"anchors, rewrote {hits} of {len(WIN32_DESKTOP_LIBS)} — "
        f"meson.build layout changed"
    )

with open(fn, 'w') as f:
    f.write(content)
print(f"Patched meson.build: {hits} win32-desktop libs made optional for MinGW")
