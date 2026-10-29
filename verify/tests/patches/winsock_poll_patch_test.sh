#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patches/ffmpeg/patch_ffmpeg_winsock_poll.py on pristine FFmpeg: it
# applies, a second run changes nothing, and in ff_poll() a socket waited on
# for POLLOUT goes into the exception set on Winsock only, before the
# select() that reads it back as POLLERR. Whether a refused connect then fails
# at once is checked on Windows by the kit's tests of a refused http:// and
# smb2:// open (Check mpv_audio_kit).
#
# Usage: bash verify/tests/patches/winsock_poll_patch_test.sh <pristine ffmpeg source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REF="${1:?usage: winsock_poll_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
T="${2:?usage: winsock_poll_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
P="$ROOT/patches/ffmpeg/patch_ffmpeg_winsock_poll.py"
F=libavformat/os_support.c
rm -rf "$T"; mkdir -p "$T/ok/libavformat"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

# The premise: pristine ff_poll() puts a socket in the exception set for
# POLLERR only, and maps the exception set to POLLERR.
python3 - "$REF/$F" <<'PY'
import sys
t = open(sys.argv[1]).read()
body = t[t.index('int ff_poll('):]
body = body[:body.index('\n}\n')]
assert body.count('&exception_set);') == 2, 'FD_SET into the exception set'
assert 'if (fds[i].events & POLLERR)\n            FD_SET(fds[i].fd, &exception_set);' in body
assert 'FD_ISSET(fds[i].fd, &exception_set))\n            fds[i].revents |= POLLERR;' in body
PY
check $? "pristine ff_poll: the exception set for POLLERR only, read back as POLLERR"

cp "$REF/$F" "$T/ok/$F"
python3 -B "$P" "$T/ok" > "$T/ok.log" 2>&1; check $? "pristine: the patch applies"
python3 - "$T/ok/$F" <<'PY'
import re, sys
t = open(sys.argv[1]).read()
body = t[t.index('int ff_poll('):]
body = body[:body.index('\n}\n')]
m = re.search(r'#if HAVE_WINSOCK2_H\n(?:\s*(?:/\*|\*).*\n)*'
              r'\s*if \(fds\[i\]\.events & POLLOUT\)\n'
              r'\s*FD_SET\(fds\[i\]\.fd, &exception_set\);\n#endif\n', body)
assert m, 'POLLOUT into the exception set under HAVE_WINSOCK2_H'
assert 'MAK_WINSOCK_POLL_V1' in m.group(0)
assert m.start() < body.index('select('), 'before the select()'
PY
check $? "patched: POLLOUT goes into the exception set on Winsock, before select()"
cp -a "$T/ok" "$T/ok.before"
python3 -B "$P" "$T/ok" > /dev/null 2>&1; check $? "pristine: a second run applies"
diff -r "$T/ok.before" "$T/ok" > /dev/null; check $? "pristine: a second run changes nothing"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
