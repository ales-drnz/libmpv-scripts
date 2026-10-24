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
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

# The win32-desktop system libs meson probes with cc.find_library() (mpv
# meson.build, `if features['win32-desktop']` block). Includes pathcch.
WIN32_DESKTOP_LIBS = [
    "avrt", "dwmapi", "gdi32", "imm32", "ntdll", "ole32",
    "pathcch", "shcore", "user32", "uuid", "uxtheme", "version",
]

# A first lib already optional means the patch ran before.
DONE = "cc.find_library('avrt', required: false)"


def apply(p, meson):
    if DONE in p.text(meson):
        print(f"Nothing to patch in {meson} (already patched)")
        return
    # Every lib must be probed exactly once: a block restructured upstream
    # would otherwise ship a meson.build where some win32 imports were never
    # made optional, deferring the failure to the link line.
    for lib in WIN32_DESKTOP_LIBS:
        p.edit(meson, f"cc.find_library('{lib}')",
               f"cc.find_library('{lib}', required: false)")


anchor.main(apply, "patch_windows_deps", usage="<mpv meson.build>",
            file_arg=True)
