# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Tests of patches/_lib/anchor.py, the anchor engine of the patch scripts:
an anchor found other than the times it must leaves every file as it was
and every failure is reported, the marker makes a second run a no-op, new
files are refreshed or refused, and the command line checks without
writing. Also parses every patch script with the grammar of Python 3.8,
the Python of the Linux build image.

Usage: python3 -B verify/tests/patches/anchor_engine_test.py
"""
from __future__ import annotations

import ast
import contextlib
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'patches' / '_lib'))
import anchor  # noqa: E402
from anchor import ALL, ANY, FIRST, Patch  # noqa: E402

MARKER = 'MAK_TEST_PATCH_V1'


class EngineTest(unittest.TestCase):
    def setUp(self):
        # The engine's messages, which the runner does not need.
        quiet = contextlib.ExitStack()
        quiet.enter_context(contextlib.redirect_stdout(io.StringIO()))
        quiet.enter_context(contextlib.redirect_stderr(io.StringIO()))
        self.addCleanup(quiet.close)
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / 'a.c').write_text('int a;\nint b;\n')
        (self.root / 'sub').mkdir()
        (self.root / 'sub' / 'b.c').write_text('void f(void);\n')

    def tearDown(self):
        self.tmp.cleanup()

    def patch(self, **kw):
        return Patch(self.root, 'patch_test', marker=MARKER,
                     here=self.root, **kw)

    def read(self, rel):
        return (self.root / rel).read_text()

    def test_edit_writes_at_commit(self):
        p = self.patch()
        self.assertTrue(p.edit('a.c', 'int b;\n', f'int b; // {MARKER}\n'))
        self.assertEqual(self.read('a.c'), 'int a;\nint b;\n')
        self.assertEqual(p.commit(), 0)
        self.assertEqual(self.read('a.c'), f'int a;\nint b; // {MARKER}\n')

    def test_a_missing_anchor_writes_no_file(self):
        p = self.patch()
        p.edit('a.c', 'int a;\n', 'int a = 1;\n')
        p.new_file('sub/new.c', f'/* {MARKER} */\n')
        p.edit('sub/b.c', 'void g(void);\n', 'void h(void);\n')
        self.assertEqual(p.commit(), 1)
        self.assertEqual(self.read('a.c'), 'int a;\nint b;\n')
        self.assertFalse((self.root / 'sub' / 'new.c').exists())
        self.assertEqual(len(p.errors), 1)
        self.assertIn('sub/b.c', p.errors[0])

    def test_every_failure_is_reported(self):
        p = self.patch()
        p.edit('a.c', 'int c;\n', '')
        p.edit('sub/b.c', 'void g(void);\n', '')
        p.edit('missing.c', 'x', 'y')
        self.assertEqual(p.commit(), 1)
        self.assertEqual(len(p.errors), 4)  # missing.c: not found, and its anchor
        self.assertTrue(any('missing.c not found' in e for e in p.errors))

    def test_a_repeated_anchor_fails(self):
        p = self.patch()
        self.assertFalse(p.edit('a.c', 'int ', 'long '))
        self.assertIn('found 2 times, expected 1', p.errors[0])
        p = self.patch()
        self.assertTrue(p.edit('a.c', 'int ', 'long ', times=2))
        self.assertEqual(p.text('a.c'), 'long a;\nlong b;\n')

    def test_first_all_and_any(self):
        p = self.patch()
        self.assertTrue(p.edit('a.c', 'int ', 'long ', times=FIRST))
        self.assertEqual(p.text('a.c'), 'long a;\nint b;\n')
        self.assertFalse(p.edit('a.c', 'char ', '', times=FIRST))
        p = self.patch()
        self.assertTrue(p.regex('a.c', r'int', 'long', times=ALL))
        self.assertEqual(p.text('a.c'), 'long a;\nlong b;\n')
        self.assertFalse(p.edit('a.c', 'char ', '', times=ALL))
        p = self.patch()
        self.assertTrue(p.edit('a.c', 'char ', 'x', times=ANY))
        self.assertTrue(p.edit('a.c', 'int ', 'long ', times=ANY))
        self.assertEqual(p.text('a.c'), 'long a;\nlong b;\n')

    def test_find_replaces_nothing(self):
        p = self.patch()
        self.assertTrue(p.find('a.c', 'int b;\n'))
        self.assertFalse(p.find('a.c', 'int '))
        self.assertEqual(p.text('a.c'), 'int a;\nint b;\n')
        self.assertEqual(len(p.errors), 1)
        self.assertEqual([a['label'] for a in p.anchors], ['int b;', 'int'])

    def test_edits_skip_a_marked_file(self):
        edits = [('int a;\n', f'int a; // {MARKER}\n'),
                 ('b label', 'int b;\n', 'int bb;\n')]
        p = self.patch()
        self.assertTrue(p.edits('a.c', edits))
        self.assertEqual(p.commit(), 0)
        after = self.read('a.c')
        p = self.patch()
        self.assertFalse(p.edits('a.c', edits))
        self.assertEqual(p.commit(), 0)
        self.assertEqual(self.read('a.c'), after)
        # Another marker of the same file is not this group's.
        p = self.patch()
        self.assertTrue(p.edits('a.c', [('int bb;\n', 'int c;\n')],
                                marker='MAK_OTHER'))

    def test_regex(self):
        p = self.patch()
        self.assertTrue(p.regex('a.c', r'int (\w);', r'long \1;', times=2))
        self.assertEqual(p.text('a.c'), 'long a;\nlong b;\n')
        # A function's result is not escape-processed: \\n stays as is.
        self.assertTrue(p.regex('a.c', r'long (a);', lambda m: 'x\\n;'))
        self.assertEqual(p.text('a.c'), 'x\\n;\nlong b;\n')
        self.assertEqual(p.errors, [])

    def test_regex_count(self):
        p = self.patch()
        self.assertFalse(p.regex('a.c', r'int \w;', 'x'))
        self.assertIn('found 2 times', p.errors[0])
        p = self.patch()
        self.assertTrue(p.regex('a.c', r'int \w;', 'x', times=FIRST))
        self.assertEqual(p.text('a.c'), 'x\nint b;\n')

    def test_optional(self):
        p = self.patch()
        self.assertTrue(p.optional('a.c', [('int c;\n', 'no'),
                                           ('int ', 'no'),
                                           ('int b;\n', 'int b2;\n')], 'b'))
        self.assertEqual(p.text('a.c'), 'int a;\nint b2;\n')
        self.assertFalse(p.optional('a.c', [('int c;\n', '')], 'c'))
        self.assertIn('none of the forms of (c)', p.errors[0])

    def test_new_file(self):
        content = f'/* {MARKER} */\nint x;\n'
        p = self.patch()
        p.new_file('dir/new.c', content)
        self.assertEqual(p.commit(), 0)
        self.assertEqual(self.read('dir/new.c'), content)
        # Equal: no write. Marked and older: refreshed.
        (self.root / 'dir' / 'new.c').write_text(f'/* {MARKER} */\nint old;\n')
        p = self.patch()
        p.new_file('dir/new.c', content)
        self.assertEqual(p.commit(), 0)
        self.assertEqual(self.read('dir/new.c'), content)
        # Someone else's file: refused, unless forced.
        p = self.patch()
        p.new_file('a.c', content)
        self.assertEqual(p.commit(), 1)
        self.assertEqual(self.read('a.c'), 'int a;\nint b;\n')
        p = self.patch()
        p.new_file('a.c', content, force=True)
        self.assertEqual(p.commit(), 0)
        self.assertEqual(self.read('a.c'), content)

    def test_replace_file(self):
        p = self.patch()
        p.replace_file('a.c', 'stub\n')
        p.replace_file('none.c', 'stub\n')
        self.assertEqual(p.commit(), 1)
        self.assertEqual(self.read('a.c'), 'int a;\nint b;\n')
        p = self.patch()
        p.replace_file('a.c', 'stub\n')
        self.assertEqual(p.commit(), 0)
        self.assertEqual(self.read('a.c'), 'stub\n')

    def test_check_writes_nothing(self):
        p = self.patch(check=True)
        self.assertTrue(p.edit('a.c', 'int a;\n', 'int z;\n'))
        self.assertEqual(p.commit(), 0)
        self.assertEqual(self.read('a.c'), 'int a;\nint b;\n')

    def test_the_mode_is_kept(self):
        f = self.root / 'configure'
        f.write_text('#!/bin/sh\necho a\n')
        f.chmod(0o755)
        p = self.patch()
        p.edit('configure', 'echo a\n', 'echo b\n')
        self.assertEqual(p.commit(), 0)
        self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o755)

    def test_asset(self):
        (self.root / 'insert.c').write_text('int inserted;\n')
        self.assertEqual(self.patch().asset('insert.c'), 'int inserted;\n')


SCRIPT = '''
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, {lib!r})
import anchor

def apply(p, extra):
    p.edit('a.c', 'int a;\\n', 'int a; // ' + extra + '\\n', 'a')
    p.edit('a.c', 'int b;\\n', 'int b2;\\n')

anchor.main(apply, 'patch_cli', marker='MAK_CLI', usage='<dir> <extra>',
            nargs=2)
'''


class CommandLineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.src = self.root / 'src'
        self.src.mkdir()
        (self.src / 'a.c').write_text('int a;\nint b;\n')
        self.script = self.root / 'patch_cli.py'
        self.script.write_text(SCRIPT.format(lib=str(ROOT / 'patches' / '_lib')))

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args):
        return subprocess.run([sys.executable, '-B', str(self.script), *args],
                              capture_output=True, text=True)

    def test_check_and_list(self):
        r = self.run_script(str(self.src), 'MAK_CLI', '--list-anchors')
        self.assertEqual(r.returncode, 0, r.stderr)
        anchors = json.loads(r.stdout)
        self.assertEqual([a['label'] for a in anchors], ['a', 'int b;'])
        self.assertEqual(anchors[1]['anchor'], 'int b;\n')
        r = self.run_script(str(self.src), 'MAK_CLI', '--check')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.src / 'a.c').read_text(), 'int a;\nint b;\n')

    def test_apply_then_already(self):
        r = self.run_script(str(self.src), 'MAK_CLI')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.src / 'a.c').read_text(),
                         'int a; // MAK_CLI\nint b2;\n')

    def test_failure_and_usage(self):
        (self.src / 'a.c').write_text('int c;\n')
        r = self.run_script(str(self.src), 'MAK_CLI', '--check')
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stderr.count('found 0 times'), 2)
        r = self.run_script(str(self.src))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('usage: patch_cli.py <dir> <extra>', r.stderr)


class GrammarTest(unittest.TestCase):
    def test_python_38(self):
        scripts = sorted((ROOT / 'patches').rglob('*.py'))
        self.assertTrue(scripts)
        for path in scripts:
            with self.subTest(path=str(path.relative_to(ROOT))):
                ast.parse(path.read_text(), str(path), feature_version=(3, 8))


if __name__ == '__main__':
    os.environ.setdefault('PYTHONDONTWRITEBYTECODE', '1')
    unittest.main(verbosity=1)
