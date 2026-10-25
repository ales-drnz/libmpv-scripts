#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Builds ring_test.c (the producer of ao_webaudio's ring) into a small wasm
# module with shared memory and runs ring_test.mjs on it in Node, against the
# worklet's consumer.
#
#   ring_test.sh <out dir>       (emcc on PATH, or EMSDK=<emsdk dir>)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
out="${1:?out dir}"
if ! command -v emcc >/dev/null 2>&1 && [[ -n "${EMSDK:-}" ]]; then
  # shellcheck source=/dev/null
  source "$EMSDK/emsdk_env.sh" >/dev/null 2>&1
fi
mkdir -p "$out"
# -pthread for a shared memory, as in the module; no thread is made.
emcc -pthread -O1 -I"$ROOT/patches/mpv/web/ao_webaudio" "$HERE/ring_test.c" \
  -sMODULARIZE -sEXPORT_ES6 -sENVIRONMENT=node -sPTHREAD_POOL_SIZE=0 \
  -sINITIAL_MEMORY=16MB -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=256MB \
  -sEXPORTED_FUNCTIONS=_malloc,_free,_rt_table,_rt_open,_rt_close,_rt_write,_rt_free,_rt_queued,_rt_flush,_rt_set,_rt_gain,_rt_layout \
  -sEXPORTED_RUNTIME_METHODS=wasmMemory -o "$out/ring_mod.mjs"
node "$HERE/ring_test.mjs" "$out/ring_mod.mjs" "$ROOT/scripts/web/mak_webaudio_processor.js"
