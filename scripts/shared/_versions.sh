# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Pinned dependency versions — single source of truth across the 5
# build_libmpv_<platform>.sh scripts.
#
# Override any version with an environment variable:
#   MPV_VERSION=0.42.0 ./build_libmpv_macos.sh
#
# This file is sourced by every per-platform build script. Do not run
# it directly.

# ── Player core ──────────────────────────────────────────────────────────────
# mpv 0.41.0 (2025-12) is the latest release. FFmpeg 8.1.1 ("Hoare",
# 2026-05) — mpv 0.41's meson floor is libavcodec >= 60.31.102, which
# the 8.x line clears comfortably; FFmpeg 8.x + mpv 0.41 is a
# community-verified pairing.
export MPV_VERSION="${MPV_VERSION:-0.41.0}"
export FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.1}"

# ── Subtitle / font / text shaping (libass + pulls) ──────────────────────────
# libass is built but not used at runtime by an audio-only consumer; mpv's
# meson still requires it as a dependency to link. The whole text stack is
# dead-code-stripped from the final audio-only binary.
export LIBASS_VERSION="${LIBASS_VERSION:-0.17.4}"
export FREETYPE_VERSION="${FREETYPE_VERSION:-2.14.3}"
export FRIBIDI_VERSION="${FRIBIDI_VERSION:-1.0.16}"
export HARFBUZZ_VERSION="${HARFBUZZ_VERSION:-14.2.0}"
# 2.16.0 is the newest fontconfig with a dist tarball on the standard
# freedesktop release mirror; 2.17.x ships only as git tags.
export FONTCONFIG_VERSION="${FONTCONFIG_VERSION:-2.16.0}"

# ── Compression / system libraries ───────────────────────────────────────────
# xz 5.8.3 is on the post-backdoor clean line and fixes CVE-2026-34743.
export ZLIB_VERSION="${ZLIB_VERSION:-1.3.2}"
export XZ_VERSION="${XZ_VERSION:-5.8.3}"
export LIBEXPAT_VERSION="${LIBEXPAT_VERSION:-2.8.1}"
# libxml2 stays on the mature 2.14 line (2.15.x carries build/API
# regressions); only pulled in transitively by ffmpeg's DASH/IMF demuxers.
export LIBXML2_VERSION="${LIBXML2_VERSION:-2.14.6}"
export LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.58}"
export BZIP2_VERSION="${BZIP2_VERSION:-1.0.8}"
# libiconv: built only where the platform lacks a system iconv that
# ffmpeg/libxml2 can link (Android, Windows).
export LIBICONV_VERSION="${LIBICONV_VERSION:-1.18}"

# ── Audio DSP ─────────────────────────────────────────────────────────────────
# rubberband 4.0.0 backs ffmpeg's `arubberband` filter. Its source uses an
# unqualified `size_t` in src/common/mathmisc.{h,cpp} that modern gcc/clang
# reject under -std=c++20 — see patches/rubberband/patch_rubberband_size_t.py.
export RUBBERBAND_VERSION="${RUBBERBAND_VERSION:-4.0.0}"
export SPEEXDSP_VERSION="${SPEEXDSP_VERSION:-1.2.1}"
export LIBSMB2_VERSION="${LIBSMB2_VERSION:-6.0.0}"

# ── TLS backend (every platform) ─────────────────────────────────────────────
# OpenSSL is the unified TLS backend across all five platforms. On Apple
# we deliberately do NOT use SecureTransport: it's been deprecated by
# Apple since 10.15, doesn't support TLS 1.3, and is on its way out of
# upstream curl/ffmpeg (curl removed it in June 2025).
#
# OpenSSL 3.5.6 is the current LTS patch (the 3.5 LTS line is supported
# until 2030). License Apache 2.0 (OpenSSL 3.0+), GPL-compatible — no
# --enable-nonfree needed on the ffmpeg side.
export OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.6}"

# ── Platform-specific (only sourced where used) ──────────────────────────────
# Some libraries are pinned per-platform because desktop/mobile track
# different upstream branches — those stay in the per-platform script and
# are NOT centralised here:
#
# - libplacebo: macOS / Linux pin v7.349.0; iOS / Android / Windows pin
#   v6.338.2. Reason: libplacebo 7.x dropped some symbols mpv 0.41.0's
#   csputils.h still references when building under the cross-compile
#   cross files used on mobile/Windows. Once mpv ships a release that
#   uses the 7.x API on those platforms too, all five can converge
#   (libplacebo 7.360.1 is the current latest).
# - Android NDK: pinned in build_libmpv_android.sh (NDK_VERSION).
# - libunibreak: pinned in build_libmpv_linux.sh (Linux libass dep).
