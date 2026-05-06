#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patches mpv to expose the embedded cover-art bytes (and their MIME type)
as two read-only client API properties **with proper change notification**
on every file load, so clients can `mpv_observe_property` them and react
to cover changes mid-playlist instead of polling after every file event.

Problem
=======

mpv's existing way to surface embedded album art to clients is to emit a
synthetic video stream from the `attached_pic` AVPacket attached to the
audio file (typical for FLAC, M4A/MP4, MKV, MP3 with ID3v2 APIC) and let
the client capture it via `screenshot-raw video` after the file loads.
The pixel buffer comes back BGRA8888.

For a wrapper whose only use of the video pipeline is exactly this — to
read out the embedded cover so a media-notification UI can render it —
the round trip is:

  decoded JPEG/PNG (libavcodec)  ─►  BGRA8888 frame  ─►  screenshot-raw
                                     ─►  Dart-side BGRA buffer
                                     ─►  re-encode via dart:ui to PNG.

The original codec bytes (the PNG/JPEG that was actually embedded in the
file) are *already* sitting in `sh->attached_picture`'s `demux_packet`
buffer. Decoding them to pixels and then re-encoding back to PNG is pure
overhead — typically 50–100 ms per file load on the hot path of
`open()` → file-loaded → cover-ready.

This patch adds two read-only client API properties:

    embedded-cover-art-data   MPV_FORMAT_NODE → BYTE_ARRAY of the codec
                              bytes (PNG / JPEG / WEBP / BMP / GIF raw
                              file content). MPV_FORMAT_NONE if no
                              embedded cover is attached to the current
                              file.
    embedded-cover-art-mime   MPV_FORMAT_STRING with the MIME type
                              ("image/png", "image/jpeg", "image/webp",
                              "image/bmp", "image/gif"). MPV_FORMAT_NONE
                              if no embedded cover.

Both properties query the current track list at read time — no MPContext
state is added, so the patch composes cleanly with
`patch_prefetch_state.py` and `patch_audio_output_state.py` (each
patches a disjoint slice of the source).

Files patched
=============

    player/command.c    registers the two properties + adds the getters
    player/loadfile.c   fires `mp_notify_property` for both properties
                        right after MPV_EVENT_FILE_LOADED, so observers
                        receive change events on every track transition

Usage
=====

    python3 patch_embedded_cover_art.py <mpv_source_dir>
