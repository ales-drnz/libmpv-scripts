#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks scripts/update_cacert.sh on two bundles cut from the one in the repo
# and served from file:// URLs (no network), and reports the age of
# patches/ffmpeg/embed_cacert/cacert.pem.
#
# The age is a warning: a bundle older than CACERT_MAX_AGE_MONTHS (default 4)
# does not fail the test, since a refresh changes what every libmpv trusts
# and is a decision, not a build step. CACERT_AGE_STRICT=1 makes it fail (for
# a release checklist). CACERT_NOW=<date> sets the day the age is counted
# from.
#
# Usage: bash verify/tests/cacert_test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PEM="$ROOT/patches/ffmpeg/embed_cacert/cacert.pem"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
bad() { echo "FAIL: $*"; failures=$((failures + 1)); }

# ── update_cacert.sh ─────────────────────────────────────────────────────────
# "old" is the bundle without its last CA, "new" the bundle without its
# first: the refresh adds the last and removes the first.
read -r FIRST LAST < <(python3 -I - "$PEM" "$TMP" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
out = pathlib.Path(sys.argv[2])
blocks = list(re.finditer(
    r"^[^\n#][^\n]*\n=+\n(?:#[^\n]*\n)*-----BEGIN CERTIFICATE-----\n.*?-----END CERTIFICATE-----\n",
    text, re.M | re.S))
assert len(blocks) > 50, len(blocks)
first, last = blocks[0], blocks[-1]
(out / "old.pem").write_text(text[:last.start()] + text[last.end():], encoding="utf-8")
(out / "cacert.pem").write_text(text[:first.start()] + text[first.end():], encoding="utf-8")
name = lambda m: m.group(0).split("\n", 1)[0].replace(" ", "_")
print(name(first), name(last))
PY
)
[[ -n "${FIRST:-}" && -n "${LAST:-}" ]] || { echo "FAIL: could not cut the fixtures"; exit 1; }
FIRST="${FIRST//_/ }" LAST="${LAST//_/ }"
( cd "$TMP" && sha256sum cacert.pem > cacert.pem.sha256 )

run() { # run <dest> [args]: the script on the fixtures, output in $TMP/out
  local dest="$1"; shift
  CACERT_URL="file://$TMP/cacert.pem" CACERT_DEST="$dest" \
    bash "$ROOT/scripts/update_cacert.sh" "$@" > "$TMP/out" 2>&1
}

cp "$TMP/old.pem" "$TMP/dest.pem"
before="$(sha256sum < "$TMP/dest.pem")"
run "$TMP/dest.pem" --check || { bad "--check exits non-zero"; cat "$TMP/out"; }
grep -qF "CAs added (1):" "$TMP/out" && grep -qF "  + $LAST  [" "$TMP/out" ||
  { bad "--check does not list the CA that enters ($LAST)"; cat "$TMP/out"; }
grep -qF "CAs removed (1):" "$TMP/out" && grep -qF "  - $FIRST  [" "$TMP/out" ||
  { bad "--check does not list the CA that leaves ($FIRST)"; cat "$TMP/out"; }
[[ "$(sha256sum < "$TMP/dest.pem")" == "$before" ]] || bad "--check wrote the bundle"

# A checksum that does not match stops the refresh and writes nothing.
printf '%064d  cacert.pem\n' 0 > "$TMP/cacert.pem.sha256"
if run "$TMP/dest.pem"; then bad "a wrong cacert.pem.sha256 was accepted"; fi
grep -q "SHA-256 mismatch" "$TMP/out" || { bad "no mismatch message"; cat "$TMP/out"; }
[[ "$(sha256sum < "$TMP/dest.pem")" == "$before" ]] || bad "a wrong checksum still wrote the bundle"

# No checksum file at all stops it too.
rm -f "$TMP/cacert.pem.sha256"
if run "$TMP/dest.pem"; then bad "a missing cacert.pem.sha256 was accepted"; fi
[[ "$(sha256sum < "$TMP/dest.pem")" == "$before" ]] || bad "a missing checksum still wrote the bundle"

# With the right checksum the refresh writes exactly the download.
( cd "$TMP" && sha256sum cacert.pem > cacert.pem.sha256 )
run "$TMP/dest.pem" || { bad "the refresh exits non-zero"; cat "$TMP/out"; }
cmp -s "$TMP/dest.pem" "$TMP/cacert.pem" || bad "the refresh did not write the download"

# ── age of the bundle in the repo ────────────────────────────────────────────
MAX="${CACERT_MAX_AGE_MONTHS:-4}"
age="$(python3 -I - "$PEM" "${CACERT_NOW:-}" <<'PY'
import datetime, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"as of: \w+ (\w+) +(\d+) [\d:]+ (\d{4}) GMT", text)
if not m:
    sys.exit("no 'Certificate data from Mozilla as of' date in the bundle")
made = datetime.datetime.strptime(" ".join(m.groups()), "%b %d %Y").date()
now = (datetime.date.fromisoformat(sys.argv[2]) if sys.argv[2]
       else datetime.datetime.now(datetime.timezone.utc).date())
days = (now - made).days
print(made.isoformat(), days, f"{days / 30.44:.1f}")
PY
)" || { bad "the date of the bundle cannot be read"; age=""; }
if [[ -n "$age" ]]; then
  read -r made days months <<< "$age"
  if (( days > MAX * 3044 / 100 )); then
    echo "WARNING: cacert.pem is from $made, $months months old (more than $MAX)." \
         "scripts/update_cacert.sh --check lists what a refresh changes."
    # A GitHub annotation, so the warning shows on the run's page.
    [[ -n "${GITHUB_ACTIONS:-}" ]] &&
      echo "::warning file=patches/ffmpeg/embed_cacert/cacert.pem::CA bundle from $made, $months months old"
    [[ "${CACERT_AGE_STRICT:-0}" == "1" ]] && bad "cacert.pem is older than $MAX months (CACERT_AGE_STRICT=1)"
  else
    echo "cacert.pem is from $made, $months months old"
  fi
fi

[[ $failures -eq 0 ]] && echo "cacert_test: ok"
exit $(( failures > 0 ))
