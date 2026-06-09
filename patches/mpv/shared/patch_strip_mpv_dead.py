#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Strip dead/unused subsystems from an audio-only libmpv build (mpv 0.41.0).

Background
==========

The audio-only consumer runs with vid=no, vo=null, sid=no, no terminal /
input / IPC / scripts / screenshot / encode, and is built with HAVE_GL=0
and HAVE_VULKAN=0. It is confirmed the kit never uses the GPU render API,
screenshot, encode, RTSP, subtitles, or mpv-side image decode (cover art
is delivered as raw PNG/JPEG bytes, never decoded by mpv).

Whole subsystems are therefore dead weight (~700KB). This patch removes
them from the build. For each removal it (a) drops the source(s) from
`meson.build`'s `files(...)` list (or overwrites the TU in place with a
stub), (b) cuts the GC-root reference that keeps the subsystem reachable
(driver/backend/filter array entry + its extern decl), and (c) provides a
stub for every cross-TU symbol from a removed file that is still referenced
by code which stays compiled — otherwise the link breaks.

Removals
========

1) GPU / SHADER RENDER STACK (~650KB)
   meson files(...) dropped:
     video/out/gpu/{context,error_diffusion,hwdec,lcms,libmpv_gpu,osd,ra,
       shader_cache,spirv,user_shaders,utils,video,video_shaders}.c
     video/out/vo_gpu.c, video/out/vo_gpu_next.c
     video/out/placebo/ra_pl.c, video/out/placebo/utils.c
     video/out/gpu_next/context.c
   GC-root anchors cut:
     video/out/vo.c:  `&video_out_gpu_next,` `&video_out_gpu,` from
       video_out_drivers[] + their two `extern` decls.
     video/out/vo_libmpv.c:  `&render_backend_gpu,` from render_backends[].
   placebo/utils.c is removed WITHOUT a stub: its only exports
   (mppl_log_create / mppl_log_set_probing) are referenced solely by
   GL/Vulkan TUs (vo_gpu_next, gpu_next/context, ra_pl, vulkan/*,
   vf_gpu_vulkan, dmabuf_interop_pl) which are removed or compiled out by
   HAVE_GL=0 / HAVE_VULKAN=0. The light libplacebo color helpers used by
   staying TUs (mp_image.c etc.) are pl_*_/pl_color_* symbols that come
   from libplacebo.a directly, NOT from mpv's placebo/utils.c. (verified)
   New stub video/out/stub_gpu.c provides the cross-TU symbols that staying
   code still references after the stack is gone:
     - ra_ctx_conf / gl_video_conf / gl_next_conf / spirv_conf
       (m_sub_options, walked by options/options.c at startup → empty but
        valid option groups; no staying code reads their fields)
     - ra_hwdec_driver_get_imgfmt_for_name
     - ra_hwdec_driver_get_device_type_for_name
     - ra_hwdec_validate_drivers_only_opt
       (the last three are called from filters/f_lavfi.c, which stays
        compiled; stubs report "no hwdec interop")

2) SCREENSHOT (~16KB)
   player/screenshot.c overwritten in place with a stub TU (kept in
   files(); screenshot.h unchanged) providing every symbol referenced by
   staying code: screenshot_init, handle_each_frame_screenshot (player/
   main.c, playloop.c), convert_image (video/image_loader.c), and the
   three command handlers cmd_screenshot / cmd_screenshot_to_file /
   cmd_screenshot_raw (player/command.c's command table). The command
   parser and the command rows are left intact — the commands simply
   become no-ops, which is strictly safer than surgically deleting the
   multi-line option rows. video/image_writer.c is stubbed under #3.

3) ENCODE MODE (~10KB)
   meson files(...) dropped: audio/out/ao_lavc.c, video/out/vo_lavc.c,
     video/out/vo_image.c.
   common/encode_lavc.c overwritten in place with a stub TU (kept in
   files()) providing the player-core encode ABI (common/encode.h:
   encode_lavc_init/free/discontinuity/showhelp/getstatus/stream_type_ok/
   expect_stream/set_metadata/didfail), encoder_update_log, and the
   `encode_config` m_sub_options (reproduced verbatim — pure option data —
   so options/options.c's OPT_SUBSTRUCT keeps parsing identically).
   GC-root anchors cut:
     audio/out/ao.c:   `&audio_out_lavc,` from audio_out_drivers[].
     video/out/vo.c:   `&video_out_lavc,` and `&video_out_image,` from
       video_out_drivers[] + their `extern` decls.
   The encoder_* helpers (encoder_context_alloc/encoder_init_codec_and_
   muxer/encoder_encode/encoder_get_mux_timebase_unlocked) are referenced
   only by the removed ao_lavc/vo_lavc/vo_image TUs, so they need no stub.

4) IMAGE WRITER (~part of screenshot/encode; ~its own TU)
   video/image_writer.c overwritten in place with a stub TU (kept in
   files(); image_writer.h unchanged) providing the symbols referenced by
   staying code: the image_writer_opts[] option table,
   image_writer_opts_defaults and struct image_writer_opts size are
   consumed by options/options.c's screenshot_conf (reproduced verbatim),
   plus image_writer_file_ext / image_writer_high_depth /
   image_writer_flexible_csp / image_writer_format_from_ext / write_image /
   dump_png as no-ops/failures.

5) SUB BITMAP decode / render (~14KB)
   meson files(...) dropped: sub/sd_lavc.c, sub/draw_bmp.c (overwritten in
     place — see below), sub/img_convert.c, sub/lavc_conv.c, sub/filter_sdh.c.
   (sub/filter_regex.c and sub/filter_jsre.c are NOT in the unconditional
    files() list in 0.41.0 — they are conditional sources — so they are
    left untouched.)
   GC-root anchor cut:
     sub/dec_sub.c:  `&sd_lavc,` from sd_list[].
   sub/draw_bmp.c overwritten in place with a stub TU (kept in files();
   draw_bmp.h unchanged) because the staying file sub/osd.c references
   mp_draw_sub_formats / mp_draw_sub_alloc / mp_draw_sub_bitmaps. The stub
   provides the whole draw_bmp.h ABI as no-ops. The exports of the other
   removed sub TUs (lavc_conv_*, mp_blur_rgba_sub_bitmap / mp_sub_bitmaps_bb
   / mp_get_sub_bb_list, the sd_lavc driver, sd_filter_sdh) are referenced
   ONLY by files that are themselves removed (sd_ass.c/ass_mp.c, removed by
   patch_strip_libass.py) or by the now-removed sub TUs, so they need no
   stub. Coordinates with patch_strip_libass.py, which already adds
   sub/stub_libass.c and supplies sd_ass / mp_sub_filter_opts /
   sd_ass_fmt_offset / sd_ass_pkt_text / sd_ass_to_plaintext — this patch
   does NOT touch any of those.

6) INPUT CONF (~14KB, low-risk)
   input/input.c: replace the builtin_input_conf[] default-keybindings
   string (#include "etc/input.conf.inc") with "" (empty). The command
   parser is untouched; with an empty builtin string the default-bindings
   loop simply iterates zero times.

Idempotency
===========

Every edit is guarded. Overwritten TUs and the new stub file carry the
MARKER and are only (re)written when missing or stale-but-ours. meson and
anchor edits check for the post-patch state (token already gone / marker
present) and are skipped on a re-run. Running the patch twice on a cached,
already-patched tree is a no-op.

Usage
=====

    python3 patch_strip_mpv_dead.py <mpv_source_dir>
"""
import sys
import os


MARKER = 'MAK_STRIP_MPV_DEAD_PATCH_V1'


# ─── helpers ────────────────────────────────────────────────────────────

def _read(path):
    with open(path) as f:
        return f.read()


def _write(path, text):
    with open(path, 'w') as f:
        f.write(text)


def _overwrite_in_place(path, content, what):
    """Replace an EXISTING upstream TU with our stub, idempotently.

    On the first run `path` is the pristine upstream source, which we replace
    wholesale (the whole point of the patch). On a re-run the file already
    equals our stub (carries MARKER) and we skip. We only ever write a file
    that already exists — never create a new path here.
    """
    if not os.path.exists(path):
        raise RuntimeError(
            f'{path} does not exist — expected an upstream TU to overwrite '
            f'({what}); mpv source layout changed.')
    existing = _read(path)
    if existing == content:
        print(f'Already stubbed: {path}')
        return
    if MARKER in existing:
        # An older revision of our own stub — refresh it.
        _write(path, content)
        print(f'Refreshed stub: {path} ({what})')
        return
    _write(path, content)
    print(f'Stubbed: {path} ({what})')


def _write_new_stub(path, content, what):
    """Create a brand-new stub file that does not exist upstream.

    Idempotent and protective: if a file is already at `path`, only
    (re)write it when it is clearly ours (carries MARKER); refuse otherwise
    so we never clobber an unrelated file that happens to share the name.
    """
    if os.path.exists(path):
        existing = _read(path)
        if existing == content:
            print(f'Already present: {path}')
            return
        if MARKER not in existing:
            raise RuntimeError(
                f'{path} exists but is not a {MARKER} stub — refusing to '
                f'overwrite ({what}).')
    _write(path, content)
    print(f'Wrote: {path} ({what})')


def _drop_lines(text, lines, path, label):
    """Remove each exact line in `lines` from `text` (idempotent: missing
    lines are tolerated, since a re-run will already have removed them)."""
    for ln in lines:
        if ln in text:
            text = text.replace(ln, '', 1)
    return text


# ─── new stub: video/out/stub_gpu.c ─────────────────────────────────────
#
# Replaces the cross-TU symbols that staying code still references after the
# whole GPU/shader render stack is removed from the build.

STUB_GPU_FILENAME = os.path.join('video', 'out', 'stub_gpu.c')

STUB_GPU_SOURCE = r'''/*
 * ''' + MARKER + r'''
 *
 * Auto-generated by patch_strip_mpv_dead.py — replacement stubs for the
 * GPU / shader render stack removed from this audio-only libmpv build
 * (HAVE_GL=0, HAVE_VULKAN=0, vo=null). Provides only the symbols from the
 * removed video/out/gpu/*.c TUs that are still referenced by code which
 * stays compiled:
 *
 *   options/options.c  (option subsystem walks these at startup):
 *       ra_ctx_conf, gl_video_conf, gl_next_conf, spirv_conf
 *       — reproduced as EMPTY but valid m_sub_options. No staying TU reads
 *         the corresponding option substructs, so the option groups can be
 *         empty; the only effect is that the --gpu-*, --icc-*, etc. options
 *         no longer exist, which is correct with no GPU renderer.
 *
 *   filters/f_lavfi.c  (audio lavfi filter graph, stays compiled):
 *       ra_hwdec_driver_get_imgfmt_for_name
 *       ra_hwdec_driver_get_device_type_for_name
 *       ra_hwdec_validate_drivers_only_opt
 *       — report "no hwdec interop"; the audio-only build has no hwdec.
 *
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdbool.h>

#include <libavutil/hwcontext.h>

#include "config.h"
#include "options/m_option.h"
#include "video/img_format.h"
#include "video/out/gpu/hwdec.h"

/* ---- option groups (empty but valid) -----------------------------------
 *
 * options/options.c references these four via OPT_SUBSTRUCT. The option
 * subsystem requires a valid m_sub_options: a non-NULL, {0}-terminated
 * opts array and a size. An empty opts array means the group registers no
 * options. The matching MPOpts substruct fields are never dereferenced by
 * any staying TU, so a 1-int placeholder backing struct is sufficient. */

struct mak_empty_opts { int unused; };

#define OPT_BASE_STRUCT struct mak_empty_opts

const struct m_sub_options ra_ctx_conf = {
    .opts = (const struct m_option[]){ {0} },
    .size = sizeof(struct mak_empty_opts),
};

const struct m_sub_options gl_video_conf = {
    .opts = (const struct m_option[]){ {0} },
    .size = sizeof(struct mak_empty_opts),
};

const struct m_sub_options gl_next_conf = {
    .opts = (const struct m_option[]){ {0} },
    .size = sizeof(struct mak_empty_opts),
};

const struct m_sub_options spirv_conf = {
    .opts = (const struct m_option[]){ {0} },
    .size = sizeof(struct mak_empty_opts),
};

/* ---- ra_hwdec helpers referenced by filters/f_lavfi.c ------------------
 *
 * Signatures copied from video/out/gpu/hwdec.h / hwdec.c. With no GPU
 * hwdec interop these report "unknown / none"; f_lavfi then loads no hwdec
 * device, which is correct for an audio-only build. */

int ra_hwdec_driver_get_imgfmt_for_name(const char *name)
{
    (void)name;
    return IMGFMT_NONE;
}

enum AVHWDeviceType ra_hwdec_driver_get_device_type_for_name(const char *name)
{
    (void)name;
    return AV_HWDEVICE_TYPE_NONE;
}

/* Declared in hwdec.h via OPT_STRING_VALIDATE_FUNC(); that macro also emits
 * the static-inline `_str` trampoline that f_lavfi's OPT_STRING_VALIDATE
 * references, so here we only need to define the non-inline target. Accept
 * any value (there are no drivers to validate against). */
int ra_hwdec_validate_drivers_only_opt(struct mp_log *log,
                                       const m_option_t *opt,
                                       struct bstr name, const char **value)
{
    (void)log; (void)opt; (void)name; (void)value;
    return 1;
}
'''


def write_stub_gpu(src):
    path = os.path.join(src, STUB_GPU_FILENAME)
    _write_new_stub(path, STUB_GPU_SOURCE, 'GPU render-stack symbols')


# ─── overwrite: player/screenshot.c ─────────────────────────────────────

SCREENSHOT_REL = os.path.join('player', 'screenshot.c')

SCREENSHOT_STUB = r'''/*
 * ''' + MARKER + r'''
 *
 * No-op stub of player/screenshot.c for an audio-only build. The kit never
 * takes screenshots (vo=null, no image output). Every symbol below is
 * referenced by code that stays compiled:
 *   - screenshot_init / handle_each_frame_screenshot : player/main.c,
 *     player/playloop.c
 *   - convert_image : video/image_loader.c (and former screenshot paths)
 *   - cmd_screenshot / cmd_screenshot_to_file / cmd_screenshot_raw :
 *     the command table in player/command.c
 * screenshot.h is kept UNCHANGED; this TU provides every symbol it declares.
 * The commands remain registered but do nothing.
 *
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stddef.h>

#include "screenshot.h"

void screenshot_init(struct MPContext *mpctx)
{
    (void)mpctx;
}

void handle_each_frame_screenshot(struct MPContext *mpctx)
{
    (void)mpctx;
}

struct mp_image *convert_image(struct mp_image *image, int destfmt,
                               struct mpv_global *global, struct mp_log *log)
{
    /* No swscale / image conversion in the audio-only build. The only
     * caller that stays compiled (video/image_loader.c) treats NULL as
     * "decode/convert failed". */
    (void)image; (void)destfmt; (void)global; (void)log;
    return NULL;
}

