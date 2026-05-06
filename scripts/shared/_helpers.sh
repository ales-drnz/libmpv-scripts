# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Shared helpers for the build_libmpv_<platform>.sh scripts.
# Sourced by every script. Do not run directly.

# ── Repo root resolution ─────────────────────────────────────────────────────
# Locates the `mpv_audio_kit` Flutter package this build infrastructure
# targets. Build outputs (libraries, generated Dart sources, fixtures) all
# land under the repo root resolved here.
#
# Self-locating + depth-agnostic: walks up the directory tree from this
# file's location, at each ancestor checking for a sibling
# `mpv_audio_kit/`. Works whether `_helpers.sh` lives at the top of
# libmpv-scripts/ or several subfolders deep (e.g. scripts/shared/).
#
# Resolution order:
#   1. $MPV_AUDIO_KIT_ROOT — explicit override (used by Docker runs
#                            where /repo is bind-mounted).
#   2. Walk up from <helpers_dir>; at each ancestor check for a sibling
#      `mpv_audio_kit/` whose pubspec.yaml has `name: mpv_audio_kit`.
#   3. Walk up from <helpers_dir>; at each ancestor check the directory
#      itself (legacy nested layout, when this infrastructure used to
#      live inside `mpv_audio_kit/scripts/`).
#
# Errors out with an actionable message when no candidate is valid.
#
# Optional first argument is accepted but ignored (back-compat shim).
resolve_repo_root() {
  local helpers_dir
  helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local candidate

  if [[ -n "${MPV_AUDIO_KIT_ROOT:-}" ]]; then
    candidate="$MPV_AUDIO_KIT_ROOT"
    _validate_repo_root "$candidate" "MPV_AUDIO_KIT_ROOT" || return 1
    (cd "$candidate" && pwd)
    return 0
  fi

  # Walk up looking for a sibling `mpv_audio_kit/` (production layout).
  local search="$helpers_dir"
  while [[ "$search" != "/" ]]; do
    candidate="$search/../mpv_audio_kit"
    if [[ -f "$candidate/pubspec.yaml" ]] && \
       grep -q "^name: mpv_audio_kit" "$candidate/pubspec.yaml" 2>/dev/null; then
      (cd "$candidate" && pwd)
      return 0
    fi
    search="$(dirname "$search")"
  done

  # Walk up looking for an ancestor that IS the mpv_audio_kit checkout
  # (legacy layout, scripts nested inside the package).
  search="$helpers_dir"
  while [[ "$search" != "/" ]]; do
    if [[ -f "$search/pubspec.yaml" ]] && \
       grep -q "^name: mpv_audio_kit" "$search/pubspec.yaml" 2>/dev/null; then
      (cd "$search" && pwd)
      return 0
    fi
    search="$(dirname "$search")"
  done

  echo "ERROR: cannot locate the mpv_audio_kit repo." >&2
  echo "Tried walking up from $helpers_dir:" >&2
  echo "  - looking for a sibling mpv_audio_kit/ at every ancestor" >&2
  echo "  - looking for an mpv_audio_kit ancestor (legacy nested layout)" >&2
  echo "" >&2
  echo "Set MPV_AUDIO_KIT_ROOT=/absolute/path/to/mpv_audio_kit" >&2
  return 1
}

_validate_repo_root() {
  local path="$1" source="$2"
  if [[ ! -d "$path" ]]; then
    echo "ERROR: $source points at a non-existent path: $path" >&2
    return 1
  fi
  if [[ ! -f "$path/pubspec.yaml" ]]; then
    echo "ERROR: $source does not contain pubspec.yaml: $path" >&2
    return 1
  fi
  if ! grep -q "^name: mpv_audio_kit" "$path/pubspec.yaml" 2>/dev/null; then
    echo "ERROR: $source pubspec.yaml is not the mpv_audio_kit package: $path" >&2
    return 1
  fi
  return 0
}

# ── libmpv-scripts repo root ─────────────────────────────────────────────────
# Self-locating: this file lives at <repo>/scripts/shared/_helpers.sh, so the
# repo root is two levels up. Used by every callsite that references the
# `patches/`, `builds/`, `verify/`, or `docker/` directories (which all live at
# the repo top level, NOT under `scripts/`).
LIBMPV_SCRIPTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export LIBMPV_SCRIPTS_ROOT

