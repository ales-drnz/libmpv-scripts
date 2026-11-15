#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# update_cacert.sh
#
# Refreshes patches/ffmpeg/embed_cacert/cacert.pem from curl.se's canonical
# mirror of the Mozilla CA bundle. Run before a binary release so HTTPS
# verification keeps working as Mozilla rotates its trust list.
#
# The bundle is the build-time input to the `embed_cacert` patch
# (patches/ffmpeg/patch_ffmpeg_embed_cacert.py), which compiles it into the
# OpenSSL TLS backend so HTTPS peer verification needs no on-device cert file.
# After refreshing, rebuild the binaries to pick up the new roots.
#
# The download is checked against https://curl.se/ca/cacert.pem.sha256, and
# the CAs that enter and leave the trust list are printed before anything is
# written: the bundle is the trust anchor of every libmpv, so a refresh is
# read, not only run.
#
# Usage (from anywhere):
#   ./scripts/update_cacert.sh           refresh the bundle in the repo
#   ./scripts/update_cacert.sh --check   print what a refresh would change,
#                                        write nothing
#
# CACERT_URL=<url> takes the bundle (and <url>.sha256) from somewhere else and
# CACERT_DEST=<file> writes another file; verify/tests/cacert_test.sh uses
# both, with file:// URLs.
#
# Exit code: 0 on success, non-zero if the download, the checksum or the
# write fails.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives in scripts/, so the repo root is one up.
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${CACERT_DEST:-$ROOT/patches/ffmpeg/embed_cacert/cacert.pem}"
URL="${CACERT_URL:-https://curl.se/ca/cacert.pem}"

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  '') ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

echo "Fetching $URL..."
TMP="$(mktemp)"
SUM="$(mktemp)"
trap 'rm -f "$TMP" "$SUM"' EXIT
curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 -o "$TMP" "$URL"
curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 -o "$SUM" "$URL.sha256"

# The checksum file is "<sha256>  cacert.pem". It comes from the same host
# as the bundle, so it catches a truncated or mangled download, not a
# compromised curl.se: the list of changes below is what a person reads.
WANT="$(awk 'NR == 1 { print $1 }' "$SUM")"
GOT="$(sha256_of "$TMP")"
if [[ ! "$WANT" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: $URL.sha256 does not start with a SHA-256." >&2
  exit 1
fi
if [[ "$GOT" != "$WANT" ]]; then
  echo "ERROR: SHA-256 mismatch for $URL: got $GOT, expected $WANT." >&2
  exit 1
fi

# Sanity: the response must look like a CA bundle. Reject anything that
# doesn't contain at least one PEM-encoded certificate (defensive against
# a captive-portal HTML page or a CDN error page silently overwriting
# the bundle).
if ! grep -q '^-----BEGIN CERTIFICATE-----' "$TMP"; then
  echo "ERROR: downloaded file does not contain any PEM certificate." >&2
  exit 1
fi

CA_COUNT="$(grep -c '^-----BEGIN CERTIFICATE-----' "$TMP")"
if (( CA_COUNT < ${CACERT_MIN_COUNT:-50} )); then
  echo "ERROR: only $CA_COUNT certificates in bundle, looks truncated." >&2
  exit 1
fi

# Print bundle metadata so the operator can sanity-check the version.
HEADER_DATE="$(grep -m1 'Certificate data from Mozilla' "$TMP" || echo '(no date header)')"

echo "  SHA-256:   $GOT (matches $URL.sha256)"
echo "  $HEADER_DATE"
echo "  Total CAs: $CA_COUNT"

# The CAs that enter and leave, by the name mk-ca-bundle gives each one (the
# line above its ==== rule) and the SHA-256 of its certificate, so a root
# reissued under the same name shows as one removed and one added. Newer
# bundles (mk-ca-bundle 1.35) put a "# Fingerprint" line under the rule.
if [[ -s "$DEST" ]]; then
  echo "  Against:   $(grep -m1 'Certificate data from Mozilla' "$DEST" || echo "$DEST")"
  python3 -I - "$DEST" "$TMP" <<'PY'
import base64, hashlib, re, sys

def roots(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    found = {}
    for name, body in re.findall(
            r"^([^\n#][^\n]*)\n=+\n(?:#[^\n]*\n)*-----BEGIN CERTIFICATE-----\n(.*?)\n-----END CERTIFICATE-----",
            text, re.M | re.S):
        der = base64.b64decode("".join(body.split()))
        found[hashlib.sha256(der).hexdigest()] = name.strip()
    return found

old, new = roots(sys.argv[1]), roots(sys.argv[2])
added = sorted((new[h], h) for h in new.keys() - old.keys())
removed = sorted((old[h], h) for h in old.keys() - new.keys())
print(f"\nCAs added ({len(added)}):")
for name, h in added:
    print(f"  + {name}  [{h[:16]}]")
print(f"CAs removed ({len(removed)}):")
for name, h in removed:
    print(f"  - {name}  [{h[:16]}]")
print(f"CAs kept: {len(new.keys() & old.keys())}")
PY
fi

if [[ "$CHECK" == "1" ]]; then
  echo
  echo "--check: $DEST not written."
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
mv -f "$TMP" "$DEST"
rm -f "$SUM"
trap - EXIT

echo
echo "→ $DEST"
echo "  Size:      $(wc -c < "$DEST" | tr -d ' ') bytes"
echo
echo "Now rebuild the binaries so the embed_cacert patch picks up the new roots."
