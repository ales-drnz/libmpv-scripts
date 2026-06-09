#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Keep ffmpeg codec long-names alive under --enable-small (audio-only fidelity).

Background
==========

The audio-only build uses ffmpeg `--enable-small` (CONFIG_SMALL=1) — worth
~2.8 MB, almost all of it CODE size-optimization and dropped DSP/lookup tables.
A tiny side effect, though, is that CONFIG_SMALL NULLs every codec's descriptive
name: in `libavcodec/codec_desc.c` each `AVCodecDescriptor.long_name` is wrapped
in `NULL_IF_CONFIG_SMALL("…")`, which expands to `NULL` under small.

mpv surfaces that exact field as the **`audio-codec`** property
(`audio-codec` → `current-tracks/audio/codec-desc` →
`mp_codec_params.codec_desc` ← `avctx->codec_descriptor->long_name`,
av_common.c). So with `--enable-small` the human-readable codec description
("AAC (Advanced Audio Coding)", "FLAC (Free Lossless Audio Codec)", …) comes
back NULL, even though the short `audio-codec-name` still works. That is a
user-visible feature loss for consumers that display the codec description.

This patch un-wraps ONLY the `.long_name` fields in codec_desc.c, restoring the
descriptive strings while leaving every other CONFIG_SMALL saving intact —
including the `.profiles = NULL_IF_CONFIG_SMALL(...)` rows in the same file
(those pull in profile arrays and are NOT touched). The whole codec-descriptor
long-name table is ~8 KB of strings, so the cost is negligible (≈0.008 MB) and
the ~2.8 MB code/table win of --enable-small is fully preserved.

No-op when --enable-small is off (the literal is identical to what
NULL_IF_CONFIG_SMALL(x) already yields), and idempotent: after the first run the
`.long_name` lines no longer mention NULL_IF_CONFIG_SMALL, so a re-run matches
nothing. Usage: patch_ffmpeg_codec_longnames.py <ffmpeg_source_dir>
"""
import os
import re
import sys

MARKER = "/* MAK_CODEC_LONGNAMES_KEPT */"

# Anchor strictly on `.long_name = NULL_IF_CONFIG_SMALL(<...>),` lines so the
# sibling `.profiles = NULL_IF_CONFIG_SMALL(...)` rows are never touched. The
# argument is always a single-line string literal (verified: 0 multi-line
# entries in 8.1.1); greedy `(.*)` to the LAST `)` before the trailing comma
# tolerates parens inside the quotes, e.g. "AAC (Advanced Audio Coding)".
PAT = re.compile(
    r'^([ \t]*\.long_name[ \t]*=[ \t]*)NULL_IF_CONFIG_SMALL\((.*)\),[ \t]*$',
    re.MULTILINE,
)


# ── codec_internal.h: the per-decoder AVCodec.p.long_name macro ──────────────
# mpv exposes `AVCodecDescriptor.long_name` as the `audio-codec`/`codec-desc`
# property (patched in codec_desc.c above) AND the per-decoder
# `AVCodec.p.long_name` as the SEPARATE `decoder-desc` property (mpv
# av_common.c: c->decoder_desc = avctx->codec->long_name). The latter is NULLed
# under CONFIG_SMALL by the CODEC_LONG_NAME(str) macro, so without this the
# kit's MpvTrack.decoderDesc is null in every --enable-small build. Un-NULL the
# macro so it keeps the string regardless of CONFIG_SMALL. Only the long-names
# of the AUDIO decoders we actually compile get linked (~1.5 KB); the per-decoder
# regex of codec_desc.c is NOT reused here — this is a one-line macro rewrite.
CI_OLD = "#define CODEC_LONG_NAME(str) .p.long_name = NULL"
CI_NEW = "#define CODEC_LONG_NAME(str) .p.long_name = str  " + MARKER


def patch_codec_internal(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if MARKER in text:
        print("Already patched: codec_internal.h (per-decoder long-names)")
        return
    if CI_OLD not in text:
        raise SystemExit(
            "patch_ffmpeg_codec_longnames: CODEC_LONG_NAME CONFIG_SMALL macro not "
            "found in codec_internal.h — ffmpeg source layout changed.")
    text = text.replace(CI_OLD, CI_NEW, 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    print("Patched: codec_internal.h (per-decoder long-names kept under --enable-small)")


def patch_codec_desc(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if MARKER in text:
        print("Already patched: codec_desc.c (long-names kept under --enable-small)")
        return
    new_text, n = PAT.subn(r"\1\2,", text)
    if n == 0:
        raise SystemExit(
            "patch_ffmpeg_codec_longnames: no `.long_name = NULL_IF_CONFIG_SMALL(...)` "
            "rows found in codec_desc.c — ffmpeg source layout changed.")
    # Drop a marker comment right after the license header's closing */ so
    # re-runs short-circuit even though the matched lines are already rewritten.
    new_text = new_text.replace(" */\n", " */\n" + MARKER + "\n", 1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)
    print(f"Patched: codec_desc.c ({n} codec long-names kept under --enable-small)")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: patch_ffmpeg_codec_longnames.py <ffmpeg_source_dir>")
    root = sys.argv[1]
    patch_codec_desc(os.path.join(root, "libavcodec", "codec_desc.c"))
    patch_codec_internal(os.path.join(root, "libavcodec", "codec_internal.h"))


if __name__ == "__main__":
    main()
