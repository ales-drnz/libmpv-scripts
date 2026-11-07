#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Builds the sysroot of the Tizen build from Tizen 6.0 packages.

The TV rootstraps of the Tizen SDK are not public. The packages of the
Tizen 6.0 snapshots on download.tizen.org are, and a TV from 2021 on
runs the same glibc 2.30, libgcc and libstdc++ (GCC 9.2): the C and C++
runtimes, the kernel headers and the two audio APIs ao_tizen uses, in one tree
that clang takes as --sysroot. flutter-tizen's embedder builds its
sysroot the same way (tools/generate_sysroot.py).

pkg-config reads the .pc files as they are, with PKG_CONFIG_SYSROOT_DIR
set to the sysroot.

The snapshots are pinned, and every package is checked against its
SHA-256 in tizen_sysroot.sha256: a package that changed stops the build.
--update writes that file from the snapshots' repodata.

Usage: tizen_sysroot.py <armv7l|i686> <out dir> [--update]
"""
import gzip
import hashlib
import lzma
import bz2
import os
import re
import shutil
import struct
import sys
import urllib.request
from pathlib import Path

sys.dont_write_bytecode = True

SITE = 'http://download.tizen.org/snapshots/TIZEN/Tizen-6.0'
SNAPSHOTS = {
    'base': 'Tizen-6.0-Base/tizen-6.0-base_20250219.050947',
    'unified': 'Tizen-6.0-Unified/tizen-6.0-unified_20251113.061353',
}
# The C runtime, libgcc and libstdc++ (libplacebo has C++) come from Base; the audio APIs from Unified,
# whose x86 packages are in the emulator repository.
PACKAGES = {
    'base': ['gcc', 'glibc', 'glibc-devel', 'libgcc', 'libstdc++', 'libstdc++-devel',
             'linux-glibc-devel'],
    'unified': [
        'capi-base-common', 'capi-base-common-devel',
        'capi-media-audio-io', 'capi-media-audio-io-devel',
        'capi-media-sound-manager', 'capi-media-sound-manager-devel',
    ],
}
ARCHES = ('armv7l', 'i686')
LOCK = Path(__file__).with_name('tizen_sysroot.sha256')


def repo(kind, arch):
    target = 'emulator' if kind == 'unified' and arch == 'i686' else 'standard'
    return f'{SITE}/{SNAPSHOTS[kind]}/repos/{target}/packages'


def fetch(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()


def primary(kind, arch):
    """name -> (location, sha256) of the repository's packages for arch."""
    base = repo(kind, arch)
    repomd = fetch(f'{base}/repodata/repomd.xml').decode()
    m = re.search(r'<data type="primary">.*?<checksum type="sha256">(\w+)</checksum>'
                  r'.*?<location href="([^"]+)"', repomd, re.S)
    if not m:
        sys.exit(f'no primary in {base}/repodata/repomd.xml')
    data = fetch(f'{base}/{m.group(2)}')
    if hashlib.sha256(data).hexdigest() != m.group(1):
        sys.exit(f'{m.group(2)}: checksum does not match repomd.xml')
    xml = gzip.decompress(data).decode()
    out = {}
    for pkg in re.findall(r'<package type="rpm">(.*?)</package>', xml, re.S):
        name = re.search(r'<name>([^<]+)</name>', pkg).group(1)
        parch = re.search(r'<arch>([^<]+)</arch>', pkg).group(1)
        if parch not in (arch, 'noarch'):
            continue
        sha = re.search(r'<checksum type="sha256"[^>]*>(\w+)</checksum>', pkg).group(1)
        loc = re.search(r'<location href="([^"]+)"', pkg).group(1)
        out[name] = (loc, sha)
    return out


def read_lock():
    lock = {}
    if LOCK.exists():
        for line in LOCK.read_text().splitlines():
            if line and not line.startswith('#'):
                sha, rel = line.split()
                lock[rel] = sha
    return lock


