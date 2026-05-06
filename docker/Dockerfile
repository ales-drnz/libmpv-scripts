# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Multi-stage Dockerfile for the libmpv build kit. Instead of one monolithic
# image carrying every cross-toolchain, each platform is its own stage built on
# a shared `base`, so you only build (and only keep on disk) the piece you need:
#
#   docker build --target linux   -t mpv-build-linux   ./docker/
#   docker build --target windows -t mpv-build-windows ./docker/
#   docker build --target android -t mpv-build-android ./docker/
#   docker build --target verify  -t mpv-build-verify  ./docker/
#
# The `base` layers are shared across all of them (built once, cached), so
# adding a second platform later only pulls in that platform's extra toolchain.
# The TUI's Docker tab (and expand()) build the missing target on demand.
#
#   base    : ubuntu:24.04 + multiarch + common build tooling (meson, cmake, …)
#   linux   : base + GCC cross (x86_64 + aarch64) + multiarch audio/X11 dev libs
#   windows : base + GNU MinGW-w64 (x86_64) + llvm-mingw (aarch64)
#   android : base alias — the NDK is fetched at runtime by build_libmpv_android.sh
#   verify  : base + the linux/windows cross-compilers + qemu-user + Wine/Hangover
#             + arm32 binutils — the union needed by verify_binaries.sh (NO audio
#             dev libs: those only matter when *building* mpv, not verifying it).
#
# Per-image arch is chosen by the kit via `docker build/run --platform` (see
# tui/orchestrate.go): linux/windows/verify build for the HOST arch (native
# cross-compilers, no emulation), while android builds linux/amd64 so the
# x86_64-only NDK toolchain is the container's native arch (accelerated by
# Rosetta on Apple Silicon; correct, if slower, under plain emulation).
#
# NOTE: base must NOT pin `--platform=$BUILDPLATFORM`. That would force base (and
# every `FROM base` stage) to the builder's arch and make `docker build
# --platform linux/amd64 --target android` silently produce an arm64 image — an
# arm64 container running the x86_64 NDK clang with no emulator → "broken C
# compiler". Letting base follow the build's target platform is what makes the
# per-image --platform actually take effect.

# ══════════════════════════════════════════════════════════════════════════════
# base — shared by every platform stage
# ══════════════════════════════════════════════════════════════════════════════
FROM ubuntu:24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive

# ── Multiarch sources.list ───────────────────────────────────────────────────
# Ubuntu 24.04 ships /etc/apt/sources.list.d/ubuntu.sources (deb822). Replace
# with arch-pinned classic sources.list so that ports.ubuntu.com serves arm64
# and archive.ubuntu.com serves amd64 — keeping a single apt update happy on
# either host arch. The foreign arch is enabled here (the linux stage installs
# foreign-arch dev libs on top).
RUN set -eux; \
    NATIVE_ARCH="$(dpkg --print-architecture)"; \
    if [ "$NATIVE_ARCH" = "arm64" ]; then FOREIGN_ARCH="amd64"; else FOREIGN_ARCH="arm64"; fi; \
    ARM64_URL="http://ports.ubuntu.com/ubuntu-ports"; \
    AMD64_URL="http://archive.ubuntu.com/ubuntu"; \
    rm -f /etc/apt/sources.list.d/ubuntu.sources; \
    { \
      echo "deb [arch=amd64] ${AMD64_URL} noble main universe restricted multiverse"; \
      echo "deb [arch=amd64] ${AMD64_URL} noble-updates main universe restricted multiverse"; \
      echo "deb [arch=amd64] ${AMD64_URL} noble-security main universe restricted multiverse"; \
      echo "deb [arch=arm64] ${ARM64_URL} noble main universe restricted multiverse"; \
      echo "deb [arch=arm64] ${ARM64_URL} noble-updates main universe restricted multiverse"; \
      echo "deb [arch=arm64] ${ARM64_URL} noble-security main universe restricted multiverse"; \
    } > /etc/apt/sources.list; \
    dpkg --add-architecture "$FOREIGN_ARCH"; \
    apt-get update

