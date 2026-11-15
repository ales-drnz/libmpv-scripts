#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Builds mpv's dummy subprocess on the web (web build only).

Problem
=======

mpv 0.42.0 spawns its child processes with clone(CLONE_VM | CLONE_VFORK)
when meson finds clone in sched.h. Emscripten declares clone there but
does not implement it, so the check passes and the link of the module
fails on an undefined clone in osdep/subprocess-posix.c. A page cannot
start a process anyway: fork and posix_spawn are stubs that fail.

Fix
===

On emscripten meson.build takes osdep/subprocess-dummy.c, the file mpv
already builds where there is no fork. The subprocess and run commands
then fail at once, as they did in the browser before.

Files patched
=============

    meson.build   the posix branch of the subprocess source

Usage: patch_web_subprocess.py <mpv_source_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MESON = "meson.build"

PATCHED_MARKER = "# mpv_audio_kit: MAK_WEB_SUBPROCESS_V1"

ANCHOR = (
    "    if not get_option('fuzzers') and cc.has_function('fork', prefix : '#include <unistd.h>')\n"
)
REPLACEMENT = (
    "    " + PATCHED_MARKER + ": no processes in a browser, and\n"
    "    # emscripten declares clone without implementing it.\n"
    "    if not get_option('fuzzers') and host_machine.system() != 'emscripten' and"
    " cc.has_function('fork', prefix : '#include <unistd.h>')\n"
)


def apply(p):
    p.edits(MESON, [("posix subprocess source", ANCHOR, REPLACEMENT)])


anchor.main(apply, "patch_web_subprocess", marker=PATCHED_MARKER,
            usage="<mpv_source_dir>")