/* mp_cmd_ctx-based command handlers. These commands are not exec_async, so
 * the command core (run_command in player/command.c) calls
 * mp_cmd_ctx_complete() automatically once the handler returns — exactly as
 * the real handlers rely on. The stub therefore just returns (no-op); the
 * command reports its default cmd->success == false. */
void cmd_screenshot(void *p)
{
    (void)p;
}

void cmd_screenshot_to_file(void *p)
{
    (void)p;
}

void cmd_screenshot_raw(void *p)
{
    (void)p;
}
'''


def write_screenshot_stub(src):
    _overwrite_in_place(os.path.join(src, SCREENSHOT_REL), SCREENSHOT_STUB,
                    'screenshot disabled')


# ─── overwrite: video/image_writer.c ────────────────────────────────────

IMAGE_WRITER_REL = os.path.join('video', 'image_writer.c')

IMAGE_WRITER_STUB = r'''/*
 * ''' + MARKER + r'''
 *
 * Stub of video/image_writer.c for an audio-only build (no screenshot, no
 * vo_image encode, no mpv-side image decode). image_writer.h is kept
 * UNCHANGED. Provides every symbol the surviving build references:
 *   - image_writer_opts[] / image_writer_opts_defaults / struct
 *     image_writer_opts : consumed by options/options.c (screenshot_conf
 *     OPT_SUBSTRUCT). Reproduced verbatim — pure option data — so option
 *     parsing is unchanged.
 *   - image_writer_file_ext / image_writer_high_depth /
 *     image_writer_flexible_csp / image_writer_format_from_ext / write_image
 *     / dump_png : no-ops / failures. Their callers (screenshot, vo_image)
 *     are stubbed / removed in the same patch.
 *
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdbool.h>
#include <stddef.h>

#include <libavcodec/codec_id.h>

#include "options/m_option.h"
#include "image_writer.h"

const struct image_writer_opts image_writer_opts_defaults = {
    .format = AV_CODEC_ID_MJPEG,
    .high_bit_depth = true,
    .png_compression = 7,
    .png_filter = 5,
    .jpeg_quality = 90,
    .jpeg_source_chroma = true,
    .webp_quality = 75,
    .webp_compression = 4,
    .jxl_distance = 1.0,
    .jxl_effort = 4,
    .avif_encoder = "libaom-av1",
    .avif_opts = (char*[]){
        "usage",    "allintra",
        "crf",      "0",
        "cpu-used", "8",
        NULL
    },
    .tag_csp = true,
};

static const struct m_opt_choice_alternatives mp_image_writer_formats[] = {
    {"jpg",  AV_CODEC_ID_MJPEG},
    {"jpeg", AV_CODEC_ID_MJPEG},
    {"png",  AV_CODEC_ID_PNG},
    {"webp", AV_CODEC_ID_WEBP},
    {"jxl",  AV_CODEC_ID_JPEGXL},
    {"avif",  AV_CODEC_ID_AV1},
    {0}
};

#define OPT_BASE_STRUCT struct image_writer_opts

const struct m_option image_writer_opts[] = {
    {"format", OPT_CHOICE_C(format, mp_image_writer_formats)},
    {"jpeg-quality", OPT_INT(jpeg_quality), M_RANGE(0, 100)},
    {"jpeg-source-chroma", OPT_BOOL(jpeg_source_chroma)},
    {"png-compression", OPT_INT(png_compression), M_RANGE(0, 9)},
    {"png-filter", OPT_INT(png_filter), M_RANGE(0, 5)},
    {"webp-lossless", OPT_BOOL(webp_lossless)},
    {"webp-quality", OPT_INT(webp_quality), M_RANGE(0, 100)},
    {"webp-compression", OPT_INT(webp_compression), M_RANGE(0, 6)},
    {"jxl-distance", OPT_DOUBLE(jxl_distance), M_RANGE(0.0, 15.0)},
    {"jxl-effort", OPT_INT(jxl_effort), M_RANGE(1, 9)},
    {"avif-encoder", OPT_STRING(avif_encoder)},
    {"avif-opts", OPT_KEYVALUELIST(avif_opts)},
    {"avif-pixfmt", OPT_STRING(avif_pixfmt)},
    {"high-bit-depth", OPT_BOOL(high_bit_depth)},
    {"tag-colorspace", OPT_BOOL(tag_csp)},
    {0},
};

const char *image_writer_file_ext(const struct image_writer_opts *opts)
{
    (void)opts;
    return "jpg";
}

bool image_writer_high_depth(const struct image_writer_opts *opts)
{
    (void)opts;
    return false;
}

bool image_writer_flexible_csp(const struct image_writer_opts *opts)
{
    (void)opts;
    return false;
}

int image_writer_format_from_ext(const char *ext)
{
    (void)ext;
    return 0;
}

bool write_image(struct mp_image *image, const struct image_writer_opts *opts,
                 const char *filename, struct mpv_global *global,
                 struct mp_log *log, bool overwrite)
{
    (void)image; (void)opts; (void)filename;
    (void)global; (void)log; (void)overwrite;
    return false;
}

void dump_png(struct mp_image *image, const char *filename, struct mp_log *log)
{
    (void)image; (void)filename; (void)log;
}
'''


def write_image_writer_stub(src):
    _overwrite_in_place(os.path.join(src, IMAGE_WRITER_REL), IMAGE_WRITER_STUB,
                    'image writer disabled')


# ─── overwrite: common/encode_lavc.c ────────────────────────────────────

ENCODE_REL = os.path.join('common', 'encode_lavc.c')

ENCODE_STUB = r'''/*
 * ''' + MARKER + r'''
 *
 * Stub of common/encode_lavc.c for an audio-only build with encode mode
 * disabled (no --o=). common/encode.h and common/encode_lavc.h are kept
 * UNCHANGED. Provides the player-core encode ABI as failures / no-ops and
 * the `encode_config` option group (reproduced verbatim — pure option
 * data) so options/options.c keeps parsing the --o* options identically
 * (they simply never trigger an encode context, because the player only
 * creates one when opts->encode_opts->file is set).
 *
 * The encoder_* helpers (encoder_context_alloc / encoder_init_codec_and_
 * muxer / encoder_encode / encoder_get_mux_timebase_unlocked) are NOT
 * provided: they were referenced only by the removed ao_lavc.c / vo_lavc.c
 * / vo_image.c TUs.
 *
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdbool.h>
#include <stddef.h>

#include "encode.h"
#include "options/m_option.h"
#include "options/options.h"

/* Option group: referenced by options/options.c via OPT_SUBSTRUCT(
 * encode_opts, encode_config). Reproduced verbatim from upstream — pure
 * option data, no libavformat dependency. */
