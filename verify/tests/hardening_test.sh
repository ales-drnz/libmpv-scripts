#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks the hardening assertions of verify_binaries.sh: elf_hardening_gaps
# of _audio_only.sh and its L16 lines (a non-executable stack, RELRO,
# BIND_NOW, the stack canary, no TEXTREL), and the DllCharacteristics of
# layer16_pe_hardening. Three parts:
#   1. recorded readelf output, of GNU readelf and of llvm-readelf, behind a
#      fake readelf: a good library and one for each missing mitigation;
#   2. recorded llvm-readobj and objdump output behind fake tools: a good
#      DLL and bad ones;
#   3. when the host has cc and readelf, small real libraries linked with
#      and without each flag, through layer16_elf_invariants.
#
# Usage: bash verify/tests/hardening_test.sh

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

# ── 1. Recorded readelf output ───────────────────────────────────────────────
# The fake readelf prints $FAKE_DIR/segments for -l, dynamic for -d and
# symbols for --dyn-syms.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/readelf" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    -lW|-l) cat "$FAKE_DIR/segments"; exit 0 ;;
    -dW|-d) cat "$FAKE_DIR/dynamic"; exit 0 ;;
    --dyn-syms) cat "$FAKE_DIR/symbols"; exit 0 ;;
  esac
done
exit 1
SH
chmod +x "$TMP/bin/readelf"

# record <name>: a good library as GNU readelf prints it.
record() {
  local d="$TMP/$1"
  mkdir -p "$d"
  cat > "$d/segments" <<'EOF'

Elf file type is DYN (Shared object file)
Program Headers:
  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align
  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x0f1000 0x0f1000 R   0x1000
  LOAD           0x0f1000 0x00000000000f1000 0x00000000000f1000 0x5e2000 0x5e2000 R E 0x1000
  LOAD           0x7c0000 0x00000000007c1000 0x00000000007c1000 0x0c0000 0x0d0000 RW  0x1000
  DYNAMIC        0x86e000 0x000000000086f000 0x000000000086f000 0x000220 0x000220 RW  0x8
  GNU_EH_FRAME   0x6d2000 0x00000000006d2000 0x00000000006d2000 0x001000 0x001000 R   0x4
  GNU_STACK      0x000000 0x0000000000000000 0x0000000000000000 0x000000 0x000000 RW  0x10
  GNU_RELRO      0x7c0000 0x00000000007c1000 0x00000000007c1000 0x0b0000 0x0b0000 R   0x1
EOF
  cat > "$d/dynamic" <<'EOF'

Dynamic section at offset 0x86e000 contains 30 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x000000000000000e (SONAME)             Library soname: [libmpv_audio_kit.so]
 0x0000000000000010 (SYMBOLIC)           0x0
 0x000000000000001e (FLAGS)              SYMBOLIC BIND_NOW
 0x000000006ffffffb (FLAGS_1)            Flags: NOW
 0x0000000000000000 (NULL)               0x0
EOF
  cat > "$d/symbols" <<'EOF'

Symbol table '.dynsym' contains 4 entries:
   Num:    Value          Size Type    Bind   Vis      Ndx Name
     0: 0000000000000000     0 NOTYPE  LOCAL  DEFAULT  UND
     1: 0000000000000000     0 FUNC    GLOBAL DEFAULT  UND __stack_chk_fail@GLIBC_2.4 (2)
     2: 0000000000000000     0 FUNC    GLOBAL DEFAULT  UND __memcpy_chk@GLIBC_2.3.4 (3)
     3: 00000000000f2000    40 FUNC    GLOBAL DEFAULT   12 mpv_create@@MPV_2
EOF
}

# gaps <name> <text the one gap must contain, or "" for none>
gaps() {
  local name="$1" want="$2" got rc=0
  got="$(FAKE_DIR="$TMP/$name" elf_hardening_gaps "$TMP/$name/lib.so" "$TMP/bin/readelf")" || rc=$?
  if (( rc != 0 )); then
    bad "$name: elf_hardening_gaps returned $rc"
  elif [[ -z "$want" && -n "$got" ]]; then
    bad "$name: a good library reported: $got"
  elif [[ -n "$want" && ( "$got" != *"$want"* || "$(wc -l <<<"$got")" -ne 1 ) ]]; then
    bad "$name: wanted the one gap '$want', got: ${got:-nothing}"
  else
    echo "ok   $name: ${got:-no gaps}"
  fi
}

record gnu_good
gaps gnu_good ""

# llvm-readelf: FLAGS_1 without "Flags:", and a symbol with no version index.
record llvm_good
sed -i 's/(FLAGS_1)            Flags: NOW/(FLAGS_1)            NOW/' "$TMP/llvm_good/dynamic"
sed -i 's/ (2)$//; s/ (3)$//' "$TMP/llvm_good/symbols"
gaps llvm_good ""

