#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Packs the web module into libmpv_web.zip, the release asset of the web
# target, and copies its record next to it for write_manifest.sh:
#
#   package_web.py <module dir> <out dir>
#
# <module dir> holds what build_libmpv_web.sh links: libmpv.mjs, libmpv.wasm,
# mak_webaudio_processor.js and build_web.json, whose "module" names the
# versions of the module. The zip holds those four files at its root, in
# that order, with fixed dates and modes: the same files give the same zip.
import json
import pathlib
import shutil
import sys
import zipfile

FILES = ["libmpv.mjs", "libmpv.wasm", "mak_webaudio_processor.js", "build_web.json"]


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: package_web.py <module dir> <out dir>")
    src, out = (pathlib.Path(a) for a in sys.argv[1:])
    missing = [n for n in FILES if not (src / n).is_file()]
    if missing:
        sys.exit(f"{src} has no {', '.join(missing)}")
    record = json.loads((src / "build_web.json").read_text())
    module = record.get("module") or {}
    if record.get("target") != "web" or not all(
            isinstance(module.get(k), int) for k in ("abi", "webaudioAbi")):
        sys.exit(f"{src / 'build_web.json'} is not the record of a web module with its versions")
    out.mkdir(parents=True, exist_ok=True)
    zip_path = out / "libmpv_web.zip"
    tmp = zip_path.with_suffix(".zip.tmp")
    with zipfile.ZipFile(tmp, "w") as z:
        for n in FILES:
            info = zipfile.ZipInfo(n, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o644 << 16
            z.writestr(info, (src / n).read_bytes(), compresslevel=9)
    tmp.replace(zip_path)
    shutil.copyfile(src / "build_web.json", out / "build_web.json")
    print(f"Wrote {zip_path} ({zip_path.stat().st_size} bytes) and {out / 'build_web.json'}")


main()
