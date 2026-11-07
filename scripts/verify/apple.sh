# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# The Apple layers of verify_binaries.sh (macOS, iOS, tvOS): the L13 dyld
# load on a macOS host, the xcframework slice check and L15 code-signing
# identity. Sourced by verify_binaries.sh. Do not run directly.

# macOS dlopen(RTLD_NOW) on a Darwin host. Closes the L13 gap for macOS: when
# verify runs natively on the Mac (clang present), it compiles the shared
# dlopen_test helper with the host clang and loads the universal dylib's
# host-arch slice — the exact dyld bind a Flutter app does at startup — then
# creates + initializes an mpv handle and reads back patched properties.
_l13_macos_dlopen() {
  local dylib="$1"
  if [[ "$(uname -s)" != "Darwin" ]]; then
    na "macOS dlopen needs a macOS host; this run is on $(uname -s) (e.g. the Linux build container — a Mach-O dylib cannot be loaded there). Run ./scripts/verify_binaries.sh macos natively on macOS to exercise the real dyld load; static layers (1-11) validate the dylib here."
    return 0
  fi
  if ! command -v clang >/dev/null 2>&1; then
    na "macOS dlopen needs clang (Xcode Command Line Tools) on the host; not found. Static layers (1-11) validate the dylib."
    return 0
  fi
  if [[ -z "$dylib" || ! -f "$dylib" ]]; then
    warn "L13 macOS: inner libmpv dylib not found to dlopen"
    return 0
  fi
  local helper_src="$LIBMPV_SCRIPTS_ROOT/verify/dlopen_test.c"
  if [[ ! -f "$helper_src" ]]; then
    warn "L13: dlopen helper missing: $helper_src"
    return 0
  fi
  local helper_bin; helper_bin="$(mktemp)"
  # macOS: dlopen/dlsym live in libSystem (no -ldl needed). Build for the host
  # arch so dlopen resolves the matching universal slice.
  if ! clang -O0 -o "$helper_bin" "$helper_src" 2>/dev/null; then
    fail "L13: dlopen helper failed to compile with host clang"
    rm -f "$helper_bin"
    return 0
  fi
  # The shipped dylib is adhoc-signed but the build's `strip -x` rewrote the
  # Mach-O AFTER signing, so its CodeDirectory hashes no longer match. On Apple
  # Silicon the kernel SIGKILLs any process that dlopen()s a broken-signature
  # image, so re-sign an adhoc COPY (the original is untouched; a consumer app
  # re-signs the dylib as part of its own bundle anyway). codesign is part of
  # the Xcode CLT that already provides clang above.
  local load_dylib="$dylib" signed_copy=""
  if command -v codesign >/dev/null 2>&1; then
    signed_copy="$(mktemp)"
    if cp "$dylib" "$signed_copy" && codesign --force --sign - "$signed_copy" 2>/dev/null; then
      load_dylib="$signed_copy"
    else
      rm -f "$signed_copy"; signed_copy=""
    fi
  fi
  local TO=()
  if command -v timeout  >/dev/null 2>&1; then TO=(timeout 60)
  elif command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout 60); fi
  local out rc
  out="$("${TO[@]}" "$helper_bin" "$load_dylib" 2>&1)"; rc=$?
  rm -f "$helper_bin"; [[ -n "$signed_copy" ]] && rm -f "$signed_copy"
  case "$rc" in
    0)   pass "L13 dlopen(RTLD_NOW, host dyld): loads + initializes + patched props respond at runtime ($(uname -m) slice)" ;;
    124) fail "L13 dlopen timed out after 60s: $out" ;;
    137) fail "L13 dlopen killed (SIGKILL=137) — likely a code-signature rejection the adhoc re-sign didn't fix: $out" ;;
    *)   fail "L13 dlopen failed (exit=$rc): $out" ;;
  esac
  return 0
}

# The slices of an unzipped libmpv.xcframework under [dir]: each one of
# [platform] (macos-, ios- or tvos-), and on iOS and tvOS a device slice.
# The _CodeSignature/ of codesign --deep, beside them, is no slice.
# The iOS and tvOS zips come from one script, so a wrong SDK or version
# flag would give a tvOS zip of iOS slices that every other layer passes.
_xcf_slices_check() {
  local platform="$1" dir="$2" s name names=() other=() device=0
  for s in "$dir"/libmpv.xcframework/*/; do
    [[ -d "$s" ]] || continue
    name="$(basename "$s")"
    [[ "$name" == _* ]] && continue
    names+=("$name")
    [[ "$name" == "$platform-"* ]] || other+=("$name")
    [[ "$name" != *-simulator ]] && device=1
  done
  if (( ${#names[@]} == 0 )); then
    fail "xcframework slices: none found"
  elif (( ${#other[@]} )); then
    fail "xcframework slices: ${other[*]} not of $platform"
  elif [[ "$platform" != macos ]] && (( ! device )); then
    fail "xcframework slices: no $platform device slice (${names[*]})"
  else
    pass "xcframework slices: ${names[*]}"
  fi
}

# Layer 15: Apple code-signing identity. For every slice in a libmpv.xcframework
# the embedded code-signing identifier (parsed from the Mach-O CodeDirectory)
# must equal that framework's CFBundleIdentifier. iOS `installd` rejects a
# device install on any mismatch (MismatchedBundleIDSigningIdentifier) — the
# exact libmpv-r9 / 0.3.5 regression, which passed every other layer because
# only a physical-device install enforces this rule (Simulator, macOS, dlopen
# and flutter test all ignore it). The signature is parsed directly
# (verify/codesign_ident.py), so this runs in the build container — meson
# already requires python3 — without needing macOS-only `codesign`.
# Args: $1 = platform, $2 = extracted xcframework dir ($xcf_tmp, may be empty)
layer15_codesign_identity() {
  local platform="$1" xcf_dir="$2"
  phase l15
  case "$platform" in
    macos|ios|tvos) ;;
    *) na "Apple code-signing only; $platform binaries are not embedded-signed .framework bundles (the identifier==bundle-id rule is an Apple loader concern)."; return 0 ;;
  esac
  if [[ -z "$xcf_dir" || ! -d "$xcf_dir" ]]; then
    warn "L15: xcframework not extracted — cannot inspect signing identity"
    return 0
  fi
  local helper="$LIBMPV_SCRIPTS_ROOT/verify/codesign_ident.py"
  if ! command -v python3 >/dev/null 2>&1 || [[ ! -f "$helper" ]]; then
    na "needs python3 + verify/codesign_ident.py to parse the Mach-O CodeDirectory; neither present here."
    return 0
  fi
  local out rc
  out="$(python3 "$helper" "$xcf_dir" 2>&1)"; rc=$?
  if [[ $rc -eq 0 ]]; then
    while IFS= read -r line; do [[ -n "$line" ]] && info "$line"; done <<<"$out"
    pass "L15 code-signing identity == CFBundleIdentifier on every slice (installs on a physical iPhone)"
  else
    while IFS= read -r line; do [[ -n "$line" ]] && printf "     %s\n" "$line"; done <<<"$out"
    fail "L15 code-signing identity != CFBundleIdentifier — iOS installd would reject this on a physical device (MismatchedBundleIDSigningIdentifier)"
  fi
}
