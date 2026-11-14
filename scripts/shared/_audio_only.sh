# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Audio-only ffmpeg flags + shared patch application across the 9
# build_libmpv_<platform>.sh scripts. Sourced by every one of them (the
# tvOS one runs the iOS one), by verify_binaries.sh and by write_manifest.sh.
#
# Strategy: keep all demuxers (so the consumer can open any container,
# including mixed audio+video files like .mkv/.mp4 — mpv ignores video
# tracks and decodes only audio); protocols are a whitelist (see
# --enable-protocol in ffmpeg_common_args); strip out video
# decoders/encoders and swscale; keep only the spdif muxer, which
# audio-spdif passthrough wraps AC3/DTS in; drop avdevice (no
# capture/output devices needed for a playback-only library).
#
# A curated audio-filter whitelist is enabled (AUDIO_FILTERS, ~86 entries) via
# --disable-filters + --enable-filter. Video filters are stripped — and a blanket
# `--enable-filters` would link the full ~400-filter
# libavfilter (~5 MB), which is wasted for audio. The typed-DSP API +
# `setCustomAudioFilters` get full coverage; the few entries that need
# external deps (flite, ladspa, lv2) are omitted because we don't link
# those libraries.
#
# Add a new codec/parser/bsf here and the next rebuild on every
# platform picks it up — the per-platform scripts reference these
# variables directly.

# ── Audio decoders mpv recognises on the audio path ──────────────────────────
# One variable, built up category-by-category — the SAME grouping (and order)
# as the build TUI's Settings catalog in `tui/catalog.go`, so the shell list
# and the UI stay symmetric. ffmpeg ignores ordering, so the split is purely
# for readability. The final string is what gets passed to `--enable-decoder=`
# on every platform; ffmpeg's configure silently skips entries it can't link
# (e.g. the Apple `*_at` decoders on non-Apple hosts, because
# `AudioToolbox.framework` isn't in the cross sysroot), and
# `verify_ffmpeg_config` then asserts each per-OS subset compiled exactly as
# expected.
#
# Every entry is testable: either via a fixture in test/fixtures/codec/
# (end-to-end decode) or via the registry-presence test in the Dart
# suite (`registry_coverage_test.dart`).
#
# Coverage:
#   Lossy:    aac (+latm), ac3, eac3, mp1/2/3 (+ float/adu/on4 variants),
#             opus, vorbis, wma v1/v2/voice/pro, atrac3/3p/9, cook, sipr,
#             speex, nellymoser, gsm, gsm_ms, musepack v7/v8,
#             adpcm_ima_qt, adpcm_ms, ralf
#   Lossless: alac, flac, mlp, truehd, tta, wavpack, wmalossless, ape, shorten
#   Surround: dca (DTS/DTS-HD), mlp, truehd
#   Pro/broadcast: s302m
#   DSD/SACD: dsd_lsbf(_planar), dsd_msbf(_planar)
#   PCM:      every bit-depth × endianness × float/int combo + alaw / mulaw /
#             bluray / dvd / lxf / vidc / s24daud
#   Apple HW: aac_at, alac_at, mp3_at — backed by AudioToolbox.framework.
#             On Apple Silicon (M-series, iPhone/iPad) these offload to
#             the dedicated audio decode block / AMX matrix unit —
#             ~3-5× lower CPU per decoded file, noticeably better battery
#             on iOS. NOT auto-selected by ffmpeg (the software variant
#             registers first); enable with `setRawProperty('ad',
#             'mp3_at,aac_at,alac_at')`.
AUDIO_DECODERS=""
# ── Lossy ───────────────────────────────────────────────────────────────────
AUDIO_DECODERS+="aac,aac_latm,ac3,eac3,dca,opus,vorbis,mp1,mp1float,mp2,mp2float,mp3,mp3float,mp3adu,mp3adufloat,mp3on4,mp3on4float,cook,sipr,ralf,speex,nellymoser,gsm,gsm_ms,atrac3,atrac3p,atrac9,mpc7,mpc8,wmav1,wmav2,wmapro,wmavoice"
# ── Lossless ────────────────────────────────────────────────────────────────
AUDIO_DECODERS+=",alac,flac,ape,tta,wavpack,wmalossless,mlp,truehd,shorten,s302m"
# ── DSD ─────────────────────────────────────────────────────────────────────
AUDIO_DECODERS+=",dsd_lsbf,dsd_lsbf_planar,dsd_msbf,dsd_msbf_planar"
# ── ADPCM ───────────────────────────────────────────────────────────────────
AUDIO_DECODERS+=",adpcm_ima_qt,adpcm_ms"
# ── PCM ─────────────────────────────────────────────────────────────────────
AUDIO_DECODERS+=",pcm_alaw,pcm_mulaw,pcm_vidc,pcm_bluray,pcm_dvd,pcm_lxf,pcm_s24daud,pcm_f16le,pcm_f24le,pcm_f32be,pcm_f32le,pcm_f64be,pcm_f64le,pcm_s8,pcm_s8_planar,pcm_s16be,pcm_s16be_planar,pcm_s16le,pcm_s16le_planar,pcm_s24be,pcm_s24le,pcm_s24le_planar,pcm_s32be,pcm_s32le,pcm_s32le_planar,pcm_s64be,pcm_s64le,pcm_u8,pcm_u16be,pcm_u16le,pcm_u24be,pcm_u24le,pcm_u32be,pcm_u32le"
# ── Apple HW ────────────────────────────────────────────────────────────────
AUDIO_DECODERS+=",aac_at,alac_at,mp3_at"
export AUDIO_DECODERS

# ── Audio parsers (pre-decoder bitstream parsers) ────────────────────────────
# Same sectioned shape as AUDIO_DECODERS for consistency. Parsers
# operate on raw bitstreams before any decoder is involved, so there
# are no Apple-only variants — the cross-platform set is the whole list.
# NOTE: this is only the EXPLICITLY-requested set. ffmpeg's configure also
# `select`s a parser automatically when a kept decoder/demuxer needs it — e.g.
# `mlp_decoder_select="mlp_parser"` + `truehd_decoder_select="mlp_parser"` mean
# CONFIG_MLP_PARSER=1 in every build (verified), so bare raw .mlp/.thd
# elementary streams parse even though `mlp` is not listed here. So a decoder
# can never end up without its required parser. verify_ffmpeg_config asserts
# every entry here actually compiled (a defence-in-depth coverage check).
AUDIO_PARSERS=""
# ── all OSes ─────────────────────────────────────────────────────────────────
AUDIO_PARSERS+="aac,aac_latm,ac3,cook,dca,flac,mpegaudio,opus,vorbis"
export AUDIO_PARSERS

# ── Audio filters (libavfilter) — explicit whitelist ─────────────────────────
# Every filter here MUST be usable in mpv's `--af` chain, which means
# strictly 1 audio input → 1 audio output. mpv's lavfi-bridge gate
# (`is_usable` in filters/f_lavfi.c) rejects anything else with
# "Option af: 'lavfi-X' isn't supported" or fails at init with
# "exactly 2 pads required". Excluded categories (do not re-add):
#   - 2-input: acrossfade, sidechaincompress, sidechaingate, amultiply,
#     aap, anlmf, anlms, arls, apsnr, asdr, asisdr, axcorrelate
#   - multi-input dynamic (init fails on chain build): amerge, amix,
#     ainterleave, join, afir
#   - multi-output: acrossover, asplit, channelsplit
#   - source filters (0-input — would need libavdevice + lavfi indev,
#     not built in this audio-only flavour): aevalsrc, afdelaysrc,
#     afireqsrc, afirsrc, anoisesrc, anullsrc, hilbert, sinc, sine
#   - sink filters: anullsink (the AO already terminates the chain)
# Skipped because of external pkg-config deps we don't bundle:
#   - bs2b      (libbs2b) — use `crossfeed` instead, native ffmpeg, same idea
#   - asr       (pocketsphinx) — speech recognition
#   - azmq      (libzmq) — ZeroMQ command bridge
#   - sofalizer (libmysofa) — binaural HRTF
#   - flite     (libflite) — TTS
#   - ladspa, lv2 — plugin hosts requiring system plugin dirs
# `rubberband` (librubberband, GPL-2.0+) is in the GPL build only (LIBMPV_GPL=1,
# see gpl_build below), which appends it to this list, passes
# `--enable-librubberband` and builds mpv's native `af_rubberband.c` with
# `-Drubberband=enabled`. The default LGPL build has neither.
# Filters dropped from the whitelist for the 0.1.0 cut (debug / utility
# only — they have no business in a music-player API):
#   abench, acopy, acue, alatency, aloop, ametadata, anull, aperms,
#   arealtime, areverse, asegment, aselect, asendcmd, asetnsamples, asetpts,
#   asettb, ashowinfo, asidedata, aspectralstats, astats, astreamselect,
#   atrim, silencedetect, volume, volumedetect.
# aintegral and asetrate came back later and are in the list below.
# The decoder-side `--replaygain` (typed `ReplayGainSettings`) and `volume`
# (typed `setVolume` / `setVolumeGain`) cover the corresponding user-facing
# concepts; the lavfi `replaygain` filter would shadow ours so it's
# dropped too.
# Built up by category — the SAME grouping as the build TUI's Settings
# catalog (tui/catalog.go), so the shell list and the UI stay symmetric.
# ffmpeg ignores ordering; the split is purely for readability.
AUDIO_FILTERS=""
# ── Dynamics ────────────────────────────────────────────────────────────────
AUDIO_FILTERS+="acompressor,alimiter,agate,adrc,compand,mcompand,dynaudnorm,speechnorm,deesser,adynamicequalizer,adynamicsmooth,apsyclip,asoftclip,acrusher,crystalizer,aexciter"
# ── EQ & Filtering ──────────────────────────────────────────────────────────
AUDIO_FILTERS+=",equalizer,anequalizer,superequalizer,firequalizer,bass,treble,highpass,lowpass,highshelf,lowshelf,tiltshelf,bandpass,bandreject,allpass,biquad,aiir,atilt,asubboost,asubcut,asupercut,asuperpass,asuperstop,aemphasis"
# ── Spatial / Stereo ────────────────────────────────────────────────────────
AUDIO_FILTERS+=",stereotools,stereowiden,extrastereo,crossfeed,haas,surround,earwax,pan,channelmap,virtualbass,dialoguenhance,adecorrelate"
# ── Time / Pitch ────────────────────────────────────────────────────────────
AUDIO_FILTERS+=",atempo,asetrate,aresample,aformat,adelay,apad,compensationdelay,afade,aphaseshift,afreqshift"
# ── Modulation / FX ─────────────────────────────────────────────────────────
AUDIO_FILTERS+=",aecho,chorus,flanger,aphaser,apulsator,tremolo,vibrato"
# ── Restoration / Noise ─────────────────────────────────────────────────────
AUDIO_FILTERS+=",afftdn,afwtdn,anlmdn,arnndn,adeclick,adeclip,adenorm,aderivative,aintegral,dcshift,hdcd,silenceremove"
# ── Loudness / Metering ─────────────────────────────────────────────────────
AUDIO_FILTERS+=",loudnorm,ebur128,drmeter"
# ── Misc / Analysis ─────────────────────────────────────────────────────────
AUDIO_FILTERS+=",aeval,afftfilt,acontrast"
export AUDIO_FILTERS

# ── Audio bitstream filters (auto-inserted by demuxers) ──────────────────────
# `aac_adtstoasc` is auto-inserted by the MP4/MOV/FLV/LATM muxers when copying
# AAC ADTS streams — without it some .m4a/.mp4 files fail to open.
# `extract_extradata` is auto-inserted by many demuxers to materialise codec
# extradata before the decoder runs. `null` and `setts` are pass-through
# helpers used internally by ffmpeg.
export AUDIO_BSFS="aac_adtstoasc,extract_extradata,null,setts"

# ── User overrides (generated by the build TUI's Settings page) ──────────────
# The Go build TUI (`./build` ▸ Settings) writes _user_overrides.sh next to
# this file when the user trims the decoder / filter selection. It re-exports
# AUDIO_DECODERS / AUDIO_FILTERS with the customised set, overriding the
# curated defaults above. Absent by default → the whitelists above are used
# verbatim. Because ffmpeg_common_args() below expands $AUDIO_* at call time,
# sourcing the override here (before any build calls that function) is enough.
#
# Required decoders the config audit asserts (aac, flac, mp3, opus, vorbis,
# alac, + Apple *_at) are force-kept by the TUI, so a customised set never
# trips verify_ffmpeg_config. The Apple *_at decoders stay in the list on
# every platform; ffmpeg silently skips them where AudioToolbox is absent,
# exactly as with the default list.
_ao_overrides="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_user_overrides.sh"
if [[ -f "$_ao_overrides" ]]; then
  # shellcheck source=/dev/null
  source "$_ao_overrides"