#define OPT_BASE_STRUCT struct encode_opts
const struct m_sub_options encode_config = {
    .opts = (const m_option_t[]) {
        {"o", OPT_STRING(file), .flags = M_OPT_NOCFG | M_OPT_PRE_PARSE | M_OPT_FILE},
        {"of", OPT_STRING(format)},
        {"ofopts", OPT_KEYVALUELIST(fopts), .flags = M_OPT_HAVE_HELP},
        {"ovc", OPT_STRING(vcodec)},
        {"ovcopts", OPT_KEYVALUELIST(vopts), .flags = M_OPT_HAVE_HELP},
        {"oac", OPT_STRING(acodec)},
        {"oacopts", OPT_KEYVALUELIST(aopts), .flags = M_OPT_HAVE_HELP},
        {"orawts", OPT_BOOL(rawts)},
        {"ocopy-metadata", OPT_BOOL(copy_metadata)},
        {"oset-metadata", OPT_KEYVALUELIST(set_metadata)},
        {"oremove-metadata", OPT_STRINGLIST(remove_metadata)},
        {0}
    },
    .size = sizeof(struct encode_opts),
    .defaults = &(const struct encode_opts){
        .copy_metadata = true,
    },
};

/* ---- player-core ABI (common/encode.h) --------------------------------
 *
 * Encode mode is unreachable in the audio-only build: the player only
 * calls encode_lavc_init() when opts->encode_opts->file is set, and the
 * kit never sets --o=. encode_lavc_init() returning NULL keeps
 * mpctx->encode_lavc_ctx NULL, and every other function tolerates a NULL
 * ctx (matching how the player calls them). */

