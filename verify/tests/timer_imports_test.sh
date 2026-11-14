#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks layer17_pe_timer_imports of scripts/verify/windows.sh, the timer
# functions a Windows DLL may import (mpv_audio_kit #12). Three parts:
#   1. recorded llvm-readobj --coff-imports output behind a fake tool: the
#      imports of the published DLL, then the same with timeBeginPeriod,
#      timeEndPeriod, a delay-loaded one, and names that only look like them;
#   2. recorded objdump -p output behind a fake tool, in the layout of
#      binutils 2.41 and in the older one;
#   3. real DLLs through the real tools: small ones built here when a mingw
#      compiler is on the host, with and without a call to timeBeginPeriod,
#      and every DLL named in TIMER_TEST_DLLS (a published libmpv), which
#      must pass.
#
# Usage: [TIMER_TEST_DLLS="a.dll b.dll"] bash verify/tests/timer_imports_test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export LIBMPV_SCRIPTS_ROOT="$ROOT"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_helpers.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_versions.sh"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_audio_only.sh"
for part in common linux windows; do
  # shellcheck source=/dev/null
  source "$ROOT/scripts/verify/$part.sh"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
bad() { echo "FAIL $*"; failures=$((failures + 1)); }
REAL_PATH="$PATH"
REAL_LLVM="${LLVM_MINGW_DIR:-/opt/llvm-mingw}"

# timer <name> <pass|fail> [text the output must contain] [text it must not]:
# layer17_pe_timer_imports with the tools the caller set up.
timer() {
  local name="$1" want="$2" text="${3:-}" without="${4:-}" before="$FAILED" got=pass out
  layer17_pe_timer_imports "${DLL:-$TMP/any.dll}" > "$TMP/out" 2>&1
  (( FAILED > before )) && got=fail
  out="$(cat "$TMP/out")"
  if [[ "$got" != "$want" ]]; then
    bad "$name: wanted $want, got $got: $out"
  elif [[ -n "$text" && "$out" != *"$text"* ]]; then
    bad "$name: the message lacks '$text': $out"
  elif [[ -n "$without" && "$out" == *"$without"* ]]; then
    bad "$name: the message has '$without': $out"
  else
    echo "ok   $name: $want"
  fi
}

# ── 1. Recorded llvm-readobj output ──────────────────────────────────────────
mkdir -p "$TMP/llvm/bin"
cat > "$TMP/llvm/bin/llvm-readobj" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "--coff-imports" && -f "$FAKE_IMPORTS" ]] || exit 1
cat "$FAKE_IMPORTS"
SH
chmod +x "$TMP/llvm/bin/llvm-readobj"
# readobj_out <file> <"library function" ...>: the tables as llvm-readobj
# prints them, one Import block per library in the order given. A library
# written "delay:NAME" goes in a DelayImport block.
readobj_out() {
  local f="$1" pair lib fn last=""; shift
  {
    echo
    echo "File: libmpv_windows-x86_64.dll"
    echo "Format: COFF-x86-64"
    echo "Arch: x86_64"
    echo "AddressSize: 64bit"
    for pair in "$@"; do
      lib="${pair%% *}" fn="${pair#* }"
      if [[ "$lib" != "$last" ]]; then
        [[ -n "$last" ]] && echo "}"
        if [[ "$lib" == delay:* ]]; then
          echo "DelayImport {"
          echo "  Name: ${lib#delay:}"
          echo "  Attributes: 0x1"
          echo "  ModuleHandle: 0x9F1000"
        else
          echo "Import {"
          echo "  Name: $lib"
          echo "  ImportLookupTableRVA: 0xA62168"
          echo "  ImportAddressTableRVA: 0xA631D0"
        fi
        last="$lib"
      fi
      echo "  Symbol: $fn (264)"
    done
    [[ -n "$last" ]] && echo "}"
  } > "$f"
}
# What libmpv-r24 imports around its timers.
R24=(
  "AVRT.dll AvSetMmThreadCharacteristicsW"
  "KERNEL32.dll CreateWaitableTimerExW"
  "KERNEL32.dll GetProcAddress"
  "KERNEL32.dll SetWaitableTimer"
  "KERNEL32.dll VerifyVersionInfoW"
  "ntdll.dll NtQueryTimerResolution"
  "ntdll.dll NtSetTimerResolution"
  "ntdll.dll VerSetConditionMask"
)
export LLVM_MINGW_DIR="$TMP/llvm"
readobj_out "$TMP/i_good" "${R24[@]}"
FAKE_IMPORTS="$TMP/i_good" timer readobj_good pass "NtSetTimerResolution is imported"
readobj_out "$TMP/i_no_nt" "${R24[@]:0:5}"
FAKE_IMPORTS="$TMP/i_no_nt" timer readobj_no_nt pass "are not imported" "NtSetTimerResolution"
readobj_out "$TMP/i_winmm" "${R24[@]}" "WINMM.dll timeBeginPeriod" "WINMM.dll timeEndPeriod"
FAKE_IMPORTS="$TMP/i_winmm" timer readobj_winmm fail "timeBeginPeriod (WINMM.dll) timeEndPeriod (WINMM.dll)"
readobj_out "$TMP/i_begin" "${R24[@]}" "winmm.dll timeBeginPeriod"
FAKE_IMPORTS="$TMP/i_begin" timer readobj_begin fail "timeBeginPeriod (winmm.dll)" "timeEndPeriod"
readobj_out "$TMP/i_end" "api-ms-win-core-timezone-l1-1-0.dll timeEndPeriod" "${R24[@]}"
FAKE_IMPORTS="$TMP/i_end" timer readobj_end fail "timeEndPeriod (api-ms-win-core-timezone-l1-1-0.dll)"
readobj_out "$TMP/i_delay" "${R24[@]}" "delay:WINMM.dll timeBeginPeriod"
FAKE_IMPORTS="$TMP/i_delay" timer readobj_delay fail "timeBeginPeriod (WINMM.dll)"
# Other functions of the multimedia timer library, and longer names.
readobj_out "$TMP/i_lookalike" "${R24[@]}" "WINMM.dll timeGetTime" "WINMM.dll timeGetDevCaps" \
  "x.dll timeBeginPeriodEx" "x.dll _timeBeginPeriod"