fi
unset _ao_overrides

# patch_on <id> — true unless <id> is listed (space-separated) in the
# DISABLED_PATCHES override the Settings ▸ Patches tab writes. Used by the
# apply_*_patches functions below to skip user-disabled feature patches.
patch_on() {
  case " ${DISABLED_PATCHES:-} " in
    *" $1 "*) return 1 ;;
    *) return 0 ;;
  esac
}

# ── License: LGPL by default, GPL on request ─────────────────────────────────
# The libmpv we publish is LGPL, version 3 or later: FFmpeg without
# --enable-gpl (LGPLv3 with --enable-version3, see ffmpeg_common_args) and mpv
# with -Dgpl=false (LGPLv2.1+), which lets an app link it under the LGPL's
# conditions whatever its own license. librubberband is GPL-2.0-or-later
# (Breakfast Quay also offers it under a commercial license), so it is not in
# that build.
#
# gpl_build — true only when LIBMPV_GPL=1, set in the environment or by the
# Settings ▸ License tab of the build TUI (it writes the override file). It
# turns on, together: FFmpeg --enable-gpl --enable-librubberband and its
# rubberband filter, mpv -Dgpl=true -Drubberband=enabled, the librubberband
# build of every platform, and the GPL-3.0-or-later license in the build
# record. Off by default; the release workflows never set it. A prefix built
# with the other setting is refused by write_build_record: clean the build
# directory after a change.
case "${LIBMPV_GPL:-0}" in
  0|1) ;;
  *) die "LIBMPV_GPL=${LIBMPV_GPL} (expected 0 or 1)" ;;
esac
gpl_build() { [[ "${LIBMPV_GPL:-0}" == "1" ]]; }

# The rubberband filter follows the license, also when an override lists the
# filters: FFmpeg would drop it without librubberband and the config audit
# would stop the build.
if gpl_build; then
  LIBMPV_LICENSE="GPL-3.0-or-later"
  case ",$AUDIO_FILTERS," in
    *",rubberband,"*) ;;
    *) AUDIO_FILTERS="${AUDIO_FILTERS:+$AUDIO_FILTERS,}rubberband" ;;
  esac
else
  LIBMPV_LICENSE="LGPL-3.0-or-later"
  AUDIO_FILTERS="$(printf ',%s,' "$AUDIO_FILTERS" | sed 's/,rubberband,/,/; s/^,//; s/,$//')"
fi
export AUDIO_FILTERS LIBMPV_LICENSE

# ── Patch record ─────────────────────────────────────────────────────────────
# Each build records the toggleable patches it applied (the ids of the TUI
# catalog; the required ones always are) and the filters FFmpeg was
# configured with, so the manifest states what the binaries contain and not
# what the settings say when it runs (F211). The record lives in the prefix
# of the stage, under share/libmpv-scripts: a cached stage keeps its prefix,
# and with it its record.
#
# patch_record_start <tree> <prefix> — the stage patches a fresh <tree>
# (ffmpeg or mpv) and installs into <prefix>: start its record afresh, with
# the license it is configured for (LIBMPV_LICENSE). The FFmpeg one also keeps
# the AUDIO_FILTERS its configure compiles in.
patch_record_start() {
  local tree="$1" dir="$2/share/libmpv-scripts"
  mkdir -p "$dir"
  PATCH_RECORD="$dir/$tree.patches"
  : > "$PATCH_RECORD"
  printf '%s\n' "$LIBMPV_LICENSE" > "$dir/$tree.license"
  if [[ "$tree" == ffmpeg ]]; then
    printf '%s\n' "$AUDIO_FILTERS" > "$dir/audio_filters"
  fi
}

# record_patch <id> — note <id> in the record of the tree being patched.
record_patch() {
  if [[ -n "${PATCH_RECORD:-}" ]]; then
    printf '%s\n' "$1" >> "$PATCH_RECORD"
  fi
}

# toolchain_note <name> <value> — one more entry of the "toolchain" of the
# records this build writes (write_build_record): what only the platform
# script knows. A later note of the same name replaces the earlier one.
TOOLCHAIN_NOTES=()
toolchain_note() {
  local kept=() n
  for n in ${TOOLCHAIN_NOTES[@]+"${TOOLCHAIN_NOTES[@]}"}; do
    [[ "$n" == "$1="* ]] || kept+=("$n")
  done
  TOOLCHAIN_NOTES=(${kept[@]+"${kept[@]}"} "$1=$2")
}

# toolchain_lines — the "toolchain" of a record as name=value lines: the
# compiler, the build tools on PATH, then the notes. $CC may hold a launcher
# and flags ("ccache gcc"), so it is split into words on purpose.
toolchain_lines() {
  local cc="${BUILD_TOOLCHAIN_CC:-${CC:-}}" line tool n
  if [[ -n "$cc" ]]; then
    # shellcheck disable=SC2086
    # || true: head closing the pipe early is not a failed compiler.
    line="$($cc --version 2>/dev/null | head -1)" || true
    [[ -n "$line" ]] && printf 'compiler=%s\n' "$line"
  fi
  for tool in meson ninja cmake; do
    line="$("$tool" --version 2>/dev/null | head -1)" || true
    [[ -n "$line" ]] && printf '%s=%s\n' "$tool" "${line#cmake version }"
  done
  for n in ${TOOLCHAIN_NOTES[@]+"${TOOLCHAIN_NOTES[@]}"}; do
    printf '%s\n' "$n"
  done
  return 0
}

# write_build_record <target> <prefix>... — write builds/release/
# build_<target>.json, the record of libmpv_<target>.*: its release, its
# license, its patches and its filters, from the prefixes it was linked from
# (one per architecture or slice, which must agree). A stage cached from a
# build with the other license setting stops it, and so does a toggle with a
# side in each tree (read_error) found in one record only: a cached FFmpeg
# stage built with it and mpv built again without it, or the reverse.
# write_manifest.sh reads it. RELEASE_DIR overrides the directory.
#
# The record also names the toolchain, "toolchain": the first line of the
# compiler's --version (the $CC the build exports, or BUILD_TOOLCHAIN_CC),
# and meson, ninja and cmake as found on PATH, so a release states what
# compiled it and not only what a Dockerfile asked for. A script adds what
# only it knows (the NDK, Xcode and its SDK, emsdk) with toolchain_note.
# A tool that is not there is left out: the record never stops a build for it.
write_build_record() {
  local target="$1"; shift
  local out="${RELEASE_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/release}"
  mkdir -p "$out"
  BUILD_TOOLCHAIN="$(toolchain_lines)" \
  python3 - "$out/build_$target.json" "$target" "$LIBMPV_RELEASE" "$LIBMPV_LICENSE" "$@" <<'PY'
import json, os, pathlib, sys

out, target, release, license, *prefixes = sys.argv[1:]
# The toggles that patch both trees, FFmpeg and mpv.
TWO_SIDED = {"read_error"}
records = []
for prefix in prefixes:
    d = pathlib.Path(prefix, "share", "libmpv-scripts")
    try:
        trees = {}
        for tree in ("ffmpeg", "mpv"):
            trees[tree] = set((d / f"{tree}.patches").read_text().split())
            built = (d / f"{tree}.license").read_text().strip()
            if built != license:
                sys.exit(f"{prefix}: {tree} was built {built}, this build is "
                         f"{license} (LIBMPV_GPL): clean the build directory "
                         "and build again")
        filters = (d / "audio_filters").read_text().strip().split(",")
    except FileNotFoundError as e:
        sys.exit(f"No patch record {e.filename}: a stage built before the "
                 "record existed, clean the build directory and build again")
    for tree, other in (("ffmpeg", "mpv"), ("mpv", "ffmpeg")):
        for half in sorted(TWO_SIDED & trees[tree] - trees[other]):
            sys.exit(f"{prefix}: {half} is in the {tree} stage and not in the "
                     f"{other} one (a stage built with other patches): clean "
                     "the build directory and build again")
    patches = trees["ffmpeg"] | trees["mpv"]
    records.append((sorted(patches), sorted(t for t in filters if t)))
if not records:
    sys.exit("write_build_record: no prefix")
if any(r != records[0] for r in records[1:]):
    sys.exit(f"The prefixes of {target} differ in patches or filters: "
             f"{dict(zip(prefixes, records))}")
patches, filters = records[0]
toolchain = dict(l.split("=", 1) for l in os.environ.get("BUILD_TOOLCHAIN", "").splitlines()
                 if "=" in l and l.split("=", 1)[1].strip())
pathlib.Path(out).write_text(json.dumps({
    "release": release,
    "target": target,
    "license": license,
    "patches": patches,
    "audioFilters": filters,
    "toolchain": toolchain,
}, indent=2) + "\n")
print(f"Wrote {out} ({license}, {len(patches)} patches, {len(filters)} filters)")
PY
}

