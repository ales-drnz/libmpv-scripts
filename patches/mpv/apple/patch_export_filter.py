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
import pathlib
import sys

if len(sys.argv) != 4:
    sys.exit(
        "usage: patch_export_filter.py <mpv_source_dir> "
        "<mpv.exports path> <prefix dir>"
    )

mpv_dir = pathlib.Path(sys.argv[1])
exports_file = pathlib.Path(sys.argv[2]).resolve()
prefix = pathlib.Path(sys.argv[3]).resolve()
target = mpv_dir / "meson.build"
text = target.read_text()

MARKER = "# mpv_audio_kit: export filter"
if MARKER in text:
    print("[patch_export_filter] already applied", file=sys.stderr)
    sys.exit(0)

# Resolve transitive static archives by absolute path so the linker
# pulls them in regardless of the meson `library()` -L search path.
def _archive(name: str) -> str:
    a = prefix / "lib" / f"lib{name}.a"
    if not a.exists():
        sys.exit(f"[patch_export_filter] missing archive: {a}")
    return str(a)

extra_archives = [
    _archive("ssl"),
    _archive("crypto"),
    _archive("xml2"),
    _archive("bz2"),
    _archive("lzma"),
]

old = "link_args: cc.get_supported_link_arguments(['-Wl,-Bsymbolic']),"
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
    + ", ".join(f"'{a}'" for a in extra_archives)
    + "],  " + MARKER
)

if old not in text:
    sys.exit(
        "[patch_export_filter] anchor not found — mpv version may have "
        "changed the libmpv link_args call site"
    )

target.write_text(text.replace(old, new))
print("[patch_export_filter] applied", file=sys.stderr)