struct encode_lavc_context *encode_lavc_init(struct mpv_global *global)
{
    (void)global;
    return NULL;
}

bool encode_lavc_free(struct encode_lavc_context *ctx)
{
    (void)ctx;
    return true;
}

void encode_lavc_discontinuity(struct encode_lavc_context *ctx)
{
    (void)ctx;
}

bool encode_lavc_showhelp(struct mp_log *log, struct encode_opts *options)
{
    (void)log; (void)options;
    return false;
}

int encode_lavc_getstatus(struct encode_lavc_context *ctx, char *buf,
                          int bufsize, float relative_position)
{
    (void)ctx; (void)buf; (void)bufsize; (void)relative_position;
    return -1;
}

bool encode_lavc_stream_type_ok(struct encode_lavc_context *ctx,
                                enum stream_type type)
{
    (void)ctx; (void)type;
    return false;
}

void encode_lavc_expect_stream(struct encode_lavc_context *ctx,
                               enum stream_type type)
{
    (void)ctx; (void)type;
}

void encode_lavc_set_metadata(struct encode_lavc_context *ctx,
                              struct mp_tags *metadata)
{
    (void)ctx; (void)metadata;
}

bool encode_lavc_didfail(struct encode_lavc_context *ctx)
{
    (void)ctx;
    return false;
}

