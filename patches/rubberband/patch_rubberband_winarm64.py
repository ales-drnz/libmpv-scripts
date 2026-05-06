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

Invoked from scripts/build_librubberband.sh after extract, before
meson setup. Idempotent: re-running on an already-patched tree is a
no-op.

Usage:
    python3 patch_rubberband_winarm64.py <rubberband-source-dir>
"""

from __future__ import annotations
import re
import sys
from pathlib import Path

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


def patch(src_root: Path) -> bool:
    target = src_root / "src" / "common" / "sysutils.cpp"
    if not target.is_file():
        print(f"ERROR: {target} not found", file=sys.stderr)
        return False
    text = target.read_text()
    if MARKER in text:
        print(f"Already patched: {target}")
        return True
    if OLD_BLOCK not in text:
        # Rubberband 4.0+ removed the system_memorybarrier() function
        # entirely (the spinlock primitive was retired upstream).
        # Older 3.x and earlier still carry the x86 xchgl asm block.
        # Treat a missing anchor in 4.0+ as a SUCCESSFUL no-op (the
        # patch is unnecessary on those versions) instead of an
        # ERROR. The marker check above keeps idempotency for re-runs
        # on already-patched 3.x trees.
        if "system_memorybarrier" not in text:
            print(f"Skipping (no system_memorybarrier in upstream 4.0+): {target}")
            return True
        print(f"ERROR: system_memorybarrier present in {target} but the "
              "expected mingw/xchgl anchor block has shifted shape; "
              "patch needs to be updated for this upstream version",
              file=sys.stderr)
        return False
    text = text.replace(OLD_BLOCK, NEW_BLOCK, 1)
    target.write_text(text)
    print(f"Patched: {target}")
    return True


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <rubberband-source-dir>", file=sys.stderr)
        sys.exit(2)
    src = Path(sys.argv[1])
    if not src.is_dir():
        print(f"ERROR: {src} is not a directory", file=sys.stderr)
        sys.exit(2)
    sys.exit(0 if patch(src) else 1)