# ── License texts ────────────────────────────────────────────────────────────
# write_licenses <target> <src dir> <component>... — write builds/release/
# licenses_<target>/: the license texts of every component linked into
# libmpv_<target>.*, copied from the source trees the build extracted into
# <src dir> (so they are the texts of the versions built), our own LICENSE,
# the notice of the Mozilla CA bundle when embed_cacert is on, README.txt:
# the license of the build and where its exact source is (the commit of this
# repo, and the tarballs and git tags this build checked against
# _sources.sha256, from SOURCES_FETCHED of _helpers.sh), and
# THIRD_PARTY_LICENSES.txt: the same texts in one plain-text file, each
# component with its name, version and SPDX license id, for an app to ship
# as it is. The caller lists
# what it links, by the settings of the build: rubberband only with gpl_build,
# libsmb2 only with patch_on libsmb2, the font stack only without
# libass_stripped, and the runtime libraries of the toolchain it links
# statically whose license asks for its notice in a binary (TOOLCHAIN below,
# texts in scripts/shared/licenses); <component>=<tree> names a tree the build
# extracted under another name (the mpv tree of each Apple arch). A component
# without its tree or its texts stops the build.
# write_manifest.sh packs the directories into licenses.zip. RELEASE_DIR
# overrides the directory.
#
# The same list, with the version of each component, goes into the record of
# the build as "components" (build_<target>.json next to the directory, or
# BUILD_RECORD when the record lives elsewhere): what this binary links, from
# the call that names it, not what _versions.sh pins for every platform. The
# runtime libraries of the toolchain have no version of their own and are
# left to "toolchain". No record there, nothing written.
#
# mpv and FFmpeg get the texts of the license they are built under (LGPL or
# GPL, see gpl_build; the LGPLv3 comes with the GPLv3 it adds to) with their
# own notes on it (Copyright, LICENSE.md); the
# other components every top-level LICENSE / COPYING / COPYRIGHT / NOTICE
# file they ship. A component without an SPDX id in SPDX below stops the
# build, so a new one gets its id.
write_licenses() {
  local target="$1" src="$2"; shift 2
  local out="${RELEASE_DIR:-$LIBMPV_SCRIPTS_ROOT/builds/release}/licenses_$target"
  # safe.directory: in Docker, root reads a checkout of the runner's user.
  local commit="${GITHUB_SHA:-$(git -c safe.directory='*' -C "$LIBMPV_SCRIPTS_ROOT" rev-parse HEAD 2>/dev/null || true)}"
  local extra=()
  patch_on embed_cacert && [[ " $* " == *" openssl "* ]] && extra+=(mozilla-ca)
  rm -rf "$out"
  # The versions a platform script pins itself are not exported.
  LIBPLACEBO_VERSION="${LIBPLACEBO_VERSION:-}" LIBUNIBREAK_VERSION="${LIBUNIBREAK_VERSION:-}" \
  LIBEXPAT_VERSION="${EXPAT_VERSION:-$LIBEXPAT_VERSION}" \
    python3 - "$out" "$target" "$src" "$commit" "$@" ${extra[@]+"${extra[@]}"} <<'PY'
import json, os, pathlib, re, shutil, sys

out, target, src, commit, *components = sys.argv[1:]
out, src = pathlib.Path(out), pathlib.Path(src)
root = pathlib.Path(os.environ["LIBMPV_SCRIPTS_ROOT"])
env = os.environ.get
gpl = env("LIBMPV_LICENSE") == "GPL-3.0-or-later"

def v(name):
    value = env(name, "")
    if not value:
        sys.exit(f"write_licenses: {name} is not set")
    return value[1:] if value.startswith("v") else value

# The SPDX id of each component, as linked here: mpv built with -Dgpl=false
# (true in the GPL build), FFmpeg with --enable-version3 (and --enable-gpl),
# libiconv and xz by their library, the static winpthreads and CRT of
# mingw-w64, the LLVM runtimes under their current license (code older than
# its relicensing is under the legacy NCSA OR MIT, in the same texts).
SPDX = {
    "mpv": "GPL-2.0-or-later" if gpl else "LGPL-2.1-or-later",
    "ffmpeg": "GPL-3.0-or-later" if gpl else "LGPL-3.0-or-later",
    "openssl": "Apache-2.0", "libxml2": "MIT", "zlib": "Zlib", "bzip2": "bzip2-1.0.6",
    "xz": "0BSD", "libiconv": "LGPL-2.1-or-later", "speexdsp": "BSD-3-Clause",
    "pipewire": "MIT", "libplacebo": "LGPL-2.1-or-later", "libsmb2": "LGPL-2.1-or-later",
    "rubberband": "GPL-2.0-or-later", "expat": "MIT", "libpng": "libpng-2.0",
    "freetype": "FTL OR GPL-2.0-or-later", "fribidi": "LGPL-2.1-or-later",
    "harfbuzz": "MIT-Modern-Variant", "fontconfig": "HPND-sell-variant",
    "libass": "ISC", "libunibreak": "Zlib", "mozilla-ca": "MPL-2.0",
    "winpthreads": "MIT AND BSD-3-Clause", "implib": "MIT",
    "mingw-w64-crt": "ZPL-2.1 AND ISC AND BSD-2-Clause AND dtoa AND SunPro AND MIT",
    "llvm-runtimes": "Apache-2.0 WITH LLVM-exception, legacy code NCSA OR MIT",
    "emscripten": "MIT OR NCSA", "musl": "MIT",
}

# The runtime libraries of the toolchain that a build links statically and
# whose license asks for its notice in a binary. No source tree of the build
# holds them, so scripts/shared/licenses/<name>/ has the upstream texts
# (SOURCES.txt there says where from). The caller lists the ones of its
# toolchain:
#   winpthreads    -lwinpthread, both Windows toolchains (MIT, BSD-3-Clause);
#   mingw-w64-crt  the CRT startup code and libmingwex/libmingw32 that -static
#                  links into every MinGW binary, both Windows toolchains: its
#                  ZPL-2.1 and BSD parts ask for the notices in binary form;
#   llvm-runtimes  libc++, libc++abi, libunwind and the compiler-rt builtins,
#                  linked statically on Android (libc++_static), Windows arm64
#                  (llvm-mingw, -static) and web (Emscripten). The LLVM
#                  exception of their Apache-2.0 waives the notice for code
#                  compiled into a binary, but the code older than the
#                  relicensing is still under the legacy NCSA OR MIT, whose
#                  terms keep the notice: shipped as cheap good practice;
#   emscripten     the JS glue and Emscripten's own system libraries in the
#                  web module (MIT OR NCSA, both keep the notice);
#   musl           the libc of the web module, musl as Emscripten bundles it
#                  (MIT).
# Not listed: libgcc and libstdc++ (GCC, Windows x86_64 and Linux), under the
# GCC Runtime Library Exception, which asks for no notice; glibc's static
# start files, under the LGPL with its linking exception; the compiler-rt
# builtins Apple's clang links, which the LLVM exception covers; and
# libc++/libSystem on Apple and glibc on Linux, which are dynamic.
TOOLCHAIN = {
    "winpthreads": ("mingw-w64 winpthreads", ["COPYING"]),
    "mingw-w64-crt": ("mingw-w64 runtime (CRT)", ["COPYING.MinGW-w64-runtime.txt"]),
    "llvm-runtimes": ("LLVM libc++, libc++abi, libunwind and compiler-rt",
                      [f"{d}/LICENSE.TXT" for d in ("libcxx", "libcxxabi", "libunwind", "compiler-rt")]),
    "emscripten": ("Emscripten", ["LICENSE"]),
    "musl": ("musl libc of Emscripten", ["COPYRIGHT"]),
}
VERSION = {"mpv": "MPV_VERSION", "ffmpeg": "FFMPEG_VERSION", "libplacebo": "LIBPLACEBO_VERSION",
           "libsmb2": "LIBSMB2_VERSION", "pipewire": "PIPEWIRE_VERSION",
           "speexdsp": "SPEEXDSP_VERSION", "harfbuzz": "HARFBUZZ_VERSION",
           "freetype": "FREETYPE_VERSION", "openssl": "OPENSSL_VERSION",
           "libxml2": "LIBXML2_VERSION", "zlib": "ZLIB_VERSION", "xz": "XZ_VERSION",
           "bzip2": "BZIP2_VERSION", "libiconv": "LIBICONV_VERSION",
           "rubberband": "RUBBERBAND_VERSION", "fribidi": "FRIBIDI_VERSION",
           "fontconfig": "FONTCONFIG_VERSION", "libass": "LIBASS_VERSION",
           "libpng": "LIBPNG_VERSION", "expat": "LIBEXPAT_VERSION",
           "libunibreak": "LIBUNIBREAK_VERSION"}

def text_of(path):
    data = path.read_bytes()
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("latin-1")

# name: (tree under <src>, the pins in _sources.sha256, license files or
# None for the usual names)
def table(name):
    if name == "mpv":
        return (f"mpv-{v('MPV_VERSION')}", rf"/mpv/archive/refs/tags/v{re.escape(v('MPV_VERSION'))}\.tar",
                ["LICENSE.GPL" if gpl else "LICENSE.LGPL", "Copyright"])
    if name == "ffmpeg":
        return (f"ffmpeg-{v('FFMPEG_VERSION')}", rf"/ffmpeg-{re.escape(v('FFMPEG_VERSION'))}\.tar",
                (["COPYING.GPLv3"] if gpl else ["COPYING.LGPLv3", "COPYING.GPLv3"]) + ["LICENSE.md"])
    if name == "libplacebo":
        return ("libplacebo-git", rf"/libplacebo\.git#v{re.escape(v('LIBPLACEBO_VERSION'))}$", None)
    if name == "libsmb2":
        return ("libsmb2", rf"/libsmb2\.git#v{re.escape(v('LIBSMB2_VERSION'))}$", None)
    if name == "pipewire":
        return (f"pipewire-{v('PIPEWIRE_VERSION')}", rf"/pipewire\.git#{re.escape(v('PIPEWIRE_VERSION'))}$", None)
    if name == "speexdsp":
        ver = re.escape(v("SPEEXDSP_VERSION"))
        return (f"speexdsp*-{v('SPEEXDSP_VERSION')}", rf"/(speexdsp|SpeexDSP)-{ver}\.tar", None)
    if name == "harfbuzz":
        ver = re.escape(v("HARFBUZZ_VERSION"))
        return (f"harfbuzz-{v('HARFBUZZ_VERSION')}", rf"/harfbuzz(/archive/refs/tags/|-){ver}\.tar", None)
    if name == "freetype":
        return (f"freetype-{v('FREETYPE_VERSION')}", rf"/freetype-{re.escape(v('FREETYPE_VERSION'))}\.tar",
                ["LICENSE.TXT", "docs/FTL.TXT", "docs/GPLv2.TXT"])
    var = VERSION.get(name)
    if not var:
        sys.exit(f"write_licenses: unknown component {name}")
    return (f"{name}-{v(var)}", rf"/{name}-{re.escape(v(var))}\.tar", None)

USUAL = re.compile(r"^(licen[cs]e|copying|copyright|notice)([.-].*)?$", re.I)
def lines(path):
    return [tuple(l.split(None, 1)) for l in path.read_text().splitlines()
            if l.strip() and not l.startswith("#")]
# The sources this build checked (SOURCES_FETCHED of _helpers.sh), each once:
# only those, so a component pinned under several URLs (mirrors, .tar.gz and
# .tar.xz) lists the one the build downloaded.
pinned = set(lines(root / "scripts/shared/_sources.sha256"))
fetched = pathlib.Path(env("SOURCES_FETCHED") or "/nonexistent")
pins = list(dict.fromkeys(lines(fetched))) if fetched.is_file() else []
out.mkdir(parents=True)
rows, sources, combined = [], [], []
for name in components:
    name, _, tree_name = name.partition("=")
    dest = out / name
    if name not in SPDX:
        sys.exit(f"write_licenses: no SPDX id for {name}")
    if name == "mozilla-ca":
        dest.mkdir()
        (dest / "NOTICE.txt").write_text(
            "libmpv embeds the Mozilla CA certificate store (patches/ffmpeg/embed_cacert/\n"
            "cacert.pem of libmpv-scripts, from https://curl.se/docs/caextract.html), made\n"
            "from Mozilla's certdata.txt. That data is subject to the terms of the Mozilla\n"
            "Public License, v. 2.0: https://mozilla.org/MPL/2.0/. Its source is the\n"
            "cacert.pem at the libmpv-scripts commit named in README.txt.\n")
        rows.append(f"  {name:<14} the Mozilla CA bundle (MPL-2.0)")
        pem = (root / "patches/ffmpeg/embed_cacert/cacert.pem").read_text()
        when = re.search(r"Certificate data from Mozilla as of: (.*)", pem)
        combined.append(("Mozilla CA certificate store", f"as of {when.group(1).strip()}" if when else "?",
                         SPDX[name], [("NOTICE.txt", text_of(dest / "NOTICE.txt"))]))
        continue
    if name in TOOLCHAIN:
        title, files = TOOLCHAIN[name]
        for f in files:
            (dest / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / "scripts/shared/licenses" / name / f, dest / f)
        rows.append(f"  {name:<14} {title} of the toolchain: {', '.join(files)}")
        combined.append((title, "of the toolchain", SPDX[name],
                         [(f, text_of(dest / f)) for f in files]))
        continue
    if name == "implib":
        # tools/implib of this repo: the trampolines of the Linux audio stubs.
        dest.mkdir()
        shutil.copyfile(root / "tools/implib/LICENSE.txt", dest / "LICENSE.txt")
        rows.append(f"  {name:<14} tools/implib of libmpv-scripts: LICENSE.txt")
        at = re.search(r"at commit `([0-9a-f]+)`", (root / "tools/implib/README.md").read_text())
        combined.append(("Implib.so", f"commit {at.group(1)}" if at else "?", SPDX[name],
                         [("LICENSE.txt", text_of(dest / "LICENSE.txt"))]))
        continue
    pattern, pin, files = table(name)
    pattern = tree_name or pattern
    trees = sorted(p for p in src.glob(pattern) if p.is_dir())
    if len(trees) != 1:
        sys.exit(f"write_licenses: {len(trees)} source trees {src}/{pattern} for {name}")
    tree = trees[0]
    if files is None:
        files = sorted(p.name for p in tree.iterdir() if p.is_file() and USUAL.match(p.name))
    if not files:
        sys.exit(f"write_licenses: no license file in {tree}")
    for f in files:
        if not (tree / f).is_file():
            sys.exit(f"write_licenses: no {f} in {tree}")
        (dest / f).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(tree / f, dest / f)
    rows.append(f"  {name:<14} {tree.name}: {', '.join(files)}")
    combined.append((name, v(VERSION[name]), SPDX[name], [(f, text_of(dest / f)) for f in files]))
    found = [f"  {h}  {u}" + ("" if (h, u) in pinned else "  (not pinned)")
             for h, u in pins if re.search(pin, u)]
    sources += found or [f"  {name}: no source checked against scripts/shared/_sources.sha256"]

dest = out / "libmpv-scripts"
dest.mkdir()
for f in ("LICENSE", "LICENSE.LGPL-2.1", "NOTICE"):
    shutil.copyfile(root / f, dest / f)
rows.insert(0, "  libmpv-scripts the build scripts and the patches of this repo: LICENSE (BSD-3-Clause),"
               "\n                 NOTICE (its files under the LGPL, MIT and MPL-2.0), LICENSE.LGPL-2.1;"
               "\n                 what a patch changes in mpv or FFmpeg is under their license")
combined.insert(0, ("libmpv-scripts", f"commit {commit or '(unknown)'}",
                    "BSD-3-Clause, with files under LGPL-2.1-or-later, MIT and MPL-2.0 (NOTICE)",
                    [(f, text_of(dest / f)) for f in ("LICENSE", "LICENSE.LGPL-2.1", "NOTICE")]))

release, license = env("LIBMPV_RELEASE", "?"), env("LIBMPV_LICENSE", "?")
what = ("This build of libmpv is GPL, version 3 or later: an app that ships it\n"
        "must be distributed under the GPLv3 too, with its source." if gpl else
        "This build of libmpv is LGPL, version 3 or later (the LGPLv3 is a set of\n"
        "permissions on top of the GPLv3, so both texts are here). It lets an app\n"
        "link the library whatever its own license, on its conditions, among them:\n"
        "ship these texts, say that the app uses libmpv and that libmpv is under\n"
        "the LGPL, provide the source of this library (see Source below), and let\n"
        "the user replace it with one built from modified source. libmpv is a\n"
        "separate dynamic library or module on every platform. The texts are the terms.")
(out / "README.txt").write_text(f"""libmpv {release} for {target}: {license}

{what}

Components, and the license files of each one in the directory of its name:
{chr(10).join(rows)}

Source: https://github.com/ales-drnz/libmpv-scripts at commit {commit or "(unknown)"}
builds this library from the upstream sources below, pinned by SHA-256 (tarballs)
or commit (git tags) in scripts/shared/_sources.sha256, with the patches under
patches/ of that commit:
{chr(10).join(sources)}
""")

# THIRD_PARTY_LICENSES.txt: the texts above in one file, for an app to ship
# without reading the directories. The ids are SPDX; the texts are what
# applies.
rule = "=" * 78
parts = [f"""Licenses of libmpv {release} for {target}: {license}

{what}

Each component linked into this library follows: its name, version and SPDX
license id, then the full text of each of its license files. The ids are a
guide; the texts are the terms.
"""]
for name, version, spdx, texts in combined:
    parts.append(f"{rule}\n{name} {version}\nLicense: {spdx}\n{rule}\n")
    for f, body in texts:
        parts.append(f"--- {f} ---\n\n{body.rstrip()}\n")
(out / "THIRD_PARTY_LICENSES.txt").write_text("\n".join(parts))
print(f"Wrote {out} ({len(components) + 1} components)")

record = pathlib.Path(env("BUILD_RECORD") or out.parent / f"build_{target}.json")
if record.is_file():
    data = json.loads(record.read_text())
    # combined holds libmpv-scripts, then one entry per component, in order.
    names = [c.partition("=")[0] for c in components]
    data["components"] = {name: version
                          for name, (_, version, _, _) in zip(names, combined[1:])
                          if name not in TOOLCHAIN}
    record.write_text(json.dumps(data, indent=2) + "\n")
PY
}

