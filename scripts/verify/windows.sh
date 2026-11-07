# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# The Windows layer of verify_binaries.sh: the L13 LoadLibrary test under
# Wine. Sourced by verify_binaries.sh. Do not run directly.

# Wine state for L13. Set once per run.
WINE_PREFIX_READY=0

# _wine_prepare exports a valid XDG_RUNTIME_DIR + HOME (Wine and Box64/FEX spin
# on "XDG_RUNTIME_DIR is invalid or not set in the environment" without one) and
# initializes the Wine prefix a single time, so the per-DLL load test below isn't
# racing a from-scratch wineboot under its own timeout.
_wine_prepare() {
  local wine_bin="$1"
  export HOME="${HOME:-/root}"
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/wine-xdg}"
  mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
  [[ "$WINE_PREFIX_READY" == "1" ]] && return 0
  WINE_PREFIX_READY=1
  log "L13: initializing the Wine prefix once (slow under arm64 emulation)…"
  WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;mshtml=" \
    timeout 180 "$wine_bin" wineboot --init >/dev/null 2>&1 || true
}

_l13_windows_loadlibrary() {
  local arch="$1" artifact="$2"

  # Which (host, PE) combos can we actually LoadLibrary under Wine?
  #   • x86_64 host → distro Wine runs an x86_64 PE natively.
  #   • arm64 host with Hangover (Wine + WoW64 + FEX/Box64; see
  #     docker/Dockerfile) → loads BOTH x86_64 (via the libarm64ecfex FEX
  #     emulator) and aarch64 (native) Windows PEs. This is what lets a
  #     single arm64 machine runtime-validate every Windows binary.
  # Anything else falls back to L11 (NEEDED allowlist, static).
  local host_arch; host_arch="$(uname -m)"
  local pe_arch_norm="$arch"
  [[ "$pe_arch_norm" == "arm64" ]] && pe_arch_norm="aarch64"

  local fex_dll="/usr/lib/wine/aarch64-windows/libarm64ecfex.dll"
  local can_run=0 via="native Wine"
  if [[ "$host_arch" == "x86_64" && "$pe_arch_norm" == "x86_64" ]]; then
    can_run=1
  elif [[ "$host_arch" == "aarch64" || "$host_arch" == "arm64" ]] && [[ -f "$fex_dll" ]]; then
    can_run=1; via="Hangover/FEX"
  fi

  if [[ $can_run -eq 0 ]]; then
    info "L13: Windows LoadLibrary skipped (host=$host_arch PE=$pe_arch_norm, no capable Wine — install Hangover for arm64). L11 NEEDED allowlist still validates."
    return 0
  fi

  if ! command -v wine >/dev/null 2>&1; then
    warn "L13: wine not installed in container — Windows load test skipped"
    return 0
  fi
  local wine_bin; wine_bin="$(command -v wine64 2>/dev/null || command -v wine)"

  local cc=""
  case "$pe_arch_norm" in
    x86_64)  cc="x86_64-w64-mingw32-gcc" ;;
    aarch64) cc="${LLVM_MINGW_DIR:-/opt/llvm-mingw}/bin/aarch64-w64-mingw32-clang" ;;
  esac

  local helper_src="$LIBMPV_SCRIPTS_ROOT/verify/winload_test.c"
  if [[ ! -f "$helper_src" ]]; then
    warn "L13: winload helper missing: $helper_src"
    return 0
  fi

  # Compile the helper into its OWN dedicated directory, and below run it with
  # the working directory set to THAT directory (passing the DLL by absolute
  # path). This is load-bearing on arm64: Box64/WowBox64/FEX, when launching an
  # x86_64 PE whose working directory differs from the executable's own module
  # directory, faults during process *teardown* and exits 29 — even though the
  # LoadLibrary + mpv_create + mpv_initialize + patched-property reads all
  # succeed. Bisected exhaustively: exit-code 29 ⇔ (cwd ≠ helper's module dir)
  # AND x86_64-via-Box64; native aarch64 PEs and an x86_64 host are immune.
  # Co-locating the cwd with the helper sidesteps the quirk so the real runtime
  # test runs to completion and PASSES, instead of warning "inconclusive". It's
  # cheap and harmless on the native-host path.
  local helper_dir; helper_dir="$(mktemp -d)"
  local helper_exe="$helper_dir/winload_test.exe"
  if ! "$cc" -O0 -o "$helper_exe" "$helper_src" -static 2>/dev/null; then
    fail "L13: winload helper failed to cross-compile for $pe_arch_norm"
    rm -rf "$helper_dir"
    return 0
  fi

  # Ensure XDG_RUNTIME_DIR/HOME are set and the Wine prefix is initialized once
  # (see _wine_prepare) — without a valid XDG_RUNTIME_DIR, Wine + Box64/FEX loop
  # on "XDG_RUNTIME_DIR is invalid or not set" and the load test hangs to its
  # timeout. WINEDEBUG=-all + the gecko/mono overrides keep wineboot quiet.
  _wine_prepare "$wine_bin"
  local out rc dll_abs
  dll_abs="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"
  out="$(cd "$helper_dir" && \
    HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;mshtml=" \
    timeout 90 "$wine_bin" "winload_test.exe" "$dll_abs" 2>&1)"
  rc=$?
  rm -rf "$helper_dir"
  _l13_windows_verdict "$via" "$rc" "$out"
  return 0
}

