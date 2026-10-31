# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Shared helpers for the build_libmpv_<platform>.sh scripts.
# Sourced by every script. Do not run directly.

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
# Usage: download <url> <dest_path> [mirror_url...]
# Smart default: an existing non-empty dest is always reused. Pass
# FORCE_DOWNLOAD=1 to redownload (useful when a tarball is corrupted or the
# upstream URL points at a moving tag). The mirrors are tried in order when
# <url> fails; the file is always checked against the pin of <url>, so a
# mirror can only serve the same bytes.
download() {
  local url="$1" dest="$2"; shift 2
  if [[ -s "$dest" && "${FORCE_DOWNLOAD:-0}" != "1" ]]; then
    ok "Cached: $(basename "$dest")"
    verify_source "$url" "$dest"
    return
  fi
  log "Download: $(basename "$dest")"
  mkdir -p "$(dirname "$dest")"
  local from fetched=0 retry=(--retry 3)
  # A reset connection is retried only with --retry-all-errors (curl 7.71;
  # the Linux image is Ubuntu 20.04, curl 7.68).
  [[ "$(curl --help all 2>/dev/null)" == *--retry-all-errors* ]] &&
    retry+=(--retry-all-errors)
  for from in "$url" "$@"; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "${retry[@]}" -o "$dest" "$from" && fetched=1
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O "$dest" "$from" && fetched=1
    else
      die "neither curl nor wget available"
    fi
    [[ "$fetched" == "1" ]] && break
    rm -f "$dest"
    warn "Download failed: $from"
  done
  [[ "$fetched" == "1" ]] || die "Download failed: $url"
  verify_source "$url" "$dest"
}

# ── Source pinning ───────────────────────────────────────────────────────────
# Every tarball is checked against scripts/shared/_sources.sha256, lines of
# "<sha256>  <url>", and every git tag clone against "<commit>  <url>#<tag>".
# A mismatch stops the build (and deletes a bad tarball). A source with no
# entry stops it too under STRICT_SOURCES=1 (what CI runs); locally it only
# warns. RECORD_SOURCES=<file> appends the line to pin it, also right before
# a strict build stops, so CI can publish it.
SOURCES_SHA256_FILE="$LIBMPV_SCRIPTS_ROOT/scripts/shared/_sources.sha256"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# pinned_source <key> — the pinned hash of <key> in _sources.sha256, or "".
pinned_source() {
  awk -v u="$1" '!/^#/ && $2 == u { print $1 }' "$SOURCES_SHA256_FILE" 2>/dev/null
}

# unpinned_source <hash> <key> — record, then stop (strict) or warn.
unpinned_source() {
  local got="$1" key="$2"
  if [[ -n "${RECORD_SOURCES:-}" ]]; then
    mkdir -p "$(dirname "$RECORD_SOURCES")"
    printf '%s  %s\n' "$got" "$key" >> "$RECORD_SOURCES"
  fi
  [[ "${STRICT_SOURCES:-0}" == "1" ]] && \
    die "Unpinned source, add to _sources.sha256: $got  $key"
  warn "Unpinned source: $got  $key"
  return 0
}

verify_source() {
  local url="$1" file="$2" want got
  got="$(sha256_of "$file")"
  want="$(pinned_source "$url")"
  if [[ -z "$want" ]]; then
    unpinned_source "$got" "$url"
    return 0
  fi
  if [[ "$got" != "$want" ]]; then
    rm -f "$file"
    die "SHA-256 mismatch for $url: got $got, expected $want"
  fi
}

# verify_git_source <url> <tag> <dir> — the clone's HEAD must be the commit
# pinned for <url>#<tag>, so a moved tag cannot change what gets built.
verify_git_source() {
  local url="$1" tag="$2" dir="$3" want got
  # safe.directory: a clone made as root in Docker may be read by another user.
  got="$(git -c safe.directory='*' -C "$dir" rev-parse HEAD)" || die "Not a git clone: $dir"
  want="$(pinned_source "$url#$tag")"
  if [[ -z "$want" ]]; then
    unpinned_source "$got" "$url#$tag"
    return 0
  fi
  [[ "$got" == "$want" ]] || \
    die "Commit mismatch for $url at $tag: got $got, expected $want (FORCE_DOWNLOAD=1 reclones)"
}

# ── Git clone with cache ─────────────────────────────────────────────────────
# Usage: download_git <repo_url> <dest_dir> [tag_or_branch]
# Smart default: an existing clone is always reused. Pass FORCE_DOWNLOAD=1
# to wipe and reclone. A requested tag that does not exist stops the build:
# falling back to the default branch would silently build whatever is on it
# today. A tag clone, fresh or cached, is checked by verify_git_source.
download_git() {
  local url="$1" dest="$2" tag="${3:-}"
  if [[ -d "$dest/.git" && "${FORCE_DOWNLOAD:-0}" != "1" ]]; then
    ok "Cached clone: $(basename "$dest")"
    [[ -n "$tag" ]] && verify_git_source "$url" "$tag" "$dest"
    return 0
  fi
  [[ "${FORCE_DOWNLOAD:-0}" == "1" ]] && rm -rf "$dest"
  log "Git clone: $(basename "$dest")"
  mkdir -p "$(dirname "$dest")"
  if [[ -n "$tag" ]]; then
    git clone --depth=1 --branch "$tag" "$url" "$dest" \
      || { rm -rf "$dest"; die "git clone failed, or no tag $tag: $url"; }
    ok "$(basename "$dest") $tag at $(git -C "$dest" rev-parse HEAD)"
    verify_git_source "$url" "$tag" "$dest"
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
