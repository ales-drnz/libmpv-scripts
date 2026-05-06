#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Gate the kAudioObjectPropertyElementMain compat shim in mpv's
osdep/mac/compat.h on TARGET_OS_OSX.

Why: starting with iPhoneOS 26 SDK Apple removed the
kAudioObjectPropertyElementMaster declaration entirely (it had been
deprecated since iOS 14 / macOS 12). The upstream shim
    #if !HAVE_MACOS_12_FEATURES || (MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_VERSION_12_0)
    #define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
    #endif
fires on iOS because `HAVE_MACOS_12_FEATURES` is false there (it gates a
macOS-only mpv feature), making `!HAVE_MACOS_12_FEATURES` true regardless
of the SDK version. `MAC_OS_X_VERSION_MAX_ALLOWED` *is* defined on iOS
(compat.h includes <AvailabilityMacros.h>), but the leading
`!HAVE_MACOS_12_FEATURES` short-circuits the test true anyway. The shim
then references kAudioObjectPropertyElementMaster, which no longer exists
in the SDK — so every iOS build of `audio/out/ao_coreaudio_properties.c`
fails with `use of undeclared identifier`.

iOS 15+ ships kAudioObjectPropertyElementMain natively in CoreAudio, so
the shim is never needed there; gating on TARGET_OS_OSX disables it for
iOS while leaving the macOS behaviour untouched.

Idempotent (MARKER-guarded). This patch is applied on the iOS build only.

Usage: patch_compat_apple.py <mpv_source_dir>
"""
import pathlib
import sys

if len(sys.argv) != 2:
    sys.exit("usage: patch_compat_apple.py <mpv_source_dir>")

target = pathlib.Path(sys.argv[1]) / "osdep" / "mac" / "compat.h"
if not target.exists():
    sys.exit(f"[patch_compat_apple] file not found: {target}")

text = target.read_text()

MARKER = "/* mpv_audio_kit: gate on TARGET_OS_OSX */"
if MARKER in text:
    print("[patch_compat_apple] already applied", file=sys.stderr)
    sys.exit(0)

# Anchor on the single, tree-wide-unique `#if` line rather than the whole
# 3-line block — shrinks the brittle match surface to one line. The
# `#define`/`#endif` below it are left untouched.
old = (
    "#if !HAVE_MACOS_12_FEATURES || (MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_VERSION_12_0)\n"
)
new = (
    "#include <TargetConditionals.h>\n"
    "/* mpv_audio_kit: gate on TARGET_OS_OSX */\n"
    "#if TARGET_OS_OSX && (!HAVE_MACOS_12_FEATURES || (MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_VERSION_12_0))\n"
)

if old not in text:
    sys.exit(
        "[patch_compat_apple] anchor not found — mpv may have already "
        "fixed this upstream or the compat.h layout changed"
    )

target.write_text(text.replace(old, new))
print("[patch_compat_apple] applied", file=sys.stderr)
