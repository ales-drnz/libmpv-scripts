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
# another release, when they disagree on the license and when a target has
# no license texts. The web module: libmpv_web.zip as scripts/web/
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

# record <dir> <target> <filters> <patches> [release] [license]: a build
# record as the build scripts write it; filters and patches separated by
# commas.
record() {
  python3 - "$@" "$RELEASE" <<'PY'
import json, sys
d, target, filters, patches, release = sys.argv[1:6]
license = sys.argv[6] if len(sys.argv) > 7 else "LGPL-3.0-or-later"
json.dump({"release": release, "target": target, "license": license,
           "patches": [p for p in patches.split(",") if p],
           "audioFilters": [f for f in filters.split(",") if f]},
          open(f"{d}/build_{target}.json", "w"), indent=2)
PY
}

# texts <dir> <target>: the license texts write_licenses leaves for <target>.
texts() {
  mkdir -p "$1/licenses_$2/mpv"
  printf 'libmpv for %s\n' "$2" > "$1/licenses_$2/README.txt"
  printf 'LGPL\n' > "$1/licenses_$2/mpv/LICENSE.LGPL"
  printf 'mpv\nLGPL\n' > "$1/licenses_$2/THIRD_PARTY_LICENSES.txt"
}

# release_dir <name>: two binaries, Linux and Android, with their license
# texts and without records.
release_dir() {
  local d="$TMP/$1"
  mkdir -p "$d"
  printf 'linux' > "$d/libmpv_linux-x86_64.so"
  printf 'android' > "$d/libmpv_android-arm64-v8a.so"
  texts "$d" linux-x86_64
  texts "$d" android-arm64-v8a
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
assert m["license"] == "LGPL-3.0-or-later", m["license"]
PY
check $? "agree: the filters of the records, the patches per target, the commit, the run and the license"
[[ "$(wc -l < "$d/SHA256SUMS")" == 3 ]]; check $? "agree: SHA256SUMS lists the binaries and licenses.zip, not the records"
python3 - "$d" <<'PY'
import hashlib, json, sys, zipfile
d = sys.argv[1]
m = json.load(open(f"{d}/manifest.json"))
assert m["licenses"] == {"asset": "licenses.zip",
                         "sha256": hashlib.sha256(open(f"{d}/licenses.zip", "rb").read()).hexdigest()}, m["licenses"]
names = sorted(zipfile.ZipFile(f"{d}/licenses.zip").namelist())
assert names == ["android-arm64-v8a/README.txt", "android-arm64-v8a/THIRD_PARTY_LICENSES.txt",
                 "android-arm64-v8a/mpv/LICENSE.LGPL",
                 "linux-x86_64/README.txt", "linux-x86_64/THIRD_PARTY_LICENSES.txt",
                 "linux-x86_64/mpv/LICENSE.LGPL"], names
assert "licenses.zip" not in m["assets"], m["assets"]
PY
check $? "agree: licenses.zip holds the texts of each target, with its hash in the manifest"
mkdir -p "$TMP/agree-again"
cp -r "$d"/libmpv_* "$d"/build_* "$d"/licenses_* "$TMP/agree-again/"
manifest "$TMP/agree-again"
cmp -s "$d/licenses.zip" "$TMP/agree-again/licenses.zip"; check $? "agree: the same texts give the same licenses.zip"
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

d="$(release_dir license)"
record "$d" linux-x86_64 'volume' 'pcm_tap'
record "$d" android-arm64-v8a 'volume' 'pcm_tap' "$RELEASE" GPL-3.0-or-later
refused license 'GPL-3.0-or-later'

d="$(release_dir notexts)"
record "$d" linux-x86_64 'volume' 'pcm_tap'
record "$d" android-arm64-v8a 'volume' 'pcm_tap'
rm -r "$d/licenses_android-arm64-v8a"
refused notexts 'licenses_android-arm64-v8a'

d="$(release_dir nocombined)"
record "$d" linux-x86_64 'volume' 'pcm_tap'
record "$d" android-arm64-v8a 'volume' 'pcm_tap'
rm "$d/licenses_linux-x86_64/THIRD_PARTY_LICENSES.txt"
refused nocombined 'licenses_linux-x86_64/THIRD_PARTY_LICENSES.txt'

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
r = {"release": release, "target": "web", "license": "LGPL-3.0-or-later",
     "patches": ["pcm_tap", "read_error"],
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
texts "$d" web
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
[[ "$(wc -l < "$d/SHA256SUMS")" == 4 ]]; check $? "web: SHA256SUMS lists the zip"
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
assert r == {"release": sys.argv[2], "target": "macos", "license": "LGPL-3.0-or-later",
             "patches": ["chain_eof", "dash_keepalive", "libsmb2", "pcm_tap"],
             "audioFilters": ["equalizer", "volume"]}, r
PY
check $? "write: the record has the license, the patches of both trees and the filters FFmpeg was configured with"

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

# A stage cached from a build with the other license setting (LIBMPV_GPL).
LIBMPV_GPL=1 stage "$w/gpl" ffmpeg libsmb2
LIBMPV_GPL=1 stage "$w/gpl" mpv pcm_tap
build_record "$w/out5" linux-x86_64 "$w/gpl" 2>/dev/null; r=$?
[[ $r != 0 && ! -e "$w/out5/build_linux-x86_64.json" ]]; check $? "write: a stage built GPL in an LGPL build fails (exit $r)"
grep -q 'GPL-3.0-or-later' "$w/out5.log"; check $? "write: the error names the license of the stage"
LIBMPV_GPL=1 build_record "$w/out6" linux-x86_64 "$w/gpl"; check $? "write: a GPL build of GPL stages"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["license"] == "GPL-3.0-or-later", r' \
  "$w/out6/build_linux-x86_64.json"; check $? "write: the record of a GPL build says GPL-3.0-or-later"

# read_error has a side in each tree: a cached FFmpeg stage built with it
# and mpv built again without it (or the reverse) is not a build with it.
stage "$w/half" ffmpeg dash_keepalive read_error
stage "$w/half" mpv pcm_tap
build_record "$w/out7" linux-x86_64 "$w/half"; r=$?
[[ $r != 0 && ! -e "$w/out7/build_linux-x86_64.json" ]]; check $? "write: read_error in the FFmpeg stage only fails (exit $r)"
grep -q 'read_error' "$w/out7.log"; check $? "write: the error names read_error"
stage "$w/half" ffmpeg dash_keepalive
stage "$w/half" mpv pcm_tap read_error
build_record "$w/out8" linux-x86_64 "$w/half"; r=$?
[[ $r != 0 && ! -e "$w/out8/build_linux-x86_64.json" ]]; check $? "write: read_error in the mpv stage only fails (exit $r)"
stage "$w/half" ffmpeg dash_keepalive read_error
build_record "$w/out9" linux-x86_64 "$w/half"; check $? "write: read_error in both stages"

# ── write_licenses, on fake source trees ───────────────────────────────────
# The source lines of README.txt are the sources the build checked
# (SOURCES_FETCHED), not every pin of the component's name: FFmpeg, xz and
# speexdsp have two pins each, and a platform downloads one of them.
L="$TMP/licenses"
pin() { awk -v u="$1" '!/^#/ && $2 == u { print $1 }' "$ROOT/scripts/shared/_sources.sha256"; }
# trees <src dir>: a source tree with a license text for every component.
trees() {
  (
    source "$ROOT/scripts/shared/_versions.sh"
    s="$1"
    for t in "zlib-$ZLIB_VERSION" "bzip2-$BZIP2_VERSION" "xz-$XZ_VERSION" \
             "libxml2-$LIBXML2_VERSION" "openssl-$OPENSSL_VERSION" "libiconv-$LIBICONV_VERSION" \
             "speexdsp-SpeexDSP-$SPEEXDSP_VERSION" "pipewire-$PIPEWIRE_VERSION" libplacebo-git \
             libsmb2 "rubberband-$RUBBERBAND_VERSION"; do
      mkdir -p "$s/$t"; printf '%s\n' "$t" > "$s/$t/COPYING"
    done
    for m in "mpv-$MPV_VERSION" mpv-arm64; do
      mkdir -p "$s/$m"; printf 'lgpl\n' > "$s/$m/LICENSE.LGPL"; printf 'gpl\n' > "$s/$m/LICENSE.GPL"
      printf 'c\n' > "$s/$m/Copyright"
    done
    f="$s/ffmpeg-$FFMPEG_VERSION"; mkdir -p "$f"
    for n in COPYING.LGPLv3 COPYING.GPLv3 LICENSE.md; do printf '%s\n' "$n" > "$f/$n"; done
  )
}
# licenses <target> <fetched file> <components...>: write_licenses on $L/src.
licenses() {
  local target="$1" fetched="$2"; shift 2
  (
    source "$ROOT/scripts/shared/_helpers.sh"
    source "$ROOT/scripts/shared/_versions.sh"
    source "$ROOT/scripts/shared/_audio_only.sh"
    SOURCES_FETCHED="$fetched" GITHUB_SHA=feedc0de LIBPLACEBO_VERSION=6.338.2 \
      RELEASE_DIR="$L/out" write_licenses "$target" "$L/src" "$@"
  ) > "$L/$target.log" 2>&1
}
V="$(bash -c "source '$ROOT/scripts/shared/_versions.sh'; echo \"\$FFMPEG_VERSION \$XZ_VERSION \$SPEEXDSP_VERSION \$OPENSSL_VERSION\"")"
read -r FFV XZV SPV OSV <<<"$V"
mkdir -p "$L/src"; trees "$L/src"
LP="https://code.videolan.org/videolan/libplacebo.git#v6.338.2"
UNPINNED="https://example.invalid/openssl-$OSV.tar.gz"

# Linux: the .tar.gz of FFmpeg, xz from GitHub, speexdsp from xiph, a
# source checked twice (cached, then again), and an unpinned one.
fl="$L/fetched-linux"
for u in "https://ffmpeg.org/releases/ffmpeg-$FFV.tar.gz" \
         "https://github.com/tukaani-project/xz/releases/download/v$XZV/xz-$XZV.tar.gz" \
         "https://downloads.xiph.org/releases/speex/speexdsp-$SPV.tar.gz" \
         "https://downloads.xiph.org/releases/speex/speexdsp-$SPV.tar.gz" "$LP"; do
  printf '%s  %s\n' "$(pin "$u")" "$u" >> "$fl"
done
printf '%s  %s\n' 0123 "$UNPINNED" >> "$fl"
licenses linux-x86_64 "$fl" mpv ffmpeg openssl libplacebo xz speexdsp implib; check $? "licenses: linux-x86_64"
python3 - "$L/out/licenses_linux-x86_64" "$FFV" "$XZV" "$SPV" "$UNPINNED" <<'PY'
import pathlib, sys
d, ffv, xzv, spv, unpinned = sys.argv[1:]
d = pathlib.Path(d)
r = (d / "README.txt").read_text()
src = [l.split()[1] for l in r.split("patches/ of that commit:\n")[1].splitlines() if "  https://" in l]
assert src == [f"https://ffmpeg.org/releases/ffmpeg-{ffv}.tar.gz", unpinned,
               "https://code.videolan.org/videolan/libplacebo.git#v6.338.2",
               f"https://github.com/tukaani-project/xz/releases/download/v{xzv}/xz-{xzv}.tar.gz",
               f"https://downloads.xiph.org/releases/speex/speexdsp-{spv}.tar.gz"], src
assert "  mpv: no source checked against" in r, r
assert f"  0123  {unpinned}  (not pinned)" in r, r
assert "at commit feedc0de" in r, r
assert r.splitlines()[0].endswith(": LGPL-3.0-or-later"), r.splitlines()[0]
assert (d / "implib/LICENSE.txt").is_file() and not (d / "winpthreads").exists()
assert not (d / "rubberband").exists()
PY
check $? "licenses: linux lists the sources it checked, once each, and marks an unpinned one"
(source "$ROOT/scripts/shared/_versions.sh"; python3 - "$L/out/licenses_linux-x86_64" "$ROOT") <<'PY'
import os, pathlib, re, sys
d, root = map(pathlib.Path, sys.argv[1:])
c = (d / "THIRD_PARTY_LICENSES.txt").read_text()
assert c.splitlines()[0].endswith(": LGPL-3.0-or-later"), c.splitlines()[0]
# One heading per component, in the order of the build, ours first.
heads = re.findall(r"^=+\n(.+)\nLicense: (.+)\n=+$", c, re.M)
v = os.environ
ca = re.search(r"as of: (.*)", (root / "patches/ffmpeg/embed_cacert/cacert.pem").read_text()).group(1).strip()
assert heads == [
    ("libmpv-scripts commit feedc0de",
     "BSD-3-Clause, with files under LGPL-2.1-or-later, MIT and MPL-2.0 (NOTICE)"),
    (f"mpv {v['MPV_VERSION']}", "LGPL-2.1-or-later"),
    (f"ffmpeg {v['FFMPEG_VERSION']}", "LGPL-3.0-or-later"),
    (f"openssl {v['OPENSSL_VERSION']}", "Apache-2.0"),
    ("libplacebo 6.338.2", "LGPL-2.1-or-later"),
    (f"xz {v['XZ_VERSION']}", "0BSD"),
    (f"speexdsp {v['SPEEXDSP_VERSION']}", "BSD-3-Clause"),
    ("Implib.so commit a3e167cf978a5b8a38ec0f710d8c4331e8dcdd9a", "MIT"),
    (f"Mozilla CA certificate store as of {ca}", "MPL-2.0"),
], heads
# Every file of the directories, in full, under its name.
for f in sorted(p for p in d.rglob("*") if p.is_file()):
    if f.name in ("README.txt", "THIRD_PARTY_LICENSES.txt"):
        continue
    assert f"--- {f.name} ---\n\n{f.read_text().rstrip()}\n" in c, f
assert (root / "NOTICE").read_text().rstrip() in c and "patches/ffmpeg/libsmb2.c" in c
assert (d / "libmpv-scripts/NOTICE").read_bytes() == (root / "NOTICE").read_bytes()
PY
check $? "licenses: linux has THIRD_PARTY_LICENSES.txt, every component with its version, SPDX id and texts"

# Windows: the .tar.xz of FFmpeg, xz from tukaani, speexdsp from GitHub, and
# the texts of mingw-w64's winpthreads and CRT.
fw="$L/fetched-windows"
for u in "https://ffmpeg.org/releases/ffmpeg-$FFV.tar.xz" \
         "https://tukaani.org/xz/xz-$XZV.tar.gz" \
         "https://github.com/xiph/speexdsp/archive/refs/tags/SpeexDSP-$SPV.tar.gz"; do
  printf '%s  %s\n' "$(pin "$u")" "$u" >> "$fw"
done
licenses windows-x86_64 "$fw" mpv ffmpeg xz speexdsp winpthreads mingw-w64-crt; check $? "licenses: windows-x86_64"
python3 - "$L/out/licenses_windows-x86_64" "$FFV" "$XZV" "$SPV" <<'PY'
import pathlib, sys
d, ffv, xzv, spv = sys.argv[1:]
d = pathlib.Path(d)
r = (d / "README.txt").read_text()
src = [l.split()[1] for l in r.split("patches/ of that commit:\n")[1].splitlines() if "  https://" in l]
assert src == [f"https://ffmpeg.org/releases/ffmpeg-{ffv}.tar.xz", f"https://tukaani.org/xz/xz-{xzv}.tar.gz",
               f"https://github.com/xiph/speexdsp/archive/refs/tags/SpeexDSP-{spv}.tar.gz"], src
assert "(not pinned)" not in r, r
c = (d / "winpthreads/COPYING").read_text()
assert "mingw-w64 project" in c and "Lockless Inc." in c, c[:200]
assert "winpthreads" in r, r
c = (d / "THIRD_PARTY_LICENSES.txt").read_text()
assert "mingw-w64 winpthreads of the toolchain\nLicense: MIT AND BSD-3-Clause\n" in c, c
assert "Lockless Inc." in c
crt = (d / "mingw-w64-crt/COPYING.MinGW-w64-runtime.txt").read_text()
assert "statically\nlinked against the MinGW-w64 runtime" in crt and "David M. Gay" in crt, crt[:300]
assert ("mingw-w64 runtime (CRT) of the toolchain\n"
        "License: ZPL-2.1 AND ISC AND BSD-2-Clause AND dtoa AND SunPro AND MIT\n") in c, c
assert f"--- COPYING.MinGW-w64-runtime.txt ---\n\n{crt.rstrip()}\n" in c
assert "mingw-w64-crt  mingw-w64 runtime (CRT) of the toolchain: COPYING.MinGW-w64-runtime.txt" in r, r
assert not (d / "llvm-runtimes").exists()
PY
check $? "licenses: windows lists the .tar.xz of FFmpeg alone, and has the texts of winpthreads and the mingw-w64 CRT"

# The LLVM runtimes of Android, Windows arm64 (llvm-mingw) and web, and on web
# Emscripten and its musl, from scripts/shared/licenses, each text in full.
licenses android-arm64-v8a "$L/none" mpv ffmpeg llvm-runtimes; check $? "licenses: android-arm64-v8a"
licenses windows-arm64 "$L/none" mpv ffmpeg winpthreads mingw-w64-crt llvm-runtimes; check $? "licenses: windows-arm64"
licenses web "$L/none" mpv ffmpeg emscripten musl llvm-runtimes; check $? "licenses: web"
python3 - "$L/out" "$ROOT/scripts/shared/licenses" <<'PY'
import pathlib, re, sys
out, fixed = map(pathlib.Path, sys.argv[1:])
llvm = [f"{n}/LICENSE.TXT" for n in ("libcxx", "libcxxabi", "libunwind", "compiler-rt")]
want = {
    "android-arm64-v8a": {"llvm-runtimes": llvm},
    "windows-arm64": {"winpthreads": ["COPYING"], "mingw-w64-crt": ["COPYING.MinGW-w64-runtime.txt"],
                      "llvm-runtimes": llvm},
    "web": {"emscripten": ["LICENSE"], "musl": ["COPYRIGHT"], "llvm-runtimes": llvm},
}
heads = {"llvm-runtimes": ("LLVM libc++, libc++abi, libunwind and compiler-rt",
                           "Apache-2.0 WITH LLVM-exception, legacy code NCSA OR MIT"),
         "emscripten": ("Emscripten", "MIT OR NCSA"), "musl": ("musl libc of Emscripten", "MIT"),
         "winpthreads": ("mingw-w64 winpthreads", "MIT AND BSD-3-Clause"),
         "mingw-w64-crt": ("mingw-w64 runtime (CRT)",
                           "ZPL-2.1 AND ISC AND BSD-2-Clause AND dtoa AND SunPro AND MIT")}
for target, comps in want.items():
    d = out / f"licenses_{target}"
    c = (d / "THIRD_PARTY_LICENSES.txt").read_text()
    got = {m.group(1) for m in re.finditer(r"^=+\n(.+) of the toolchain\nLicense: .+\n=+$", c, re.M)}
    assert got == {heads[n][0] for n in comps}, (target, got)
    for n, files in comps.items():
        assert f"{heads[n][0]} of the toolchain\nLicense: {heads[n][1]}\n" in c, (target, n)
        for f in files:
            body = (fixed / n / f).read_bytes()
            assert (d / n / f).read_bytes() == body, (target, n, f)
            assert f"--- {f} ---\n\n{body.decode().rstrip()}\n" in c, (target, n, f)
llvm_text = (fixed / "llvm-runtimes/libcxx/LICENSE.TXT").read_text()
assert "LLVM Exceptions to the Apache 2.0 License" in llvm_text and "Legacy LLVM License" in llvm_text
assert "MIT license" in (fixed / "emscripten/LICENSE").read_text()
assert "Rich Felker" in (fixed / "musl/COPYRIGHT").read_text()
PY
check $? "licenses: android, windows-arm64 and web have the texts of the toolchain runtimes they link"

# macOS: the mpv tree of the first arch, the GPL build, no record of sources.
LIBMPV_GPL=1 licenses macos "$L/none" mpv=mpv-arm64 ffmpeg rubberband; check $? "licenses: macos (GPL)"
python3 - "$L/out/licenses_macos" <<'PY'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
r = (d / "README.txt").read_text()
assert r.splitlines()[0].endswith(": GPL-3.0-or-later"), r.splitlines()[0]
assert (d / "mpv/LICENSE.GPL").is_file() and not (d / "mpv/LICENSE.LGPL").exists()
assert (d / "ffmpeg/COPYING.GPLv3").is_file() and not (d / "ffmpeg/COPYING.LGPLv3").exists()
assert (d / "rubberband/COPYING").is_file()
for n in ("mpv", "ffmpeg", "rubberband"):
    assert f"  {n}: no source checked against" in r, r
c = (d / "THIRD_PARTY_LICENSES.txt").read_text()
assert c.splitlines()[0].endswith(": GPL-3.0-or-later"), c.splitlines()[0]
for h in ("License: GPL-2.0-or-later\n", "License: GPL-3.0-or-later\n"):
    assert c.count(h) == (2 if h.startswith("License: GPL-2") else 1), (h, c)
assert "--- LICENSE.GPL ---" in c and "--- LICENSE.LGPL ---" not in c and "COPYING.LGPLv3" not in c
PY
check $? "licenses: macos takes the tree of its arch, the GPL texts, and says when no source was checked"

# verify_source lists what it checked in SOURCES_FETCHED; sourcing the
# helpers alone writes nothing.
(
  # CI exports STRICT_SOURCES=1, under which an unpinned source stops
  # before it is recorded.
  export TMPDIR="$L/tmp" STRICT_SOURCES=0; unset RECORD_SOURCES
  mkdir -p "$TMPDIR"
  source "$ROOT/scripts/shared/_helpers.sh"
  [[ ! -e "$SOURCES_FETCHED" ]] || exit 1
  printf 'x' > "$L/x.tar.gz"
  verify_source "https://example.invalid/x.tar.gz" "$L/x.tar.gz" 2>/dev/null
  grep -qx "$(sha256_of "$L/x.tar.gz")  https://example.invalid/x.tar.gz" "$SOURCES_FETCHED"
); check $? "licenses: verify_source lists the source it checked, and no file before"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
