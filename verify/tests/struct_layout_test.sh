#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks verify/struct_layout.py on a client.h written here with the
# END_FILE fields of patch_read_error.py: the numbers it reads back on both
# data models, and a struct that lays out unlike on two targets of one
# model (a long, 4 bytes on Windows) refused. Needs clang.
#
# Usage: bash verify/tests/struct_layout_test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

# header <dir> <type of mpv_event_start_file.playlist_entry_id>
header() {
  mkdir -p "$1/mpv"
  {
    cat <<'H'
#include <stdint.h>
#include <stddef.h>
typedef struct mpv_byte_array { void *data; size_t size; } mpv_byte_array;
struct mpv_node_list;
typedef struct mpv_node { union { char *string; int flag; int64_t int64; double double_;
  struct mpv_node_list *list; struct mpv_byte_array *ba; } u; int format; } mpv_node;
typedef struct mpv_node_list { int num; mpv_node *values; char **keys; } mpv_node_list;
typedef struct mpv_event_property { const char *name; int format; void *data; } mpv_event_property;
typedef struct mpv_event_log_message { const char *prefix; const char *level; const char *text;
  int log_level; } mpv_event_log_message;
typedef struct mpv_event_end_file { int reason; int error; int64_t playlist_entry_id;
  int64_t playlist_insert_id; int playlist_insert_num_entries;
H
    cat "$ROOT/patches/mpv/shared/read_error/end_file_fields_insert.h"
    printf '} mpv_event_end_file;\n'
    printf 'typedef struct mpv_event_start_file { %s playlist_entry_id; } mpv_event_start_file;\n' "$2"
    printf 'typedef struct mpv_event_hook { const char *name; uint64_t id; } mpv_event_hook;\n'
    printf 'typedef struct mpv_event { int event_id; int error; uint64_t reply_userdata; void *data; } mpv_event;\n'
  } > "$1/mpv/client.h"
}

header "$TMP/good" int64_t
python3 -B "$ROOT/verify/struct_layout.py" "$TMP/good" "$TMP/good.json" > "$TMP/good.log" 2>&1
check $? "a client.h of the release: struct_layout.py succeeds"
python3 - "$TMP/good.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert sorted(d) == ["ilp32", "lp64"], sorted(d)
end = {"reason": 0, "error": 4, "playlist_entry_id": 8, "playlist_insert_id": 16,
       "playlist_insert_num_entries": 24, "mak_read_error": 28,
       "mak_skipped_segments": 32, "mak_duration": 40, "mak_position": 48}
for m in d.values():
    assert m["mpv_event_end_file"] == {"size": 56, "fields": end}, m["mpv_event_end_file"]
    assert m["mpv_event"]["fields"]["data"] == 16, m["mpv_event"]
assert d["lp64"]["mpv_node_list"] == {"size": 24, "fields": {"num": 0, "values": 8, "keys": 16}}
assert d["ilp32"]["mpv_node_list"] == {"size": 12, "fields": {"num": 0, "values": 4, "keys": 8}}
assert d["ilp32"]["mpv_event_log_message"]["fields"]["log_level"] == 12
assert d["lp64"]["mpv_byte_array"]["fields"]["size"] == 8
PY
check $? "the numbers of both models, END_FILE of 56 bytes"

header "$TMP/long" long
python3 -B "$ROOT/verify/struct_layout.py" "$TMP/long" > "$TMP/long.log" 2>&1
r=$?
[[ $r != 0 ]] && grep -q "unlike" "$TMP/long.log"
check $? "a long in a struct: the targets of lp64 disagree, refused"

# Every Apple xcframework of the Build has its device and simulator triples
# in TARGETS, macOS its two architectures. Needs no clang.
python3 -B - "$ROOT" <<'PY'
import re, sys
root = sys.argv[1]
sys.path.insert(0, root + "/verify")
import struct_layout
triples = sum(struct_layout.TARGETS.values(), [])
build = open(root + "/.github/workflows/build.yml").read()
oses = sorted(set(re.findall(r"libmpv_(\w+)\.xcframework\.zip", build)))
assert oses, "no xcframework in build.yml"
missing = []
for os_ in oses:
    want = ([f"{a}-apple-macos" for a in ("arm64", "x86_64")] if os_ == "macos" else
            [f"arm64-apple-{os_}", f"arm64-apple-{os_}-simulator",
             f"x86_64-apple-{os_}-simulator"])
    missing += [t for t in want if t not in triples]
assert not missing, "not in TARGETS: " + ", ".join(missing)
PY
check $? "every Apple xcframework of the Build has its triples in TARGETS"

echo "struct_layout_test: $fails failure(s)"
(( fails == 0 ))