# ── ANSI colours ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { echo -e "${CYAN}▶ $*${NC}" >&2; }
ok()   { echo -e "${GREEN}✓ $*${NC}" >&2; }
warn() { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
err()  { echo -e "${RED}✗ $*${NC}" >&2; }
die()  { err "$*"; exit 1; }

# Backwards-compatible alias used by some scripts.
fail() { die "$@"; }

# ── Source download with cache ───────────────────────────────────────────────
# Usage: download <url> <dest_path>
# Smart default: an existing non-empty dest is always reused. Pass
# FORCE_DOWNLOAD=1 to redownload (useful when a tarball is corrupted or the
# upstream URL points at a moving tag). SKIP_DOWNLOAD=1 is still honored as
# a no-op for backwards compatibility — the cache is the default now.
download() {
  local url="$1" dest="$2"
  if [[ -s "$dest" && "${FORCE_DOWNLOAD:-0}" != "1" ]]; then
    ok "Cached: $(basename "$dest")"
    return
  fi
  log "Download: $(basename "$dest")"
  mkdir -p "$(dirname "$dest")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$dest" "$url" || die "Download failed: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" "$url" || die "Download failed: $url"
  else
    die "neither curl nor wget available"
  fi
}

# ── Git clone with cache ─────────────────────────────────────────────────────
# Usage: download_git <repo_url> <dest_dir> [tag_or_branch]
# Smart default: an existing clone is always reused. Pass FORCE_DOWNLOAD=1
# to wipe and reclone. If a specific tag is requested, falls back to a full
# shallow clone when the tag isn't reachable on the remote.
download_git() {
  local url="$1" dest="$2" tag="${3:-}"
  if [[ -d "$dest/.git" && "${FORCE_DOWNLOAD:-0}" != "1" ]]; then
    ok "Cached clone: $(basename "$dest")"
    return
  fi
  [[ "${FORCE_DOWNLOAD:-0}" == "1" ]] && rm -rf "$dest"
  log "Git clone: $(basename "$dest")"
  mkdir -p "$(dirname "$dest")"
  if [[ -n "$tag" ]]; then
    git clone --depth=1 --branch "$tag" "$url" "$dest" 2>/dev/null \
      || { rm -rf "$dest"; git clone --depth=1 "$url" "$dest"; }
  else
    git clone --depth=1 "$url" "$dest" || die "git clone failed: $url"
  fi
}

# ── Build dir cleanup ────────────────────────────────────────────────────────
# Default: wipe `build/` and `prefix/` but KEEP `src/` (the download cache).
# Next invocation reuses the tarballs/git clones — saves a full re-download
# even when you don't pass KEEP_BUILD=1.
#
# KEEP_BUILD=1 — preserve everything (useful for inspecting build artifacts)
# WIPE_ALL=1   — also wipe the download cache (forces full re-download next run)
cleanup_build() {
  local build_dir="$1"
  # Guard against an empty arg: `rm -rf "$build_dir/build"` with build_dir=""
  # would target "/build" at the filesystem root (the container runs as root).
  [[ -n "$build_dir" ]] || die "cleanup_build: empty build dir (refusing to rm -rf)"
  if [[ "${KEEP_BUILD:-0}" == "1" ]]; then
    log "Keeping BUILD_DIR (KEEP_BUILD=1)"
    return
  fi
  if [[ "${WIPE_ALL:-0}" == "1" ]]; then
    rm -rf "$build_dir"
    ok "BUILD_DIR removed (incl. download cache)"
  else
    rm -rf "$build_dir/build" "$build_dir/prefix"
    ok "BUILD_DIR cleaned — src/ download cache kept"
  fi
}

# ── Archive extract ──────────────────────────────────────────────────────────
# Usage: extract <archive_path> <dest_parent>
# Detects extracted top directory from the archive's basename minus the
# `.tar.<ext>` / `.tgz` suffix. Returns the extracted directory path on
# stdout. Idempotent: if the directory already exists, skips extraction.
extract() {
  local archive="$1" dest_parent="$2"
  local name
  name="$(basename "$archive" | sed 's/\.tar\..*//' | sed 's/\.tgz//')"
  if [[ -d "$dest_parent/$name" ]]; then
    ok "Already extracted: $name"
    echo "$dest_parent/$name"
    return
  fi
  log "Extracting: $name"
  mkdir -p "$dest_parent"
  tar -xf "$archive" -C "$dest_parent"
  echo "$dest_parent/$name"
}
