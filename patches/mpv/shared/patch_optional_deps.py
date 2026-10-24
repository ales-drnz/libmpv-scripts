# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Mark libplacebo and libass as optional in mpv's meson.build.

Sets `required: false` on both dependencies so `meson setup` still
configures when they are absent or at an unexpected version. Their
link-time use is then gated out for an audio-only build by
`auto_features=disabled` + LTO dead-code elimination (mpv still
`#include`s their headers, which is why the deps are built but not
required). Applied on every platform via apply_mpv_patches_common().
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

# libplacebo: head-anchored on the unique `dependency('libplacebo'` token
# so an upstream reflow of the default_options list can't drift the match.
# In Python `re`, `[^)]` spans newlines and the two-line call has no ')'
# inside its argument list, so `[^)]*` correctly swallows to the single
# closing paren. The patched call matches too, and is rewritten as itself.
LP_RE = r"libplacebo = dependency\('libplacebo'[^)]*\)"
LP_NEW = "libplacebo = dependency('libplacebo', version: '>=6.338.2', required: false)"

# libass: the patched form on a re-run is not an error. Neither is a tree
# where patch_strip_libass.py already dropped the line and swapped in its
# stub source.
LA_OLD = "libass = dependency('libass', version: '>= 0.12.2')"
LA_NEW = "libass = dependency('libass', version: '>= 0.12.2', required: false)"
LA_STRIPPED = "'sub/stub_libass.c'"


def apply(p, meson):
    p.regex(meson, LP_RE, LP_NEW, 'libplacebo dependency() call')
    text = p.text(meson)
    if LA_NEW not in text and LA_STRIPPED not in text:
        p.edit(meson, LA_OLD, LA_NEW, 'libass dependency() call')


anchor.main(apply, 'patch_optional_deps', usage='<mpv meson.build>',
            file_arg=True)
