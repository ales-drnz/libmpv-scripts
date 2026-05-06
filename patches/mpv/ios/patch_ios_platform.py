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
import sys
import re

mpv_dir = sys.argv[1]
sdk = sys.argv[2]

# 1. meson.build: recognize iOS as a Darwin-like system. Scope the rewrite
#    to the single `darwin = ...` assignment (the only occurrence in 0.41.0)
#    so a future second inline `host_machine.system() == 'darwin'` test can't
#    be rewritten by accident. A post-condition assert turns a silent miss
#    on a future bump into a hard failure rather than a macOS-shaped libmpv.
meson_path = f"{mpv_dir}/meson.build"
with open(meson_path) as f:
    content = f.read()

DARWIN_OLD = "darwin = host_machine.system() == 'darwin'"
DARWIN_NEW = ("darwin = host_machine.system() == 'darwin' "
              "or host_machine.system() == 'ios'")
if "host_machine.system() == 'ios'" not in content:
    if DARWIN_OLD not in content:
        sys.exit("[patch_ios_platform] darwin-system anchor not found in "
                 "meson.build — layout changed")
    content = content.replace(DARWIN_OLD, DARWIN_NEW, 1)
    with open(meson_path, 'w') as f:
        f.write(content)

assert "host_machine.system() == 'ios'" in content, \
    "[patch_ios_platform] iOS system test missing after patch"

# 2. TOOLS/macos-sdk-version.py: query the iOS SDK instead of macosx. The
#    tool invokes `xcrun --sdk macosx ...`; upstream writes the token in
#    double quotes ("macosx"), so the match is quote-agnostic. All
#    occurrences are swapped, then asserted, so the iOS build can never
#    silently resolve the macOS SDK version.
sdk_py = f"{mpv_dir}/TOOLS/macos-sdk-version.py"
with open(sdk_py) as f:
    sdk_content = f.read()

if sdk not in sdk_content:
    sdk_content, n = re.subn(r"([\"'])macosx\1",
                             rf"\g<1>{sdk}\g<1>", sdk_content)
    if n == 0:
        sys.exit(f"[patch_ios_platform] 'macosx' SDK token not found in "
                 f"{sdk_py} — layout changed")
    with open(sdk_py, 'w') as f:
        f.write(sdk_content)

assert sdk in sdk_content and "macosx" not in sdk_content, \
    f"[patch_ios_platform] SDK swap incomplete in {sdk_py}"

print(f"Patched mpv for iOS platform support (sdk={sdk})")
