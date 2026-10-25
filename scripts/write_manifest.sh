#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# write_manifest.sh
#
# Writes builds/release/manifest.json, published with the binaries as part of
# the libmpv-<release> GitHub release. It states what the release contains,
# so consumers never re-derive it from this repo's scripts:
#
#   release        the release tag suffix (LIBMPV_RELEASE, e.g. "r19")
#   mpv, ffmpeg    the pinned upstream versions
#   audioFilters   the lavfi audio filters compiled in, which mpv_audio_kit's
#                  codegen turns into its typed effects API
#   patches        the toggleable patches applied, per target (the ids of the
#                  TUI catalog; the required patches are always applied)
#   source         the commit of this repo the binaries were built from, and
#                  the CI run that built them (null for a local build)
#   assets         SHA-256 of every binary in builds/release/, keyed by name
#   web            the web module, when libmpv_web.zip is there: its asset,
#                  the module's versions from its record (abi, the
#                  MAK_WEB_ABI a client checks with mak_web_abi_version();
#                  webaudioAbi; emscripten) and the SHA-256 of each file a
#                  client installs from the zip
#
# Filters and patches come from the record each build leaves next to its
# binary, builds/release/build_<target>.json (write_build_record in
# shared/_audio_only.sh), not from the settings of today (F211). It fails,
# writing nothing, when a binary has no record, when a record belongs to
# another release or when the records disagree on the filters, and when
# libmpv_web.zip holds other files than the module's or a record other than
# build_web.json, or that record has no module versions.
#
# It also writes builds/release/SHA256SUMS, the same hashes in the
# `sha256sum -c` format, published next to the binaries.
#
# Usage (from the repo root): scripts/write_manifest.sh
# RELEASE_DIR overrides the directory it reads and writes.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"

RELEASE_DIR="${RELEASE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)/builds/release}"
[[ -d "$RELEASE_DIR" ]] || die "No release directory: $RELEASE_DIR"

# On CI the commit and the run of the Build; locally the checkout's commit.
SOURCE_COMMIT="${GITHUB_SHA:-$(git -C "$SCRIPT_DIR/.." rev-parse HEAD 2>/dev/null || true)}"
SOURCE_RUN="${GITHUB_RUN_ID:-}"

RELEASE_DIR="$RELEASE_DIR" SOURCE_COMMIT="$SOURCE_COMMIT" SOURCE_RUN="$SOURCE_RUN" python3 - <<'PY'
import hashlib, json, os, pathlib, zipfile

release_dir = pathlib.Path(os.environ["RELEASE_DIR"])
release = os.environ["LIBMPV_RELEASE"]
assets = {}
for f in sorted(release_dir.iterdir()):
    if f.is_file() and f.name.startswith("libmpv_"):
        assets[f.name] = hashlib.sha256(f.read_bytes()).hexdigest()
if not assets:
    raise SystemExit(f"No libmpv_* binaries in {release_dir}")

# libmpv_linux-x86_64.so and libmpv_macos.xcframework.zip are the targets
# linux-x86_64 and macos.
records = {}
for name in assets:
    target = name[len("libmpv_"):].split(".", 1)[0]
    path = release_dir / f"build_{target}.json"
    if not path.is_file():
        raise SystemExit(f"{name} has no build record {path.name}: build it again")
    record = json.loads(path.read_text())
    if record["release"] != release:
        raise SystemExit(f"{path.name} is a build of {record['release']}, not {release}")
    records[target] = record
filters = {t: sorted(r["audioFilters"]) for t, r in records.items()}
if len({tuple(f) for f in filters.values()}) != 1:
    raise SystemExit("The builds disagree on audioFilters:\n" +
                     "\n".join(f"  {t}: {','.join(f)}" for t, f in sorted(filters.items())))

# The web module: the files a client installs (libmpv.mjs imports
# libmpv.wasm and loads the worklet from beside itself) and the record of
# the build, which must be the one next to the zip.
WEB_FILES = ["libmpv.mjs", "libmpv.wasm", "mak_webaudio_processor.js"]
web = None
if "web" in records:
    asset = next(n for n in assets if n.startswith("libmpv_web."))
    try:
        with zipfile.ZipFile(release_dir / asset) as z:
            members = {i.filename: z.read(i) for i in z.infolist()}
    except zipfile.BadZipFile as e:
        raise SystemExit(f"{asset} is not a zip: {e}")
    if sorted(members) != sorted(WEB_FILES + ["build_web.json"]):
        raise SystemExit(f"{asset} holds {sorted(members)}, not "
                         f"{sorted(WEB_FILES + ['build_web.json'])}")
    if json.loads(members["build_web.json"]) != records["web"]:
        raise SystemExit(f"The build_web.json in {asset} is not the one next to it")
    module = records["web"].get("module") or {}
    if not all(isinstance(module.get(k), int) for k in ("abi", "webaudioAbi")):
        raise SystemExit("build_web.json has no module versions (abi, webaudioAbi): build it again")
    web = {
        "asset": asset,
        "abi": module["abi"],
        "webaudioAbi": module["webaudioAbi"],
        "emscripten": module.get("emscripten"),
        "files": {n: hashlib.sha256(members[n]).hexdigest() for n in WEB_FILES},
    }

manifest = {
    "release": release,
    "mpv": os.environ["MPV_VERSION"],
    "ffmpeg": os.environ["FFMPEG_VERSION"],
    "audioFilters": next(iter(filters.values())),
    "patches": {t: records[t]["patches"] for t in sorted(records)},
    "source": {
        "commit": os.environ["SOURCE_COMMIT"] or None,
        "run": os.environ["SOURCE_RUN"] or None,
    },
    "assets": assets,
}
if web:
    manifest["web"] = web
out = release_dir / "manifest.json"
out.write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Wrote {out} ({len(assets)} assets, {len(manifest['audioFilters'])} filters)")
sums = release_dir / "SHA256SUMS"
sums.write_text("".join(f"{h}  {n}\n" for n, h in assets.items()))
print(f"Wrote {sums}")
PY