/* Declared in common/encode_lavc.h; called from player/main.c at startup
 * to wire the global log. No encode log to install in the stub. */
void encoder_update_log(struct mpv_global *global)
{
    (void)global;
}
'''


def write_encode_stub(src):
    _overwrite_in_place(os.path.join(src, ENCODE_REL), ENCODE_STUB,
                    'encode mode disabled')


# ─── overwrite: sub/draw_bmp.c ──────────────────────────────────────────

DRAW_BMP_REL = os.path.join('sub', 'draw_bmp.c')

DRAW_BMP_STUB = r'''/*
 * ''' + MARKER + r'''
 *
 * No-op stub of sub/draw_bmp.c for an audio-only build (sid=no, vo=null,
 * no OSD/subtitle bitmap rendering). draw_bmp.h is kept UNCHANGED. The
 * staying file sub/osd.c references mp_draw_sub_formats / mp_draw_sub_alloc
 * / mp_draw_sub_bitmaps; other (conditional, not-compiled) VOs reference
 * mp_draw_sub_overlay / mp_draw_sub_get_dbg_info / mp_draw_sub_alloc_test.
 * All are provided here as no-ops / failures: no subtitle bitmaps are ever
 * produced (sid=no), so these are unreachable at runtime.
 *
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stddef.h>
#include <stdbool.h>

#include "draw_bmp.h"

/* osd.c passes this as the list of sub-bitmap formats the renderer accepts.
 * All-false means "render nothing", which is correct without a renderer. */
