# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
# shellcheck shell=bash

# The OHOS pieces of verify_binaries.sh: the sysroot of the OpenHarmony
# native SDK for L12, and in place of a load test (no OHOS loader runs
# here: ohos-emulator.yml loads the library and plays it on the Oniro
# emulator) the checks of what the library binds on the device. L11 and
# L16 have their ohos case in common.sh and linux.sh. Sourced by
# verify_binaries.sh. Do not run directly.

# The OHAudio calls ao_ohaudio may make: those of API 12 or older
# (HarmonyOS 5.0), with the API each came in. libmpv is linked with -z now,
# so a newer one would keep it from loading on an older system.
OHOS_OHAUDIO_API12=(
  OH_AudioStreamBuilder_Create:10
  OH_AudioStreamBuilder_Destroy:10
  OH_AudioStreamBuilder_SetSamplingRate:10
  OH_AudioStreamBuilder_SetChannelCount:10
  OH_AudioStreamBuilder_SetSampleFormat:10
  OH_AudioStreamBuilder_SetEncodingType:10
  OH_AudioStreamBuilder_SetLatencyMode:10
  OH_AudioStreamBuilder_SetRendererInfo:10
  OH_AudioStreamBuilder_SetRendererCallback:10
  OH_AudioStreamBuilder_SetRendererOutputDeviceChangeCallback:11
  OH_AudioStreamBuilder_SetRendererWriteDataCallback:12
  OH_AudioStreamBuilder_GenerateRenderer:10
  OH_AudioRenderer_Start:10
  OH_AudioRenderer_Pause:10
  OH_AudioRenderer_Stop:10
  OH_AudioRenderer_Flush:10
  OH_AudioRenderer_Release:10
  OH_AudioRenderer_GetTimestamp:10
  OH_AudioRenderer_GetUnderflowCount:12
)

# The native SDK's sysroot: the build's when it is there, else fetched at
# its pin (scripts/ohos/ohos_sdk.sh, about 1 GB streamed).
_ohos_sysroot() {
  local dir="${OHOS_SDK_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/ohos-sdk}"
  bash "$LIBMPV_SCRIPTS_ROOT/scripts/ohos/ohos_sdk.sh" "$dir" native >/dev/null || return 1
  echo "$dir/native/sysroot"
}

# clang's target of an OHOS arch, the directory of its libraries in the
# sysroot.
_ohos_target() {
  case "$1" in
    arm64-v8a) echo "aarch64-linux-ohos" ;;
    x86_64)    echo "x86_64-linux-ohos" ;;
    *)         return 1 ;;
  esac
}

# L13 for OHOS: what the library binds, which a load would check. The
# OHAudio calls are of API 12 or older, and the C++ runtime and the
# unwinder are linked in (no libc++_shared.so in the HAP): nothing of
# theirs is left undefined.
_l13_ohos_binds() {
  local artifact="$1" nm und
  nm="$(_llvm_tool nm)"
  und="$("$nm" -D --undefined-only "$artifact" 2>/dev/null | awk '{print $NF}' | sed 's/@.*//' | sort -u)"
  if [[ -z "$und" ]]; then
    fail "L13 OHOS: nm read no undefined symbols (tool failure)"
    return 0
  fi
  local allowed sym bad="" newest=0 api
  allowed="$(printf '%s\n' "${OHOS_OHAUDIO_API12[@]}" | cut -d: -f1)"
  while IFS= read -r sym; do
    [[ "$sym" == OH_* ]] || continue
    if grep -qx "$sym" <<<"$allowed"; then
      api="$(printf '%s\n' "${OHOS_OHAUDIO_API12[@]}" | grep "^$sym:" | cut -d: -f2)"
      (( api > newest )) && newest="$api"
    else
      bad+="$sym "
    fi
  done <<<"$und"
  if [[ -n "$bad" ]]; then
    fail "L13 OHOS: OHAudio calls outside the API 12 list (a newer system only): $bad"
  elif (( newest == 0 )); then
    fail "L13 OHOS: no OHAudio call bound (ao_ohaudio missing)"
  else
    pass "L13 OHOS: OHAudio calls of API $newest at most (HarmonyOS 5.0 has API 12)"
  fi
  local cxx
  cxx="$(grep -E '^(_Z|__cxa_(allocate|throw|begin|end|rethrow|guard|pure)|_Unwind_|__gxx_personality)' <<<"$und" | head -5 | tr '\n' ' ')"
  if [[ -n "$cxx" ]]; then
    fail "L13 OHOS: C++ runtime or unwinder left to the system: $cxx"
  else
    pass "L13 OHOS: libc++, libc++abi and libunwind linked in"
  fi
  na "L13 dlopen: no OHOS loader runs here; ohos-emulator.yml loads libmpv on the Oniro emulator and plays it through ao_ohaudio"
  return 0
}