# swscale_stripped — true only when libswscale can actually be dropped. That
# needs BOTH reduction patches on:
#   - strip_swscale   severs mpv's own libswscale link (stubs mp_sws_*) and
#                     pairs with ffmpeg --disable-swscale, AND
#   - strip_mpv_dead  removes video/out/vo_tct.c + vo_kitty.c, the only TUs that
#                     `#include <libswscale/swscale.h>` directly — they fail to
#                     compile once the libswscale headers are gone.
# If the user keeps the GPU/terminal-VO stack (strip_mpv_dead disabled) we must
# therefore keep libswscale too, regardless of the strip_swscale checkbox. Both
# ffmpeg_common_args (--disable-swscale vs --enable-swscale) and the mpv patch
# application below pivot on this single predicate so the two sides never
# disagree.
swscale_stripped() {
  patch_on strip_swscale && patch_on strip_mpv_dead
}

# libass_stripped — true when the libass subtitle/OSD stack must be removed.
# libass can only be KEPT when BOTH strip_libass AND strip_mpv_dead are disabled:
# the real sub/sd_ass.c + sub/ass_mp.c reference the subtitle decode/draw infra
# (lavc_conv_*, sd_filter_sdh, mp_get_sub_bb_list / sub-bitmap draw_bmp) that
# strip_mpv_dead removes — so stripping the dead mpv subsystems also forces
# libass out (otherwise the final mpv link fails with those undefined refs).
# Mirrors swscale_stripped()'s coupling to strip_mpv_dead. Every libass site
# (patch application, font-stack build, link flags, HAVE_LIBASS audit, verify)
# pivots on THIS predicate so the two sides never disagree.
libass_stripped() {
  patch_on strip_libass || patch_on strip_mpv_dead
}

