# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Pinned dependency versions: single source of truth across the 9
# build_libmpv_<platform>.sh scripts (the tvOS one runs the iOS one).
#
# Override any version with an environment variable:
#   MPV_VERSION=0.42.0 ./build_libmpv_macos.sh
#
# This file is sourced by every per-platform build script. Do not run
# it directly.

# ── Player core ──────────────────────────────────────────────────────────────
# mpv 0.42.0 (2026-11) is the latest release. Its meson floor is FFmpeg 6.1
# (libavcodec >= 60.31.102) and libplacebo 7.387.0.
export MPV_VERSION="${MPV_VERSION:-0.42.0}"
# The mpv_audio_kit release these binaries ship as (GitHub release
# libmpv-<release>). Baked into mpv's own version string, so a running app
# can tell which build it loaded: mpv-version reads "mpv v0.42.0+r26".
export LIBMPV_RELEASE="${LIBMPV_RELEASE:-r26}"
export FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.1}"

# ── Subtitle / font / text shaping (libass + pulls) ──────────────────────────
# Built only when libass is kept (strip_libass and strip_mpv_dead both
# disabled in Settings > Patches, see libass_stripped in _audio_only.sh).
# By default patch_strip_libass.py removes libass and this chain is skipped.
export LIBASS_VERSION="${LIBASS_VERSION:-0.17.5}"
export FREETYPE_VERSION="${FREETYPE_VERSION:-2.15.0}"
export FRIBIDI_VERSION="${FRIBIDI_VERSION:-1.0.18}"
export HARFBUZZ_VERSION="${HARFBUZZ_VERSION:-15.1.0}"
# Since 2.17 the dist tarballs are GitLab generic packages, no longer on the
# freedesktop release mirror.
export FONTCONFIG_VERSION="${FONTCONFIG_VERSION:-2.18.3}"

# ── Compression / system libraries ───────────────────────────────────────────
# xz stays on the post-backdoor clean line (5.8.x).
export ZLIB_VERSION="${ZLIB_VERSION:-1.4}"
export XZ_VERSION="${XZ_VERSION:-5.8.4}"
export LIBEXPAT_VERSION="${LIBEXPAT_VERSION:-2.10.0}"
# libxml2: only pulled in by ffmpeg's DASH and IMF demuxers.
export LIBXML2_VERSION="${LIBXML2_VERSION:-2.15.4}"
export LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.59}"
export BZIP2_VERSION="${BZIP2_VERSION:-1.0.8}"
# libiconv: built only where the platform lacks a system iconv that
# ffmpeg/libxml2 can link (Android, Windows).
export LIBICONV_VERSION="${LIBICONV_VERSION:-1.19.1}"

# ── Audio DSP ─────────────────────────────────────────────────────────────────
# rubberband 4.0.0 backs ffmpeg's `arubberband` filter. Its source uses an
# unqualified `size_t` in src/common/mathmisc.{h,cpp} that modern gcc/clang
# reject under -std=c++20 — see patches/rubberband/patch_rubberband_size_t.py.
export RUBBERBAND_VERSION="${RUBBERBAND_VERSION:-4.0.0}"
export SPEEXDSP_VERSION="${SPEEXDSP_VERSION:-1.2.1}"
export LIBSMB2_VERSION="${LIBSMB2_VERSION:-6.0.0}"

# ── PipeWire (Linux, headers and stub source only) ───────────────────────────
# libmpv does not link PipeWire: its AO goes through a lazily loaded stub (see
# patches/mpv/linux/patch_optional_audio_libs.py). This version supplies the
# headers and the symbol set, so it is also the oldest PipeWire the AO works
# with at run time. 0.3.57 is mpv's own floor (still so in 0.42.0), and building against it
# keeps mpv on the code paths every later PipeWire supports.
export PIPEWIRE_VERSION="${PIPEWIRE_VERSION:-0.3.57}"

# ── TLS backend (every platform) ─────────────────────────────────────────────
# OpenSSL is the TLS backend of every native platform (macOS, iOS, tvOS,
# Android, Linux, Windows, Tizen, webOS). The web build has none: the
# browser does TLS. On Apple we deliberately do NOT use SecureTransport:
# it's been deprecated by Apple since 10.15, doesn't support TLS 1.3, and
# is on its way out of upstream curl/ffmpeg (curl removed it in June 2025).
#
# OpenSSL 3.5.6 is the current LTS patch (the 3.5 LTS line is supported
# until 2030). License Apache 2.0 (OpenSSL 3.0+), GPL-compatible — no
# --enable-nonfree needed on the ffmpeg side.
export OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.6}"

# ── libplacebo (every platform) ──────────────────────────────────────────────
# mpv 0.42.0 needs 7.387.0 or later: video/csputils.c and video/mp_image.c,
# which stay in the audio-only build, use symbols the older releases lack
# (PL_ALPHA_NONE, pl_map_avdovi_metadata). One version on every platform, built
# minimal (no vulkan, shaderc, d3d11, opengl). Its meson floor is 1.3.0.
export LIBPLACEBO_VERSION="${LIBPLACEBO_VERSION:-7.387.0}"

# ── Platform-specific (only sourced where used) ──────────────────────────────
# Pinned in the script of the one platform that uses them:
#
# - Android NDK: build_libmpv_android.sh (NDK_VERSION).
# - emsdk: build_libmpv_web.sh (EMSDK_VERSION).
# - libunibreak: build_libmpv_linux.sh (Linux libass dep).
