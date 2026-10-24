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

Invoked from every build_libmpv_<platform>.sh after extract, before
meson setup. Idempotent: re-running on an already-patched tree is a
no-op via the marker check.

Usage:
    python3 patch_rubberband_size_t.py <rubberband-source-dir>
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "_lib"))
import anchor  # noqa: E402

MARKER = "/* libmpv-scripts: stddef.h for size_t */"

ANCHOR_H = '#include "sysutils.h"'
ANCHOR_CPP = '#include "mathmisc.h"'

INJECT_H = MARKER + "\n#include <stddef.h>\n#include \"sysutils.h\""
INJECT_CPP = MARKER + "\n#include <stddef.h>\n#include \"mathmisc.h\""


def patch_one(p, rel: str, anchor_line: str, inject: str) -> None:
    if not p.exists(rel):
        p.fail(f"{rel} not found")
        return
    text = p.text(rel)
    if MARKER in text:
        print(f"Already patched: {rel}")
        return
    if anchor_line not in text and "size_t" not in text:
        # Upstream may have reshuffled the header. With no unqualified
        # size_t reference left in the file the patch is unnecessary on
        # that tree.
        print(f"Skipping (no size_t reference): {rel}")
        return
    p.edit(rel, anchor_line, inject)


def apply(p):
    patch_one(p, "src/common/mathmisc.h", ANCHOR_H, INJECT_H)
    patch_one(p, "src/common/mathmisc.cpp", ANCHOR_CPP, INJECT_CPP)


anchor.main(apply, "patch_rubberband_size_t", marker=MARKER,
            usage="<rubberband-source-dir>")
