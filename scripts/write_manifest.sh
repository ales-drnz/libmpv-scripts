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
#   release        the release tag suffix (LIBMPV_RELEASE, e.g. "r15")
#   mpv, ffmpeg    the pinned upstream versions
#   audioFilters   the lavfi audio filters compiled in (AUDIO_FILTERS, with
#                  the TUI's overrides applied), which mpv_audio_kit's codegen
#                  turns into its typed effects API
#   assets         SHA-256 of every binary in builds/release/, keyed by name
#
# Usage (from the repo root): scripts/write_manifest.sh
# RELEASE_DIR overrides the directory it reads and writes.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"
source "$SCRIPT_DIR/shared/_audio_only.sh"

RELEASE_DIR="${RELEASE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)/builds/release}"
[[ -d "$RELEASE_DIR" ]] || die "No release directory: $RELEASE_DIR"

RELEASE_DIR="$RELEASE_DIR" python3 - <<'PY'
import hashlib, json, os, pathlib

release_dir = pathlib.Path(os.environ["RELEASE_DIR"])
assets = {}
for f in sorted(release_dir.iterdir()):
    if f.is_file() and f.name.startswith("libmpv_"):
        assets[f.name] = hashlib.sha256(f.read_bytes()).hexdigest()
if not assets:
    raise SystemExit(f"No libmpv_* binaries in {release_dir}")

manifest = {
    "release": os.environ["LIBMPV_RELEASE"],
    "mpv": os.environ["MPV_VERSION"],
    "ffmpeg": os.environ["FFMPEG_VERSION"],
    "audioFilters": sorted(t for t in os.environ["AUDIO_FILTERS"].split(",") if t),
    "assets": assets,
}
out = release_dir / "manifest.json"
out.write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Wrote {out} ({len(assets)} assets, {len(manifest['audioFilters'])} filters)")
PY