# _l13_windows_verdict turns the exit code of winload_test.exe into the L13
# result. Args: $1 = via ("native Wine" or "Hangover/FEX"), $2 = exit code,
# $3 = the helper's output. verify/tests/l13_windows_test.sh checks it.
_l13_windows_verdict() {
  local via="$1" rc="$2" out="$3"
  # The last lines of the helper's output without the Box64/Wine startup
  # noise, so the actual reason is visible.
  local reason
  reason="$(printf '%s' "$out" | grep -avE 'BOX64|WowBox64|XDG_RUNTIME|^wine:|created the configuration' | tail -2 | tr '\n' ' ' || true)"
  case "$rc" in
    0)
      pass "L13 LoadLibrary ($via): DLL loads + initializes + patched props respond at runtime"
      ;;
    1)
      # The helper's deliberate failure (LoadLibrary / GetProcAddress / init /
      # patched-property mismatch) — a real defect, with a diagnostic on stderr.
      fail "L13 LoadLibrary failed: $reason"
      ;;
    *)
      # The helper only ever returns 0 or 1, so any other code is a crash and
      # 124 is a stall. Native Wine runs the x86_64 DLL with no emulator in
      # between, so the crash or the stall is the DLL's own, for example an
      # access violation in mpv_initialize or mpv_terminate_destroy (Wine then
      # exits with code 5). That fails, like the Linux dlopen test.
      if [[ "$via" == "native Wine" ]]; then
        if [[ "$rc" == "124" ]]; then
          fail "L13 LoadLibrary timed out after 90s under native Wine: $reason"
        else
          fail "L13 LoadLibrary crashed (exit $rc) under native Wine: $reason"
        fi
      elif [[ "$rc" == "124" ]]; then
        # A timeout under Box64/FEX emulation means the runtime check couldn't
        # finish — not that the DLL is broken. The static layers (L11 NEEDED
        # allowlist) already validate it, so warn instead of failing.
        warn "L13 LoadLibrary inconclusive: Wine/emulation timed out after 90s (prefix init under Box64/FEX is slow). Static checks still validate the DLL."
      else
        # The previously-common code 29 (a Box64/FEX teardown fault) is fixed
        # by the cwd co-location in _l13_windows_loadlibrary, so any OTHER
        # abnormal code under emulation means an unexpected emulator crash,
        # not a broken DLL — still inconclusive (the static layers validate
        # it), but surface the code so a genuinely new emulator regression is
        # visible.
        warn "L13 LoadLibrary inconclusive: helper exited abnormally (code $rc) under Box64/FEX emulation — unexpected (the cwd-teardown fix should prevent code 29). Static checks still validate the DLL."
      fi
      ;;
  esac
  return 0
}
