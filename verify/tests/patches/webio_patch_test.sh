#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patches/ffmpeg/patch_ffmpeg_webio.py on pristine FFmpeg: the three
# protocols declared where configure reads them, the object in the
# Makefile, webio.c copied, a second run without effect, and with either
# anchor missing it fails and writes no file.
#
# Usage: bash verify/tests/patches/webio_patch_test.sh <pristine ffmpeg source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REF="${1:?usage: webio_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
T="${2:?usage: webio_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
P="$ROOT/patches/ffmpeg/patch_ffmpeg_webio.py"
SRC="$ROOT/patches/ffmpeg/webio/webio.c"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
tree() { mkdir -p "$T/$1/libavformat"; cp "$REF"/libavformat/{Makefile,protocols.c} "$T/$1/libavformat/"; }
edit() { python3 - "$@" <<'PY'
import sys
p, old, new = sys.argv[1:]
t = open(p).read()
assert t.count(old) == 1, old
open(p, 'w').write(t.replace(old, new))
PY
}

# control: pristine tree.
tree ok
python3 -B "$P" "$T/ok" > "$T/ok.log" 2>&1; check $? "pristine: the patch applies"
# The protocol list configure builds (find_things_extern in configure).
protos="$(sed -n 's/^[^#]*extern.*URLProtocol *ff_\([^ ]*\)_protocol;/\1/p' "$T/ok/libavformat/protocols.c" | grep webio | tr '\n' ' ')"
[[ "$protos" == "webio_http webio_https webio_makblob " ]]; check $? "pristine: configure sees webio_http, webio_https, webio_makblob ($protos)"
[[ "$(grep -c '+= webio.o$' "$T/ok/libavformat/Makefile")" == 3 ]]; check $? "pristine: the Makefile builds webio.o for each"
cmp -s "$SRC" "$T/ok/libavformat/webio.c"; check $? "pristine: webio.c copied"
cp -a "$T/ok" "$T/ok.before"
python3 -B "$P" "$T/ok" > /dev/null 2>&1; check $? "pristine: a second run applies"
diff -r "$T/ok.before" "$T/ok" > /dev/null; check $? "pristine: a second run changes nothing"

# broken <name> <file> <anchor> <replacement>: with that anchor missing the
# patch fails and the tree stays as it was.
broken() {
  tree "$1"; edit "$T/$1/$2" "$3" "$4"
  cp -a "$T/$1" "$T/$1.before"
  python3 -B "$P" "$T/$1" > "$T/$1.log" 2>&1; local r=$?
  [[ $r != 0 ]]; check $? "$1: the patch fails (exit $r)"
  diff -r "$T/$1.before" "$T/$1" > /dev/null; check $? "$1: no file written"
}
broken protocols libavformat/protocols.c 'extern const URLProtocol ff_ipns_gateway_protocol;' \
  'extern const URLProtocol ff_ipns_protocol;'
broken makefile libavformat/Makefile 'OBJS-$(CONFIG_LIBZMQ_PROTOCOL)           += libzmq.o' \
  'OBJS-$(CONFIG_LIBZMQ_PROTOCOL) += libzmq.o'

echo
[[ $fails == 0 ]] && echo "webio_patch_test: all checks passed" || echo "webio_patch_test: $fails check(s) failed"
exit $(( fails > 0 ))
