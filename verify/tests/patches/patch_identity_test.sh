#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Compares the trees two versions of patches/ make from the pristine sources:
# the reference (another checkout or archive) and this repo's. Each case
# applies the patch steps of one platform build script, through the
# functions of scripts/shared/_audio_only.sh with one set of disabled
# patches, to a copy with each version, then a second time; both versions
# must succeed or fail together, and diff -r must find the trees equal after
# each run. Equal source trees build equal binaries, so a refactor of the
# patch scripts proven here needs no rebuild. The cases: every platform with
# everything on (iOS for both SDKs, the Apple export filter with a fake
# prefix), each toggle off alone where it acts, the coupled strips, FFmpeg
# with each of its toggles off, and the two rubberband patches.
#
# Usage: bash verify/tests/patches/patch_identity_test.sh <reference root>
#        <pristine mpv> <pristine ffmpeg> <pristine rubberband> <work dir>
# <reference root> holds patches/, e.g. `git archive <rev> patches | tar -x`.
# CASES="name ..." runs only the cases named. CHANGED="id ..." names toggles
# whose patch changed on purpose since the reference: they are left out on
# both sides of every case, so the cases prove the other scripts unchanged.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
usage="usage: patch_identity_test.sh <reference root> <pristine mpv> <pristine ffmpeg> <pristine rubberband> <work dir>"
REF="${1:?$usage}"; MPV="${2:?$usage}"; FFMPEG="${3:?$usage}"; RB="${4:?$usage}"; T="${5:?$usage}"
REF="$(cd "$REF" && pwd)"
[[ -d "$REF/patches" ]] || { echo "no patches/ in $REF"; exit 2; }
rm -rf "$T"; mkdir -p "$T"
export PYTHONDONTWRITEBYTECODE=1

# A prefix with the archives patch_export_filter.py checks for.
PREFIX="$T/prefix"
mkdir -p "$PREFIX/lib"
for a in ssl crypto xml2 bz2 lzma; do : > "$PREFIX/lib/lib$a.a"; done
EXPORTS="$ROOT/scripts/shared/mpv.exports"

# steps <patches root> <kind> <dir> <disabled>: the patch steps of one build,
# with DISABLED_PATCHES as the Settings would set it.
steps() (
  set -e
  # shellcheck source=/dev/null
  source "$ROOT/scripts/shared/_helpers.sh"
  # shellcheck source=/dev/null
  source "$ROOT/scripts/shared/_versions.sh"
  # shellcheck source=/dev/null
  source "$ROOT/scripts/shared/_audio_only.sh"
  LIBMPV_SCRIPTS_ROOT="$1"
  DISABLED_PATCHES="$4"
  unset PATCH_RECORD
  local m="$1/patches/mpv" d="$3"
  case "$2" in
    linux)
      apply_mpv_patches_common "$d"
      python3 "$m/linux/patch_optional_audio_libs.py" "$d" ;;
    android)
      apply_mpv_patches_common "$d"
      if patch_on audiotrack; then python3 "$m/android/patch_audiotrack.py" "$d"; fi ;;
    ios-*)
      python3 "$m/ios/patch_ios_platform.py" "$d" "${2#ios-}"
      python3 "$m/ios/patch_ios_audio_stubs.py" "$d"
      python3 "$m/apple/patch_utils_mac.py" "$d/meson.build"
      python3 "$m/ios/patch_compat_apple.py" "$d"
      python3 "$m/apple/patch_export_filter.py" "$d" "$EXPORTS" "$PREFIX"
      apply_mpv_patches_common "$d" ;;
    macos)
      python3 "$m/apple/patch_utils_mac.py" "$d/meson.build"
      python3 "$m/apple/patch_export_filter.py" "$d" "$EXPORTS" "$PREFIX"
      apply_mpv_patches_common "$d" ;;
    windows)
      python3 "$m/windows/patch_windows_deps.py" "$d/meson.build"
      if patch_on timer_resolution; then python3 "$m/windows/patch_timer_resolution.py" "$d"; fi
      apply_mpv_patches_common "$d" ;;
    ffmpeg)
      apply_ffmpeg_patches "$d" ;;
    rubberband)
      python3 "$1/patches/rubberband/patch_rubberband_size_t.py" "$d"
      python3 "$1/patches/rubberband/patch_rubberband_winarm64.py" "$d" ;;
  esac
)

# <name> <kind> <disabled patches...>
CASE_LIST=(
  "linux linux"
  "android android"
  "ios-iphoneos ios-iphoneos"
  "ios-iphonesimulator ios-iphonesimulator"
  "macos macos"
  "windows windows"
  "ffmpeg ffmpeg"
  "rubberband rubberband"
  "no-strip_win_resources windows strip_win_resources"
  "no-timer_resolution windows timer_resolution"
  "no-audiotrack android audiotrack"
  "no-strip_mpv_dead linux strip_mpv_dead"
  "no-strip_libass+strip_mpv_dead linux strip_libass strip_mpv_dead"
  "no-strip_swscale+strip_mpv_dead linux strip_swscale strip_mpv_dead"
)
for t in strip_swscale strip_libass afmt_reset prefetch \
         audio_output_state embedded_cover_art pcm_tap bulk_analysis loudness_scan \
         filter_label_tap chain_eof lavfi_eof_passthrough hotplug_core_thread \
         playlist_prev_dos_path chapter_list_reset af_command_args read_error; do
  CASE_LIST+=("no-$t linux $t")
done
for t in libsmb2 advanced_editlist dash_keepalive read_error embed_cacert; do
  CASE_LIST+=("no-$t ffmpeg $t")
done

fails=0 ran=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

for c in "${CASE_LIST[@]}"; do
  read -r name kind disabled <<< "$c"
  disabled="$disabled ${CHANGED:-}"
  if [[ -n "${CASES:-}" && " $CASES " != *" $name "* ]]; then continue; fi
  ran=$((ran + 1))
  case "$kind" in
    ffmpeg) src="$FFMPEG" ;;
    rubberband) src="$RB" ;;
    *) src="$MPV" ;;
  esac
  for side in ref new; do cp -a "$src" "$T/$name.$side"; done
  for run in 1 2; do
    steps "$REF" "$kind" "$T/$name.ref" "$disabled" > "$T/$name.ref.$run.log" 2>&1; r1=$?
    steps "$ROOT" "$kind" "$T/$name.new" "$disabled" > "$T/$name.new.$run.log" 2>&1; r2=$?
    [[ $(( r1 == 0 )) == $(( r2 == 0 )) ]]
    check $? "$name run $run: both versions agree (exit $r1 and $r2)"
    diff -r "$T/$name.ref" "$T/$name.new" > "$T/$name.$run.diff"
    check $? "$name run $run: equal trees"
  done
  [[ -s "$T/$name.1.diff" || -s "$T/$name.2.diff" ]] || rm -rf "$T/$name.ref" "$T/$name.new"
done

(( ran > 0 )) || { echo "no case ran"; exit 2; }
if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed ($ran cases)"
