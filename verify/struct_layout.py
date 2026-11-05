#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""The layout of the client API structs a binding reads, per ABI.

Compiles a table of sizeof and offsetof of the structs below against an
mpv include dir (the patched one: mpv_event_end_file carries the mak_
fields of patch_read_error.py) with clang for each target the release
ships, freestanding and only to assembly, and reads the numbers back from
it: nothing runs on the target. Prints JSON:

  {"lp64": {"mpv_event_end_file": {"size": 56, "fields": {"reason": 0, ...}}, ...},
   "ilp32": {...}}

Targets of one data model must agree, or it fails: they are one entry.
mpv_audio_kit checks its FFI structs (lp64, ilp32) and its wasm32 table
(ilp32) against this, from the copy write_manifest.sh puts in manifest.json.

Usage: python3 verify/struct_layout.py <mpv include dir> [out.json]
"""

import json
import pathlib
import re
import subprocess
import sys
import tempfile

STRUCTS = {
    "mpv_event": ["event_id", "error", "reply_userdata", "data"],
    "mpv_event_start_file": ["playlist_entry_id"],
    "mpv_event_end_file": [
        "reason", "error", "playlist_entry_id", "playlist_insert_id",
        "playlist_insert_num_entries", "mak_read_error",
        "mak_skipped_segments", "mak_duration", "mak_position",
    ],
    "mpv_event_property": ["name", "format", "data"],
    "mpv_event_log_message": ["prefix", "level", "text", "log_level"],
    "mpv_node": ["u", "format"],
    "mpv_node_list": ["num", "values", "keys"],
    "mpv_byte_array": ["data", "size"],
    "mpv_event_hook": ["name", "id"],
}

# The targets of the release, by data model (pointer and size_t width, and
# an 8-byte int64_t). Android x86 is not one: i386 aligns int64_t on 4, so
# mpv_node and mpv_event_hook lay out unlike these.
TARGETS = {
    "lp64": [
        "x86_64-linux-gnu", "aarch64-linux-gnu", "x86_64-linux-android",
        "aarch64-linux-android", "arm64-apple-macos", "x86_64-apple-macos",
        "arm64-apple-ios", "arm64-apple-ios-simulator", "x86_64-apple-ios-simulator",
        "arm64-apple-tvos", "arm64-apple-tvos-simulator", "x86_64-apple-tvos-simulator",
        "x86_64-w64-windows-gnu", "aarch64-w64-windows-gnu",
    ],
    "ilp32": ["armv7a-linux-androideabi", "wasm32-unknown-emscripten"],
}

# The integers of the table in the assembly of each target.
_VALUE = re.compile(r"^\s*\.(?:long|word|int32|4byte)\s+(-?\d+)\s*(?:[#@/;].*)?$")


def _source():
    lines = ["#include <stddef.h>", "#include <mpv/client.h>", "const int mak_layout[] = {"]
    for struct, fields in STRUCTS.items():
        lines.append(f"  (int)sizeof(struct {struct}),")
        lines += [f"  (int)offsetof(struct {struct}, {f})," for f in fields]
    lines.append("};")
    return "\n".join(lines) + "\n"


def _table(include, target, work):
    src = work / "layout.c"
    src.write_text(_source())
    run = subprocess.run(
        ["clang", f"--target={target}", "-ffreestanding", "-nostdinc",
         "-isystem", _resource_include(), "-I", str(include),
         "-O0", "-S", "-o", "-", str(src)],
        capture_output=True, text=True)
    if run.returncode != 0:
        raise SystemExit(f"{target}: clang failed on the table:\n{run.stderr}")
    out = run.stdout
    values = [int(m.group(1)) for m in map(_VALUE.match, out.splitlines()) if m]
    want = sum(1 + len(f) for f in STRUCTS.values())
    if len(values) != want:
        raise SystemExit(f"{target}: read {len(values)} numbers from the assembly, not {want}")
    layout, i = {}, 0
    for struct, fields in STRUCTS.items():
        layout[struct] = {"size": values[i], "fields": dict(zip(fields, values[i + 1:]))}
        i += 1 + len(fields)
    return layout


def _resource_include():
    # clang's own stddef.h and stdint.h: the target's libc is not needed.
    out = subprocess.run(["clang", "-print-resource-dir"], check=True,
                         capture_output=True, text=True).stdout.strip()
    return str(pathlib.Path(out) / "include")


def layout(include):
    result = {}
    with tempfile.TemporaryDirectory() as tmp:
        for model, targets in TARGETS.items():
            tables = {t: _table(include, t, pathlib.Path(tmp)) for t in targets}
            first = tables[targets[0]]
            for t, table in tables.items():
                if table != first:
                    raise SystemExit(f"{t} lays out the structs unlike {targets[0]} ({model})")
            result[model] = first
    return result


def main(argv):
    if len(argv) not in (2, 3):
        raise SystemExit(__doc__)
    include = pathlib.Path(argv[1])
    if not (include / "mpv" / "client.h").is_file():
        raise SystemExit(f"No mpv/client.h in {include}")
    text = json.dumps(layout(include), indent=2) + "\n"
    if len(argv) == 3:
        pathlib.Path(argv[2]).write_text(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main(sys.argv)