FAKE_IMPORTS="$TMP/i_lookalike" timer readobj_lookalike pass "are not imported"
# No table and no tool are failures, not a clean DLL.
readobj_out "$TMP/i_empty"
FAKE_IMPORTS="$TMP/i_empty" timer readobj_empty fail "tool failure"
FAKE_IMPORTS="$TMP/missing" timer readobj_fails fail "tool failure"
export FAKE_IMPORTS

# ── 2. Recorded objdump output ───────────────────────────────────────────────
# A PATH with the fake objdump and the few tools the function calls, so a
# real llvm-readobj of the host is out of reach.
mkdir -p "$TMP/objbin"
for tool in awk grep sed cat; do ln -s "$(command -v "$tool")" "$TMP/objbin/$tool"; done
cat > "$TMP/objbin/objdump" <<SH
#!$(command -v bash)
[[ -f "\$FAKE_DUMP" ]] || exit 1
cat "\$FAKE_DUMP"
SH
chmod +x "$TMP/objbin/objdump"
# objdump_out <file> <new|old> <"library function" ...>
objdump_out() {
  local f="$1" layout="$2" pair lib fn last=""; shift 2
  {
    printf '\nlibmpv_windows-x86_64.dll:     file format pei-x86-64\n\n'
    printf 'DllCharacteristics\t00000160\n\nThe Import Tables (interpreted .idata section contents)\n'
    printf ' vma:            Hint    Time      Forward  DLL       First\n'
    printf '                 Table   Stamp     Chain    Name      Thunk\n'
    for pair in "$@"; do
      lib="${pair%% *}" fn="${pair#* }"
      if [[ "$lib" != "$last" ]]; then
        printf ' 00a62000\t00a62168 00000000 00000000 00a65a18 00a631d0\n\n\tDLL Name: %s\n' "$lib"
        if [[ "$layout" == new ]]; then
          printf '\tvma:     Ordinal  Hint  Member-Name  Bound-To\n'
        else
          printf '\tvma:  Hint/Ord Member-Name Bound-To\n'
        fi
        last="$lib"
      fi
      if [[ "$layout" == new ]]; then
        printf '\t00a633e0  <none>  0108  %s\n' "$fn"
      else
        printf '\ta633e0\t  264  %s\n' "$fn"
      fi
    done
    # An import by ordinal has no name, and the export table has names that
    # are no imports.
    [[ "$layout" == new ]] && printf '\t00a633e8      12  <none>\n'
    printf '\n 00a62014\t00000000 00000000 00000000 00000000 00000000\n\n'
    printf 'The Export Tables (interpreted .edata section contents)\n\n'
    printf '[Ordinal/Name Pointer] Table -- Ordinal Base 1\n'
    printf '\t[   0] +base[   1]  0000 timeBeginPeriod\n\t[   1] +base[   2]  0001 mpv_create\n'
  } > "$f"
}
objdump_timer() { # objdump_timer <name> <dump file> <pass|fail> [text] [without]
  local saved="$PATH"
  # shellcheck disable=SC2123  # on purpose: only the fake tools are reachable
  PATH="$TMP/objbin"; export FAKE_DUMP="$2" LLVM_MINGW_DIR="$TMP/none"
  timer "$1" "$3" "${4:-}" "${5:-}"
  PATH="$saved"; export LLVM_MINGW_DIR="$TMP/llvm"
}
for layout in new old; do
  objdump_out "$TMP/d_good_$layout" "$layout" "${R24[@]}"
  objdump_timer "objdump_${layout}_good" "$TMP/d_good_$layout" pass "NtSetTimerResolution is imported"
  objdump_out "$TMP/d_winmm_$layout" "$layout" "${R24[@]}" "WINMM.dll timeBeginPeriod" "WINMM.dll timeEndPeriod"
  objdump_timer "objdump_${layout}_winmm" "$TMP/d_winmm_$layout" fail "timeBeginPeriod (WINMM.dll) timeEndPeriod (WINMM.dll)"
  objdump_out "$TMP/d_lookalike_$layout" "$layout" "${R24[@]:0:5}" "WINMM.dll timeGetTime"
  objdump_timer "objdump_${layout}_lookalike" "$TMP/d_lookalike_$layout" pass "are not imported" "NtSetTimerResolution"
  objdump_out "$TMP/d_empty_$layout" "$layout"
  objdump_timer "objdump_${layout}_empty" "$TMP/d_empty_$layout" fail "tool failure"
