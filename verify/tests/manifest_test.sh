#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks scripts/write_manifest.sh against the build records that the build
# scripts leave next to each binary (builds/release/build_<target>.json). The
# manifest lists the patches of every target and the commit and run of the
# build, and takes the filters from the records, not from the override present
# when it runs (F211). It fails and writes nothing when the records disagree
# on the filters, when a binary has no record and when a record belongs to
# another release. The web module: libmpv_web.zip as scripts/web/
# package_web.py packs it, whose files and versions the manifest lists, and
# the zips it refuses. Then the side that writes the records:
# write_build_record of scripts/shared/_audio_only.sh, on what the patch
# steps left in the prefixes.
#
# Usage: bash verify/tests/manifest_test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RELEASE="$(bash -c "source '$ROOT/scripts/shared/_versions.sh'; echo \"\$LIBMPV_RELEASE\"")"

# A copy of the scripts in a git repository of its own, so an override can
# sit next to them and the local commit is known.
REPO="$TMP/repo"
mkdir -p "$REPO/scripts/web"
cp -r "$ROOT/scripts/write_manifest.sh" "$ROOT/scripts/shared" "$REPO/scripts/"
cp "$ROOT/scripts/web/package_web.py" "$REPO/scripts/web/"
rm -f "$REPO/scripts/shared/_user_overrides.sh"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.name=test -c user.email=test@example.com commit -qm test
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

# record <dir> <target> <filters> <patches> [release]: a build record as the
# build scripts write it; filters and patches separated by commas.
record() {
  python3 - "$@" "$RELEASE" <<'PY'
import json, sys
d, target, filters, patches, release = sys.argv[1:6]
json.dump({"release": release, "target": target,
           "patches": [p for p in patches.split(",") if p],
           "audioFilters": [f for f in filters.split(",") if f]},
          open(f"{d}/build_{target}.json", "w"), indent=2)
PY
}

# release_dir <name>: two binaries, Linux and Android, without records.
release_dir() {
  local d="$TMP/$1"
  mkdir -p "$d"
  printf 'linux' > "$d/libmpv_linux-x86_64.so"
  printf 'android' > "$d/libmpv_android-arm64-v8a.so"
  echo "$d"
}

# manifest <dir> [env...]: write_manifest.sh on <dir>, from the copy.
manifest() {
  local d="$1"; shift
  env -u GITHUB_SHA -u GITHUB_RUN_ID "$@" RELEASE_DIR="$d" \
    bash "$REPO/scripts/write_manifest.sh" > "$d.log" 2>&1
}

# ── The records agree, and an override lists other filters (F211) ──────────
d="$(release_dir agree)"
record "$d" linux-x86_64 'equalizer,volume' 'chain_eof,pcm_tap,strip_win_resources'
record "$d" android-arm64-v8a 'volume,equalizer' 'audiotrack,chain_eof,pcm_tap,strip_win_resources'
printf 'export AUDIO_FILTERS="hdcd"\n' > "$REPO/scripts/shared/_user_overrides.sh"
manifest "$d" GITHUB_SHA=0123abc GITHUB_RUN_ID=42; check $? "agree: write_manifest.sh succeeds"
python3 - "$d/manifest.json" "$RELEASE" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["release"] == sys.argv[2], m["release"]
assert isinstance(m["mpv"], str) and isinstance(m["ffmpeg"], str)
assert sorted(m["assets"]) == ["libmpv_android-arm64-v8a.so", "libmpv_linux-x86_64.so"], m["assets"]
assert m["audioFilters"] == ["equalizer", "volume"], m["audioFilters"]
assert m["patches"] == {
    "android-arm64-v8a": ["audiotrack", "chain_eof", "pcm_tap", "strip_win_resources"],
    "linux-x86_64": ["chain_eof", "pcm_tap", "strip_win_resources"],
}, m["patches"]
assert m["source"] == {"commit": "0123abc", "run": "42"}, m["source"]
PY
check $? "agree: the filters of the records, the patches per target, the commit and the run"
[[ "$(wc -l < "$d/SHA256SUMS")" == 2 ]]; check $? "agree: SHA256SUMS lists the binaries and not the records"
rm -f "$REPO/scripts/shared/_user_overrides.sh"

# ── A local run: the commit of the checkout, no run ────────────────────────
d="$(release_dir local)"
record "$d" linux-x86_64 'volume' 'pcm_tap'
record "$d" android-arm64-v8a 'volume' 'pcm_tap'
manifest "$d"; check $? "local: write_manifest.sh succeeds"
python3 - "$d/manifest.json" "$HEAD_SHA" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["source"] == {"commit": sys.argv[2], "run": None}, m["source"]
PY
check $? "local: source has the commit of the checkout and no run"