"""
import sys
import os


# Idempotency marker — re-running the build pipeline against the same
# extracted mpv tree is safe.
MARKER = 'MAK_EMBEDDED_COVER_ART_PATCH_V1'


# ─── command.c ─────────────────────────────────────────────────────────

# Insert the property registrations right after `audio-device-list`. We
# explicitly avoid the `audio-out-params → aid` boundary because
# `patch_audio_output_state.py` inserts there too, and we want the two
# patches to compose in either order. `audio-device-list → audio-display`
# is a few lines further down, untouched by any other patch in this
# repo's `scripts/patches/mpv/`, and stable across recent mpv releases.
TABLE_PRISTINE = (
    '    {"audio-device-list", mp_property_audio_devices},'
)

TABLE_PATCHED = (
    '    {"audio-device-list", mp_property_audio_devices},\n'
    '    /* ' + MARKER + ' */\n'
    '    {"embedded-cover-art-data", mp_property_embedded_cover_art_data},\n'
    '    {"embedded-cover-art-mime", mp_property_embedded_cover_art_mime},'
)

# Insert the two getters just before the audio-params getter — same
# neighbourhood, stable, and disjoint from any other patch's anchor.
GETTER_ANCHOR = (
    'static int mp_property_audio_params(void *ctx, struct m_property *prop,'
)

GETTER_INSERT = (
    '/* ' + MARKER + ' ─── helper: walk the current track list and return the\n'
    ' * first track with an embedded `attached_picture` (album art). NULL if\n'
    ' * no embedded cover is currently loaded. */\n'
    'static struct demux_packet *mak_find_attached_picture(MPContext *mpctx,\n'
    '                                                     const char **codec_out)\n'
    '{\n'
    '    if (!mpctx || !mpctx->demuxer)\n'
    '        return NULL;\n'
    '    for (int n = 0; n < mpctx->num_tracks; n++) {\n'
    '        struct track *t = mpctx->tracks[n];\n'
    '        if (t && t->attached_picture && t->stream &&\n'
    '            t->stream->attached_picture)\n'
    '        {\n'
    '            if (codec_out)\n'
    '                *codec_out = t->stream->codec ? t->stream->codec->codec : NULL;\n'
    '            return t->stream->attached_picture;\n'
    '        }\n'
    '    }\n'
    '    return NULL;\n'
    '}\n'
    '\n'
    '/* ' + MARKER + ' ─── translate the libavcodec codec name reported by\n'
    ' * mpv\'s codec params (e.g. "png", "mjpeg") into a media-friendly\n'
    ' * MIME type. Returns NULL for codecs we do not recognise so the\n'
    ' * mime property reads as unavailable rather than as a misleading\n'
    ' * fallback. */\n'
    'static const char *mak_codec_to_mime(const char *codec)\n'
    '{\n'
    '    if (!codec)               return NULL;\n'
    '    if (!strcasecmp(codec, "png"))  return "image/png";\n'
    '    if (!strcasecmp(codec, "mjpeg") || !strcasecmp(codec, "jpeg"))\n'
    '                                  return "image/jpeg";\n'
    '    if (!strcasecmp(codec, "webp")) return "image/webp";\n'
    '    if (!strcasecmp(codec, "bmp"))  return "image/bmp";\n'
    '    if (!strcasecmp(codec, "gif"))  return "image/gif";\n'
    '    return NULL;\n'
    '}\n'
    '\n'
    '/* ' + MARKER + ' ─── read-only property: the raw codec bytes of the\n'
    ' * current file\'s embedded cover art (typically PNG or JPEG), or\n'
    ' * MPV_FORMAT_NONE if no embedded cover is attached. Returned as\n'
    ' * MPV_FORMAT_NODE wrapping a MPV_FORMAT_BYTE_ARRAY, which is the\n'
    ' * established mpv idiom for binary payloads in property reads — see\n'
    ' * `screenshot-raw` in this file for the same pattern. */\n'
    'static int mp_property_embedded_cover_art_data(void *ctx,\n'
    '                                               struct m_property *prop,\n'
    '                                               int action, void *arg)\n'
    '{\n'
    '    MPContext *mpctx = ctx;\n'
    '    switch (action) {\n'
    '        case M_PROPERTY_GET_TYPE:\n'
    '            *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_NODE};\n'
    '            return M_PROPERTY_OK;\n'
    '        case M_PROPERTY_GET:\n'
    '        case M_PROPERTY_GET_NODE: {\n'
    '            struct demux_packet *pkt = mak_find_attached_picture(mpctx, NULL);\n'
    '            if (!pkt || !pkt->buffer || pkt->len <= 0)\n'
    '                return M_PROPERTY_UNAVAILABLE;\n'
    '            struct mpv_byte_array *ba = talloc_zero(NULL, struct mpv_byte_array);\n'
    '            ba->data = talloc_memdup(ba, pkt->buffer, pkt->len);\n'
    '            ba->size = pkt->len;\n'
    '            *(struct mpv_node *)arg = (struct mpv_node){\n'
    '                .format = MPV_FORMAT_BYTE_ARRAY,\n'
    '                .u.ba = ba,\n'
    '            };\n'
    '            return M_PROPERTY_OK;\n'
    '        }\n'
    '    }\n'
    '    return M_PROPERTY_NOT_IMPLEMENTED;\n'
    '}\n'
    '\n'
    '/* ' + MARKER + ' ─── read-only string property reporting the MIME type\n'
    ' * of the bytes returned by `embedded-cover-art-data` ("image/png",\n'
    ' * "image/jpeg", etc.). MPV_FORMAT_NONE if no embedded cover or if\n'
    ' * the codec is unrecognised. */\n'
    'static int mp_property_embedded_cover_art_mime(void *ctx,\n'
    '                                               struct m_property *prop,\n'
    '                                               int action, void *arg)\n'
    '{\n'
    '    MPContext *mpctx = ctx;\n'
    '    /* Answer GET_TYPE up front so the property type resolves even when\n'
    '     * no cover is currently loaded. Doing the attached-picture lookup\n'
    '     * first (as a naive getter would) returns M_PROPERTY_UNAVAILABLE\n'
    '     * for every action including GET_TYPE, so an observer could never\n'
    '     * learn the property is a string until a cover happened to exist. */\n'
    '    if (action == M_PROPERTY_GET_TYPE) {\n'
    '        *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_STRING};\n'
    '        return M_PROPERTY_OK;\n'
    '    }\n'
    '    const char *codec = NULL;\n'
    '    struct demux_packet *pkt = mak_find_attached_picture(mpctx, &codec);\n'
    '    if (!pkt)\n'
    '        return M_PROPERTY_UNAVAILABLE;\n'
    '    const char *mime = mak_codec_to_mime(codec);\n'
    '    if (!mime)\n'
    '        return M_PROPERTY_UNAVAILABLE;\n'
    '    return m_property_strdup_ro(action, arg, mime);\n'
    '}\n'
    '\n'
    + GETTER_ANCHOR
)


def patch_command_c(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if TABLE_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (property table) not found in {path}.'
        )
    if GETTER_ANCHOR not in text:
        raise RuntimeError(
            f'Pristine anchor (getter insertion point) not found in {path}.'
        )
    text = text.replace(TABLE_PRISTINE, TABLE_PATCHED, 1)
    text = text.replace(GETTER_ANCHOR, GETTER_INSERT, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── loadfile.c ────────────────────────────────────────────────────────
#
# Hook the change notifications onto MPV_EVENT_FILE_LOADED. mpv emits
# this event from `play_current_file()` exactly once per file load,
# AFTER the demuxer has been opened and tracks are registered — which
# means our `mak_find_attached_picture` walk over `mpctx->tracks` is
# guaranteed to see the freshly-loaded attached_picture (or none, if
# the new file has no embedded cover, in which case observers correctly
# read MPV_FORMAT_NONE).

LOADFILE_PRISTINE = (
    '    mp_notify(mpctx, MPV_EVENT_FILE_LOADED, NULL);'
)

LOADFILE_PATCHED = (
    '    mp_notify(mpctx, MPV_EVENT_FILE_LOADED, NULL);\n'
    '    /* ' + MARKER + ' */\n'
    '    mp_notify_property(mpctx, "embedded-cover-art-data");\n'
    '    mp_notify_property(mpctx, "embedded-cover-art-mime");'
)


def patch_loadfile_c(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if LOADFILE_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (MPV_EVENT_FILE_LOADED notify) not found in '
            f'{path}.'
        )
    text = text.replace(LOADFILE_PRISTINE, LOADFILE_PATCHED, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <mpv_src_dir>')
        sys.exit(1)
    src = sys.argv[1]
    patch_command_c(os.path.join(src, 'player', 'command.c'))
    patch_loadfile_c(os.path.join(src, 'player', 'loadfile.c'))


if __name__ == '__main__':
    main()
