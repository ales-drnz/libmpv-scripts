#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Cross-compile OpenSSL statically into $prefix/.
#
# OpenSSL 3.5.x LTS is the TLS backend for FFmpeg (HTTPS/HLS/DASH/RTMPS/
# RTSPS) and libsmb2 (SMB3 signing) on every platform.
#
# Caller exports:
#   CC / AR / RANLIB              (cross-toolchain)
#   CFLAGS / LDFLAGS              (target arch + sysroot)
#   plus a third positional arg `openssl_target` for OpenSSL's Configure.
#   Required because OpenSSL doesn't auto-detect the cross target —
#   Configure needs an explicit platform string (darwin64-arm64-cc,
#   linux-aarch64, mingw64, android-arm64, ios64-cross, etc.).
#
# Outputs (all in $prefix/lib):
#   libssl.a libcrypto.a   (static, Apache 2.0)
#
# Link order for consumers: -lssl -lcrypto (ssl depends on crypto).
#
# Sourced by every per-platform build script. Do not run directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared/_helpers.sh"
source "$SCRIPT_DIR/shared/_versions.sh"

# Cross-compile OpenSSL into $prefix.
#
# Args:
#   1  prefix          install prefix (libssl.a / libcrypto.a land in lib/)
#   2  b               build dir (source download + extract cache)
#   3  openssl_target  OpenSSL Configure target string for this platform/arch
#
# Common targets:
#   macOS arm64       darwin64-arm64-cc
#   macOS x86_64      darwin64-x86_64-cc
#   iOS arm64         ios64-cross
#   iOS sim arm64     iossimulator-xcrun
#   iOS sim x86_64    iossimulator-xcrun
#   Linux x86_64      linux-x86_64
#   Linux aarch64     linux-aarch64
#   Windows x86_64    mingw64
#   Windows aarch64   mingw64   (with llvm-mingw CC + appropriate flags)
#   Android arm64     android-arm64
#   Android x86_64    android-x86_64
build_openssl() {
    local prefix="$1" b="$2" openssl_target="${3:-}" extra_config="${4:-}"
    [[ -f "$prefix/lib/libssl.a" ]] && { ok "openssl already built"; return; }
    [[ -n "$openssl_target" ]] || die "build_openssl: third arg (openssl_target) is required"
    log "Build openssl $OPENSSL_VERSION (target=$openssl_target)..."

    # OpenSSL release tarballs live at github.com/openssl/openssl/releases.
    # Filename convention: openssl-<version>.tar.gz.
    local src="$b/src/openssl-$OPENSSL_VERSION.tar.gz"
    download "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" "$src"
    local dir; dir="$(extract "$src" "$b/src")"

    # OpenSSL's Configure is in-tree (it writes Makefile next to it),
    # so we cannot do an out-of-tree build cleanly. Wipe + reconfigure
    # in-place. Safe because we extract into a per-version directory.
    pushd "$dir" >/dev/null
    make clean 2>/dev/null || true

    # Static-only + minimal: no shared libs, no docs, no apps, no tests,
    # no engines (deprecated in 3.x), no deprecated APIs we don't use.
    # Threads stay on (libsmb2 needs them). All algorithms stay on —
    # FFmpeg's HTTPS path needs the full default set.
    #
    # Caller's CFLAGS/LDFLAGS get passed via env (Configure honours them).
    # extra_config (4th arg, optional): extra Configure tokens — e.g.
    # Android passes `-D__ANDROID_API__=N` so OpenSSL targets the same
    # API level as the rest of the build instead of the NDK's max.
    ./Configure "$openssl_target" \
        --prefix="$prefix" \
        --openssldir="$prefix/ssl" \
        --libdir=lib \
        no-shared \
        no-tests \
        no-apps \
        no-docs \
        no-engine \
        no-legacy \
        no-quic \
        no-dtls \
        no-srp \
        no-psk \
        no-cms \
        no-ts \
        no-ct \
        no-comp \
        no-asm \
        no-ec2m no-dsa no-aria no-camellia no-bf no-cast no-idea no-rc2 no-rc4 \
        no-seed no-md4 no-mdc2 no-rmd160 no-whirlpool no-blake2 \
        no-sm2 no-sm3 no-sm4 no-ocsp no-cmp no-siphash no-scrypt no-argon2 no-rfc3779 \
        no-dso no-dynamic-engine no-module no-static-engine \
        no-afalgeng no-capieng no-padlockeng \
        no-async no-http no-nextprotoneg no-ocb no-ssl-trace \
        no-thread-pool no-uplink no-filenames no-cmac no-siv \
        threads \
        -Os -DOPENSSL_SMALL_FOOTPRINT \
        ${extra_config}
    make -j"${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || nproc)}"
    make install_sw       # install_sw = libs + headers, skip docs/man
    popd >/dev/null

    [[ -f "$prefix/lib/libssl.a"    ]] || die "openssl install missing libssl.a"
    [[ -f "$prefix/lib/libcrypto.a" ]] || die "openssl install missing libcrypto.a"
    ok "openssl built"
}
