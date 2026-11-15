#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks check_emsdk_files of scripts/build_libmpv_web.sh on a fake emsdk
# tree: the function is taken from the script as it is written. Every native
# tool it lists and emcc.py must have the SHA-256 of the pins, a tool behind
# a symlink is hashed as the file it points to, and a changed, missing or
# (under STRICT_SOURCES=1) unpinned file stops the build. Then the pins of
# the repo: one for each file of the emsdk release the script names, for
# linux-x86_64, the host of the CI job.
#
# Usage: bash verify/tests/emsdk_pins_test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/build_libmpv_web.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

{
  grep -E '^EMSDK_VERSION=' "$SCRIPT"
  grep -E '^EMSDK_NATIVE=' "$SCRIPT"
  awk '$0 == "check_emsdk_files() {" { on = 1 } on { print } on && $0 == "}" { exit }' "$SCRIPT"
} > "$TMP/emsdk.sh"
[[ "$(wc -l < "$TMP/emsdk.sh")" -gt 10 ]]; check $? "the script has EMSDK_VERSION, EMSDK_NATIVE and check_emsdk_files"
# shellcheck disable=SC1091
VERSION="$(bash -c "source '$TMP/emsdk.sh' 2>/dev/null; echo \"\$EMSDK_VERSION\"")"
read -r -a NATIVE <<< "$(bash -c "source '$TMP/emsdk.sh' 2>/dev/null; echo \"\${EMSDK_NATIVE[*]}\"")"
[[ " ${NATIVE[*]} " == *" bin/clang "* && " ${NATIVE[*]} " == *" bin/wasm-ld "* &&
   " ${NATIVE[*]} " == *" bin/wasm-opt "* && " ${NATIVE[*]} " == *" bin/llvm-ar "* ]]
check $? "the compiler, the linker, the optimizer and the archiver are among the files checked"

# A fake release: wasm-ld is a symlink to lld, as in emsdk.
U="$TMP/upstream"; mkdir -p "$U/bin" "$U/emscripten"
HOST="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
: > "$TMP/pins"
for f in "${NATIVE[@]}" emscripten/emcc.py; do
  if [[ "$f" == bin/wasm-ld ]]; then
    printf 'lld of the test\n' > "$U/bin/lld"; ln -s lld "$U/bin/wasm-ld"
  else
    printf '%s of the test\n' "$f" > "$U/$f"
  fi
  key="emsdk:$VERSION/upstream/$f"
  [[ "$f" == bin/* ]] && key="emsdk:$VERSION/$HOST/upstream/$f"
  printf '%s  %s\n' "$(sha256sum "$U/$f" | cut -d' ' -f1)" "$key" >> "$TMP/pins"
done

# run [env...]: check_emsdk_files on the fake release, with the pins of $TMP/pins.
run() {
  env TMPDIR="$TMP" STRICT_SOURCES=1 "$@" bash -c "
    set -euo pipefail
    source '$ROOT/scripts/shared/_helpers.sh'
    unset RECORD_SOURCES
    SOURCES_SHA256_FILE='$TMP/pins'
    source '$TMP/emsdk.sh'
    check_emsdk_files '$U'" > "$TMP/out" 2>&1
}
run; check $? "a release whose files all match their pins passes"

printf 'another lld\n' > "$U/bin/lld"
if run; then false; else true; fi
check $? "a linker with another SHA-256 stops the build"
grep -q "emsdk:$VERSION/$HOST/upstream/bin/wasm-ld: SHA-256 " "$TMP/out"; check $? "and names the file and the two hashes"
printf 'lld of the test\n' > "$U/bin/lld"

mv "$U/bin/wasm-opt" "$TMP/wasm-opt"
if run; then false; else true; fi
check $? "a release without wasm-opt stops the build"
mv "$TMP/wasm-opt" "$U/bin/wasm-opt"

grep -v '/bin/llvm-ar$' "$TMP/pins" > "$TMP/pins.less" && mv "$TMP/pins.less" "$TMP/pins"
if run; then false; else true; fi
check $? "a file with no pin stops a strict build"
grep -q "Unpinned source, add to _sources.sha256: .*  emsdk:$VERSION/$HOST/upstream/bin/llvm-ar" "$TMP/out"
check $? "and prints the line to pin"
run STRICT_SOURCES=0; check $? "and only warns in a local one"

# The pins of the repo, for the host of the CI job.
missing=0
for f in "${NATIVE[@]}"; do
  grep -Eq "^[0-9a-f]{64}  emsdk:$VERSION/linux-x86_64/upstream/$f\$" "$ROOT/scripts/shared/_sources.sha256" ||
    { echo "no pin: emsdk:$VERSION/linux-x86_64/upstream/$f"; missing=1; }
done
grep -Eq "^[0-9a-f]{64}  emsdk:$VERSION/upstream/emscripten/emcc.py\$" "$ROOT/scripts/shared/_sources.sha256" || missing=1
check $missing "_sources.sha256 pins every file of emsdk $VERSION for linux-x86_64"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "emsdk_pins_test: ok"