# Android: BIND_NOW as its own tag, symbols versioned @LIBC.
record android_good
sed -i '/(FLAGS)/d; /(FLAGS_1)/d; /(SYMBOLIC)/a\ 0x0000000000000018 (BIND_NOW)           ' "$TMP/android_good/dynamic"
sed -i 's/@GLIBC_2.4 (2)/@LIBC/' "$TMP/android_good/symbols"
gaps android_good ""

record exec_stack
sed -i '/GNU_STACK/ s/ RW  0x10/ RWE 0x10/' "$TMP/exec_stack/segments"
gaps exec_stack "GNU_STACK is executable"

record no_stack_header
sed -i '/GNU_STACK/d' "$TMP/no_stack_header/segments"
gaps no_stack_header "no GNU_STACK segment"

record no_relro
sed -i '/GNU_RELRO/d' "$TMP/no_relro/segments"
gaps no_relro "no GNU_RELRO segment"

record lazy
sed -i 's/SYMBOLIC BIND_NOW/SYMBOLIC/; /(FLAGS_1)/d' "$TMP/lazy/dynamic"
gaps lazy "no BIND_NOW"

record textrel
sed -i 's/SYMBOLIC BIND_NOW/SYMBOLIC TEXTREL BIND_NOW/' "$TMP/textrel/dynamic"
gaps textrel "TEXTREL"

record textrel_tag
sed -i '/(SYMBOLIC)/a\ 0x0000000000000016 (TEXTREL)            0x0' "$TMP/textrel_tag/dynamic"
gaps textrel_tag "TEXTREL"

record no_canary
sed -i '/__stack_chk_fail/d' "$TMP/no_canary/symbols"
gaps no_canary "no __stack_chk_fail"

# A defined __stack_chk_fail is not the canary's reference.
record canary_defined
sed -i '/__stack_chk_fail/ s/ UND /  12 /' "$TMP/canary_defined/symbols"
gaps canary_defined "no __stack_chk_fail"

# A readelf that prints nothing is a tool failure, not a clean library.
mkdir -p "$TMP/empty"
: > "$TMP/empty/segments"; : > "$TMP/empty/dynamic"; : > "$TMP/empty/symbols"
rc=0
FAKE_DIR="$TMP/empty" elf_hardening_gaps "$TMP/empty/lib.so" "$TMP/bin/readelf" >/dev/null || rc=$?
if (( rc == 2 )); then echo "ok   empty: tool failure reported"; else bad "empty: wanted exit 2, got $rc"; fi

# ── 2. DllCharacteristics ────────────────────────────────────────────────────
# pe <name> <pass|fail> [text the output must contain]: layer16_pe_hardening
# with the tools the caller set up.
pe() {
  local name="$1" want="$2" text="${3:-}" before="$FAILED" got=pass out
  layer16_pe_hardening "$TMP/any.dll" > "$TMP/out" 2>&1
  (( FAILED > before )) && got=fail
  out="$(cat "$TMP/out")"
  if [[ "$got" != "$want" ]]; then
    bad "$name: wanted $want, got $got: $out"
  elif [[ -n "$text" && "$out" != *"$text"* ]]; then
    bad "$name: the message lacks '$text': $out"
  else
    echo "ok   $name: $want"
  fi
}

# llvm-readobj in LLVM_MINGW_DIR, printing $FAKE_HEADERS.
mkdir -p "$TMP/llvm/bin"
cat > "$TMP/llvm/bin/llvm-readobj" <<'SH'
#!/usr/bin/env bash
[[ -f "$FAKE_HEADERS" ]] || exit 1
cat "$FAKE_HEADERS"
SH
chmod +x "$TMP/llvm/bin/llvm-readobj"
readobj_out() { # readobj_out <file> <flag lines...>
  local f="$1"; shift
  {
    echo "ImageFileHeader {"
    echo "  Characteristics [ (0x2026)"
    echo "    IMAGE_FILE_DLL (0x2000)"
    echo "  ]"
    echo "}"
    echo "ImageOptionalHeader {"
    echo "  Subsystem: IMAGE_SUBSYSTEM_WINDOWS_CUI (0x3)"
    echo "  Characteristics [ (0x160)"
    local flag
    for flag in "$@"; do echo "    IMAGE_DLL_CHARACTERISTICS_$flag (0x0)"; done
    echo "  ]"
    echo "}"
  } > "$f"
}
export LLVM_MINGW_DIR="$TMP/llvm"
readobj_out "$TMP/h_good" DYNAMIC_BASE HIGH_ENTROPY_VA NX_COMPAT
FAKE_HEADERS="$TMP/h_good" pe readobj_good pass
readobj_out "$TMP/h_no_aslr" NX_COMPAT
FAKE_HEADERS="$TMP/h_no_aslr" pe readobj_no_aslr fail "DYNAMIC_BASE HIGH_ENTROPY_VA"
readobj_out "$TMP/h_no_nx" DYNAMIC_BASE HIGH_ENTROPY_VA
FAKE_HEADERS="$TMP/h_no_nx" pe readobj_no_nx fail "NX_COMPAT"
readobj_out "$TMP/h_none"
FAKE_HEADERS="$TMP/h_none" pe readobj_none fail "DYNAMIC_BASE HIGH_ENTROPY_VA NX_COMPAT"
FAKE_HEADERS="$TMP/missing" pe readobj_fails fail "tool failure"
export FAKE_HEADERS