# decoder_on <name> — true if <name> is in the (possibly user-overridden)
# AUDIO_DECODERS list. Lets the config audit assert presence only for decoders
# actually selected, so a trimmed selection never trips verify_ffmpeg_config.
decoder_on() {
  case ",${AUDIO_DECODERS:-}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# _ao_upper <token> — uppercase a component token for its CONFIG_* macro name
# (bash 3.2-safe; avoids ${var^^} which is bash 4+).
_ao_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# ── ffmpeg configure: shared flags ───────────────────────────────────────────
# Per-platform script appends its own toolchain / SDK / TLS-backend / hwaccel
# flags after expanding $(ffmpeg_common_args).
ffmpeg_common_args() {
  # LTO flag: ffmpeg's `--enable-lto=thin` becomes `-flto=thin` which Clang
  # accepts (and prefers) but upstream GCC rejects. Probe $CC and emit the
  # right flavour. Plain `--enable-lto` (= `-flto`) is portable and what GCC
  # gets; Clang gets the thin variant for build parallelism.
  local _ffmpeg_lto_flag="--enable-lto"
  local _cc="${CC:-cc}"; _cc="${_cc##* }"
  if "$_cc" --version 2>/dev/null | grep -qiE 'clang|llvm'; then
    _ffmpeg_lto_flag="--enable-lto=thin"
  fi
  # libsmb2 is gated by its (toggleable) ffmpeg patch. When the user disables
  # it in Settings ▸ Patches, drop the protocol token and omit --enable-libsmb2
  # so configure never sees an option it was never patched to understand.
  local _smb2_proto="" _smb2_flag=""
  if patch_on libsmb2; then
    _smb2_proto=",libsmb2"
    _smb2_flag="--enable-libsmb2"
  fi
  # Optimize ffmpeg for size (default ON; FFMPEG_SMALL=0 to disable). Trades a
  # little decode CPU for smaller libav* code; measured per-codec impact is
  # modest for the audio path. Gated so the size/CPU delta is easy to isolate.
  local _small_flag=""
  [[ "${FFMPEG_SMALL:-1}" == "1" ]] && _small_flag="--enable-small"
  # libswscale is the pixel-scaler. The audio-only consumer (vid=no, vo=null,
  # sid=no, cover-art-as-bytes) never scales a pixel, so the swscale reduction
  # patch drops it (~1.5M). When that strip is disabled — i.e. the user wants the
  # video/render path back — ffmpeg must BUILD swscale so mpv's required
  # `dependency('libswscale')` resolves via pkg-config. swscale_stripped()
  # couples this to strip_mpv_dead (see its definition above).
  local _swscale_flag="--enable-swscale"
  swscale_stripped && _swscale_flag="--disable-swscale"
  # License (see gpl_build). --enable-version3 stays on in both builds:
  # OpenSSL 3 is Apache-2.0, which is incompatible with the (L)GPLv2 but not
  # with version 3 (FFmpeg's LICENSE.md says so of its Apache-2.0 libraries;
  # what it says of OpenSSL is about the old OpenSSL license), so FFmpeg
  # links it under the LGPLv3. Configure enforces that only with
  # --enable-gpl ("OpenSSL >=3.0.0 requires --enable-version3") and would
  # build an LGPLv2.1 FFmpeg with OpenSSL 3 without a word;
  # verify_ffmpeg_config asserts CONFIG_VERSION3 instead.
  local _gpl_flag="" _rubberband_flag=""
  if gpl_build; then
    _gpl_flag="--enable-gpl"
    _rubberband_flag="--enable-librubberband"
  fi
  cat <<EOF
--enable-static
--disable-shared
--disable-programs
--disable-doc
--disable-debug
${_small_flag}
--enable-avcodec
--enable-avfilter
--enable-avformat
--enable-avutil
--enable-swresample
${_swscale_flag}
--disable-avdevice
--disable-protocols
--enable-protocol=file,http,https,httpproxy,tcp,udp,tls,data,pipe,async,cache,crypto,subfile${_smb2_proto}
--enable-demuxers
--disable-decoders
--enable-decoder=$AUDIO_DECODERS
--disable-encoders
--disable-muxers
--enable-muxer=spdif
--disable-filters
--enable-filter=$AUDIO_FILTERS
--disable-parsers
--enable-parser=$AUDIO_PARSERS
--disable-bsfs
--enable-bsf=$AUDIO_BSFS
--disable-outdevs
--disable-indevs
--enable-zlib
--disable-bzlib
--enable-lzma
--disable-iconv
--enable-network
${_gpl_flag}
--enable-version3
--enable-libxml2
${_smb2_flag}
${_rubberband_flag}
--enable-openssl
--disable-mbedtls
--disable-sdl2
--disable-xlib
--disable-libdrm
--disable-vaapi
--disable-vdpau
--disable-hwaccels
--disable-vulkan
--disable-pixelutils
${_ffmpeg_lto_flag}
EOF
}

# ── mpv meson: shared flags ─────────────────────────────────────────────────
# Per-platform script appends audio-output backends and any platform-specific
# overrides (cross-file, native-file, link args) after expanding
# \$(mpv_common_args). \`auto_features=disabled\` flips every \`auto\` feature
# off; the optional-deps patch makes libplacebo / libass not-required so
# unbuilt deps don't fail configure.
mpv_common_args() {
  # License (see gpl_build). -Dgpl=false does not turn rubberband off (mpv's
  # rubberband feature does not depend on gpl), so both are set.
  local _gpl=false _rubberband=disabled
  if gpl_build; then
    _gpl=true
    _rubberband=enabled
  fi
  cat <<EOF
-Db_lto=true
-Doptimization=s
-Dauto_features=disabled
-Dgpl=${_gpl}
-Dlibmpv=true
-Dcplayer=false
-Dbuild-date=false
-Dtests=false
-Dgl=disabled
-Dplain-gl=disabled
-Drubberband=${_rubberband}
-Dzlib=enabled
EOF
}

# ── Build-time config audit ─────────────────────────────────────────────────
# Catches the silent auto-detect-disabled bug class: a `--enable-foo` flag
# passes through configure without error but ends up as `#define CONFIG_FOO 0`
# in config.h because the probe failed to find headers / pkg-config / a
# subordinate dependency. Without this audit the build proceeds, links a
# stub'd-out function in place of the real one, and the failure only shows
# at runtime as a confusing "X has not been registered" / "ENOSYS" message
# (e.g. ffmpeg's CONFIG_JNI=0 → audiotrack errors with
# "No Java virtual machine has been registered" on Android).
#
# Each verify_*_config function aborts the build via `die` on first
# mismatch — ~1 second after configure returns — instead of after the
# 10-min compile + flaky on-device smoke that would otherwise reveal it.

# Asserts a `#define <key> <expected>` line exists in <file>. Treats a
# missing line as `#define <key> 0` (ffmpeg / mpv conventions both omit
# disabled features rather than emit `#define CONFIG_X 0`).
assert_define() {
  local file="$1" key="$2" expected="$3"
  local actual
  actual=$(awk -v k="$key" '$1=="#define" && $2==k {print $3; found=1; exit}
                            END { if (!found) print "0" }' "$file")
  if [[ "$actual" != "$expected" ]]; then
    die "Config audit: $(basename "$file"): $key=$actual (expected $expected)"
  fi
}

# Audits ffmpeg's post-configure config files. Call from each
# build_libmpv_<platform>.sh right after `./configure` returns.
#
# ffmpeg 6+ splits its compile-time configuration across two files:
#   - config.h            : global flags (CONFIG_AUDIOTOOLBOX,
#                           CONFIG_LIBSMB2, CONFIG_LIBXML2, CONFIG_JNI,
#                           the *_VA / *_TOOLBOX hwaccel toggles, …).
#   - config_components.h : per-component opt-ins
#                           (CONFIG_*_DECODER, CONFIG_*_PARSER,
#                            CONFIG_*_BSF, CONFIG_*_DEMUXER, …).
# `assert_define` is called against whichever file owns each key.
#
# Usage: verify_ffmpeg_config <ffmpeg_build_dir> <platform>
verify_ffmpeg_config() {
  local dir="$1" platform="$2"
  local cfg="$dir/config.h"
  local cmp="$dir/config_components.h"
  [[ -f "$cfg" ]] || die "verify_ffmpeg_config: $cfg not found (call after ./configure)"
  [[ -f "$cmp" ]] || die "verify_ffmpeg_config: $cmp not found (call after ./configure)"

  log "Auditing ffmpeg config for $platform..."

  # ── Required across every platform ───────────────────────────────────
  # SMB2/3 protocol (Samba / NAS playback) — adaptive: assert ON when the
  # libsmb2 patch is enabled, OFF when the user disabled it in Settings.
  if patch_on libsmb2; then
    assert_define "$cfg" "CONFIG_LIBSMB2" "1"
  else
    assert_define "$cfg" "CONFIG_LIBSMB2" "0"
  fi
  # libxml2 — required by the DASH demuxer's manifest parser (Plex etc).
  assert_define "$cfg" "CONFIG_LIBXML2"   "1"

  # License (see gpl_build): (L)GPL version 3 in both builds, never nonfree,
  # GPL only in the opt-in build, the only one that links librubberband.
  assert_define "$cfg" "CONFIG_VERSION3" "1"
  assert_define "$cfg" "CONFIG_NONFREE"  "0"
  if gpl_build; then
    assert_define "$cfg" "CONFIG_GPL"           "1"
    assert_define "$cfg" "CONFIG_LIBRUBBERBAND" "1"
  else
    assert_define "$cfg" "CONFIG_GPL"           "0"
    assert_define "$cfg" "CONFIG_LIBRUBBERBAND" "0"
  fi

  # The spdif muxer behind audio-spdif. Without it ad_spdif drops every
  # packet with no log, so a passthrough file plays nothing.
  assert_define "$cmp" "CONFIG_SPDIF_MUXER" "1"

  if [[ "$platform" == "web" ]]; then
    # The browser does the transport and TLS: no sockets, no OpenSSL, the
    # protocols that read memory and WasmFS, and http, https and blob: URLs
    # through fetch (webio), which the HLS and DASH demuxers open too.
    assert_define "$cfg" "CONFIG_OPENSSL"         "0"
    assert_define "$cfg" "CONFIG_NETWORK"         "0"
    assert_define "$cmp" "CONFIG_FILE_PROTOCOL"   "1"
    assert_define "$cmp" "CONFIG_DATA_PROTOCOL"   "1"
    assert_define "$cmp" "CONFIG_HTTP_PROTOCOL"   "0"
    assert_define "$cmp" "CONFIG_WEBIO_HTTP_PROTOCOL"    "1"
    assert_define "$cmp" "CONFIG_WEBIO_HTTPS_PROTOCOL"   "1"
    assert_define "$cmp" "CONFIG_WEBIO_MAKBLOB_PROTOCOL" "1"
    assert_define "$cmp" "CONFIG_HLS_DEMUXER"     "1"
    assert_define "$cmp" "CONFIG_DASH_DEMUXER"    "1"
  else
    # TLS backend: OpenSSL on every platform. We deliberately avoid
    # SecureTransport on Apple — Apple deprecated it (no TLS 1.3, on its
    # way out of upstream curl/ffmpeg). Assert it is OFF too, to catch a
    # future regression that would silently re-enable both backends.
    assert_define "$cfg" "CONFIG_OPENSSL"         "1"
    case "$platform" in
      macos|ios|tvos) assert_define "$cfg" "CONFIG_SECURETRANSPORT" "0" ;;
    esac
    # An https source opens https over tls, and through http-proxy (or the
    # http_proxy variable) tls opens an httpproxy:// URL: without httpproxy
    # every https source fails with "Protocol not found" behind a proxy.
    assert_define "$cmp" "CONFIG_HTTPS_PROTOCOL"     "1"
    assert_define "$cmp" "CONFIG_TLS_PROTOCOL"       "1"
    assert_define "$cmp" "CONFIG_HTTPPROXY_PROTOCOL" "1"
  fi

  # Full 1:1 audit: EVERY selected decoder and filter must have actually
  # compiled (CONFIG_X=1). This catches a flag that passed ./configure but
  # silently produced CONFIG_X=0 (missing header / unmet sub-dependency) —
  # which would otherwise surface only at runtime as "file fails to play" or
  # "filter not found". The selection drives it, so a trimmed build asserts
  # exactly what it asked for. Apple-only AudioToolbox decoders are excluded
  # here and asserted per-platform below (they only compile on Apple).
  local _appleonly=" aac_at alac_at mp3_at "
  local _tok
  for _tok in $(printf '%s' "$AUDIO_DECODERS" | tr ',' ' '); do
    case "$_appleonly" in *" $_tok "*) continue ;; esac
    assert_define "$cmp" "CONFIG_$(_ao_upper "$_tok")_DECODER" "1"
  done
  for _tok in $(printf '%s' "$AUDIO_FILTERS" | tr ',' ' '); do
    assert_define "$cmp" "CONFIG_$(_ao_upper "$_tok")_FILTER" "1"
  done
  # Parser coverage: every whitelisted parser must have compiled. A decoder
  # advertised WITHOUT its companion raw-stream parser would silently fail on
  # bare elementary streams (e.g. truehd/mlp without the `mlp` parser) while
  # still passing the decoder audit above — this closes that blind spot.
  for _tok in $(printf '%s' "$AUDIO_PARSERS" | tr ',' ' '); do
    assert_define "$cmp" "CONFIG_$(_ao_upper "$_tok")_PARSER" "1"
  done
  # BSF coverage: same idea for the auto-inserted bitstream filters.
  for _tok in $(printf '%s' "$AUDIO_BSFS" | tr ',' ' '); do
    assert_define "$cmp" "CONFIG_$(_ao_upper "$_tok")_BSF" "1"
  done

  # Audio-only invariant: the 4 most common video decoders MUST be off.
  # If one is present, the binary is at least 30% larger than necessary
  # (and the audio-only branding is a lie).
  assert_define "$cmp" "CONFIG_H264_DECODER" "0"
  assert_define "$cmp" "CONFIG_HEVC_DECODER" "0"
  assert_define "$cmp" "CONFIG_VP9_DECODER"  "0"
  assert_define "$cmp" "CONFIG_AV1_DECODER"  "0"

  # ── AudioToolbox decoders: Apple-only ────────────────────────────────
  # Even though the AUDIO_DECODERS whitelist lists them on every
  # platform, ffmpeg's configure silently skips them when
  # AudioToolbox.framework is absent from the cross sysroot. Assert
  # both branches to catch a future toolchain regression.
  case "$platform" in
    macos|ios|tvos)
      # Adaptive: assert each AudioToolbox decoder present only when selected,
      # and AudioToolbox itself enabled when any of them is.
      for _d in "aac_at:AAC_AT" "alac_at:ALAC_AT" "mp3_at:MP3_AT"; do
        if decoder_on "${_d%%:*}"; then
          assert_define "$cmp" "CONFIG_${_d##*:}_DECODER" "1"
        fi
      done
      if decoder_on aac_at || decoder_on alac_at || decoder_on mp3_at; then
        assert_define "$cfg" "CONFIG_AUDIOTOOLBOX" "1"
      fi
      ;;
    *)
      # Non-Apple: the *_at decoders never compile (no AudioToolbox), so they
      # must be off regardless of selection.
      assert_define "$cmp" "CONFIG_AAC_AT_DECODER"  "0"
      assert_define "$cmp" "CONFIG_ALAC_AT_DECODER" "0"
      assert_define "$cmp" "CONFIG_MP3_AT_DECODER"  "0"
      ;;
  esac

  # ── Platform-specific ─────────────────────────────────────────────────
  case "$platform" in
    android)
      # JNI bootstrap — without it, av_jni_set_java_vm becomes a stub
      # returning AVERROR(ENOSYS), audiotrack reports "no JVM registered"
      # at runtime and falls back to opensles (slower, no audio focus).
      assert_define "$cfg" "CONFIG_JNI"        "1"
      # Audio-only: mediacodec is the Android hardware video decoder.
      assert_define "$cfg" "CONFIG_MEDIACODEC" "0"
      ;;
    windows)
      # No DirectX video acceleration in audio-only build.
      assert_define "$cfg" "CONFIG_D3D11VA" "0"
      assert_define "$cfg" "CONFIG_DXVA2"   "0"
      ;;
    macos|ios|tvos)
      # No HW video acceleration in audio-only build.
      assert_define "$cfg" "CONFIG_VIDEOTOOLBOX" "0"
      ;;
  esac

  ok "ffmpeg config audit passed ($platform)"
}

# Audits mpv's post-configure `config.h` (meson convention:
# `#define HAVE_<X> 1`). Call from each build_libmpv_<platform>.sh
# right after `meson setup` returns.
#
# Usage: verify_mpv_config <mpv_build_dir> <platform>
verify_mpv_config() {
  local dir="$1" platform="$2"
  local cfg="$dir/config.h"
  [[ -f "$cfg" ]] || die "verify_mpv_config: $cfg not found (call after meson setup)"

  log "Auditing mpv config.h for $platform..."

  # ── Cross-platform must-haves ─────────────────────────────────────────
  assert_define "$cfg" "HAVE_LIBPLACEBO" "1"
  # libass: adaptive. Stripped by default (audio-only: sid=no, vo=null) → HAVE
  # is 0; when the user disables BOTH strip_libass AND strip_mpv_dead (see
  # libass_stripped) the whole font stack is rebuilt and mpv re-detects libass
  # via pkg-config → HAVE is 1.
  if libass_stripped; then
    assert_define "$cfg" "HAVE_LIBASS" "0"
  else
    assert_define "$cfg" "HAVE_LIBASS" "1"
  fi
  # License (see gpl_build): -Dgpl and -Drubberband move together.
  if gpl_build; then
    assert_define "$cfg" "HAVE_GPL"        "1"
    assert_define "$cfg" "HAVE_RUBBERBAND" "1"
  else
    assert_define "$cfg" "HAVE_GPL"        "0"
    assert_define "$cfg" "HAVE_RUBBERBAND" "0"
  fi
  assert_define "$cfg" "HAVE_ZLIB"       "1"

  # ── Audio outputs per platform ────────────────────────────────────────
  # An accidentally-disabled AO = "library loads fine but sounds nothing".
  case "$platform" in
    android)
      assert_define "$cfg" "HAVE_AUDIOTRACK" "1"
      assert_define "$cfg" "HAVE_AAUDIO"     "1"
      assert_define "$cfg" "HAVE_OPENSLES"   "1"
      ;;
    linux)
      assert_define "$cfg" "HAVE_ALSA"     "1"
      assert_define "$cfg" "HAVE_PULSE"    "1"
      assert_define "$cfg" "HAVE_PIPEWIRE" "1"
      ;;
    macos)
      assert_define "$cfg" "HAVE_COREAUDIO"    "1"
      assert_define "$cfg" "HAVE_AVFOUNDATION" "1"
      ;;
    ios|tvos)
      assert_define "$cfg" "HAVE_AUDIOUNIT"    "1"
      assert_define "$cfg" "HAVE_AVFOUNDATION" "1"
      ;;
    windows)
      assert_define "$cfg" "HAVE_WASAPI" "1"
      ;;
    web)
      # patch_ao_webaudio.py and -Dwebaudio=enabled: the only output there.
      assert_define "$cfg" "HAVE_WEBAUDIO" "1"
      ;;
    tizen)
      # patch_ao_tizen.py and -Dtizen-audio=enabled: an app has no other
      # output there, and the Linux ones would only fail at runtime.
      assert_define "$cfg" "HAVE_TIZEN_AUDIO" "1"
      assert_define "$cfg" "HAVE_ALSA"        "0"
      assert_define "$cfg" "HAVE_PULSE"       "0"
      assert_define "$cfg" "HAVE_PIPEWIRE"    "0"
      ;;
    webos)
      # ALSA, the one sound API of the NDK's sysroot: no PulseAudio nor
      # PipeWire there.
      assert_define "$cfg" "HAVE_ALSA"     "1"
      assert_define "$cfg" "HAVE_PULSE"    "0"
      assert_define "$cfg" "HAVE_PIPEWIRE" "0"
      ;;
  esac

  ok "mpv config audit passed ($platform)"
}

