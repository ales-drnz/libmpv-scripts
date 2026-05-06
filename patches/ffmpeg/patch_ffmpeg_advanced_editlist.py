#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Patches FFmpeg's mov demuxer to honor edit lists even for fragmented MP4.

Upstream ffmpeg disables `advanced_editlist` processing when it
encounters a fragmented MP4 (no stts entries, trun atoms carry the
timing). The relevant block in libavformat/mov.c (7.1.1) is:

    if (!sc->stts_count && c->advanced_editlist) {

        av_log(c->fc, AV_LOG_VERBOSE, "advanced_editlist does not work with fragmented "
                                      "MP4. disabling.\\n");
        c->advanced_editlist = 0;
        c->advanced_editlist_autodisabled = 1;
    }

For most fragmented MP4 sources this autodisable is fine — it's
defensive against malformed edit lists emitted by some DASH/HLS
encoders. But Plex's DASH segmenter emits per-segment edit lists
declaring AAC encoder priming (~2112 samples). With the autodisable
active those priming samples are NOT skipped → faint click at every
~2s segment boundary.

This patch removes the autodisable. The edit list is then processed
the same way it would be for a non-fragmented MP4 file, so the
priming skip works correctly and segment boundaries become
sample-accurate.

Notes on the upstream form we match:
- The log string is split across two C string literals (wrapped at
  "fragmented ") — accounted for by the regex below.
- Log level is `AV_LOG_VERBOSE` (was `AV_LOG_WARNING` in older trees).
- The block sets two flags: `advanced_editlist` and
  `advanced_editlist_autodisabled`. Both assignments are removed.
- The enclosing `if` also checks `!sc->stts_count` — we preserve that
  outer structure in case other parts of ffmpeg rely on the branch
  being entered, but make the body a no-op.

Usage:
    python3 patch_ffmpeg_advanced_editlist.py <ffmpeg_source_dir>
"""
import sys
import os
import re


MARKER = 'MAK_ADVANCED_EDITLIST_PATCH_V1'


def patch_mov_c(path: str) -> None:
    with open(path) as f:
        text = f.read()

    if MARKER in text:
        print(f'Already patched: {path}')
        return

    # Match the exact 7.1.1 block. Tolerate incidental whitespace, but
    # anchor on the characteristic C-literal split ("fragmented " +
    # "MP4. disabling.") so we don't accidentally rewrite unrelated
    # advanced_editlist references elsewhere in mov.c.
    pattern = re.compile(
        r'if \(!sc->stts_count && c->advanced_editlist\) \{\s*\n'
        r'\s*\n'
        r'\s*av_log\(c->fc, AV_LOG_VERBOSE,\s*'
        r'"advanced_editlist does not work with fragmented "\s*\n'
        r'\s*"MP4\. disabling\.\\n"\);\s*\n'
        r'\s*c->advanced_editlist = 0;\s*\n'
        r'\s*c->advanced_editlist_autodisabled = 1;\s*\n'
        r'\s*\}',
        re.MULTILINE,
    )

    replacement = (
        'if (!sc->stts_count && c->advanced_editlist) {\n'
        '        /* ' + MARKER + ' ─── do NOT autodisable advanced_editlist\n'
        '         * on fragmented MP4. Plex\'s DASH segmenter emits per-segment\n'
        '         * edit lists declaring AAC encoder priming; dropping them\n'
        '         * causes a click at every ~2s segment boundary. Honoring\n'
        '         * the edit list is safe as long as the encoder produces a\n'
        '         * valid elst — which Plex does. */\n'
        '        (void)c;\n'
        '    }'
    )

    new_text, count = pattern.subn(replacement, text)
    if count == 0:
        raise RuntimeError(
            f'Pristine advanced_editlist autodisable block not found in {path}.\n'
            'The ffmpeg source structure may have changed — review the patch\n'
            'against the current upstream mov.c around the\n'
            '"advanced_editlist does not work with fragmented MP4" warning.'
        )
    if count > 1:
        raise RuntimeError(
            f'Pattern matched {count} times in {path}; expected exactly 1.'
        )

    with open(path, 'w') as f:
        f.write(new_text)
    print(f'Patched: {path}')


def main() -> None:
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <ffmpeg_src_dir>')
        sys.exit(1)

    ffmpeg_dir = sys.argv[1]
    patch_mov_c(os.path.join(ffmpeg_dir, 'libavformat', 'mov.c'))


if __name__ == '__main__':
    main()
