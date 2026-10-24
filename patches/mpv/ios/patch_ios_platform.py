# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patch mpv's meson.build and TOOLS for iOS platform support.

Applies two changes:
1. Recognizes 'ios' as a Darwin-like system alongside 'darwin' in meson.build
2. Points TOOLS/macos-sdk-version.py at the iOS SDK name instead of macosx

Usage: python3 patch_ios_platform.py <mpv_source_dir> <sdk_name>
  sdk_name is 'iphoneos' or 'iphonesimulator'
"""
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

# 1. meson.build: recognize iOS as a Darwin-like system. Scoped to the
#    single `darwin = ...` assignment (the only occurrence in 0.41.0) so a
#    future second inline `host_machine.system() == 'darwin'` test can't be
#    rewritten by accident.
IOS_TEST = "host_machine.system() == 'ios'"
DARWIN_OLD = "darwin = host_machine.system() == 'darwin'"
DARWIN_NEW = ("darwin = host_machine.system() == 'darwin' "
              "or host_machine.system() == 'ios'")

# 2. TOOLS/macos-sdk-version.py: query the iOS SDK instead of macosx. The
#    tool invokes `xcrun --sdk macosx ...`; upstream writes the token in
#    double quotes ("macosx"), so the match is quote-agnostic. Every
#    occurrence is swapped, so the iOS build can never silently resolve
#    the macOS SDK version.
SDK_TOOL = 'TOOLS/macos-sdk-version.py'


def apply(p, sdk):
    if IOS_TEST not in p.text('meson.build'):
        p.edit('meson.build', DARWIN_OLD, DARWIN_NEW, 'darwin-system test')
    if sdk not in p.text(SDK_TOOL):
        p.regex(SDK_TOOL, r"([\"'])macosx\1", rf"\g<1>{sdk}\g<1>",
                "'macosx' SDK token", times=anchor.ALL)
    if 'macosx' in p.text(SDK_TOOL):
        p.fail(f'{SDK_TOOL}: macosx still named after the swap')


anchor.main(apply, 'patch_ios_platform', usage='<mpv_source_dir> <sdk_name>',
            nargs=2)