# ── ffmpeg patch application (9 scripts, identical on every platform) ───────
# Three are always applied and five are toggles, of which read_error runs
# two scripts. The web build runs a tenth after them, patch_ffmpeg_webio.py
# (build_libmpv_web.sh).
# Usage: apply_ffmpeg_patches <ffmpeg_source_dir>
# Requires SCRIPT_DIR to be set to the directory containing this file.
apply_ffmpeg_patches() {
  local ffmpeg_dir="$1"

  # Keep codec long-names alive under --enable-small (CONFIG_SMALL NULLs every
  # AVCodecDescriptor.long_name, which mpv surfaces as the `audio-codec`
  # property). Un-wraps ONLY the .long_name rows in libavcodec/codec_desc.c
  # (~8 KB of strings) so the descriptive codec name survives, while every other
  # --enable-small saving (≈2.8 MB of code/tables) stays intact. Idempotent;
  # no-op when --enable-small is off. Structural fidelity fix — not user-gated.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_codec_longnames.py" "$ffmpeg_dir"

  # Audio filters refuse values that read or write out of their buffers, and
  # live commands stop leaking expressions (chorus, aecho, pan, mcompand,
  # compand, aiir, aeval, anequalizer, adelay, dynaudnorm, adrc). The typed
  # effects of mpv_audio_kit are checked in Dart, a raw af string is not.
  # Every anchor checked before writing, MARKER-guarded. Safety fix, not
  # user-gated.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_filter_bounds.py" "$ffmpeg_dir"

  # A refused connect fails at once on Windows: ff_poll(), FFmpeg's poll()
  # over select() where there is no poll.h, waits for a failed connect in the
  # exception set too, where Winsock reports it, instead of until the network
  # timeout (http:// and smb2://). Builds only with winsock2.h. Defect fix,
  # not user-gated.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_winsock_poll.py" "$ffmpeg_dir"

  # libsmb2 patch (toggleable): copies libavformat/libsmb2.c and edits
  # configure, Makefile and protocols.c. Idempotent, and every platform
  # extracts a fresh FFmpeg tree, so it runs on every build. When the user
  # disables it, ffmpeg_common_args also omits --enable-libsmb2.
  if patch_on libsmb2; then
    log "Patching FFmpeg for libsmb2 support..."
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_libsmb2.py" \
      "$ffmpeg_dir" "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/libsmb2.c"
    record_patch libsmb2
  else
    warn "Skipping disabled patch: libsmb2"
  fi

  # advanced_editlist patch: idempotent (MARKER-guarded), safe on every build.
  if patch_on advanced_editlist; then
    log "Patching FFmpeg mov demuxer: AAC priming of fragmented MP4, none cut at DASH segments..."
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_advanced_editlist.py" "$ffmpeg_dir"
    record_patch advanced_editlist
  else
    warn "Skipping disabled patch: advanced_editlist"
  fi

  # DASH demuxer keep-alive patch: idempotent, MARKER-guarded.
  if patch_on dash_keepalive; then
    log "Patching FFmpeg DASH demuxer for HTTP keep-alive..."
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_dash_keepalive.py" "$ffmpeg_dir"
    record_patch dash_keepalive
  else
    warn "Skipping disabled patch: dash_keepalive"
  fi

  # The FFmpeg side of read_error, one toggle with the mpv side: http.c ends
  # a body cut short with EIO and not as a complete file (a reconnect that
  # gets an error reply, a chunked body without its last chunk), and the
  # HLS and DASH demuxers count the segments they lose in the read-only
  # skipped_segments option mpv reads. After dash_keepalive, whose anchors
  # in dashdec.c it leaves alone.
  if patch_on read_error; then
    log "Patching FFmpeg http, HLS and DASH to report read errors..."
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_http_read_errors.py" "$ffmpeg_dir"
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_segment_skips.py" "$ffmpeg_dir"
    record_patch read_error
  else
    warn "Skipping disabled patch: read_error (FFmpeg side)"
  fi

  # Embedded CA bundle: compile the Mozilla root store into the OpenSSL TLS
  # backend so HTTPS verification works with no on-device cert file (sandboxed
  # macOS, iOS, Android). Text edits MARKER-guarded; the .c/.h are rewritten
  # each run so a refreshed cacert.pem propagates.
  if patch_on embed_cacert; then
    log "Patching FFmpeg to embed the CA root bundle into OpenSSL..."
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_embed_cacert.py" "$ffmpeg_dir"
    record_patch embed_cacert
  else
    warn "Skipping disabled patch: embed_cacert"
  fi
}

# ── mpv patch application (the shared mpv patch set, every platform) ────────
# Usage: apply_mpv_patches_common <mpv_source_dir>
# Platform-specific mpv patches (patch_utils_mac, patch_ios_*,
# patch_windows_deps) stay inline in the per-platform script.
# _mpv_patch <id> <script.py> <args...> — apply a shared mpv patch unless the
# user disabled <id> in Settings ▸ Patches, and record it. Required patches
# don't go through this gate (they're applied unconditionally).
_mpv_patch() {
  local id="$1" script="$2"; shift 2
  if patch_on "$id"; then
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/shared/$script" "$@"
    record_patch "$id"
  else
    warn "Skipping disabled patch: $id"
  fi
}

apply_mpv_patches_common() {
  local mpv_dir="$1"
  # Stamp the release into mpv's version (see LIBMPV_RELEASE). A tarball has no
  # git history, so mpv's version.h falls back to this file: "v0.41.0+r24".
  printf '%s+%s\n' "$MPV_VERSION" "$LIBMPV_RELEASE" > "$mpv_dir/MPV_VERSION"
  # Build infrastructure (libplacebo + libass made required:false) — never gated.
  # MUST run before strip_libass/strip_mpv_dead, which both assume this form.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/shared/patch_optional_deps.py" "$mpv_dir/meson.build"
  # The property seam of player/command.c, never gated either. Every patch
  # below that adds a property writes its headers, getters and table entries
  # to the three files it creates, not to command.c, so it MUST run first.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/shared/patch_property_seam.py" "$mpv_dir"

  # ── Size-reduction patches (toggleable from Settings ▸ Patches) ──────────────
  # Each strips a subsystem the audio-only consumer (vid=no, vo=null, sid=no,
  # cover-art-as-bytes) never reaches. They default ON (smaller binary); the
  # user restores a feature by disabling the corresponding strip in the TUI,
  # which lists the patch in DISABLED_PATCHES so patch_on returns false here.

  # strip_swscale: make libswscale optional + stub mp_sws_* so mpv links without
  # it (paired with ffmpeg --disable-swscale). Coupled to strip_mpv_dead via
  # swscale_stripped() because vo_tct.c/vo_kitty.c #include <libswscale/...>
  # directly and are only removed by strip_mpv_dead — so we keep libswscale
  # whenever either strip is off. Idempotent (meson.build, common/av_log.c,
  # video/sws_utils.c).
  if swscale_stripped; then
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/shared/patch_swscale_optional.py" "$mpv_dir"
    record_patch strip_swscale
  else
    warn "Keeping libswscale (strip_swscale or strip_mpv_dead disabled)"
  fi

  # strip_libass: fully remove libass (subtitle/OSD text render). Stubs the
  # osd_libass/ass_mp/sd_ass symbols so the core still links, and lets the
  # per-platform script drop the whole font chain (freetype/harfbuzz/fontconfig/
  # fribidi/unibreak/expat/png) — gated there on the SAME libass_stripped().
  # Coupled to strip_mpv_dead (see libass_stripped()): if the user disabled
  # strip_libass alone we still apply it (libass needs the subtitle infra
  # strip_mpv_dead removed) and warn. Idempotent; operates on the whole mpv tree.
  if libass_stripped; then
    if ! patch_on strip_libass; then
      warn "libass still stripped: it needs the subtitle infra (lavc_conv/sd_filter/draw_bmp) that strip_mpv_dead removes — disable strip_mpv_dead too to restore subtitles."
    fi
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/shared/patch_strip_libass.py" "$mpv_dir"
    record_patch strip_libass
  else
    warn "Skipping disabled patch: strip_libass (libass kept — strip_mpv_dead also disabled)"
  fi

  # strip_mpv_dead: strip dead mpv subsystems unused by an audio-only consumer —
  # the GPU/shader render stack (vo_gpu/vo_gpu_next + video/out/gpu/* — unlocks
  # libplacebo renderer dead-strip), screenshot, encode mode, bitmap-subtitle
  # decode, vo_tct/vo_kitty and the default keybindings table. Idempotent; stubs
  # all cross-TU symbols. (Disabling this also forces libswscale to be kept —
  # see swscale_stripped().)
  _mpv_patch strip_mpv_dead     patch_strip_mpv_dead.py     "$mpv_dir"

  # strip_win_resources: drop the Windows icon/manifest/version resources (~267K
  # of PE .rsrc) — only meaningful for the mpv.exe player, dead weight in a
  # libmpv DLL. No-op off Windows (the resource block is win32-gated). Idempotent.
  _mpv_patch strip_win_resources patch_strip_win_resources.py "$mpv_dir"

  # ── Optional feature patches — toggleable from Settings ▸ Patches. ───────────
  _mpv_patch afmt_reset         patch_afmt_reset.py         "$mpv_dir/options/m_option.c"
  _mpv_patch prefetch           patch_prefetch.py           "$mpv_dir"
  _mpv_patch audio_output_state patch_audio_output_state.py "$mpv_dir"
  _mpv_patch embedded_cover_art patch_embedded_cover_art.py "$mpv_dir"
  _mpv_patch pcm_tap            patch_pcm_tap.py            "$mpv_dir"
  # pcm_stream: live PCM input (mak-pcm://<id> and the mak_pcm_* C API).
  # Required, not a toggle: mpv.def lists the mak_pcm_* names, which must
  # resolve in the Windows link (the other export lists use a glob).
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/shared/patch_pcm_stream.py" "$mpv_dir"
  _mpv_patch bulk_analysis      patch_bulk_analysis.py      "$mpv_dir"
  # loudness_scan layers on bulk_analysis (its anchors live in that
  # patch's output and the scan rides the same decode pass), so it is
  # skipped — with a warning — when bulk_analysis is disabled.
  if patch_on bulk_analysis; then
    _mpv_patch loudness_scan    patch_loudness_scan.py      "$mpv_dir"
  elif patch_on loudness_scan; then
    warn "Skipping loudness_scan: it requires bulk_analysis (disabled)"
  fi
  # filter_label_tap also feeds the progressive waveform from the af chain
  # (mak_waveform_tap_in). It builds without bulk_analysis, but
  # bulk_analysis without it never grows a progressive or rolling envelope.
  if patch_on bulk_analysis && ! patch_on filter_label_tap; then
    warn "filter_label_tap disabled: the progressive and rolling waveform of bulk_analysis gets no frames"
  fi
  _mpv_patch filter_label_tap   patch_filter_label_tap.py   "$mpv_dir"
  _mpv_patch chain_eof          patch_chain_eof.py          "$mpv_dir"
  # gapless_tail: an output underrun in the tail of a gapless end no
  # longer leaves that tail unplayed (keep-open parked with it queued).
  _mpv_patch gapless_tail       patch_gapless_tail.py       "$mpv_dir"
  # keep_open_park: keep-open-parked tells the park of keep-open from a
  # pause of the client in the tail, which pauses at once instead of
  # draining the output first.
  _mpv_patch keep_open_park     patch_keep_open_park.py     "$mpv_dir"
  _mpv_patch lavfi_eof_passthrough patch_lavfi_eof_passthrough.py "$mpv_dir"
  _mpv_patch hotplug_core_thread patch_hotplug_core_thread.py "$mpv_dir"
  _mpv_patch playlist_prev_dos_path patch_playlist_prev_dos_path.py "$mpv_dir"
  _mpv_patch chapter_list_reset patch_chapter_list_reset.py "$mpv_dir"
  # fd_pread: each stream of an fd://N (an Android content:// URI) reads at
  # its own position, so the prefetch of the same entry does not move the
  # offset the current file reads at.
  _mpv_patch fd_pread           patch_fd_pread.py           "$mpv_dir"
  # af_command_args: a successful af-command updates the arguments af and
  # the filter keep, so a seek, a track switch or the next file keeps the
  # value, and the af-command-saves-args flag tells a client so.
  _mpv_patch af_command_args    patch_af_command_args.py    "$mpv_dir"
  # read_error: the demuxer-read-error and demuxer-skipped-segments
  # properties and the END_FILE fields that tell a file cut short by a read
  # error from one that ended, and a seek after the error tries the read
  # again. The FFmpeg side of the same toggle (apply_ffmpeg_patches) fixes
  # the EIO of http.c and counts the segments; without it the count stays 0.
  _mpv_patch read_error         patch_read_error.py         "$mpv_dir"
  # NOTE: the `timer_resolution` patch is Windows-only (it edits the
  # win32-only osdep/timer-win32.c), so it lives in patches/mpv/windows/ and
  # is applied — still toggleable via `patch_on timer_resolution` — inline in
  # build_libmpv_windows.sh, not from this shared function.
}

