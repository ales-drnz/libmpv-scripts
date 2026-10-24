# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""The anchor engine of the patch scripts.

A patch script edits upstream sources by anchors: strings that must be
found in the pristine file, replaced with the patched text. The engine
holds every file the script touches in memory, checks each anchor as it
is used, and writes the files only at the end, when every check passed.
A missing or repeated anchor (the upstream layout changed) leaves the
tree as it was, and every failure is reported, not only the first.

A script builds its edits on a Patch and hands its apply function to
main():

    def apply(p):
        p.edits('player/command.c', [(old, new), ...])

    anchor.main(apply, 'patch_example', marker='MAK_EXAMPLE_PATCH_V1')

Idempotence comes from the marker that the patched text carries: edits()
leaves a file that has it, so a second run changes nothing. New files
carry it too, which lets a second run refresh them and refuse a file of
someone else.

Command line of every script: <source> [arguments] [--check]
[--list-anchors]. --check runs every check and writes nothing;
--list-anchors does the same and prints the anchors used, in JSON, for
the tests that break them one at a time.

Kept to Python 3.8: the Linux build image is Ubuntu 20.04.
"""
from __future__ import annotations

import inspect
import json
import re
import sys
from pathlib import Path

# times= of edit() and regex(): found at least once, the first replaced.
FIRST = 'first'
# times= of edit() and regex(): found any number of times, all replaced.
ANY = 'any'


def _label(anchor) -> str:
    """The first line of an anchor that has one, for the messages."""
    if not isinstance(anchor, str):
        anchor = anchor.pattern
    lines = [line for line in anchor.splitlines() if line.strip()]
    return (lines[0] if lines else anchor).strip()


class _File:
    def __init__(self, disk):
        self.disk = disk   # the text on disk, None when there is no file
        self.text = disk   # the text with the edits so far


class Patch:
    """The files a patch script edits, held in memory until commit()."""

    def __init__(self, root, name, marker=None, here=None, check=False):
        self.root = Path(root)
        self.name = name
        self.marker = marker
        self.here = Path(here) if here is not None else None
        self.check = check
        self.errors = []
        self.anchors = []
        self._files = {}

    # ── files ──────────────────────────────────────────────────────────

    def path(self, rel) -> Path:
        return self.root / rel

    def _file(self, rel) -> _File:
        f = self._files.get(rel)
        if f is None:
            path = self.path(rel)
            disk = None
            if path.is_file():
                with open(path, encoding='utf-8') as fh:
                    disk = fh.read()
            f = self._files[rel] = _File(disk)
        return f

    def exists(self, rel) -> bool:
        return self._file(rel).text is not None

    def text(self, rel) -> str:
        """The text of rel with the edits so far. A missing file is an
        error, and reads as empty so the checks that follow fail too."""
        f = self._file(rel)
        if f.text is None:
            self.fail(f'{rel} not found')
            return ''
        return f.text

    def write(self, rel, text) -> None:
        """Sets the whole text of rel, a file that exists or a new one."""
        self._file(rel).text = text

    def marked(self, rel, marker=None) -> bool:
        """Whether rel exists and carries marker (the patch's by default)."""
        marker = marker or self.marker
        return self.exists(rel) and marker in self._file(rel).text

    def asset(self, name) -> str:
        """A file shipped next to the script, such as a C source it copies
        or splices in."""
        with open(self.here / name, encoding='utf-8') as fh:
            return fh.read()

    # ── edits ──────────────────────────────────────────────────────────

    def fail(self, message) -> None:
        self.errors.append(message)

    def _count_ok(self, n, times) -> bool:
        if times == FIRST:
            return n >= 1
        if times == ANY:
            return True
        return n == times

    def edit(self, rel, anchor, new, label=None, times=1) -> bool:
        """Replaces anchor with new in rel. The anchor must be found
        exactly times times, all replaced; FIRST asks for at least one and
        replaces the first, ANY takes any number and replaces them all."""
        text = self.text(rel)
        label = label or _label(anchor)
        self.anchors.append({'file': rel, 'label': label, 'kind': 'edit',
                             'anchor': anchor})
        n = text.count(anchor)
        if not self._count_ok(n, times):
            self.fail(f'{rel}: anchor ({label}) found {n} times, '
                      f'expected {times}')
            return False
        if n:
            count = 1 if times == FIRST else -1
            self.write(rel, text.replace(anchor, new, count))
        return True

    def edits(self, rel, edits, marker=None) -> bool:
        """Applies each edit, (anchor, new) or (label, anchor, new), unless
        rel already carries the marker. Returns whether it edited."""
        if self.marked(rel, marker):
            print(f'Already patched: {rel}')
            return False
        for e in edits:
            label, anchor, new = e if len(e) == 3 else (None,) + tuple(e)
            self.edit(rel, anchor, new, label)
        return True

    def regex(self, rel, pattern, repl, label=None, times=1, flags=0) -> bool:
        """edit() with a regular expression: re.subn with repl (a string
        with group references, or a function)."""
        text = self.text(rel)
        rx = re.compile(pattern, flags) if isinstance(pattern, str) else pattern
        label = label or _label(rx)
        self.anchors.append({'file': rel, 'label': label, 'kind': 'regex',
                             'anchor': rx.pattern})
        n = sum(1 for _ in rx.finditer(text))
        if not self._count_ok(n, times):
            self.fail(f'{rel}: pattern ({label}) found {n} times, '
                      f'expected {times}')
            return False
        if n:
            text, _ = rx.subn(repl, text, count=1 if times == FIRST else 0)
            self.write(rel, text)
        return True

    def optional(self, rel, variants, label) -> bool:
        """Applies the first (anchor, new) of variants whose anchor is found
        exactly once: the forms a file takes with or without the patches
        that may have run before."""
        text = self.text(rel)
        for anchor, new in variants:
            self.anchors.append({'file': rel, 'label': label,
                                 'kind': 'optional', 'anchor': anchor})
            if text.count(anchor) == 1:
                self.write(rel, text.replace(anchor, new, 1))
                return True
        self.fail(f'{rel}: none of the forms of ({label}) found once')
        return False

    def new_file(self, rel, content, marker=None, force=False) -> None:
        """Creates rel with content. A file already there is left when it
        is equal, refreshed when it carries the marker (an older copy of
        this patch) or with force, and refused otherwise."""
        if self.exists(rel):
            old = self._file(rel).text
            if old == content:
                return
            marker = marker or self.marker
            if not force and not (marker and marker in old):
                self.fail(f'{rel}: refusing to overwrite a file this patch '
                          f'did not write')
                return
        self.write(rel, content)

    def replace_file(self, rel, content) -> None:
        """Replaces the whole of the upstream file rel, which must exist,
        with content (a stub of a translation unit)."""
        if not self.exists(rel):
            self.fail(f'{rel} not found')
            return
        self.write(rel, content)

    # ── end ────────────────────────────────────────────────────────────

    def commit(self) -> int:
        """Writes every changed file if no check failed, and returns the
        exit status. With check set it writes nothing."""
        if self.errors:
            for e in self.errors:
                print(f'{self.name}: {e}', file=sys.stderr)
            print(f'{self.name}: {len(self.errors)} error(s), no file written',
                  file=sys.stderr)
            return 1
        if self.check:
            print(f'{self.name}: every check passed, no file written',
                  file=sys.stderr)
            return 0
        for rel, f in self._files.items():
            if f.text is None or f.text == f.disk:
                continue
            path = self.path(rel)
            path.parent.mkdir(parents=True, exist_ok=True)
            # In place, so the file keeps its mode (configure is executable).
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(f.text)
            print(f'{"Created" if f.disk is None else "Patched"}: {path}')
        return 0


def main(apply, name, marker=None, usage='<source dir>', nargs=1,
         file_arg=False) -> None:
    """The command line of a patch script: runs apply(p, *arguments) on a
    Patch of the source directory and commits it. With file_arg the first
    argument is a file, and apply gets its name relative to its directory
    as the first argument."""
    argv = sys.argv[1:]
    check = '--check' in argv
    listing = '--list-anchors' in argv
    args = [a for a in argv if a not in ('--check', '--list-anchors')]
    if len(args) != nargs:
        sys.exit(f'usage: {name}.py {usage} [--check] [--list-anchors]')
    first = Path(args[0])
    here = Path(inspect.getfile(apply)).resolve().parent
    if file_arg:
        p = Patch(first.parent, name, marker, here, check or listing)
        rest = [first.name] + args[1:]
    else:
        if not first.is_dir():
            sys.exit(f'{name}: {first} is not a directory')
        p = Patch(first, name, marker, here, check or listing)
        rest = args[1:]
    apply(p, *rest)
    if listing:
        json.dump(p.anchors, sys.stdout, indent=1)
        print()
    sys.exit(p.commit())