# refused <name> <what>: write_manifest.sh fails on <name> and leaves no
# manifest.json nor SHA256SUMS.
refused() {
  manifest "$TMP/$1"; local r=$?
  [[ $r != 0 ]]; check $? "$1: write_manifest.sh fails (exit $r)"
  [[ ! -e "$TMP/$1/manifest.json" && ! -e "$TMP/$1/SHA256SUMS" ]]; check $? "$1: nothing written"
  grep -q "$2" "$TMP/$1.log"; check $? "$1: the error names $2"
}

d="$(release_dir filters)"
record "$d" linux-x86_64 'equalizer,volume' 'pcm_tap'
record "$d" android-arm64-v8a 'volume' 'pcm_tap'
refused filters 'audioFilters'

d="$(release_dir missing)"
record "$d" linux-x86_64 'volume' 'pcm_tap'
refused missing 'build_android-arm64-v8a.json'

d="$(release_dir older)"
record "$d" linux-x86_64 'volume' 'pcm_tap'
record "$d" android-arm64-v8a 'volume' 'pcm_tap' r1
refused older 'r1'

# ── The web module ──────────────────────────────────────────────────────────
# web_module <dir> [record fields as JSON]: what build_libmpv_web.sh leaves
# in its RELEASE_DIR, with the record's module versions unless overridden.
web_module() {
  local d="$1"
  mkdir -p "$d"
  printf 'glue' > "$d/libmpv.mjs"
  printf '\0asm\1\0\0\0' > "$d/libmpv.wasm"
  printf 'worklet' > "$d/mak_webaudio_processor.js"
  python3 - "$d" "$RELEASE" "${2:-{\}}" <<'PY'
import json, sys
d, release, extra = sys.argv[1:]
r = {"release": release, "target": "web", "patches": ["pcm_tap", "read_error"],
     "audioFilters": ["volume"],
     "module": {"abi": 1, "webaudioAbi": 1, "emscripten": "6.0.12"}}
r.update(json.loads(extra))
open(f"{d}/build_web.json", "w").write(json.dumps(r, indent=2) + "\n")
PY
}
package() { python3 "$REPO/scripts/web/package_web.py" "$@" > "$TMP/package.log" 2>&1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

d="$(release_dir web)"
record "$d" linux-x86_64 'volume' 'pcm_tap'
record "$d" android-arm64-v8a 'volume' 'pcm_tap'
web_module "$TMP/web-module"
package "$TMP/web-module" "$d"; check $? "web: package_web.py packs the module"
package "$TMP/web-module" "$TMP/web-again"
cmp -s "$d/libmpv_web.zip" "$TMP/web-again/libmpv_web.zip"; check $? "web: the same files give the same zip"
manifest "$d"; check $? "web: write_manifest.sh succeeds"
python3 - "$d/manifest.json" "$(sha "$TMP/web-module/libmpv.mjs")" \
  "$(sha "$TMP/web-module/libmpv.wasm")" "$(sha "$TMP/web-module/mak_webaudio_processor.js")" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert "libmpv_web.zip" in m["assets"], m["assets"]
assert m["patches"]["web"] == ["pcm_tap", "read_error"], m["patches"]
assert m["web"] == {
    "asset": "libmpv_web.zip", "abi": 1, "webaudioAbi": 1, "emscripten": "6.0.12",
    "files": {"libmpv.mjs": sys.argv[2], "libmpv.wasm": sys.argv[3],
              "mak_webaudio_processor.js": sys.argv[4]},
}, m["web"]
PY
check $? "web: the asset, its patches, the module versions and the hash of each file"
[[ "$(wc -l < "$d/SHA256SUMS")" == 3 ]]; check $? "web: SHA256SUMS lists the zip"
python3 -c 'import json,sys; sys.exit("web" in json.load(open(sys.argv[1])))' "$TMP/local/manifest.json"
check $? "web: no web section without the zip"

# A module without its versions is not packed.
web_module "$TMP/web-noabi-module" '{"module": null}'
package "$TMP/web-noabi-module" "$TMP/web-noabi-out"; r=$?
[[ $r != 0 && ! -e "$TMP/web-noabi-out/libmpv_web.zip" ]]; check $? "web: package_web.py refuses a record without versions (exit $r)"

# A zip without the worklet, as from an older build.
d="$(release_dir web-files)"
record "$d" linux-x86_64 'volume' 'pcm_tap'
record "$d" android-arm64-v8a 'volume' 'pcm_tap'
cp "$TMP/web-module/build_web.json" "$d/"
python3 - "$TMP/web-module" "$d/libmpv_web.zip" <<'PY'
import sys, zipfile
src, out = sys.argv[1:]
with zipfile.ZipFile(out, "w") as z:
    for n in ("libmpv.mjs", "libmpv.wasm", "build_web.json"):
        z.write(f"{src}/{n}", n)
PY
refused web-files 'mak_webaudio_processor.js'

# The record next to the zip is not the one inside it.
d="$(release_dir web-record)"
record "$d" linux-x86_64 'volume' 'pcm_tap'
record "$d" android-arm64-v8a 'volume' 'pcm_tap'
package "$TMP/web-module" "$d"
web_module "$TMP/web-other" '{"patches": ["pcm_tap"]}'
cp "$TMP/web-other/build_web.json" "$d/build_web.json"
refused web-record 'not the one next to it'

# A record without the module versions, the zip packed by hand.
d="$(release_dir web-noabi)"
record "$d" linux-x86_64 'volume' 'pcm_tap'
record "$d" android-arm64-v8a 'volume' 'pcm_tap'
cp "$TMP/web-noabi-module/build_web.json" "$d/"
python3 - "$TMP/web-noabi-module" "$d/libmpv_web.zip" <<'PY'
import sys, zipfile
src, out = sys.argv[1:]
with zipfile.ZipFile(out, "w") as z:
    for n in ("libmpv.mjs", "libmpv.wasm", "mak_webaudio_processor.js", "build_web.json"):
        z.write(f"{src}/{n}", n)
PY
refused web-noabi 'module versions'

# ── write_build_record, on the records of the stages ────────────────────────
# stage <prefix> <tree> <ids...>: what the patch steps of a stage on a fresh
# tree leave in its prefix, with AUDIO_FILTERS as FFmpeg is configured.
stage() {
  local prefix="$1" tree="$2"; shift 2
  (
    source "$ROOT/scripts/shared/_helpers.sh"
    source "$ROOT/scripts/shared/_versions.sh"
    source "$ROOT/scripts/shared/_audio_only.sh"
    export AUDIO_FILTERS="${STAGE_FILTERS:-volume,equalizer}"
    patch_record_start "$tree" "$prefix"
    for id in "$@"; do record_patch "$id"; done
  )
}
# build_record <out dir> <target> <prefixes...>, with other AUDIO_FILTERS in
# the environment, as after a change of the settings.
build_record() {
  local out="$1"; shift
  (
    source "$ROOT/scripts/shared/_helpers.sh"
    source "$ROOT/scripts/shared/_versions.sh"
    source "$ROOT/scripts/shared/_audio_only.sh"
    export AUDIO_FILTERS="hdcd"
    RELEASE_DIR="$out" write_build_record "$@"
  ) > "$out.log" 2>&1
}

w="$TMP/write"; mkdir -p "$w/out"
stage "$w/arm64" ffmpeg libsmb2 dash_keepalive
stage "$w/arm64" mpv pcm_tap chain_eof pcm_tap
stage "$w/x86_64" ffmpeg dash_keepalive libsmb2
stage "$w/x86_64" mpv chain_eof pcm_tap
build_record "$w/out" macos "$w/arm64" "$w/x86_64"; check $? "write: two slices with the same patches"
python3 - "$w/out/build_macos.json" "$RELEASE" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r == {"release": sys.argv[2], "target": "macos",
             "patches": ["chain_eof", "dash_keepalive", "libsmb2", "pcm_tap"],
             "audioFilters": ["equalizer", "volume"]}, r
PY
check $? "write: the record has the patches of both trees and the filters FFmpeg was configured with"

# A stage built again starts its record afresh.
stage "$w/x86_64" mpv chain_eof
build_record "$w/out2" macos "$w/arm64" "$w/x86_64" 2>/dev/null; r=$?
[[ $r != 0 && ! -e "$w/out2/build_macos.json" ]]; check $? "write: slices with different patches fail (exit $r)"

STAGE_FILTERS=volume stage "$w/x86_64" ffmpeg dash_keepalive libsmb2
stage "$w/x86_64" mpv chain_eof pcm_tap
build_record "$w/out3" macos "$w/arm64" "$w/x86_64" 2>/dev/null; r=$?
[[ $r != 0 && ! -e "$w/out3/build_macos.json" ]]; check $? "write: slices with different filters fail (exit $r)"

# A cached stage whose prefix has no record (built by an older script).
stage "$w/nompv" ffmpeg libsmb2
build_record "$w/out4" linux-x86_64 "$w/nompv" 2>/dev/null; r=$?
[[ $r != 0 && ! -e "$w/out4/build_linux-x86_64.json" ]]; check $? "write: a stage without a record fails (exit $r)"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