# ── libsmb2 source patch (Apple platforms — shared by macOS + iOS) ──────────
# libsmb2 only runs find_package(GSSAPI) on iOS, not macOS. Patch
# CMakeLists to use APPLE so it covers both.
apply_libsmb2_apple_patch() {
  local smb2_dir="$1"
  if ! grep -q 'elseif(APPLE)' "$smb2_dir/CMakeLists.txt"; then
    sed -i '' 's/elseif(IOS)/elseif(APPLE)/' "$smb2_dir/CMakeLists.txt"
  fi
}

# ── libsmb2 post-install fixes (every platform) ─────────────────────────────
# Fix 1 — libsmb2.h uses size_t/uint8_t/SMB2_GUID_SIZE without including the
#         needed headers. Inject the missing includes.
# Fix 2 — installed .pc misses the smb2/ include subdir. On Apple platforms,
#         also append the framework set GSS+CoreFoundation+resolv (+ krb5 on
#         macOS only) needed by Kerberos symbols.
# Usage: apply_libsmb2_post_install_fixes <prefix> <platform>
#        platform: macos | ios | tvos | linux
apply_libsmb2_post_install_fixes() {
  local prefix="$1" platform="$2"
  local hdr="$prefix/include/smb2/libsmb2.h"
  local pc="$prefix/lib/pkgconfig/libsmb2.pc"

  # `-i` flavor depends on the build HOST (where sed runs), not the
  # target platform of the binary. BSD sed (macOS) needs an empty
  # argument; GNU sed (Linux) takes none.
  local sed_inplace=(-i)
  [[ "$(uname -s)" == "Darwin" ]] && sed_inplace=(-i '')

  if [[ -f "$hdr" ]] && ! grep -q 'stddef.h' "$hdr"; then
    # Inject the missing system includes at line 1. BSD sed's `1i\`
    # requires every continuation line to end with a backslash AND
    # the final line to NOT have a trailing newline before the
    # closing quote — incompatible with GNU's looser form. Use a
    # here-doc-built temp file instead so the script is portable
    # across both seds without quoting tricks.
    local injected
    injected="$(mktemp)"
    {
      printf '#include <time.h>\n'
      printf '#include <stdint.h>\n'
      printf '#include <stddef.h>\n'
      printf '#include "smb2.h"\n'
      cat "$hdr"
    } > "$injected"
    mv "$injected" "$hdr"
  fi

  if [[ -f "$pc" ]] && ! grep -q 'includedir}/smb2' "$pc"; then
    sed "${sed_inplace[@]}" 's|Cflags: -I${includedir}|Cflags: -I${includedir} -I${includedir}/smb2|' "$pc"
    case "$platform" in
      macos)
        sed "${sed_inplace[@]}" 's|Libs: -L${libdir} -lsmb2|Libs: -L${libdir} -lsmb2 -framework GSS -framework CoreFoundation -lresolv -lkrb5|' "$pc"
        ;;
      ios)
        sed "${sed_inplace[@]}" 's|Libs: -L${libdir} -lsmb2|Libs: -L${libdir} -lsmb2 -framework GSS -framework CoreFoundation -lresolv|' "$pc"
        ;;
      tvos)
        # tvOS has no GSS framework, so libsmb2 builds without Kerberos.
        sed "${sed_inplace[@]}" 's|Libs: -L${libdir} -lsmb2|Libs: -L${libdir} -lsmb2 -framework CoreFoundation -lresolv|' "$pc"
        ;;
    esac
  fi
}

# ── libplacebo source patch (every platform that builds it) ─────────────────
# Python 3.14 changed ElementTree.__init__ to require an Element, not an
# ElementTree. libplacebo's vulkan codegen still uses the old form. Idempotent.
apply_libplacebo_patches() {
  local lp_dir="$1"

  # Patch 1 (vulkan utils): ET.parse() returns ElementTree; .getroot()
  # is required to feed it into VkXML — newer Python ElementTree
  # versions enforce this distinction.
  local vk_target="$lp_dir/src/vulkan/utils_gen.py"
  if [[ -f "$vk_target" ]] && grep -q 'VkXML(ET\.parse(xmlfile))' "$vk_target"; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' 's/VkXML(ET\.parse(xmlfile))/VkXML(ET.parse(xmlfile).getroot())/g' "$vk_target"
    else
      sed -i 's/VkXML(ET\.parse(xmlfile))/VkXML(ET.parse(xmlfile).getroot())/g' "$vk_target"
    fi
  fi

  # Patch 2 (Windows export hygiene): libplacebo's src/meson.build hardcodes
  # `c_args: ['-DPL_EXPORT']` when building the library, regardless of
  # default_library = static|shared. On Windows that bakes
  # `__declspec(dllexport)` into every `pl_*` function and emits 300+
  # `-export:pl_*` directives into the .a's COFF .drectve sections —
  # which the final libmpv-2.dll link honors despite `--exclude-all-symbols`,
  # leaking the libplacebo API into the public DLL exports.
  # Switch the unconditional `-DPL_EXPORT` to `-DPL_STATIC` so PL_API
  # collapses to nothing when we build static. No-op on ELF (.drectve is
  # PE/COFF only).
  local mb_target="$lp_dir/src/meson.build"
  if [[ -f "$mb_target" ]] && grep -q "c_args: \['-DPL_EXPORT'\]" "$mb_target"; then
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s/c_args: \['-DPL_EXPORT'\]/c_args: ['-DPL_STATIC']/g" "$mb_target"
    else
      sed -i "s/c_args: \['-DPL_EXPORT'\]/c_args: ['-DPL_STATIC']/g" "$mb_target"
    fi
  fi
}

# ── Dep-side LTO (default ON; disable with ENABLE_LTO_DEPS=0) ───────────────
# Returns the additional CFLAGS/CXXFLAGS to enable ThinLTO on the static
# dependency builds (zlib, libpng, freetype, harfbuzz, etc.). Combined with
# the LTO already on for ffmpeg + mpv, the final linker can see the entire
# bitcode universe and dead-strip / inline across `.a` boundaries.
#
# Toolchain requirements (all already met by this repo):
# - Apple platforms (macOS / iOS): Apple's `ar` and `libtool -static` are
#   `llvm-ar` underneath since Xcode 11+ — bitcode `.o` files in `.a`
#   archives are handled transparently.
# - Android: the NDK's `llvm-ar` is already used unconditionally.
# - Linux (gcc): the per-platform script auto-substitutes `gcc-ar` /
#   `gcc-ranlib` when this flag is on so the linker plugin handles bitcode.
# - Windows (MinGW cross): the per-platform script does the same gcc-ar
#   substitution.
#
# Cost: +30-90s on the final mpv link; benefit: ~1-2 MB of extra dead-code
# elimination across static-lib boundaries. Disable with ENABLE_LTO_DEPS=0
# if a specific dep refuses to link with bitcode (then file an issue).
lto_deps_cflags() {
  [[ "${ENABLE_LTO_DEPS:-1}" == "0" ]] && return
  # Compiler dispatch:
  #   Clang  → `-flto=thin` (preferred for build parallelism; lld unpacks
  #             ThinLTO bitcode natively, no fat-object workaround needed)
  #   GCC    → `-flto -ffat-lto-objects` — emits .o files with BOTH native
  #             code AND GIMPLE bitcode. Crucial for cross-MinGW: its
  #             linker plugin chain is fragile and can fail to extract
  #             bitcode from meson-built archives at the final link
  #             ("BFD: plugin needed to handle lto object"). Fat objects
  #             give the linker a native fallback so the link succeeds
  #             regardless of plugin state. The bitcode is still there
  #             for the final link's own LTO pass to consume when
  #             everything works. Mild .a size bump (~30%) for total
  #             reliability.
  local cc="${CC:-cc}"
  # Strip ccache-style prefix wrappers ("ccache gcc") — only the last token
  # is the actual compiler binary.
  cc="${cc##* }"
  if "$cc" --version 2>/dev/null | grep -qiE 'clang|llvm'; then
    # THIN on purpose — full LTO (-flto) was measured 2026-06-12 on
    # macos-arm64: −420 KiB, but the produced libmpv HANGS at runtime
    # (event loop never delivers; every Player bring-up times out).
    # Do not retry without a runtime suite pass.
    echo "-flto=thin"
  else
    echo "-flto -ffat-lto-objects"
  fi
}

# ── Hidden visibility for static deps (default ON) ──────────────────────────
# Returns CFLAGS/CXXFLAGS that hide every dep symbol by default. Only symbols
# with explicit `__attribute__((visibility("default")))` (mpv's MPV_EXPORT)
# remain exported. Combined with the per-platform exports list / version
# script in build_mpv, the resulting libmpv.{dylib,so} dynamic symbol table
# drops from ~8000 to ~60 — eliminating ffmpeg/libass/freetype symbol-clash
# risk in Flutter apps that load multiple plugins linking the same libs.
#
# DISABLE with VIS_HIDDEN=0 (e.g. for crash debugging where you want to see
# internal symbols in `nm -D` output).
vis_deps_cflags() {
  if [[ "${VIS_HIDDEN:-1}" != "0" ]]; then
    echo "-fvisibility=hidden -fvisibility-inlines-hidden"
  fi
}

# ── Section-based dead-code stripping for ELF deps (default ON) ─────────────
# `-ffunction-sections -fdata-sections` puts each function/global in its own
# section. The final linker (`-Wl,--gc-sections`) then drops every section
# nothing references — typically -10 to -25% on the resulting .so.
#
# NO-OP on Apple (Mach-O always uses .subsections_via_symbols, which is the
# native equivalent and is enabled by default — `-Wl,-dead_strip` at link
# time covers the same ground for Apple targets).
#
# Returns CFLAGS to add for ELF; empty on Mach-O.
section_gc_cflags() {
  if [[ "${SECTION_GC:-1}" != "0" ]]; then
    echo "-ffunction-sections -fdata-sections"
  fi
}

# ── Unwind-table trim for C-only ffmpeg + mpv (default ON; EH_FRAME_TRIM=0) ──
# ffmpeg and mpv are pure C and use no exceptions, so their .eh_frame /
# .eh_frame_hdr only serve crash-backtrace quality — not any audio feature.
# Dropping them shrinks the shipped artifact (.eh_frame survives --strip-unneeded).
# This MUST NOT go into the shared CFLAGS/CXXFLAGS or any meson cross-file, which
# also compile the C++ deps (libplacebo / harfbuzz / libass, rubberband in the
# GPL build) that need unwind tables for C++ exception correctness. Wire it
# ONLY via ffmpeg --extra-cflags and mpv -Dc_args (both C-only knobs).
eh_frame_cflags() {
  [[ "${EH_FRAME_TRIM:-1}" == "0" ]] && return
  echo "-fno-asynchronous-unwind-tables -fno-unwind-tables"
}

# ── Unwind-table trim for the C/C++ DEPENDENCY builds (default ON) ───────────
# The weaker, C++-safe variant of eh_frame_cflags(): -fno-asynchronous-unwind-
# tables drops the async .eh_frame (backtrace/profiler precision) but KEEPS C++
# exception unwinding intact, so it is safe for the C++ deps (libplacebo, and
# rubberband in the GPL build). Add this to every platform's shared dep CFLAGS/CXXFLAGS export
# (ffmpeg + mpv themselves get the stronger C-only eh_frame_cflags via their own
# --extra-cflags / -Dc_args). Shared so the policy lives in one place.
dep_unwind_cflags() {
  [[ "${EH_FRAME_TRIM:-1}" == "0" ]] && return
  echo "-fno-asynchronous-unwind-tables"
}

# ── SONAME of the bundled library (linux + android) ──────────────────────────
# mpv's meson names the library libmpv.so.2 on Linux and libmpv.so on Android,
# the name another plugin's libmpv may ship too. Two libraries with one SONAME cannot live
# in one process on bionic, which resolves a dlopen by name against the
# SONAMEs already loaded, and they collide on disk too: lib/<abi>/ in the
# APK, lib/ in the Linux bundle. The kit's plugin therefore owns its own name,
# file and SONAME alike, and the consumer's build hook writes the file under
# it. The release asset names are unchanged. Emitted as a comma suffix for an
# existing `-Wl,...` group, after meson's own -soname: both GNU ld and lld take
# the last one on the line. The build scripts assert the result with readelf.
MPV_SONAME="libmpv_audio_kit.so"
export MPV_SONAME
mpv_soname_ldflags() { printf ',-soname,%s' "$MPV_SONAME"; }

