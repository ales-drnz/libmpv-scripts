#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
A refused connect fails at once on Windows.

Without poll.h (MinGW), FFmpeg's network code calls ff_poll(), a poll()
made of select(). It puts a socket in select's exception set only when
the caller asks for POLLERR. Winsock reports a non-blocking connect()
that failed (a port nothing listens on, a host that refuses) in the
exception set only: the socket never turns writable. A caller waiting
for POLLOUT, as ff_listen_connect(), the parallel connect of
ff_connect_parallel() and the libsmb2 protocol (smb2_which_events() while
connecting) do, so waits until its timeout: 60 s for each try of an
http:// entry with mpv's network-timeout, which the reconnect options
repeat, and the whole connect timeout for smb2://. poll() reports POLLERR
whatever the events asked for.

This patch adds a socket waited on for POLLOUT to the exception set on
Winsock, so the failure comes back as POLLERR in the next select(). The
callers read SO_ERROR on any event (ff_listen_connect,
ff_connect_parallel), or handle POLLERR (libsmb2's smb2_service), and
fail with the connect's error, ECONNREFUSED. A connect that succeeds is
not in the exception set, and a socket that is connected only lands
there with out-of-band data, which no caller asks for and which reads as
ready, as POLLOUT would.

Every platform runs it, as the build applies the same FFmpeg patches; the
code it adds builds only with winsock2.h. Not user-gated: a defect of the
poll emulation.

MARKER-guarded: MAK_WINSOCK_POLL_V1 in the inserted hunk.

Usage:
    python3 patch_ffmpeg_winsock_poll.py <ffmpeg_src_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402


MARKER = 'MAK_WINSOCK_POLL_V1'

OS_SUPPORT = 'libavformat/os_support.c'

# The events ff_poll() turns into select's sets.
SETS = (
    '        if (fds[i].events & POLLERR)\n'
    '            FD_SET(fds[i].fd, &exception_set);\n'
)

SETS_NEW = SETS + (
    '#if HAVE_WINSOCK2_H\n'
    '        /* ' + MARKER + ': Winsock reports a connect() that failed\n'
    '         * in the exception set only, and poll() reports it as POLLERR\n'
    '         * whatever the events asked for. */\n'
    '        if (fds[i].events & POLLOUT)\n'
    '            FD_SET(fds[i].fd, &exception_set);\n'
    '#endif\n'
)


def apply(p):
    p.edits(OS_SUPPORT, [
        ('the sets of ff_poll', SETS, SETS_NEW),
    ])


anchor.main(apply, 'patch_ffmpeg_winsock_poll', marker=MARKER,
            usage='<ffmpeg_src_dir>')