# objdump alone: a PATH with the fake objdump and the few tools the function
# calls, so a real llvm-readobj of the host is out of reach.
mkdir -p "$TMP/objbin"
for tool in awk grep sed cat; do ln -s "$(command -v "$tool")" "$TMP/objbin/$tool"; done
cat > "$TMP/objbin/objdump" <<SH
#!$(command -v bash)
[[ -n "\$FAKE_HEX" ]] || exit 1
printf 'Subsystem\t\t00000003\t(Windows CUI)\nDllCharacteristics\t%s\n\t\t\t\t\tHIGH_ENTROPY_VA\n' "\$FAKE_HEX"
SH
chmod +x "$TMP/objbin/objdump"
objdump_pe() { # objdump_pe <name> <hex> <pass|fail> [text]
  local saved="$PATH"
  # shellcheck disable=SC2123  # on purpose: only the fake tools are reachable
  PATH="$TMP/objbin"; export FAKE_HEX="$2" LLVM_MINGW_DIR="$TMP/none"
  pe "$1" "$3" "${4:-}"
  PATH="$saved"; export LLVM_MINGW_DIR="$TMP/llvm"
}
objdump_pe objdump_good 00000160 pass
objdump_pe objdump_no_high_entropy 00000140 fail "HIGH_ENTROPY_VA"
objdump_pe objdump_no_nx 00000060 fail "NX_COMPAT"
objdump_pe objdump_zero 00000000 fail "DYNAMIC_BASE HIGH_ENTROPY_VA NX_COMPAT"
objdump_pe objdump_fails "" fail "tool failure"

# ── 3. Real libraries, when the host can build them ──────────────────────────
if command -v cc >/dev/null 2>&1 && command -v readelf >/dev/null 2>&1; then
  cat > "$TMP/lib.c" <<'EOF'
#include <string.h>
int mpv_fill(const char *s) { char buf[64]; strcpy(buf, s); return buf[0]; }
EOF
  # real <name> <pass|fail> <text> <cc flags...>: L16 as verify runs it on a
  # Linux library, which must fail only for the gap named.
  real() {
    local name="$1" want="$2" text="$3"; shift 3
    if ! cc -shared -fPIC -O1 -U_FORTIFY_SOURCE "$TMP/lib.c" -Wl,-soname,"$MPV_SONAME" \
         -Wl,-z,relro,-z,now,-z,noexecstack "$@" -o "$TMP/$name.so" 2> "$TMP/cc.err"; then
      bad "$name: did not build: $(cat "$TMP/cc.err")"; return
    fi
    local before="$FAILED" got=pass out
    LINUX_GLIBC_FLOOR=9.99 layer16_elf_invariants linux x86_64 "$TMP/$name.so" readelf > "$TMP/out" 2>&1
    (( FAILED > before )) && got=fail
    out="$(grep -a 'hardening' "$TMP/out" | grep -av 'fortified' || true)"
    if [[ "$got" != "$want" ]]; then
      bad "$name: L16 should $want, got $got:"; cat "$TMP/out"
    elif [[ "$out" != *"$text"* || ( "$want" == fail && "$(wc -l <<<"$out")" -ne 1 ) ]]; then
      bad "$name: wanted the one line '$text', got: $out"
    else
      echo "ok   $name: L16 $want"
    fi
  }
  real real_good pass "NX stack, full RELRO" -fstack-protector-all
  real real_exec_stack fail "GNU_STACK is executable" -fstack-protector-all -Wl,-z,execstack
  real real_no_relro fail "no GNU_RELRO" -fstack-protector-all -Wl,-z,norelro
  real real_lazy fail "no BIND_NOW" -fstack-protector-all -Wl,-z,lazy
  real real_no_canary fail "no __stack_chk_fail" -fno-stack-protector
else
  echo "skip real libraries: no cc or readelf on this host"
fi

(( failures == 0 )) && echo "hardening_test: all passed" || echo "hardening_test: $failures failed"
exit $(( failures > 0 ))
