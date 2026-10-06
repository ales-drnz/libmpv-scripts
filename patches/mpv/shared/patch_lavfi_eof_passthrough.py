# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Pass an EOF that reaches a new audio filter before any data straight on.

A lavfi filter builds its graph from the format of the first frame it gets.
When that frame is an EOF, f_lavfi builds it on a dummy format, float stereo
at 48 kHz, only to tell the graph the stream ended. A filter that takes no
float, such as hdcd (s16 and s32 only), then fails to configure, and the
output chain disables it for good: the effect is gone although `af` still
lists it.

An EOF comes first when the filter is created while the chain restarts, for
example during the refresh seek of patch_chain_eof.py: setting an effect
right after removing one that held the end of a short file disabled the new
one now and then.

This patch builds no graph for an audio filter whose inputs all bring an EOF
first: the EOF goes to the outputs as is, and the graph is built on the
next real frame, with its real format. A graph fed only an EOF has nothing
to filter, so the output is the same.

Usage: patch_lavfi_eof_passthrough.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "MAK_LAVFI_EOF_PASSTHROUGH_PATCH_V1"

root = Path(sys.argv[1])
lavfi = root / "filters/f_lavfi.c"

EDITS = [
    (
        "    bool got_eagain;\n",
        "    bool got_eagain;\n"
        f"    bool mak_eof_passed; // {MARKER}\n",
    ),
    (
        "        pad->got_eagain = false;\n",
        "        pad->got_eagain = false;\n"
        f"        pad->mak_eof_passed = false; // {MARKER}\n",
    ),
    (
        "static void lavfi_process(struct mp_filter *f)\n",
        f"/* {MARKER}: an audio graph whose inputs all bring an EOF before any\n"
        " * data is not built on the dummy float format, which a filter like hdcd\n"
        " * refuses: the EOF goes straight to the outputs, and the graph is built\n"
        " * on the next real frame. Returns true if it handled the input. */\n"
        "static bool mak_pass_eof_only_input(struct lavfi *c)\n"
        "{\n"
        "    if (c->num_in_pads < 1 || c->draining_recover)\n"
        "        return false;\n"
        "\n"
        "    for (int n = 0; n < c->num_in_pads; n++) {\n"
        "        struct lavfi_pad *pad = c->in_pads[n];\n"
        "        if (pad->type != MP_FRAME_AUDIO)\n"
        "            return false;\n"
        "        read_pad_input(c, pad);\n"
        "        if (pad->pending.type != MP_FRAME_EOF)\n"
        "            return false;\n"
        "    }\n"
        "\n"
        "    for (int n = 0; n < c->num_out_pads; n++) {\n"
        "        struct lavfi_pad *pad = c->out_pads[n];\n"
        "        if (pad->mak_eof_passed)\n"
        "            continue;\n"
        "        if (!mp_pin_in_needs_data(pad->pin))\n"
        "            return true; // called again once the output asks\n"
        "        mp_pin_in_write(pad->pin, MP_EOF_FRAME);\n"
        "        pad->mak_eof_passed = true;\n"
        "    }\n"
        "\n"
        "    MP_VERBOSE(c, \"EOF before any data, passed on without a graph\\n\");\n"
        "    for (int n = 0; n < c->num_in_pads; n++)\n"
        "        mp_frame_unref(&c->in_pads[n]->pending);\n"
        "    for (int n = 0; n < c->num_out_pads; n++)\n"
        "        c->out_pads[n]->mak_eof_passed = false;\n"
        "    mp_filter_internal_mark_progress(c->f);\n"
        "    return true;\n"
        "}\n"
        "\n"
        "static void lavfi_process(struct mp_filter *f)\n",
    ),
    (
        "    if (!c->initialized)\n"
        "        init_graph(c);\n",
        f"    if (!c->initialized && mak_pass_eof_only_input(c)) // {MARKER}\n"
        "        return;\n"
        "\n"
        "    if (!c->initialized)\n"
        "        init_graph(c);\n",
    ),
]

text = lavfi.read_text()
if MARKER in text:
    print(f"Already patched: {lavfi.name}")
    sys.exit(0)
# Every anchor is checked before the file is written, so a mismatch leaves
# the tree as it was instead of half patched.
for old, new in EDITS:
    if text.count(old) != 1:
        sys.exit(f"patch_lavfi_eof_passthrough: anchor not found once in "
                 f"{lavfi}: {old!r}")
    text = text.replace(old, new, 1)
lavfi.write_text(text)
print(f"Patched: {lavfi}")
