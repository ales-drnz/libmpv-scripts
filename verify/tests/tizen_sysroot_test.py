# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Tests of scripts/tizen/tizen_sysroot.py without the network: the RPM
payload and its cpio archive are unpacked whole (a hard link gets the
data of the last of its names, an absolute symlink points inside the
sysroot), the fix-ups give the asm headers and the start files, and a
package missing from the lock or with another checksum stops the build.

Usage: python3 -B verify/tests/tizen_sysroot_test.py
"""
import gzip
import importlib.util
import lzma
import os
import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    'tizen_sysroot', ROOT / 'scripts/tizen/tizen_sysroot.py')
ts = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(ts)


def cpio(entries):
    """A newc archive of (name, mode, ino, nlink, data) entries."""
    out = b''
    for name, mode, ino, nlink, data in entries + [('TRAILER!!!', 0, 0, 1, b'')]:
        raw = name.encode() + b'\0'
        fields = [ino, mode, 0, 0, nlink, 0, len(data), 0, 0, 0, 0, len(raw), 0]
        out += b'070701' + b''.join(b'%08x' % f for f in fields) + raw
        out += b'\0' * (-len(out) % 4) + data
        out += b'\0' * (-len(out) % 4)
    return out


def rpm(payload):
    """An RPM: the lead, an empty signature header, an empty header."""
    header = b'\x8e\xad\xe8\x01' + b'\0' * 4 + struct.pack('>II', 0, 0)
    return b'\0' * 96 + header + header + payload


class Unpack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def unpack(self, entries, compress=lzma.compress):
        ts.unpack_cpio(ts.rpm_payload(rpm(compress(cpio(entries)))), self.root)

    def test_files_dirs_and_modes(self):
        self.unpack([('./usr/lib', 0o040755, 1, 2, b''),
                     ('./usr/lib/libc.so.6', 0o100755, 2, 1, b'ELF')])
        lib = self.root / 'usr/lib/libc.so.6'
        self.assertEqual(lib.read_bytes(), b'ELF')
        self.assertTrue(os.access(lib, os.X_OK))

    def test_gzip_payload(self):
        self.unpack([('./a', 0o100644, 1, 1, b'x')], gzip.compress)
        self.assertEqual((self.root / 'a').read_bytes(), b'x')

    def test_hard_link_gets_the_data_of_its_last_name(self):
        self.unpack([('./usr/bin/gcc', 0o100755, 7, 2, b''),
                     ('./usr/bin/cc', 0o100755, 7, 2, b'compiler')])
        self.assertEqual((self.root / 'usr/bin/gcc').read_bytes(), b'compiler')
        self.assertEqual((self.root / 'usr/bin/cc').read_bytes(), b'compiler')

    def test_absolute_symlink_stays_in_the_sysroot(self):
        self.unpack([('./lib/libc.so.6', 0o100644, 1, 1, b'ELF'),
                     ('./usr/lib/libc.so', 0o120777, 2, 1, b'/lib/libc.so.6')])
        link = self.root / 'usr/lib/libc.so'
        self.assertEqual(os.readlink(link), '../../lib/libc.so.6')
        self.assertEqual(link.read_bytes(), b'ELF')

    def test_not_an_rpm(self):
        with self.assertRaises(SystemExit):
            ts.rpm_payload(b'\0' * 200)

    def test_fix_up(self):
        gcc = self.root / 'usr/lib/gcc/armv7l-tizen-linux-gnueabi/9.2.0'
        gcc.mkdir(parents=True)
        (gcc / 'crtbeginS.o').write_bytes(b'o')
        (gcc / 'libgcc.a').write_bytes(b'a')
        (self.root / 'usr/include').mkdir(parents=True)
        ts.fix_up(self.root, 'armv7l')
        self.assertEqual(os.readlink(self.root / 'usr/include/asm'), 'asm-arm')
        self.assertEqual((self.root / 'usr/lib/crtbeginS.o').read_bytes(), b'o')
        self.assertEqual((self.root / 'usr/lib/libgcc.a').read_bytes(), b'a')

    def test_fix_up_x86_64_is_lib64(self):
        gcc = self.root / 'usr/lib64/gcc/x86_64-tizen-linux-gnu/9.2.0'
        gcc.mkdir(parents=True)
        (gcc / 'crtbeginS.o').write_bytes(b'o')
        (self.root / 'usr/include').mkdir(parents=True)
        ts.fix_up(self.root, 'x86_64')
        self.assertEqual(os.readlink(self.root / 'usr/include/asm'), 'asm-x86')
        self.assertEqual((self.root / 'usr/lib64/crtbeginS.o').read_bytes(), b'o')


class Lock(unittest.TestCase):
    def test_every_package_of_both_arches_is_locked(self):
        lock = ts.read_lock()
        for arch in ts.ARCHES:
            for kind, names in ts.PACKAGES.items():
                for name in names:
                    self.assertTrue(
                        any(rel.startswith(f'{arch}:{kind}/{arch}/{name}-') for rel in lock),
                        f'{arch} {name} is not in the lock')

    def test_a_package_with_another_checksum_stops_the_build(self):
        loc = 'armv7l/glibc-2.30-1.15.armv7l.rpm'
        index = {name: (f'armv7l/{name}-0.armv7l.rpm', 'f' * 64)
                 for names in ts.PACKAGES.values() for name in names}
        index['glibc'] = (loc, '0' * 64)
        saved = ts.primary, ts.fetch
        ts.primary = lambda kind, arch: index
        ts.fetch = lambda url: self.fail('fetched ' + url)
        argv = sys.argv
        with tempfile.TemporaryDirectory() as out:
            sys.argv = ['tizen_sysroot.py', 'armv7l', out]
            try:
                with self.assertRaises(SystemExit) as stop:
                    ts.main()
            finally:
                sys.argv = argv
                ts.primary, ts.fetch = saved
        self.assertIn('not in tizen_sysroot.sha256', str(stop.exception))


if __name__ == '__main__':
    unittest.main()
