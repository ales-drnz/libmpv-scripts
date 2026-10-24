#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Breaks one anchor of a patch script at a time, on the tree as the build
# hands it to that script, and checks that the script fails and writes no
# file: a moved upstream line must stop the build, not leave a tree patched
# halfway or skip the edit in silence.
#
# First three anchors that the scripts before the anchor engine got wrong:
# patch_pcm_stream.py had created three files and edited five when the
# playloop.c one failed, patch_optional_audio_libs.py had written four files
# when the meson.build one did, and patch_strip_libass.py let a libass source
# line it no longer found stay in the build. Then every anchor that a script
# on the engine lists with --list-anchors, in the order of each build script
# with every patch on: the shared mpv patches on the Linux order, the
# platform ones on theirs, and FFmpeg's. An anchor that may be found any
# number of times, or more than once where the first or all count, is left
# out: breaking one occurrence is not a failure there.
#
# Usage: bash verify/tests/patches/anchor_corrupt_test.sh <pristine mpv source dir> <pristine ffmpeg source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
USAGE="usage: anchor_corrupt_test.sh <pristine mpv source dir> <pristine ffmpeg source dir> <work dir>"
MPV="${1:?$USAGE}"; FFMPEG="${2:?$USAGE}"; T="${3:?$USAGE}"
P="$ROOT/patches"
rm -rf "$T"; mkdir -p "$T"
export PYTHONDONTWRITEBYTECODE=1
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

# swap <file> <old> <new>: replaces the one occurrence of old.
swap() { python3 - "$@" <<'PY'
import sys
p, old, new = sys.argv[1:]
t = open(p).read()
assert t.count(old) == 1, f'{p}: {old!r} found {t.count(old)} times'
open(p, 'w').write(t.replace(old, new))
PY
}

# broken <name> <file> <old> <new> <script> [args]: on a pristine copy with
# that line changed, the script fails and leaves every file as it was.
broken() {
  local name="$1" file="$2" old="$3" new="$4"; shift 4
  cp -a "$MPV" "$T/$name"
  swap "$T/$name/$file" "$old" "$new" || { check 1 "$name: test anchor found"; return; }
  : > "$T/$name.stamp"
  python3 -B "$@" "$T/$name" > "$T/$name.log" 2>&1; local r=$?
  [[ $r != 0 ]]; check $? "$name: the patch fails (exit $r)"
  local written; written="$(find "$T/$name" -type f -newer "$T/$name.stamp" | sed "s|$T/$name/||")"
  [[ -z "$written" ]]; check $? "$name: no file written${written:+ (wrote ${written//$'\n'/, })}"
  rm -rf "$T/$name"
}

broken pcm_stream player/playloop.c \
  $'static void handle_loop_file(struct MPContext *mpctx)\n{\n    if (mpctx->stop_play != AT_END_OF_FILE)\n' \
  $'static void handle_loop_file(struct MPContext *mpctx)\n{\n    if (mpctx->stop_play != AT_END_OF_FILE )\n' \
  "$P/mpv/shared/patch_pcm_stream.py"
broken optional_audio_libs meson.build \
  $'    sources += files(\'audio/out/ao_pulse.c\')\nendif\n' \
  $'    sources += files(\'audio/out/ao_pulse.c\')\n\nendif\n' \
  "$P/mpv/linux/patch_optional_audio_libs.py"
broken strip_libass meson.build \
  $'    \'sub/sd_ass.c\',\n' $'    \'sub/sd_ass.c\', \n' \
  "$P/mpv/shared/patch_strip_libass.py"

# Every listed anchor, by build order.
python3 -B - "$ROOT" "$MPV" "$FFMPEG" "$T" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT, MPV, FFMPEG, T = map(Path, sys.argv[1:5])
P = ROOT / 'patches'
PREFIX = T / 'prefix'
(PREFIX / 'lib').mkdir(parents=True)
for a in ('ssl', 'crypto', 'xml2', 'bz2', 'lzma'):
    (PREFIX / 'lib' / f'lib{a}.a').write_bytes(b'')

# The shared mpv patches in the order of apply_mpv_patches_common, which
# the test reads back from scripts/shared/_audio_only.sh.
SHARED = [
    'patch_optional_deps.py', 'patch_swscale_optional.py',
    'patch_strip_libass.py', 'patch_strip_mpv_dead.py',
    'patch_strip_win_resources.py', 'patch_afmt_reset.py',
    'patch_prefetch_hook.py', 'patch_prefetch_state.py',
    'patch_audio_output_state.py', 'patch_embedded_cover_art.py',
    'patch_pcm_tap.py', 'patch_pcm_stream.py', 'patch_bulk_analysis.py',
    'patch_loudness_scan.py', 'patch_filter_label_tap.py',
    'patch_chain_eof.py', 'patch_lavfi_eof_passthrough.py',
    'patch_hotplug_core_thread.py', 'patch_playlist_prev_dos_path.py',
    'patch_chapter_list_reset.py',
]
audio_only = (ROOT / 'scripts/shared/_audio_only.sh').read_text()
body = re.search(r'^apply_mpv_patches_common\(\) \{\n(.*?)^\}', audio_only,
                 re.M | re.S).group(1)
named = list(dict.fromkeys(re.findall(r'patch_\w+\.py', body)))
fails = 0
if named != SHARED:
    print(f'FAIL the shared patches of _audio_only.sh are {named}')
    fails += 1