# assert_soname <elf> <readelf> — die unless <elf> carries $MPV_SONAME.
assert_soname() {
  local elf="$1" readelf="${2:-readelf}" got
  got="$(LC_ALL=C "$readelf" -dW "$elf" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p')"
  [[ "$got" == "$MPV_SONAME" ]] || die "SONAME is '${got:-none}', expected $MPV_SONAME: $elf"
  ok "SONAME $got"
}

# ── Linux loader floor ───────────────────────────────────────────────────────
# The newest glibc symbol version libmpv may bind on Linux. The linux Docker
# stage builds on Ubuntu 20.04 for this: 2.31 covers Debian 11, RHEL 9 and
# every Ubuntu since 20.04.
LINUX_GLIBC_FLOOR="2.31"
# On Tizen: a TV of 2021 runs Tizen 6.0, whose glibc 2.30 is the sysroot's
# (scripts/tizen/tizen_sysroot.py).
TIZEN_GLIBC_FLOOR="2.30"
# On webOS: webOS 26 is the first the TVs run Flutter apps on, and its
# glibc 2.39 is the NDK's sysroot (the webos Docker stage).
WEBOS_GLIBC_FLOOR="2.39"

# assert_glibc_floor <elf> <max> <readelf> — die if <elf> needs a GLIBC_x.y
# symbol version newer than <max>.
assert_glibc_floor() {
  local elf="$1" max="$2" readelf="${3:-readelf}" newest
  newest="$(LC_ALL=C "$readelf" -W -V "$elf" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/GLIBC_//' | sort -Vu | tail -1)"
  [[ -n "$newest" ]] || die "no GLIBC symbol versions found in $elf"
  [[ "$(printf '%s\n%s\n' "$newest" "$max" | sort -V | tail -1)" == "$max" ]] || \
    die "needs glibc $newest, above the $max floor: $elf"
  ok "glibc floor: needs $newest (max $max)"
}

# assert_no_needed <elf> <regex> <readelf> — die if a DT_NEEDED entry of <elf>
# matches <regex> (libraries that must be loaded at run time, not linked).
assert_no_needed() {
  local elf="$1" pattern="$2" readelf="${3:-readelf}" hits
  hits="$(LC_ALL=C "$readelf" -dW "$elf" 2>/dev/null \
    | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' | grep -E "$pattern" || true)"
  [[ -z "$hits" ]] || die "must not be DT_NEEDED: $(echo $hits): $elf"
  ok "no DT_NEEDED on $pattern"
}

# assert_no_relr <elf> <readelf> — die if <elf> packs its relative relocs as
# DT_RELR (tag 0x24, or Android's OS-private 0x6fffe000). Linux keeps plain
# RELA: RELR needs glibc 2.36, which leaves Ubuntu 22.04 and RHEL 9 out, for
# about 1 MB saved. Android uses APS2: bionic below API 30 skips DT_RELR
# silently and the library crashes at load (see mpv_elf_size_ldflags).
assert_no_relr() {
  local elf="$1" readelf="${2:-readelf}" dyn
  dyn="$(LC_ALL=C "$readelf" -dW "$elf" 2>/dev/null)"
  [[ -n "$dyn" ]] || die "readelf -d read nothing from $elf"
  if grep -qE '^ *0x0*(24|6fffe000) ' <<<"$dyn"; then
    die "DT_RELR present (glibc < 2.36 refuses it, Android < 11 skips it): $elf"
  fi
  ok "no DT_RELR"
}

# assert_load_align <elf> <min> <readelf> — die if a LOAD segment of <elf> is
# aligned below <min> bytes. Android 15+ devices with 16 KB pages refuse a
# 64-bit library whose segments are only 4 KB aligned.
assert_load_align() {
  local elf="$1" min="$2" readelf="${3:-readelf}" aligns a
  aligns="$(LC_ALL=C "$readelf" -lW "$elf" 2>/dev/null | awk '$1 == "LOAD" {print $NF}')"
  [[ -n "$aligns" ]] || die "no LOAD segments read from $elf"
  for a in $aligns; do
    (( a >= min )) || die "LOAD segment aligned to $a, below $min: $elf"
  done
  ok "LOAD alignment >= $min"
}

# ── Hardening of the ELF builds (linux, tizen, webos) ────────────────────────
# libmpv parses untrusted network input (FFmpeg's demuxers, HLS and DASH,
# libxml2, libsmb2, TLS), so the code of every dependency gets a stack canary
# and the fortified libc calls, and the library is linked with full RELRO:
#   -fstack-protector-strong   a canary in every function with an array or an
#                              address-taken local
#   -D_FORTIFY_SOURCE=2        the __*_chk variants of memcpy, sprintf and the
#                              like. It needs optimization, which every CFLAGS
#                              here has. -U first: Ubuntu's gcc predefines it.
#                              The __*_chk symbols are in every sysroot:
#                              Tizen's glibc 2.30 has them too.
#   -z relro -z now            the GOT is resolved at load and then read-only
#   -z noexecstack             a non-executable stack whatever an assembly
#                              object says
# The callers add hardening_cflags to the CFLAGS and CXXFLAGS every dependency
# reads, and again to FFmpeg's --extra-cflags and mpv's -Dc_args: an explicit
# -Dc_args makes meson drop the CFLAGS of the environment, and -Dc_link_args
# the LDFLAGS, so mpv takes hardening_ldflags in its link arguments too.
#
# -z now and the Linux audio stubs: PipeWire and PulseAudio are loaded on
# first use by Implib.so trampolines (build_audio_stubs), which jump through
# a table of their own in .data that their resolver fills with dlsym. They
# are not PLT entries and libmpv has no dynamic relocation against either
# library, so binding at load changes nothing for them.
#
# Android and Windows do not call these: the NDK's clang and linker already
# give canary, fortify, full RELRO and BIND_NOW, and binutils and llvm-mingw
# already set the three DllCharacteristics. scripts/verify asserts both
# (layer16_elf_invariants, layer16_pe_hardening).
hardening_cflags() {
  echo "-fstack-protector-strong -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2"
}
hardening_ldflags() {
  echo "-Wl,-z,relro,-z,now,-z,noexecstack"
}

# elf_hardening_gaps <elf> <readelf>: prints one line for each mitigation
# <elf> lacks, nothing when it has them all: a non-executable GNU_STACK, a
# GNU_RELRO segment, BIND_NOW, the canary's __stack_chk_fail among the
# undefined dynamic symbols, and no TEXTREL. Returns 2 when readelf read
# nothing. Reads the output of GNU readelf and of llvm-readelf.
elf_hardening_gaps() {
  local elf="$1" readelf="${2:-readelf}" segs dyn syms stack
  segs="$(LC_ALL=C "$readelf" -lW "$elf" 2>/dev/null)"
  dyn="$(LC_ALL=C "$readelf" -dW "$elf" 2>/dev/null)"
  syms="$(LC_ALL=C "$readelf" -W --dyn-syms "$elf" 2>/dev/null)"
  [[ -n "$segs" && -n "$dyn" && -n "$syms" ]] || return 2
  # The flags are what stands between the six columns after the name and the
  # alignment: "RW" or "RWE", and "R E" in two fields.
  stack="$(awk '$1 == "GNU_STACK" { f = ""; for (i = 7; i < NF; i++) f = f $i; print "flags=" f; exit }' <<<"$segs")"
  if [[ -z "$stack" ]]; then
    echo "no GNU_STACK segment (the loader takes the stack as executable)"
  elif [[ "$stack" == *E* ]]; then
    echo "GNU_STACK is executable"
  fi
  grep -qE '^ *GNU_RELRO ' <<<"$segs" || echo "no GNU_RELRO segment"
  grep -qE '\(BIND_NOW\)|\(FLAGS\).*BIND_NOW|\(FLAGS_1\).*NOW' <<<"$dyn" || \
    echo "no BIND_NOW (RELRO is partial: the PLT's GOT stays writable)"
  if grep -qE '\(TEXTREL\)|\(FLAGS\).*TEXTREL' <<<"$dyn"; then
    echo "TEXTREL (relocations in the code, which must then be writable)"
  fi
  awk '$7 == "UND" && $8 ~ /^__stack_chk_fail(@|$)/ { found = 1 } END { exit !found }' <<<"$syms" || \
    echo "no __stack_chk_fail among the undefined symbols (no stack canary)"
  return 0
}

# assert_hardening <elf> <readelf>: die unless elf_hardening_gaps finds
# nothing missing in <elf>.
assert_hardening() {
  local elf="$1" readelf="${2:-readelf}" gaps rc=0
  gaps="$(elf_hardening_gaps "$elf" "$readelf")" || rc=$?
  (( rc == 0 )) || die "readelf read nothing from $elf"
  [[ -z "$gaps" ]] || die "hardening missing in $elf: $(tr '\n' ';' <<<"$gaps")"
  ok "hardening: NX stack, full RELRO, BIND_NOW, stack canary, no TEXTREL"
}

# ── Extra ELF size flags for the final libmpv link (linux + android) ─────────
# Returned as a COMMA SUFFIX to append inside an existing `-Wl,...` group, e.g.
#   ld_args="-Wl,--gc-sections,--exclude-libs=ALL,--no-undefined$(mpv_elf_size_ldflags relr)"
#   -Bsymbolic            bind libmpv's internal global refs at link time (no
#                         interposition; only mpv_* is exported) — cuts PLT/GOT.
# libmpv carries ~44k relative dynrelocs, ~1MB as plain .rela.dyn, so they get
# packed — but WHICH packing is safe depends on the loader, so the caller picks:
#   relr     -z pack-relative-relocs → bit-packed .relr.dyn, ~3% of .rela.dyn.
#            Needs glibc>=2.36 / musl>=2022 / bionic API 30+. On glibc lld also
#            emits a GLIBC_ABI_DT_RELR version dep, so an older loader refuses
#            the library outright instead of misbehaving.
#   android  --pack-dyn-relocs=android → APS2 (DT_ANDROID_RELA, or
#            DT_ANDROID_REL on 32-bit arm), understood by bionic since API 23.
#            Bulkier than RELR, because a RELA group carries an addend per
#            reloc: on libmpv's ~44k relative relocs that is ~166K against
#            RELR's ~16K, still far under the ~1MB of unpacked .rela.dyn. The
#            32-bit arm REL form has no addend and costs only ~41K.
#   none     -Bsymbolic only, plain .rela.dyn. What Linux ships since r16: RELR
#            there needs glibc 2.36 (Ubuntu 22.04 has 2.35, RHEL 9 has 2.34)
#            and the ~1 MB it saves is not worth that floor on a desktop.
# Android MUST NOT use relr while minSdk is 24. Bionic learned the official
# DT_RELR tags only in API 30 (it had them under OS-private tags since API 28);
# below that it SKIPS them silently, so every relative reloc stays unapplied,
# .init_array[0] keeps its link-time value and dlopen() segfaults before any app
# code runs. Android has no GLIBC_ABI_DT_RELR equivalent to turn that into a
# clean load error. See mpv_audio_kit issue #16.
#
# Emit exactly one packing flag: lld selects the format with an if/else, not a
# merge, so appending an override does NOT undo an earlier flag — `-z
# pack-relative-relocs` beats `--pack-dyn-relocs=none`, and
# `--pack-dyn-relocs=relr` beats `-z nopack-relative-relocs`.
#
# ELF-only: Mach-O (macOS/iOS) uses automatic chained fixups and PE (Windows)
# has no RELR, so those platforms must NOT call this. Env opt-out: MPV_SIZE_LD=0.
mpv_elf_size_ldflags() {
  [[ "${MPV_SIZE_LD:-1}" == "0" ]] && return
  # ${1-relr}, not ${1:-relr}: an omitted argument defaults, an empty one is a
  # caller bug and must hit the error branch rather than silently pick relr.
  case "${1-relr}" in
    android) echo ",-Bsymbolic,--pack-dyn-relocs=android" ;;
    relr)    echo ",-Bsymbolic,-z,pack-relative-relocs" ;;
    none)    echo ",-Bsymbolic" ;;
    *)       echo "mpv_elf_size_ldflags: unknown packing '$1'" >&2; return 1 ;;
  esac
}