# ── Common build tooling (arch-agnostic) ──────────────────────────────────────
# `apt-get update` is repeated inside this RUN so the package index is fresh in
# this same layer — otherwise a cached index goes stale when Ubuntu prunes
# superseded point-release .debs and the install 404s.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      ninja-build \
      nasm \
      pkg-config \
      autoconf \
      automake \
      libtool \
      git \
      curl \
      ca-certificates \
      python3 \
      python3-pip \
      unzip \
      xz-utils \
      gperf \
      gettext \
      autopoint \
      patchelf \
      file \
    && rm -rf /var/lib/apt/lists/*

# Meson from pip, not apt: Ubuntu 24.04 ships meson 1.3.2, but fontconfig 2.16+
# and other recent deps require meson >= 1.6.0. --break-system-packages is fine
# in a throwaway build image (PEP 668 / Ubuntu 24.04).
RUN pip3 install --break-system-packages --no-cache-dir 'meson>=1.6.0'

WORKDIR /src

# ══════════════════════════════════════════════════════════════════════════════
# linux — GCC cross-toolchains (both arches) + multiarch audio/X11 dev libs
# ══════════════════════════════════════════════════════════════════════════════
FROM base AS linux

RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-x86-64-linux-gnu g++-x86-64-linux-gnu binutils-x86-64-linux-gnu \
      gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu \
    && rm -rf /var/lib/apt/lists/*

# ── Linux dev libs for BOTH arches via multiarch ──────────────────────────────
# System audio/video backend headers + .so files that mpv links against on
# Linux. They MUST be installed in two passes (native first, foreign second):
# libpulse-dev / libpipewire-0.3-dev pull libglib2.0-dev, which transitively
# requires libglib2.0-dev-bin — a Multi-Arch: foreign package allowing only one
# arch at a time. Both archs in one `apt install` makes the solver abort with
# "held broken packages". Splitting lets the native arch's libglib2.0-dev-bin
# land first; the foreign-arch pass then pulls only Multi-Arch: same packages.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libasound2-dev libpulse-dev libpipewire-0.3-dev \
      libx11-dev libxext-dev libxrandr-dev libxinerama-dev \
      libva-dev libvdpau-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    NATIVE_ARCH="$(dpkg --print-architecture)"; \
    if [ "$NATIVE_ARCH" = "arm64" ]; then FOREIGN_ARCH=amd64; else FOREIGN_ARCH=arm64; fi; \
    apt-get update && apt-get install -y --no-install-recommends \
      libasound2-dev:${FOREIGN_ARCH} libpulse-dev:${FOREIGN_ARCH} libpipewire-0.3-dev:${FOREIGN_ARCH} \
      libx11-dev:${FOREIGN_ARCH} libxext-dev:${FOREIGN_ARCH} libxrandr-dev:${FOREIGN_ARCH} libxinerama-dev:${FOREIGN_ARCH} \
      libva-dev:${FOREIGN_ARCH} libvdpau-dev:${FOREIGN_ARCH} zlib1g-dev:${FOREIGN_ARCH} \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# ══════════════════════════════════════════════════════════════════════════════
# windows — GNU MinGW-w64 (x86_64) + llvm-mingw (aarch64)
# ══════════════════════════════════════════════════════════════════════════════
FROM base AS windows

ARG LLVM_MINGW_VERSION=20260421
ENV LLVM_MINGW_DIR=/opt/llvm-mingw
# llvm-mingw is intentionally NOT prepended to PATH: its tarball ships
# x86_64-w64-mingw32-* shadow wrappers that would override the GNU MinGW-w64
# toolchain — Windows x86_64 builds must keep using GCC. The Windows build
# script adds /opt/llvm-mingw/bin to PATH only when building Windows aarch64.

RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 \
      mingw-w64-tools mingw-w64-common \
    && rm -rf /var/lib/apt/lists/*

# ── llvm-mingw (Windows aarch64 cross-toolchain) ──────────────────────────────
# GNU MinGW-w64 has no aarch64-Windows target; llvm-mingw (Martin Storsjö) is
# the standard alternative — clang+lld+ucrt builds for Windows on ARM64.
# Tarball arch = host arch (it runs the toolchain natively).
RUN set -eux; \
    HOST_ARCH="$(dpkg --print-architecture)"; \
    case "$HOST_ARCH" in \
      arm64) LLVM_TARBALL_ARCH="aarch64" ;; \
      amd64) LLVM_TARBALL_ARCH="x86_64"  ;; \
      *) echo "unsupported host arch: $HOST_ARCH" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${LLVM_TARBALL_ARCH}.tar.xz"; \
    mkdir -p "$LLVM_MINGW_DIR"; \
    curl -fsSL "$URL" | tar -xJ --strip-components=1 -C "$LLVM_MINGW_DIR"; \
    "${LLVM_MINGW_DIR}/bin/aarch64-w64-mingw32-clang" --version

WORKDIR /src

# ══════════════════════════════════════════════════════════════════════════════
# android — base (built linux/amd64; the NDK is x86_64-only)
# ══════════════════════════════════════════════════════════════════════════════
# The Android build uses the NDK's own LLVM toolchain (fetched at runtime by
# build_libmpv_android.sh; cached in the build work dir, freed by "clean work").
# Google ships ONLY a linux-x86_64 host NDK, so the kit builds/runs this image as
# linux/amd64 (see orchestrate.go): the NDK clang is then the container's NATIVE
# arch — native on an x86_64 host, Rosetta-accelerated on Apple Silicon — so no
# in-container emulator (qemu) is needed and the image stays just `base`.
FROM base AS android
WORKDIR /src

# ══════════════════════════════════════════════════════════════════════════════
# verify — the union needed by scripts/verify_binaries.sh
# ══════════════════════════════════════════════════════════════════════════════
# Built on the `linux` stage so it inherits the Linux cross-compilers AND the
# multiarch RUNTIME libs (libpipewire / libpulse / libasound / libc6 for BOTH
# arches). The verifier needs those present, not just at mpv-compile time:
#   • L12 (UND resolvability) resolves the binary's NEEDED symbols against the
#     container's actual .so files;
#   • L13 (dlopen) loads the binary, which fails if a NEEDED .so is missing;
#   • the foreign-arch glibc loader (/lib64/ld-linux-x86-64.so.2) from the
#     :amd64 libs is what qemu-user needs to run the x86_64 dlopen helper.
# On top it adds the Windows cross-compilers, qemu-user-static (run foreign-arch
# helpers), Wine/Hangover (load Windows DLLs) and arm32 binutils (Android JNI
# stub detection). The Android NDK sysroot is bind-mounted at runtime.
FROM linux AS verify

ARG LLVM_MINGW_VERSION=20260421
ENV LLVM_MINGW_DIR=/opt/llvm-mingw

# Windows cross — GNU MinGW (x86_64) + llvm-mingw (aarch64) for the LoadLibrary
# helper, and llvm-objdump / llvm-readobj (Mach-O + COFF) used across platforms.
RUN apt-get update && apt-get install -y --no-install-recommends \
      gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 \
      mingw-w64-tools mingw-w64-common \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    HOST_ARCH="$(dpkg --print-architecture)"; \
    case "$HOST_ARCH" in \
      arm64) LLVM_TARBALL_ARCH="aarch64" ;; \
      amd64) LLVM_TARBALL_ARCH="x86_64"  ;; \
      *) echo "unsupported host arch: $HOST_ARCH" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-${LLVM_TARBALL_ARCH}.tar.xz"; \
    mkdir -p "$LLVM_MINGW_DIR"; \
    curl -fsSL "$URL" | tar -xJ --strip-components=1 -C "$LLVM_MINGW_DIR"; \
    "${LLVM_MINGW_DIR}/bin/aarch64-w64-mingw32-clang" --version

# ── Cross-arch + Windows runtime tools ────────────────────────────────────────
# qemu-user-static: run a foreign-arch ELF helper inside this native-arch image
#   (binfmt-support hooks binfmt_misc so /usr/bin/qemu-*-static runs it).
# winbind: Wine's NTLM auth path (pulled transitively by the runtime-DLL chain).
# binutils-arm-linux-gnueabihf: ARM 32-bit nm/objdump for the armeabi-v7a JNI
#   stub-detection layer — the only target with no 32-bit-ARM toolchain here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      qemu-user-static binfmt-support \
      winbind \
      binutils-arm-linux-gnueabihf \
    && rm -rf /var/lib/apt/lists/*

# Wine for the Windows DLL load test. The build-host arch decides which Wine:
#   • x86_64 host → distro Wine runs x86_64 PEs natively.
#   • arm64 host (Apple Silicon — the usual case) → distro Wine is arm64-only
#     and CANNOT load an x86_64 PE. Install Hangover instead: Wine + WoW64 with
#     the FEX (libarm64ecfex, x86_64) and Box64 emulators, so one arm64 machine
#     runtime-loads BOTH x86_64 and aarch64 Windows PEs. hangover-wine
#     Provides/Replaces the distro `wine`, so the two never coexist.
# Pinned (like LLVM_MINGW_VERSION): the .deb set / default emulator can shift
# between releases — bump consciously and re-verify against
# https://github.com/AndreRH/hangover/releases
ENV HANGOVER_VERSION=11.9
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    apt-get update; \
    if [ "$arch" = "arm64" ]; then \
      cd /tmp; \
      curl -fsSL -o hangover.tar \
        "https://github.com/AndreRH/hangover/releases/download/hangover-${HANGOVER_VERSION}/hangover_${HANGOVER_VERSION}_ubuntu2404_noble_arm64.tar"; \
      mkdir hangover && tar xf hangover.tar -C hangover; \
      apt-get install -y --no-install-recommends \
        ./hangover/hangover-wine_*.deb \
        ./hangover/hangover-libarm64ecfex_*.deb \
        ./hangover/hangover-libwow64fex_*.deb \
        ./hangover/hangover-wowbox64_*.deb; \
      rm -rf hangover hangover.tar; \
    else \
      apt-get install -y --no-install-recommends wine; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# Wine's first run wants gecko/mono; disabled via WINEDLLOVERRIDES at runtime by
# verify_binaries.sh rather than pre-initing the prefix here (the pre-init step
# was unreliable across host arches — Wine arm64 chokes on a clean headless
# wineboot). Each verify run lets Wine init its prefix lazily.
ENV WINEDLLOVERRIDES="mscoree=,mshtml="

# ── Sanity: every cross-compiler resolves + the load-test emulators work ──────
RUN set -eux; \
    x86_64-linux-gnu-gcc                              --version | head -1; \
    aarch64-linux-gnu-gcc                             --version | head -1; \
    x86_64-w64-mingw32-gcc                            --version | head -1; \
    "${LLVM_MINGW_DIR}/bin/aarch64-w64-mingw32-clang" --version | head -1; \
    qemu-x86_64-static --version | head -1 || true; \
    qemu-aarch64-static --version | head -1 || true; \
    wine --version | head -1 || true; \
    if [ "$(dpkg --print-architecture)" = "arm64" ]; then \
      test -f /usr/lib/wine/aarch64-windows/libarm64ecfex.dll \
        && echo "Hangover FEX (x86_64-on-arm64) present" \
        || { echo "ERROR: Hangover FEX emulator missing on arm64" >&2; exit 1; }; \
    fi

WORKDIR /src