done
objdump_timer objdump_fails "$TMP/missing" fail "tool failure"

# ── 3. Real DLLs through the real tools ──────────────────────────────────────
PATH="$REAL_PATH"; export LLVM_MINGW_DIR="$REAL_LLVM"
MINGW=""
for cc in x86_64-w64-mingw32-gcc "$REAL_LLVM/bin/x86_64-w64-mingw32-clang" x86_64-w64-mingw32-clang; do
  if command -v "$cc" >/dev/null 2>&1; then MINGW="$cc"; break; fi
done
if [[ -n "$MINGW" ]]; then
  cat > "$TMP/dll.c" <<'EOF'
#include <windows.h>
#include <mmsystem.h>
__declspec(dllexport) int mpv_wait(void)
{
#ifdef WITH_PERIOD
    timeBeginPeriod(1);
#endif
    HANDLE t = CreateWaitableTimerExW(NULL, NULL, 2, TIMER_ALL_ACCESS);
    if (t)
        CloseHandle(t);
#ifdef WITH_PERIOD
    timeEndPeriod(1);
#endif
    return t != NULL;
}
EOF
  # built <name> <pass|fail> <text> <cc flags...>
  built() {
    local name="$1" want="$2" text="$3"; shift 3
    if ! "$MINGW" -shared -O1 "$TMP/dll.c" "$@" -o "$TMP/$name.dll" 2> "$TMP/cc.err"; then
      bad "$name: did not build: $(cat "$TMP/cc.err")"; return
    fi
    DLL="$TMP/$name.dll" timer "$name" "$want" "$text"
  }
  built real_plain pass "are not imported"
  built real_period fail "timeBeginPeriod" -DWITH_PERIOD -lwinmm
else
  echo "skip built DLLs: no mingw compiler on this host"
fi
for dll in ${TIMER_TEST_DLLS:-}; do
  if [[ ! -f "$dll" ]]; then bad "$dll: no such file"; continue; fi
  DLL="$dll" timer "published $(basename "$dll")" pass "are not imported"
  sed 's/^/     /' "$TMP/out"
done

# The layer is one of those check_binary runs on a Windows DLL.
if grep -q 'layer17_pe_timer_imports "\$artifact"' "$ROOT/scripts/verify/common.sh"; then
  echo "ok   check_binary calls the layer"
else
  bad "check_binary of scripts/verify/common.sh does not call layer17_pe_timer_imports"
fi

(( failures == 0 )) && echo "timer_imports_test: all passed" || echo "timer_imports_test: $failures failed"
exit $(( failures > 0 ))
