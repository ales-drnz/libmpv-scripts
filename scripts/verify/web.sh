# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
# shellcheck shell=bash

# The web module of verify_binaries.sh: check_web_binary, the static checks
# of libmpv_web.zip. Sourced by verify_binaries.sh. Do not run directly.

# ── The web module ────────────────────────────────────────────────────────────
# WebAssembly has no loader to try nor symbols to read, so the module gets the
# static layers that apply, on the strings of its data and on the functions
# the glue exports as Module._<name> (the wasm's own export names are
# minified, the glue maps each one). Its exports differ from the natives' by
# design (no render API, no wakeup pipe, the shim's functions), so it stays
# out of the API surface hash: the expected list is derived here from
# shared/mpv.def, as build_libmpv_web.sh does.
WEB_FILES=(libmpv.mjs libmpv.wasm mak_webaudio_processor.js build_web.json)
WEB_EXTRA_EXPORTS=(mak_web_abi_version mak_web_wakeup_attach mak_web_wakeup_detach
                   mak_web_layout mak_wa_table_get mak_webio_live_streams)
# Ceiling of the raw wasm: 12 MB; the module is about 4.5 MB.
WEB_WASM_MAX_BYTES=12000000

# wasm_info <file.wasm>: "shared <0|1>" for its imported memory, then one
# exported function name per line.
wasm_info() {
  python3 -I - "$1" <<'PY'
import sys
b = open(sys.argv[1], "rb").read()
if b[:4] != b"\0asm" or b[4:8] != b"\1\0\0\0":
    sys.exit("not a wasm module (version 1)")
def leb(i):
    r = s = 0
    while True:
        c = b[i]; i += 1
        r |= (c & 0x7f) << s; s += 7
        if c < 0x80:
            return r, i
def name(i):
    n, i = leb(i)
    return b[i:i + n].decode(), i + n
def limits(i):
    flag = b[i]; i += 1
    _, i = leb(i)
    if flag & 1:
        _, i = leb(i)
    return flag, i
shared, exports, i = 0, [], 8
while i < len(b):
    sid = b[i]; size, i = leb(i + 1); end = i + size
    if sid == 2:  # imports
        n, j = leb(i)
        for _ in range(n):
            _, j = name(j); _, j = name(j)
            kind = b[j]; j += 1
            if kind == 0:
                _, j = leb(j)
            elif kind == 1:
                _, j = limits(j + 1)
            elif kind == 2:
                flag, j = limits(j)
                shared = int(bool(flag & 2))
            elif kind == 3:
                j += 2
            else:
                j += 1; _, j = leb(j)
    elif sid == 7:  # exports
        n, j = leb(i)
        for _ in range(n):
            nm, j = name(j)
            kind = b[j]; _, j = leb(j + 1)
            if kind == 0:
                exports.append(nm)
    i = end
print(f"shared {shared}")
print("\n".join(exports))
PY
}