ARGS = {
    'patch_optional_deps.py': lambda d: [d / 'meson.build'],
    'patch_afmt_reset.py': lambda d: [d / 'options/m_option.c'],
    'patch_utils_mac.py': lambda d: [d / 'meson.build'],
    'patch_windows_deps.py': lambda d: [d / 'meson.build'],
    'patch_ios_platform.py': lambda d: [d, 'iphoneos'],
    'patch_export_filter.py': lambda d: [d, ROOT / 'scripts/shared/mpv.exports', PREFIX],
    'patch_ffmpeg_libsmb2.py': lambda d: [d, P / 'ffmpeg/libsmb2.c'],
}

# (pristine tree, [(script, tested)]): each build's patch steps.
shared = [(f'mpv/shared/{s}', True) for s in SHARED]
untested = [(s, False) for s, _ in shared]
BUILDS = {
    'linux': (MPV, shared + [('mpv/linux/patch_optional_audio_libs.py', True)]),
    'android': (MPV, untested + [('mpv/android/patch_audiotrack.py', True)]),
    'windows': (MPV, [('mpv/windows/patch_windows_deps.py', True),
                      ('mpv/windows/patch_timer_resolution.py', True)]),
    'ios': (MPV, [('mpv/ios/patch_ios_platform.py', True),
                  ('mpv/ios/patch_ios_audio_stubs.py', True),
                  ('mpv/apple/patch_utils_mac.py', True),
                  ('mpv/ios/patch_compat_apple.py', True),
                  ('mpv/apple/patch_export_filter.py', True)]),
    'ffmpeg': (FFMPEG, [(f'ffmpeg/{s}', True) for s in (
        'patch_ffmpeg_codec_longnames.py', 'patch_ffmpeg_filter_bounds.py',
        'patch_ffmpeg_libsmb2.py', 'patch_ffmpeg_advanced_editlist.py',
        'patch_ffmpeg_dash_keepalive.py', 'patch_ffmpeg_embed_cacert.py')]),
    # The web build: no libsmb2 and no embed_cacert, then webio.
    'web': (FFMPEG, [(f'ffmpeg/{s}', False) for s in (
        'patch_ffmpeg_codec_longnames.py', 'patch_ffmpeg_filter_bounds.py',
        'patch_ffmpeg_advanced_editlist.py', 'patch_ffmpeg_dash_keepalive.py')]
        + [('ffmpeg/patch_ffmpeg_webio.py', True)]),
}


def run(script, d, *extra):
    argv = [sys.executable, '-B', str(P / script)]
    argv += [str(a) for a in ARGS.get(Path(script).name, lambda d: [d])(d)]
    return subprocess.run(argv + list(extra), capture_output=True, text=True)


def files(d):
    for base, _, names in os.walk(d):
        for n in names:
            yield Path(base, n)


def breakable(text, a):
    """Where to break anchor a in text, None when breaking it proves
    nothing: the position after the first character that is not blank of
    each occurrence to break."""
    if a['kind'] == 'regex':
        found = [(m.start(), m.group(0)) for m in
                 re.compile(a['anchor'], a['flags']).finditer(text)]
    else:
        n, at, found = text.count(a['anchor']), -1, []
        for _ in range(n):
            at = text.find(a['anchor'], at + 1)
            found.append((at, a['anchor']))
    times = a['times']
    if times == 'any' or not found:
        return None
    if times in ('first', 'all') and len(found) != 1:
        return None
    start, s = found[0]
    lead = len(s) - len(s.lstrip())
    if lead == len(s):
        return None
    return start + lead + 1


for build, (pristine, steps) in BUILDS.items():
    d = T / build
    shutil.copytree(pristine, d, symlinks=True)
    for script, tested in steps:
        if tested and 'anchor.main(' in (P / script).read_text():
            r = run(script, d, '--list-anchors')
            if r.returncode:
                print(f'FAIL {build} {script}: --list-anchors exit {r.returncode}\n{r.stderr}')
                fails += 1
                continue
            anchors = json.loads(r.stdout)
            first = Path(ARGS.get(Path(script).name, lambda d: [d])(d)[0])
            root = first if first.is_dir() else first.parent
            snap = T / 'snap'
            shutil.rmtree(snap, ignore_errors=True)
            shutil.copytree(d, snap, symlinks=True)
            groups = {}
            for a in anchors:
                key = (a['file'], a['label']) if a['kind'] == 'optional' else id(a)
                groups.setdefault(key, []).append(a)
            tried = 0
            for group in groups.values():
                path = root / group[0]['file']
                text = path.read_text()
                broken = text
                for a in group:
                    at = breakable(broken, a)
                    if at is not None:
                        broken = broken[:at] + '\x01' + broken[at:]
                if broken == text:
                    continue
                tried += 1
                path.write_text(broken)
                stamp = path.stat().st_mtime_ns
                r = run(script, d)
                written = [f for f in files(d) if f.stat().st_mtime_ns > stamp]
                label = f"{build} {Path(script).name}: {group[0]['file']} ({group[0]['label']})"
                if r.returncode == 0 or written:
                    print(f'FAIL {label}: exit {r.returncode}, '
                          f'wrote {[str(f.relative_to(d)) for f in written]}')
                    fails += 1
                for f in written:
                    s = snap / f.relative_to(d)
                    if s.exists():
                        shutil.copy2(s, f)
                    else:
                        f.unlink()
                path.write_text(text)
            print(f'ok   {build} {Path(script).name}: {tried} anchors broken one at a time')
        r = run(script, d)
        if r.returncode:
            print(f'FAIL {build} {script}: the patch does not apply\n{r.stderr}')
            fails += 1
            break
    shutil.rmtree(d)

sys.exit(1 if fails else 0)
PY
check $? "every listed anchor: the patch fails and writes nothing"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
