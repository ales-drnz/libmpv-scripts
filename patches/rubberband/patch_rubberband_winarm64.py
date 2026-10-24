#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patch rubberband's src/common/sysutils.cpp so it compiles under
llvm-mingw clang targeting Windows aarch64.

The upstream MinGW branch of `system_memorybarrier()` uses inline x86
assembly (`xchgl %%eax,%0`) which has no aarch64 equivalent. Clang on
Windows ARM64 fails the build with:

    sysutils.cpp:176:26: error: unknown token in expression
    sysutils.cpp:176:26: error: invalid operand

Fix: replace the entire MinGW branch with a portable C11/C++11 atomic
fence. `__atomic_thread_fence` is a GCC/clang builtin and emits the
correct memory barrier instruction on every architecture (DMB on
aarch64, MFENCE on x86_64, etc.).

This patch is applied unconditionally — the new builtin is at least as
strong as the original xchgl barrier on x86/x86_64 too, so the
non-Windows-ARM builds are unaffected.

Invoked from scripts/build_libmpv_windows.sh after extract, before
meson setup. Idempotent: re-running on an already-patched tree is a
no-op.

Usage:
    python3 patch_rubberband_winarm64.py <rubberband-source-dir>
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_lib"))
import anchor  # noqa: E402

OLD_BLOCK = """#else /* (mingw) */
    LONG Barrier = 0;
    __asm__ __volatile__(\"xchgl %%eax,%0 \"
                         : \"=r\" (Barrier));
#endif"""

NEW_BLOCK = """#else /* (mingw) — portable across x86/x86_64/aarch64 */
    /* Patched by libmpv-scripts (patch_rubberband_winarm64.py): the
       upstream xchgl asm is x86-only and breaks Windows ARM64 builds
       under llvm-mingw clang. __atomic_thread_fence is a clang/gcc
       builtin that emits the correct barrier on every architecture. */
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif"""

MARKER = "patch_rubberband_winarm64"
TARGET = "src/common/sysutils.cpp"


def apply(p):
    if not p.exists(TARGET):
        p.fail(f"{TARGET} not found")
        return
    text = p.text(TARGET)
    if MARKER in text:
        print(f"Already patched: {TARGET}")
        return
    if "system_memorybarrier" not in text:
        # Rubberband 4.0+ removed system_memorybarrier() entirely (the
        # spinlock primitive was retired upstream); older 3.x and earlier
        # still carry the x86 xchgl asm block. The patch is unnecessary on
        # those versions.
        print(f"Skipping (no system_memorybarrier in upstream 4.0+): {TARGET}")
        return
    # system_memorybarrier present: the mingw/xchgl block must be there in
    # the shape this patch knows.
    p.edit(TARGET, OLD_BLOCK, NEW_BLOCK, "mingw xchgl barrier")


anchor.main(apply, "patch_rubberband_winarm64", marker=MARKER,
            usage="<rubberband-source-dir>")
