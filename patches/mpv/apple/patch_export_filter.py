#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Inject `-Wl,-exported_symbols_list,<file> -Wl,-dead_strip` into the
libmpv `library()` call in mpv's meson.build so the resulting libmpv.dylib
exposes only the public mpv_* C API. Also adds explicit static-archive
references for transitive ffmpeg dependencies whose `Libs.private` is
not picked up by meson's pkg-config call (no `--static`) — openssl,
libxml2, bzip2, xz/lzma.

Why a source patch instead of `c_link_args` from a meson native-file:
the `library()` invocation hard-codes
    link_args: cc.get_supported_link_arguments(['-Wl,-Bsymbolic'])
which Meson treats as the canonical link-args set for that target — flags
from the native-file's `[built-in options]` either get dropped or come too
late to bind into the `LINK_ARGS` Ninja rule. Editing the call site is the
only way to make the export filter survive into the final ld64 invocation.

Idempotent (MARKER-guarded). Apple-only (no-op elsewhere; the ELF version
script lives at link time via `-Wl,--version-script` directly in build_mpv).

Usage: patch_export_filter.py <mpv_source_dir> <abs_path_to_mpv.exports> <abs_prefix_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = "# mpv_audio_kit: export filter"

OLD = "link_args: cc.get_supported_link_arguments(['-Wl,-Bsymbolic']),"


def apply(p, exports, prefix):
    if p.marked("meson.build"):
        print("Already patched: meson.build (export filter)")
        return
    exports_file = Path(exports).resolve()
    prefix = Path(prefix).resolve()

    # Resolve transitive static archives by absolute path so the linker
    # pulls them in regardless of the meson `library()` -L search path.
    archives = []
    for name in ("ssl", "crypto", "xml2", "bz2", "lzma"):
        a = prefix / "lib" / f"lib{name}.a"
        if not a.exists():
            p.fail(f"missing archive: {a}")
        archives.append(str(a))

    # The `-Wl,...` flags go through cc.get_supported_link_arguments() (a
    # compile-probe + filter). The absolute static-archive paths must NOT —
    # a bare `.a` path can be silently dropped by the probe on some
    # clang/ld64 combos, defeating the static link. Concatenate them raw to
    # the probed flag list instead.
    new = (
        "link_args: cc.get_supported_link_arguments(["
        "'-Wl,-Bsymbolic', "
        f"'-Wl,-exported_symbols_list,{exports_file}', "
        "'-Wl,-dead_strip']) + ["
        + ", ".join(f"'{a}'" for a in archives)
        + "],  " + MARKER
    )
    # A missing anchor: mpv may have changed the libmpv link_args call site.
    p.edit("meson.build", OLD, new, "libmpv link_args")


anchor.main(apply, "patch_export_filter", marker=MARKER,
            usage="<mpv_source_dir> <mpv.exports path> <prefix dir>", nargs=3)