const bool mp_draw_sub_formats[SUBBITMAP_COUNT] = {0};

struct mp_draw_sub_cache *mp_draw_sub_alloc(void *ta_parent, struct mpv_global *g)
{
    (void)ta_parent; (void)g;
    return NULL;
}

struct mp_draw_sub_cache *mp_draw_sub_alloc_test(struct mp_image *dst)
{
    (void)dst;
    return NULL;
}

bool mp_draw_sub_bitmaps(struct mp_draw_sub_cache *cache, struct mp_image *dst,
                         struct sub_bitmap_list *sbs_list)
{
    (void)cache; (void)dst; (void)sbs_list;
    return false;
}

char *mp_draw_sub_get_dbg_info(struct mp_draw_sub_cache *c)
{
    (void)c;
    return NULL;
}

struct mp_image *mp_draw_sub_overlay(struct mp_draw_sub_cache *cache,
                                     struct sub_bitmap_list *sbs_list,
                                     struct mp_rect *act_rcs,
                                     int max_act_rcs,
                                     int *num_act_rcs,
                                     struct mp_rect *mod_rcs,
                                     int max_mod_rcs,
                                     int *num_mod_rcs)
{
    (void)cache; (void)sbs_list;
    (void)act_rcs; (void)max_act_rcs;
    (void)mod_rcs; (void)max_mod_rcs;
    if (num_act_rcs)
        *num_act_rcs = 0;
    if (num_mod_rcs)
        *num_mod_rcs = 0;
    return NULL;
}
'''


def write_draw_bmp_stub(src):
    _overwrite_in_place(os.path.join(src, DRAW_BMP_REL), DRAW_BMP_STUB,
                    'sub bitmap rendering disabled')


# ─── meson.build: drop removed sources + add the new gpu stub ───────────

# Sources removed entirely (no surviving reference → no stub needed).
MESON_REMOVE_SRC = [
    # GPU / shader render stack
    "    'video/out/gpu/context.c',\n",
    "    'video/out/gpu/error_diffusion.c',\n",
    "    'video/out/gpu/hwdec.c',\n",
    "    'video/out/gpu/lcms.c',\n",
    "    'video/out/gpu/libmpv_gpu.c',\n",
    "    'video/out/gpu/osd.c',\n",
    "    'video/out/gpu/ra.c',\n",
    "    'video/out/gpu/shader_cache.c',\n",
    "    'video/out/gpu/spirv.c',\n",
    "    'video/out/gpu/user_shaders.c',\n",
    "    'video/out/gpu/utils.c',\n",
    "    'video/out/gpu/video.c',\n",
    "    'video/out/gpu/video_shaders.c',\n",
    "    'video/out/vo_gpu.c',\n",
    "    'video/out/vo_gpu_next.c',\n",
    "    'video/out/placebo/ra_pl.c',\n",
    "    'video/out/placebo/utils.c',\n",
    "    'video/out/gpu_next/context.c',\n",
    # Encode mode VO/AO (encode_lavc.c is stubbed in place, not removed)
    "    'audio/out/ao_lavc.c',\n",
    "    'video/out/vo_lavc.c',\n",
    "    'video/out/vo_image.c',\n",
    # Terminal video outputs (ASCII/kitty-graphics) — pure video, unused for
    # audio (vo=null) and they #include <libswscale/swscale.h> directly, which
    # is gone after --disable-swscale, so they MUST be dropped.
    "    'video/out/vo_tct.c',\n",
    "    'video/out/vo_kitty.c',\n",
    # Sub bitmap decode/render (draw_bmp.c is stubbed in place, not removed)
    "    'sub/sd_lavc.c',\n",
    "    'sub/img_convert.c',\n",
    "    'sub/lavc_conv.c',\n",
    "    'sub/filter_sdh.c',\n",
]

# Anchor for inserting the new stub_gpu.c source (a sibling that always
# stays in the unconditional files() list and is not otherwise touched).
MESON_STUB_GPU_LINE = "    'video/out/stub_gpu.c',\n"
MESON_STUB_GPU_ANCHOR = "    'video/out/vo.c',\n"


def patch_meson(path):
    text = _read(path)
    orig = text

    text = _drop_lines(text, MESON_REMOVE_SRC, path, 'removed sources')

    if MESON_STUB_GPU_LINE not in text:
        if MESON_STUB_GPU_ANCHOR not in text:
            raise RuntimeError(
                f"Anchor `video/out/vo.c` not found in {path}; cannot add "
                f"the GPU stub source.")
        text = text.replace(MESON_STUB_GPU_ANCHOR,
                            MESON_STUB_GPU_ANCHOR + MESON_STUB_GPU_LINE, 1)

    if text == orig:
        print(f'Already patched: {path}')
        return
    _write(path, text)
    print(f'Patched: {path} (dropped dead sources, added stub_gpu.c)')


# ─── video/out/vo.c: cut driver externs + array entries ─────────────────

VO_C_EXTERNS = [
    "extern const struct vo_driver video_out_gpu;\n",
    "extern const struct vo_driver video_out_gpu_next;\n",
    "extern const struct vo_driver video_out_image;\n",
    "extern const struct vo_driver video_out_lavc;\n",
    "extern const struct vo_driver video_out_tct;\n",
    "extern const struct vo_driver video_out_kitty;\n",
]

VO_C_ENTRIES = [
    "    &video_out_gpu_next,\n",
    "    &video_out_gpu,\n",
    "    &video_out_image,\n",
    "    &video_out_lavc,\n",
    "    &video_out_tct,\n",
    "    &video_out_kitty,\n",
]


def patch_vo_c(path):
    text = _read(path)
    orig = text
    text = _drop_lines(text, VO_C_EXTERNS, path, 'vo driver externs')
    text = _drop_lines(text, VO_C_ENTRIES, path, 'vo driver array entries')
    if text == orig:
        print(f'Already patched: {path}')
        return
    # Sanity: the anchors must actually have been present at least once.
    if "&video_out_gpu_next" in text or "&video_out_lavc" in text or \
       "&video_out_image" in text:
        raise RuntimeError(
            f"Failed to fully cut removed VO driver entries from {path} — "
            f"mpv source layout changed.")
    _write(path, text)
    print(f'Patched: {path} (cut gpu/gpu_next/image/lavc VO drivers)')


# ─── video/out/vo_libmpv.c: cut render_backend_gpu entry ────────────────

VO_LIBMPV_ENTRY_OLD = (
    "const struct render_backend_fns *render_backends[] = {\n"
    "    &render_backend_gpu,\n"
    "    &render_backend_sw,\n"
    "    NULL\n"
    "};\n"
)
VO_LIBMPV_ENTRY_NEW = (
    "const struct render_backend_fns *render_backends[] = {\n"
    "    /* " + MARKER + ": &render_backend_gpu removed (GPU stack stripped). */\n"
    "    &render_backend_sw,\n"
    "    NULL\n"
    "};\n"
)


def patch_vo_libmpv_c(path):
    text = _read(path)
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if VO_LIBMPV_ENTRY_OLD not in text:
        raise RuntimeError(
            f"render_backends[] array not in the expected form in {path} — "
            f"mpv source layout changed.")
    text = text.replace(VO_LIBMPV_ENTRY_OLD, VO_LIBMPV_ENTRY_NEW, 1)
    _write(path, text)
    print(f'Patched: {path} (cut render_backend_gpu)')


# ─── audio/out/ao.c: cut audio_out_lavc entry ───────────────────────────

AO_C_ENTRY = "    &audio_out_lavc,\n"
AO_C_EXTERN = "extern const struct ao_driver audio_out_lavc;\n"


def patch_ao_c(path):
    text = _read(path)
    orig = text
    text = _drop_lines(text, [AO_C_EXTERN, AO_C_ENTRY], path, 'ao lavc')
    if text == orig:
        print(f'Already patched: {path}')
        return
    if "&audio_out_lavc" in text:
        raise RuntimeError(
            f"Failed to cut &audio_out_lavc from {path} — layout changed.")
    _write(path, text)
    print(f'Patched: {path} (cut audio_out_lavc driver)')


# ─── sub/dec_sub.c: cut sd_lavc from sd_list[] ──────────────────────────
#
# Drops the &sd_lavc array entry. The `extern const struct sd_functions
# sd_lavc;` decl is left in place (harmless unused decl; an unreferenced
# extern does not force a link). sd_ass is left untouched — it is supplied
# by patch_strip_libass.py.

DEC_SUB_ENTRY = "    &sd_lavc,\n"


def patch_dec_sub_c(path):
    text = _read(path)
    if DEC_SUB_ENTRY not in text:
        print(f'Already patched: {path}')
        return
    text = text.replace(DEC_SUB_ENTRY, '', 1)
    if "&sd_lavc," in text:
        raise RuntimeError(
            f"Failed to cut &sd_lavc from {path} — layout changed.")
    _write(path, text)
    print(f'Patched: {path} (cut sd_lavc from sd_list[])')


# ─── input/input.c: empty out builtin_input_conf[] ──────────────────────

INPUT_CONF_OLD = (
    "static const char builtin_input_conf[] =\n"
    "#include \"etc/input.conf.inc\"\n"
    ";\n"
)
INPUT_CONF_NEW = (
    "/* " + MARKER + ": default key bindings stripped (empty builtin conf). */\n"
    "static const char builtin_input_conf[] = \"\";\n"
)


def patch_input_c(path):
    text = _read(path)
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if INPUT_CONF_OLD not in text:
        raise RuntimeError(
            f"builtin_input_conf[] definition not in the expected form in "
            f"{path} — mpv source layout changed.")
    text = text.replace(INPUT_CONF_OLD, INPUT_CONF_NEW, 1)
    _write(path, text)
    print(f'Patched: {path} (emptied builtin_input_conf[])')


# ─── driver ─────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <mpv_src_dir>')
        sys.exit(1)
    src = sys.argv[1]

    # New / overwritten stub TUs.
    write_stub_gpu(src)
    write_screenshot_stub(src)
    write_image_writer_stub(src)
    write_encode_stub(src)
    write_draw_bmp_stub(src)

    # meson source list.
    patch_meson(os.path.join(src, 'meson.build'))

    # GC-root anchors.
    patch_vo_c(os.path.join(src, 'video', 'out', 'vo.c'))
    patch_vo_libmpv_c(os.path.join(src, 'video', 'out', 'vo_libmpv.c'))
    patch_ao_c(os.path.join(src, 'audio', 'out', 'ao.c'))
    patch_dec_sub_c(os.path.join(src, 'sub', 'dec_sub.c'))

    # Input default-bindings string.
    patch_input_c(os.path.join(src, 'input', 'input.c'))


if __name__ == '__main__':
    main()
