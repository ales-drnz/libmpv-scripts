# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Read an fd://N of a regular file at each stream's own position.

An Android content:// URI reaches mpv as fd://N (or fdclose://N), and every
open of that entry reads the same descriptor: the current file and its
prefetch (a one-entry playlist in a loop), or two players of one source.
stream_file.c reads it with read() and seeks with lseek(), so all of them
share the one offset the kernel keeps for the open file description, and
each open moves it back to 0. A stream then read where another had left
it: wrong bytes, or nothing at all when the other had read to the end, and
the file ended early.

This patch gives such a stream its own position: fill_buffer() reads with
pread() at it, seek() only sets it, and the open no longer moves the
shared offset to test seeking (a regular file seeks). A pipe, a socket,
stdin, a path, Windows and writes keep read(), write() and lseek().

Usage: patch_fd_pread.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_lib"))
import anchor  # noqa: E402

MARKER = "MAK_FD_PREAD_PATCH_V1"

PRIV = (
    "struct priv fields",
    "    bool appending;\n"
    "    int64_t orig_size;\n",
    "    bool appending;\n"
    "    int64_t orig_size;\n"
    f"    // {MARKER}: an fd://N of a regular file is read with\n"
    "    // pread() at pos, the stream's own position.\n"
    "    bool use_pread;\n"
    "    int64_t pos;\n",
)

READ = (
    "fill_buffer",
    "static int fill_buffer(stream_t *s, void *buffer, int max_len)\n",
    "static int read_fd(struct priv *p, void *buffer, int max_len)\n"
    "{\n"
    "#ifndef _WIN32\n"
    "    if (p->use_pread) {\n"
    "        ssize_t r = pread(p->fd, buffer, max_len, p->pos);\n"
    "        if (r > 0)\n"
    "            p->pos += r;\n"
    "        return r;\n"
    "    }\n"
    "#endif\n"
    "    return read(p->fd, buffer, max_len);\n"
    "}\n"
    "\n"
    "static int fill_buffer(stream_t *s, void *buffer, int max_len)\n",
)

READ_CALL = (
    "read in fill_buffer",
    "        int r = read(p->fd, buffer, max_len);\n",
    "        int r = read_fd(p, buffer, max_len);\n",
)

SEEK = (
    "seek",
    "    return lseek(p->fd, newpos, SEEK_SET) != (off_t)-1;\n",
    "    if (p->use_pread) {\n"
    "        p->pos = newpos;\n"
    "        return 1;\n"
    "    }\n"
    "    return lseek(p->fd, newpos, SEEK_SET) != (off_t)-1;\n",
)

OPEN = (
    "seekable test of open",
    "    off_t len = lseek(p->fd, 0, SEEK_END);\n"
    "    lseek(p->fd, 0, SEEK_SET);\n",
    f"    // {MARKER}: other streams may read this fd://N, so the\n"
    "    // shared offset is left alone. A regular file seeks.\n"
    "    off_t len = 0;\n"
    "#ifndef _WIN32\n"
    "    p->use_pread = (strncmp(url, \"fd://\", 5) == 0 || is_fdclose) &&\n"
    "                   p->regular_file && !write;\n"
    "#endif\n"
    "    if (!p->use_pread) {\n"
    "        len = lseek(p->fd, 0, SEEK_END);\n"
    "        lseek(p->fd, 0, SEEK_SET);\n"
    "    }\n",
)


def apply(p):
    p.edits("stream/stream_file.c", [PRIV, READ, READ_CALL, SEEK, OPEN])


anchor.main(apply, "patch_fd_pread", marker=MARKER)