check_web_binary() {
  local artifact="$1"
  local name; name="$(basename "$artifact")"
  printf "\n${BOLD}════ %s ${DIM}[web]${NC}\n" "$name"
  # shellcheck disable=SC2034  # read by the result helpers of common.sh
  CUR_BIN="$name" CUR_PHASE=""
  emit bin "$name" "web"

  # ── 1. the zip, the record, the wasm format ──
  phase fmt
  local tmp; tmp="$(mktemp -d)"
  if ! unzip -qo "$artifact" -d "$tmp" 2>/dev/null; then
    fail "not a zip archive"
    rm -rf "$tmp"; emit bindone "$name"; return 0
  fi
  local members want
  members="$(cd "$tmp" && find . -type f | sed 's|^\./||' | sort | tr '\n' ' ')"
  want="$(printf '%s\n' "${WEB_FILES[@]}" | sort | tr '\n' ' ')"
  if [[ "$members" == "$want" ]]; then
    pass "zip holds ${WEB_FILES[*]}"
  else
    fail "zip holds: $members(wanted: $want)"
  fi
  local rec
  rec="$(python3 -I - "$tmp/build_web.json" "$LIBMPV_RELEASE" <<'PY' 2>&1
import json, sys
try:
    r = json.load(open(sys.argv[1]))
except (OSError, ValueError) as e:
    sys.exit(f"build_web.json unreadable: {e}")
m = r.get("module") or {}
ok = (r.get("target") == "web" and r.get("release") == sys.argv[2]
      and isinstance(m.get("abi"), int) and isinstance(m.get("webaudioAbi"), int))
print(f"release {r.get('release')}, abi {m.get('abi')}, webaudio abi "
      f"{m.get('webaudioAbi')}, emscripten {m.get('emscripten')}")
sys.exit(0 if ok else 1)
PY
)" && pass "build_web.json: $rec" || fail "build_web.json: $rec (wanted release $LIBMPV_RELEASE and the module versions)"
  local wasm="$tmp/libmpv.wasm" info=""
  if [[ -f "$wasm" ]] && info="$(wasm_info "$wasm" 2>&1)"; then
    pass "libmpv.wasm: WebAssembly version 1"
  else
    fail "libmpv.wasm: ${info:-missing}"
    rm -rf "$tmp"; emit bindone "$name"; return 0
  fi
  if [[ "$(head -1 <<<"$info")" == "shared 1" ]]; then
    pass "imported memory is shared (pthreads)"
  else
    fail "imported memory is not shared: the module was linked without -pthread"
  fi
  local size; size="$(stat -c %s "$wasm")"
  if (( size <= WEB_WASM_MAX_BYTES )); then
    pass "libmpv.wasm $size bytes (ceiling $WEB_WASM_MAX_BYTES)"
  else
    fail "libmpv.wasm $size bytes, over the ceiling of $WEB_WASM_MAX_BYTES"
  fi
  if grep -sqF 'makWebAudio' "$tmp/libmpv.mjs" && grep -sqF 'libmpv.wasm' "$tmp/libmpv.mjs"; then
    pass "libmpv.mjs: the glue with Module.makWebAudio, loading libmpv.wasm"
  else
    fail "libmpv.mjs: no makWebAudio or no libmpv.wasm in the glue"
  fi
  if grep -sqF 'registerProcessor' "$tmp/mak_webaudio_processor.js"; then
    pass "mak_webaudio_processor.js registers the worklet"
  else
    fail "mak_webaudio_processor.js registers no AudioWorkletProcessor"
  fi

  # ── 2. exports: exactly the mpv_* and mak_* names of the web build ──
  phase exports
  local wasm_exports pairs exports expected got unmapped
  wasm_exports="$(tail -n +2 <<<"$info")"
  # Module["_mpv_create"]=wasmExports["oa"] -> "mpv_create oa"
  pairs="$(grep -soE 'Module\["_[A-Za-z0-9_]+"\]=wasmExports\["[^"]+"\]' "$tmp/libmpv.mjs" \
    | sed -E 's/^Module\["_([^"]+)"\]=wasmExports\["([^"]+)"\]$/\1 \2/' || true)"
  exports="$(cut -d' ' -f1 <<<"$pairs")"
  unmapped="$(cut -s -d' ' -f2 <<<"$pairs" | grep -vxF -f <(echo "$wasm_exports") || true)"
  if [[ -n "$pairs" && -z "$unmapped" ]]; then
    pass "the glue's $(wc -l <<<"$pairs") Module exports are functions of libmpv.wasm"
  else
    fail "the glue maps functions libmpv.wasm does not export: ${unmapped:-none found}"
  fi
  expected="$( { awk '/^EXPORTS/ {on=1; next} on && NF {print $1}' "$SCRIPT_DIR/shared/mpv.def" \
      | grep -Ev '^(mpv_render_|mpv_get_wakeup_pipe$)'; printf '%s\n' "${WEB_EXTRA_EXPORTS[@]}"; } | sort)"
  got="$(grep -E '^(mpv|mak)_' <<<"$exports" | sort || true)"
  local n_mpv n_pcm
  n_mpv="$(grep -c '^mpv_' <<<"$got" || true)"
  n_pcm="$(grep -c '^mak_pcm_' <<<"$got" || true)"
  if [[ "$got" == "$expected" ]]; then
    pass "mpv_* and mak_* exports: exactly the $(wc -l <<<"$expected") of the web build ($n_mpv mpv_*, $n_pcm mak_pcm_*)"
  else
    fail "mpv_* and mak_* exports differ from the web build's list"
    diff <(echo "$expected") <(echo "$got") | grep '^[<>]' | head -5 | sed 's/^/     · /' || true
  fi
  if (( n_pcm == EXPECTED_MAK_PCM_EXPORTS )); then
    pass "mak_pcm_* exports: $n_pcm/$EXPECTED_MAK_PCM_EXPORTS"
  else
    fail "mak_pcm_* exports: expected $EXPECTED_MAK_PCM_EXPORTS, got $n_pcm"
  fi
  if grep -qx malloc <<<"$exports" && grep -qx free <<<"$exports" \
     && [[ "$(grep -cvE '^(mpv_|mak_|malloc$|free$)' <<<"$exports" || true)" == 0 ]]; then
    pass "malloc and free exported, and nothing else"
  else
    fail "malloc or free not exported, or other exports: $(grep -vE '^(mpv_|mak_)' <<<"$exports" | tr '\n' ' ')"
  fi

  local str_text; str_text="$(strings -n 4 "$wasm")"
  [[ -n "$str_text" ]] || fail "strings produced no output for libmpv.wasm (tool failure)"

  # ── 3. patched mpv properties and the webaudio output ──
  phase patches
  local prop
  for prop in "${MPV_PATCHED_PROPS[@]}" webaudio-volume webaudio-mute webaudio-output; do
    if grep -qF "$prop" <<<"$str_text"; then
      pass "mpv patch present: $prop"
    else
      fail "mpv patch MISSING: $prop"
    fi
  done

  # ── 4. FFmpeg patches: the shared ones but libsmb2, and webio ──
  phase ffmpeg
  local entry marker desc
  for entry in "${FFMPEG_PATCH_MARKERS[@]}" "makblob|webio protocols (http, https, blob: through fetch)"; do
    marker="${entry%%|*}" desc="${entry#*|}"
    [[ "$marker" == libsmb2 || "$marker" == "Chunked stream ends"* ]] && continue
    if grep -qF "$marker" <<<"$str_text"; then
      pass "ffmpeg patch present: $desc"
    else
      fail "ffmpeg patch MISSING: $desc"
    fi
  done
  if [[ ",$AUDIO_FILTERS," == *",chorus,"* ]]; then
    if grep -qF "Invalid delay, decay, speed or depth for voice" <<<"$str_text"; then
      pass "ffmpeg patch present: filter bounds"
    else
      fail "ffmpeg patch MISSING: filter bounds (chorus message)"
    fi
  fi

  # ── 5, 6. audio decoders and filters ──
  phase decoders
  local missing=0 x
  for x in "${REQUIRED_DECODERS[@]}"; do grep -qF "$x" <<<"$str_text" || missing=$((missing + 1)); done
  if (( missing == 0 )); then
    pass "audio decoders sample (${#REQUIRED_DECODERS[@]}) present"
  else
    fail "$missing/${#REQUIRED_DECODERS[@]} sampled audio decoders missing"
  fi
  phase filters
  missing=0
  for x in "${REQUIRED_FILTERS[@]}"; do grep -qF "$x" <<<"$str_text" || missing=$((missing + 1)); done
  if (( missing == 0 )); then
    pass "audio filters (all ${#REQUIRED_FILTERS[@]}) present"
  else
    fail "$missing/${#REQUIRED_FILTERS[@]} audio filters missing"
  fi

  # ── 7c. license ──
  layer_license "$name" "$str_text" || fail "7c: layer aborted (exit $?)"

  # ── 9. mpv's version names this release ──
  phase versions
  if grep -qF "v$MPV_VERSION+$LIBMPV_RELEASE" <<<"$str_text"; then
    pass "mpv version v$MPV_VERSION+$LIBMPV_RELEASE"
  else
    fail "mpv version v$MPV_VERSION+$LIBMPV_RELEASE not in the module"
  fi

  rm -rf "$tmp"
  emit bindone "$name"
}
