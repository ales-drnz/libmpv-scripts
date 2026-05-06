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
import re

fn = sys.argv[1]  # path to meson.build
with open(fn) as f:
    content = f.read()

# libplacebo: head-anchored on the unique `dependency('libplacebo'` token
# so an upstream reflow of the default_options list can't drift the match.
# In Python `re`, `[^)]` spans newlines and the two-line call has no ')'
# inside its argument list, so `[^)]*` correctly swallows to the single
# closing paren.
LP_NEW = "libplacebo = dependency('libplacebo', version: '>=6.338.2', required: false)"
content, n_lp = re.subn(
    r"libplacebo = dependency\('libplacebo'[^)]*\)", LP_NEW, content)
if n_lp == 0:
    sys.exit(f"[patch_optional_deps] libplacebo dependency() call not found "
             f"in {fn} — mpv source layout changed")

# libass: make optional. Idempotent — on a re-run the unpatched anchor is
# gone but the patched form is present, which is not an error.
LA_OLD = "libass = dependency('libass', version: '>= 0.12.2')"
LA_NEW = "libass = dependency('libass', version: '>= 0.12.2', required: false)"
if LA_OLD in content:
    content = content.replace(LA_OLD, LA_NEW, 1)
elif LA_NEW not in content:
    sys.exit(f"[patch_optional_deps] libass dependency() call not found "
             f"in {fn} — mpv source layout changed")

with open(fn, 'w') as f:
    f.write(content)
print("Patched meson.build: libplacebo and libass made optional")
