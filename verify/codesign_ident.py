#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
#
# Layer 15 helper: for an extracted libmpv.xcframework (or a single
# libmpv.framework), assert that each slice's embedded code-signing identifier
# equals its CFBundleIdentifier.
#
# WHY THIS EXISTS: iOS `installd` rejects a device install when an embedded
# framework's code-signing identifier != its CFBundleIdentifier
# (MismatchedBundleIDSigningIdentifier). That is exactly the libmpv-r9 / 0.3.5
# regression: `strip -x` invalidated the signature, the re-sign targeted the
# bare Mach-O (no Info.plist in scope) so codesign defaulted the identifier to
# `libmpv-<hash>` instead of `com.ales-drnz.libmpv`. It passed every existing
# layer (Simulator, macOS, dlopen, flutter test) because only a physical-device
# install enforces the identifier==bundle-id rule.
#
# The signing identifier is parsed straight from the Mach-O
# (LC_CODE_SIGNATURE -> CS_SuperBlob -> CodeDirectory.identOffset), so this runs
# in the verify container (meson already requires python3) and on a macOS host
# alike — no `codesign` (macOS-only) needed.
#
# Prints one line per slice; exits 0 if every slice matches, 1 on any mismatch,
# 2 if no framework was found.

import os
import plistlib
import struct
import sys


def macho_codesign_identifier(path):
    """Identifier string from the first Mach-O slice carrying a code signature."""
    with open(path, "rb") as f:
        data = f.read()

    # Image offsets — a fat/universal wrapper is always big-endian.
    fat = struct.unpack(">I", data[0:4])[0]
    offsets = []
    if fat in (0xCAFEBABE, 0xCAFEBABF):  # FAT_MAGIC / FAT_MAGIC_64
        n = struct.unpack(">I", data[4:8])[0]
        wide = fat == 0xCAFEBABF
        rec = 32 if wide else 20
        for i in range(n):
            b = 8 + i * rec
            offsets.append(
                struct.unpack(">Q" if wide else ">I", data[b + 8 : b + 8 + (8 if wide else 4)])[0]
            )
    else:
        offsets.append(0)

    for base in offsets:
        le = struct.unpack("<I", data[base : base + 4])[0]
        be = struct.unpack(">I", data[base : base + 4])[0]
        if le in (0xFEEDFACE, 0xFEEDFACF):  # thin Mach-O, little-endian (arm64/x86_64)
            en, is64 = "<", le == 0xFEEDFACF
        elif be in (0xFEEDFACE, 0xFEEDFACF):
            en, is64 = ">", be == 0xFEEDFACF
        else:
            continue
        ncmds = struct.unpack(en + "I", data[base + 16 : base + 20])[0]
        o = base + (32 if is64 else 28)
        for _ in range(ncmds):
            cmd, sz = struct.unpack(en + "II", data[o : o + 8])
            if cmd == 0x1D:  # LC_CODE_SIGNATURE
                dataoff = struct.unpack(en + "I", data[o + 8 : o + 12])[0]
                sb = base + dataoff  # CS_SuperBlob — always big-endian
                count = struct.unpack(">I", data[sb + 8 : sb + 12])[0]
                for i in range(count):
                    boff = struct.unpack(">I", data[sb + 12 + i * 8 + 4 : sb + 12 + i * 8 + 8])[0]
                    cd = sb + boff
                    if struct.unpack(">I", data[cd : cd + 4])[0] == 0xFADE0C02:  # CodeDirectory
                        ident_off = struct.unpack(">I", data[cd + 20 : cd + 24])[0]
                        s = cd + ident_off
                        return data[s : data.index(b"\x00", s)].decode()
                return None
            o += sz
    return None


def bundle_identifier(framework_dir):
    for rel in (
        "Info.plist",
        "Resources/Info.plist",
        "Versions/Current/Resources/Info.plist",
        "Versions/A/Resources/Info.plist",
    ):
        p = os.path.join(framework_dir, rel)
        if os.path.isfile(p):
            with open(p, "rb") as f:
                return plistlib.load(f).get("CFBundleIdentifier")
    return None


def inner_binary(framework_dir):
    for rel in ("libmpv", "Versions/Current/libmpv", "Versions/A/libmpv"):
        p = os.path.join(framework_dir, rel)
        if os.path.isfile(p):
            return p
    return None


def main():
    if len(sys.argv) != 2:
        print("usage: codesign_ident.py <xcframework-or-framework-dir>")
        return 2
    root = sys.argv[1]

    frameworks = []
    if root.rstrip("/").endswith(".framework"):
        frameworks = [root]
    else:
        for dirpath, dirnames, _ in os.walk(root):
            for d in dirnames:
                if d == "libmpv.framework":
                    frameworks.append(os.path.join(dirpath, d))

    if not frameworks:
        print("no libmpv.framework found under %s" % root)
        return 2

    bad = 0
    for fw in sorted(frameworks):
        slice_name = os.path.basename(os.path.dirname(fw))
        binp = inner_binary(fw)
        ident = macho_codesign_identifier(binp) if binp else None
        bid = bundle_identifier(fw)
        ok = ident is not None and bid is not None and ident == bid
        if not ok:
            bad += 1
        print("%-28s sign=%s bundle=%s %s" % (slice_name, ident, bid, "OK" if ok else "MISMATCH"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
