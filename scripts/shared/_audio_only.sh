# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Audio-only ffmpeg flags + shared patch application across the 5
# build_libmpv_<platform>.sh scripts. Sourced by every script.
#
# Strategy: keep all demuxers + protocols (so the consumer can open
# any container, including mixed audio+video files like .mkv/.mp4 —
# mpv ignores video tracks and decodes only audio); strip out video
# decoders/encoders/muxers and swscale; drop avdevice (no
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
# `rubberband` IS built — we bundle librubberband and pass
# `--enable-librubberband` so ffmpeg registers `af_rubberband` as a
# lavfi filter (separate from mpv's native `af_rubberband.c`, which is
# always available via `-Drubberband=enabled` in mpv meson).
# Filters dropped from the whitelist for the 0.1.0 cut (debug / utility
# only — they have no business in a music-player API):
#   abench, acopy, acue, aintegral, alatency, aloop, ametadata, anull,
#   aperms, arealtime, areverse, asegment, aselect, asendcmd, asetnsamples,
#   asetpts, asetrate, asettb, ashowinfo, asidedata, aspectralstats, astats,
#   astreamselect, atrim, silencedetect, volume, volumedetect.
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
AUDIO_FILTERS+=",stereotools,stereowiden,extrastereo,crossfeed,haas,headphone,surround,earwax,pan,channelmap,virtualbass,dialoguenhance,adecorrelate"
# ── Time / Pitch ────────────────────────────────────────────────────────────
AUDIO_FILTERS+=",atempo,rubberband,aresample,aformat,adelay,apad,compensationdelay,afade,aphaseshift,afreqshift"
# ── Modulation / FX ─────────────────────────────────────────────────────────
AUDIO_FILTERS+=",aecho,chorus,flanger,aphaser,apulsator,tremolo,vibrato"
# ── Restoration / Noise ─────────────────────────────────────────────────────
AUDIO_FILTERS+=",afftdn,afwtdn,anlmdn,arnndn,adeclick,adeclip,adenorm,aderivative,dcshift,hdcd,silenceremove"
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
  cat <<EOF
--enable-static
--disable-shared
--disable-programs
--disable-doc
--disable-debug
--enable-avcodec
--enable-avfilter
--enable-avformat
--enable-avutil
--enable-swresample
--enable-swscale
--disable-avdevice
--disable-protocols
--enable-protocol=file,http,https,tcp,udp,tls,data,pipe,async,cache,crypto,subfile${_smb2_proto}
--enable-demuxers
--disable-decoders
--enable-decoder=$AUDIO_DECODERS
--disable-encoders
--disable-muxers
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
--enable-gpl
--enable-version3
--enable-libxml2
${_smb2_flag}
--enable-librubberband
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
  cat <<'EOF'
-Db_lto=true
-Dauto_features=disabled
-Dgpl=true
-Dlibmpv=true
-Dcplayer=false
-Dbuild-date=false
-Dtests=false
-Dgl=disabled
-Dplain-gl=disabled
-Drubberband=enabled
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

  # TLS backend: OpenSSL on every platform. We deliberately avoid
  # SecureTransport on Apple — Apple deprecated it (no TLS 1.3, on its
  # way out of upstream curl/ffmpeg). Assert it is OFF too, to catch a
  # future regression that would silently re-enable both backends.
  assert_define "$cfg" "CONFIG_OPENSSL"         "1"
  case "$platform" in
    macos|ios) assert_define "$cfg" "CONFIG_SECURETRANSPORT" "0" ;;
  esac

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
    macos|ios)
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
    macos|ios)
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
  assert_define "$cfg" "HAVE_LIBASS"     "1"
  assert_define "$cfg" "HAVE_RUBBERBAND" "1"
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
    ios)
      assert_define "$cfg" "HAVE_AUDIOUNIT"    "1"
      assert_define "$cfg" "HAVE_AVFOUNDATION" "1"
      ;;
    windows)
      assert_define "$cfg" "HAVE_WASAPI" "1"
      ;;
  esac

  ok "mpv config audit passed ($platform)"
}

# ── ffmpeg patch application (3 patches, identical on every platform) ───────
# Usage: apply_ffmpeg_patches <ffmpeg_source_dir>
# Requires SCRIPT_DIR to be set to the directory containing this file.
apply_ffmpeg_patches() {
  local ffmpeg_dir="$1"

  # libsmb2 patch (toggleable): gated by presence of the dropped-in file so we
  # don't retry the copy on every rebuild. Not fully idempotent (drops a new
  # .c file + edits configure/Makefile), so only on fresh extracts. When the
  # user disables it, ffmpeg_common_args also omits --enable-libsmb2.
  if patch_on libsmb2; then
    if [[ ! -f "$ffmpeg_dir/libavformat/libsmb2.c" ]]; then
      log "Patching FFmpeg for libsmb2 support..."
      python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_libsmb2.py" \
        "$ffmpeg_dir" "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/libsmb2.c"
    fi
  else
    warn "Skipping disabled patch: libsmb2"
  fi

  # advanced_editlist patch: idempotent (MARKER-guarded), safe on every build.
  if patch_on advanced_editlist; then
    log "Patching FFmpeg mov demuxer to honor edit list on fragmented MP4..."
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_advanced_editlist.py" "$ffmpeg_dir"
  else
    warn "Skipping disabled patch: advanced_editlist"
  fi

  # DASH demuxer keep-alive patch: idempotent, MARKER-guarded.
  if patch_on dash_keepalive; then
    log "Patching FFmpeg DASH demuxer for HTTP keep-alive..."
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/ffmpeg/patch_ffmpeg_dash_keepalive.py" "$ffmpeg_dir"
  else
    warn "Skipping disabled patch: dash_keepalive"
  fi
}

# ── mpv patch application (7 patches common to every platform) ──────────────
# Usage: apply_mpv_patches_common <mpv_source_dir>
# Platform-specific mpv patches (patch_utils_mac, patch_ios_*,
# patch_windows_deps) stay inline in the per-platform script.
# _mpv_patch <id> <script.py> <args...> — apply a shared mpv patch unless the
# user disabled <id> in Settings ▸ Patches. Required patches don't go through
# this gate (they're applied unconditionally).
_mpv_patch() {
  local id="$1" script="$2"; shift 2
  if patch_on "$id"; then
    python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/shared/$script" "$@"
  else
    warn "Skipping disabled patch: $id"
  fi
}

apply_mpv_patches_common() {
  local mpv_dir="$1"
  # Required (build configures only with these) — never gated.
  python3 "$LIBMPV_SCRIPTS_ROOT/patches/mpv/shared/patch_optional_deps.py" "$mpv_dir/meson.build"
  # Optional feature patches — toggleable from Settings ▸ Patches.
  _mpv_patch afmt_reset         patch_afmt_reset.py         "$mpv_dir/options/m_option.c"
  _mpv_patch prefetch_hook      patch_prefetch_hook.py      "$mpv_dir/player/loadfile.c"
  _mpv_patch prefetch_state     patch_prefetch_state.py     "$mpv_dir"
  _mpv_patch audio_output_state patch_audio_output_state.py "$mpv_dir"
  _mpv_patch embedded_cover_art patch_embedded_cover_art.py "$mpv_dir"
  _mpv_patch pcm_tap            patch_pcm_tap.py            "$mpv_dir"
  _mpv_patch bulk_analysis      patch_bulk_analysis.py      "$mpv_dir"
  _mpv_patch filter_label_tap   patch_filter_label_tap.py   "$mpv_dir"
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
#        platform: macos | ios | linux
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