def rpm_payload(data):
    """The cpio archive inside an RPM: past the lead and both headers."""
    def header_end(off):
        if data[off:off + 3] != b'\x8e\xad\xe8':
            sys.exit('not an RPM header')
        count, size = struct.unpack('>II', data[off + 8:off + 16])
        return off + 16 + count * 16 + size
    off = header_end(96)
    off = header_end((off + 7) // 8 * 8)
    payload = data[off:]
    if payload[:6] == b'\xfd7zXZ\x00':
        return lzma.decompress(payload)
    if payload[:2] == b'\x1f\x8b':
        return gzip.decompress(payload)
    if payload[:3] == b'BZh':
        return bz2.decompress(payload)
    sys.exit('unknown RPM payload compression')


def unpack_cpio(data, root):
    """Unpacks a newc cpio archive under root; symlinks become relative.
    The names of a hard link come first with no data, the last one has it."""
    links = {}
    off = 0
    while True:
        if data[off:off + 6] != b'070701':
            sys.exit('not a newc cpio archive')
        fields = [int(data[off + 6 + i * 8:off + 14 + i * 8], 16) for i in range(13)]
        ino, mode, nlink, filesize, namesize = fields[0], fields[1], fields[4], fields[6], fields[11]
        off += 110
        name = data[off:off + namesize - 1].decode()
        off = (off + namesize + 3) // 4 * 4
        body = data[off:off + filesize]
        off = (off + filesize + 3) // 4 * 4
        if name == 'TRAILER!!!':
            return
        path = root / name.lstrip('./')
        kind = mode & 0o170000
        if kind == 0o040000:
            path.mkdir(parents=True, exist_ok=True)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.is_symlink() or path.exists():
            path.unlink()
        if kind == 0o120000:
            target = body.decode()
            if target.startswith('/'):
                target = os.path.relpath(root / target.lstrip('/'), path.parent)
            path.symlink_to(target)
        elif kind == 0o100000:
            names = links.pop(ino, []) + [path] if nlink > 1 and filesize else [path]
            if nlink > 1 and not filesize:
                links.setdefault(ino, []).append(path)
            for target in names:
                target.write_bytes(body)
                target.chmod(mode & 0o755 | 0o600)


def fix_up(root, arch):
    """What the packages' install scripts would do, as the embedder does:
    the asm headers of the arch, and the start files and libgcc.a where
    the linker looks for them."""
    asm = root / 'usr/include/asm'
    if not asm.exists():
        asm.symlink_to('asm-arm' if arch == 'armv7l' else 'asm-x86')
    lib = root / 'usr/lib'
    for obj in sorted(lib.glob('gcc/*/*/*.[oa]')):
        shutil.copy2(obj, lib / obj.name)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    update = '--update' in sys.argv
    if len(args) != 2 or args[0] not in ARCHES:
        sys.exit(__doc__.strip().splitlines()[-1])
    arch, out = args[0], Path(args[1]).resolve()
    lock = read_lock()
    wanted = []
    for kind, names in PACKAGES.items():
        index = primary(kind, arch)
        for name in names:
            if name not in index:
                sys.exit(f'{name}: not in the {kind} snapshot for {arch}')
            loc, sha = index[name]
            wanted.append((kind, loc, sha))
    if update:
        keep = {rel: sha for rel, sha in lock.items() if not rel.startswith(f'{arch}:')}
        for kind, loc, sha in wanted:
            keep[f'{arch}:{kind}/{loc}'] = sha
        LOCK.write_text('# SHA-256 of the Tizen 6.0 packages of the sysroot, by tizen_sysroot.py --update\n'
                        + ''.join(f'{sha} {rel}\n' for rel, sha in sorted(keep.items())))
        print(f'{LOCK.name}: {len(wanted)} packages for {arch}')
        return
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for kind, loc, sha in wanted:
        rel = f'{arch}:{kind}/{loc}'
        if lock.get(rel) != sha:
            sys.exit(f'{rel}: not in {LOCK.name} with this checksum (--update after a review)')
        data = fetch(f'{repo(kind, arch)}/{loc}')
        if hashlib.sha256(data).hexdigest() != sha:
            sys.exit(f'{loc}: SHA-256 does not match')
        unpack_cpio(rpm_payload(data), out)
        print(f'unpacked {loc}')
    fix_up(out, arch)


if __name__ == '__main__':
    main()
