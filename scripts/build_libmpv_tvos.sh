#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# =============================================================================
# build_libmpv_tvos.sh
#
# Compiles mpv 0.41.0 as a DYNAMIC library for tvOS: build_libmpv_ios.sh with
# the tvOS SDKs (APPLE_OS=tvos). It takes the same options.
#
# Final artifact: builds/release/libmpv_tvos.xcframework.zip, with the slices
#   tvos-arm64                    (Apple TV)
#   tvos-arm64_x86_64-simulator   (Apple TV Simulator)
# =============================================================================

set -euo pipefail
APPLE_OS=tvos exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build_libmpv_ios.sh" "$@"
