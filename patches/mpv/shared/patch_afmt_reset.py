# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patch mpv's parse_afmt to accept "" and "no" as reset-to-default values.

mpv's audio format option parser (m_option.c) accepts format names like "s16",
"float", etc. but has no way to reset the value back to AF_FORMAT_UNKNOWN (auto).
print_afmt outputs "no" for the default state, but parse_afmt never accepts it —
this is an asymmetry that prevents runtime reset of audio-format via the API.

This patch adds an early return in parse_afmt so that empty string or "no" sets
the internal value to 0 (AF_FORMAT_UNKNOWN), matching the initial default.
"""
import sys
import re

fn = sys.argv[1]  # path to options/m_option.c
with open(fn) as f:
    content = f.read()

# Find the parse_afmt function and add reset handling after the opening brace.
old = (
    'static int parse_afmt(struct mp_log *log, const m_option_t *opt,\n'
    '                      struct bstr name, struct bstr param, void *dst)\n'
    '{'
)

new = (
    'static int parse_afmt(struct mp_log *log, const m_option_t *opt,\n'
    '                      struct bstr name, struct bstr param, void *dst)\n'
    '{\n'
    '    // Allow "" and "no" to reset to AF_FORMAT_UNKNOWN (auto/default).\n'
    '    if (param.len == 0 || bstr_equals0(param, "no")) {\n'
    '        if (dst)\n'
    '            *(int *)dst = 0;\n'
    '        return 1;\n'
    '    }'
)

if old not in content:
    print(f"WARNING: Could not find parse_afmt signature in {fn}")
    sys.exit(1)

content = content.replace(old, new, 1)

with open(fn, 'w') as f:
    f.write(content)
print("Patched m_option.c: parse_afmt now accepts '' and 'no' for reset to default")
