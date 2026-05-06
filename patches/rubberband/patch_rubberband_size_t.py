#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patch rubberband 4.0+'s src/common/mathmisc.{h,cpp} to qualify or
include `size_t` properly.

Upstream uses unqualified `size_t` in the function signatures:

    size_t roundUp(size_t value);
    size_t roundUpDiv(double divisionOf, size_t divisor);

This compiles fine with toolchains that transitively pull `size_t`
into the global namespace, but modern clang on macOS SDK 26.4 +
strict mode (-std=c++20 + explicit -isysroot) rejects it with:

    error: unknown type name 'size_t'; did you mean 'std::size_t'?

Fix: inject `#include <stddef.h>` at the top of mathmisc.{h,cpp}.
<stddef.h> is the standard C header that declares `size_t` in the
global namespace (vs <cstddef> which only guarantees std::size_t).
Both files use unqualified `size_t` so we don't want to force a
std::size_t rewrite.

Invoked from scripts/build_librubberband.sh after extract, before
meson setup. Idempotent: re-running on an already-patched tree is a
no-op via the marker check.

Usage:
    python3 patch_rubberband_size_t.py <rubberband-source-dir>
"""

from __future__ import annotations
import sys
from pathlib import Path

MARKER = "/* libmpv-scripts: stddef.h for size_t */"

ANCHOR_H = '#include "sysutils.h"'
ANCHOR_CPP = '#include "mathmisc.h"'

INJECT_H = MARKER + "\n#include <stddef.h>\n#include \"sysutils.h\""
INJECT_CPP = MARKER + "\n#include <stddef.h>\n#include \"mathmisc.h\""


def patch_one(target: Path, anchor: str, inject: str) -> bool:
    if not target.is_file():
        print(f"ERROR: {target} not found", file=sys.stderr)
        return False
    text = target.read_text()
    if MARKER in text:
        print(f"Already patched: {target}")
        return True
    if anchor not in text:
        # Upstream may have reshuffled the header. If there's no
        # unqualified size_t reference left in the file, the patch
        # is unnecessary on that tree — no-op success.
        if "size_t" not in text:
            print(f"Skipping (no size_t reference): {target}")
            return True
        print(f"ERROR: anchor not found in {target}; patch needs "
              "update for this upstream version", file=sys.stderr)
        return False
    text = text.replace(anchor, inject, 1)
    target.write_text(text)
    print(f"Patched: {target}")
    return True


def patch(src_root: Path) -> bool:
    h_target = src_root / "src" / "common" / "mathmisc.h"
    cpp_target = src_root / "src" / "common" / "mathmisc.cpp"
    ok_h = patch_one(h_target, ANCHOR_H, INJECT_H)
    ok_cpp = patch_one(cpp_target, ANCHOR_CPP, INJECT_CPP)
    return ok_h and ok_cpp


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <rubberband-source-dir>", file=sys.stderr)
        sys.exit(2)
    src = Path(sys.argv[1])
    if not src.is_dir():
        print(f"ERROR: {src} is not a directory", file=sys.stderr)
        sys.exit(2)
    sys.exit(0 if patch(src) else 1)
