#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Make libswscale optional so mpv links without it (~1.57M saved).

For the audio-only consumer (vid=no, vo=null, sid=no, cover-art-auto=no,
cover art exposed as raw PNG/JPEG bytes), nothing ever scales pixels:
every video output, the subtitle bitmap renderer, the screenshot scaler,
the autoconvert/swscale filter graph and the image writer are all
unreachable at runtime. So the whole libswscale link dependency is dead
weight. ffmpeg itself is built separately with --disable-swscale (NOT
this patch's job); this patch only severs mpv's side of the dependency.

What it does to the mpv source tree (argv[1])
=============================================

1) meson.build — make the `libswscale` dependency `required: false` and
   drop the bare `libswscale` token from the `dependencies = [ ... ]`
   array so it is no longer force-linked into the binary.

2) meson.build — remove `filters/f_swscale.c` from the `files(...)`
   source list (it is the only TU that pulls in real libswscale symbols
   through `mp_sws_*`, and it's the swscale autoconvert filter, dead in
   an audio-only build).

3) common/av_log.c — compile out the `#include <libswscale/...>` headers
   and the `{"libswscale", ...}` version-table row, so the FFmpeg
   library-version banner no longer references swscale_version() /
   LIBSWSCALE_VERSION_INT.

4) video/sws_utils.c — OVERWRITE the whole TU with a stub that #includes
   the UNCHANGED sws_utils.h / f_swscale.h and provides, with EXACT
   signatures, every mp_sws_* / mp_image_* / sws_conf symbol that the
   surviving build files still reference. Stub bodies fail / no-op:
   scale → -1, alloc → talloc-zeroed context, *supports* → false,
   find_best_out_format → 0, filter_create → NULL, swap_to_native →
   identity. sws_utils.h and f_swscale.h are kept UNCHANGED.

Idempotent: every edit is guarded by a marker / "already done" check, so
re-running the build pipeline against a cached, already-patched tree is a
no-op and never double-applies or corrupts.

Usage
=====

    python3 patch_swscale_optional.py <mpv_source_dir>
"""
import sys
import os


# Idempotency marker — present in the stub TU and used as the meson.build
# "already patched" sentinel.
MARKER = 'MAK_SWSCALE_OPTIONAL_PATCH_V1'


# ─── meson.build ───────────────────────────────────────────────────────

# 1a) make the dependency() optional.
MESON_DEP_OLD = (
    "libswscale = dependency('libswscale', version: '>= 7.5.100')"
)
MESON_DEP_NEW = (
    "libswscale = dependency('libswscale', version: '>= 7.5.100', "
    "required: false)  # " + MARKER
)

# 1b) drop the bare `libswscale` element (and its leading comma) from the
# `dependencies = [ ... ]` array. Anchor on the two-line tail so we remove
# exactly the trailing element and nothing else.
MESON_ARR_OLD = (
    "                libswresample,\n"
    "                libswscale]"
)
MESON_ARR_NEW = (
    "                libswresample]"
)

# 2) drop the f_swscale.c source entry from the files(...) list.
MESON_SRC_OLD = "    'filters/f_swscale.c',\n"
MESON_SRC_NEW = ""


def patch_meson(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return

    if MESON_DEP_OLD not in text:
        raise RuntimeError(
            f'libswscale dependency() call not found in {path} — '
            f'mpv source layout changed.'
        )
    text = text.replace(MESON_DEP_OLD, MESON_DEP_NEW, 1)

    if MESON_ARR_OLD not in text:
        raise RuntimeError(
            f'`dependencies = [ ... libswscale]` array tail not found in '
            f'{path} — mpv source layout changed.'
        )
    text = text.replace(MESON_ARR_OLD, MESON_ARR_NEW, 1)

    if MESON_SRC_OLD not in text:
        raise RuntimeError(
            f"'filters/f_swscale.c' source entry not found in {path} — "
            f'mpv source layout changed.'
        )
    text = text.replace(MESON_SRC_OLD, MESON_SRC_NEW, 1)

    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path} '
          '(libswscale optional, dropped from link + f_swscale.c source)')


# ─── common/av_log.c ───────────────────────────────────────────────────

# Compile out the swscale headers. The two #include lines are contiguous
# in the source; wrapping them in `#if 0` removes both compile and link
# references to libswscale's version symbols.
AVLOG_INC_OLD = (
    "#include <libswscale/swscale.h>\n"
    "#include <libswscale/version.h>\n"
)
AVLOG_INC_NEW = (
    "/* " + MARKER + " — libswscale removed; headers compiled out */\n"
    "#if 0\n"
    "#include <libswscale/swscale.h>\n"
    "#include <libswscale/version.h>\n"
    "#endif\n"
)

# Compile out the version-table row that calls swscale_version() /
# references LIBSWSCALE_VERSION_INT (both gone with the headers above).
AVLOG_ROW_OLD = (
    "        {\"libswscale\",    LIBSWSCALE_VERSION_INT,    swscale_version()},\n"
)
AVLOG_ROW_NEW = (
    "        /* " + MARKER + " — libswscale row removed */\n"
)


def patch_av_log(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return

    if AVLOG_INC_OLD not in text:
        raise RuntimeError(
            f'libswscale #include block not found in {path} — '
            f'mpv source layout changed.'
        )
    text = text.replace(AVLOG_INC_OLD, AVLOG_INC_NEW, 1)

    if AVLOG_ROW_OLD not in text:
        raise RuntimeError(
            f'libswscale version-table row not found in {path} — '
            f'mpv source layout changed.'
        )
    text = text.replace(AVLOG_ROW_OLD, AVLOG_ROW_NEW, 1)

    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path} (libswscale version banner entry removed)')


# ─── video/sws_utils.c (full overwrite with a no-swscale stub) ─────────
#
# This replaces the libswscale-backed implementation with a self-contained
# stub TU. It keeps the public ABI that the rest of mpv links against:
#
#   from video/sws_utils.h (unchanged):
#       const int mp_sws_fast_flags;
#       bool      mp_sws_supported_format(int imgfmt);
#       int       mp_image_sw_blur_scale(struct mp_image*, struct mp_image*, float);
#       struct mp_sws_context *mp_sws_alloc(void *talloc_ctx);
#       void      mp_sws_enable_cmdline_opts(struct mp_sws_context*, struct mpv_global*);
#       int       mp_sws_reinit(struct mp_sws_context*);
#       int       mp_sws_scale(struct mp_sws_context*, struct mp_image*, struct mp_image*);
#       bool      mp_sws_supports_formats(struct mp_sws_context*, int, int);
#       struct mp_image *mp_img_swap_to_native(struct mp_image*);
#
#   from filters/f_swscale.h (unchanged; f_swscale.c is no longer built,
#   but f_autoconvert.c / f_auto_filters.c still reference these):
#       struct mp_sws_filter *mp_sws_filter_create(struct mp_filter *parent);
#       int  mp_sws_find_best_out_format(struct mp_sws_filter*, int, int*, int);
#       bool mp_sws_supports_input(int imgfmt);
#
#   the option sub-group, referenced by options/options.c via
#   `extern const struct m_sub_options sws_conf;` + OPT_SUBSTRUCT:
#       const struct m_sub_options sws_conf;
#
# sws_conf is kept fully populated (same opts/size/defaults as upstream)
# so the `--sws-*` option group keeps parsing identically. The SWS_* flag
# values it needs are compile-time constants; libswscale's header may be
# gone (ffmpeg built --disable-swscale), so they are defined locally as
# the stable public FFmpeg enum values rather than #included. No libswscale
# function is called or referenced, so nothing here forces the link.

SWS_UTILS_STUB = '''\
/*
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

/* ''' + MARKER + '''
 *
 * No-op stub of video/sws_utils.c for an audio-only build where mpv is
 * linked WITHOUT libswscale. Every pixel-scaling path that would reach
 * these functions (video output, subtitle bitmap blending, screenshots,
 * the autoconvert/swscale filter, the image writer) is disabled at
 * runtime in the audio-only consumer, so the stub bodies — which fail or
 * no-op — are never actually executed. They exist only to satisfy the
 * link.
 *
 * sws_utils.h and filters/f_swscale.h are kept UNCHANGED; this TU
 * provides every symbol the surviving build files still reference.
 */

#include <stdbool.h>

#include "config.h"

#include "sws_utils.h"

#include "common/common.h"
#include "options/m_option.h"
#include "video/mp_image.h"
#include "common/msg.h"

#include "filters/f_swscale.h"

/* f_swscale.h takes a `struct mp_filter *` by pointer only. */
struct mp_filter;

/* ---- option sub-group --------------------------------------------------
 *
 * options/options.c references `sws_conf` (extern) and registers the
 * `--sws-*` option group with OPT_SUBSTRUCT(sws_opts, sws_conf). We keep
 * the exact same group (opts/size/defaults) so command-line parsing is
 * unchanged, but define the SWS_* scaler enum values locally instead of
 * pulling them from <libswscale/swscale.h>, which may be absent when
 * ffmpeg is built with --disable-swscale. These are the stable public
 * FFmpeg `enum SwsFlags` bit values. */
#define MAK_SWS_FAST_BILINEAR  (1 <<  0)
#define MAK_SWS_BILINEAR       (1 <<  1)
#define MAK_SWS_BICUBIC        (1 <<  2)
#define MAK_SWS_X              (1 <<  3)
#define MAK_SWS_POINT          (1 <<  4)
#define MAK_SWS_AREA           (1 <<  5)
#define MAK_SWS_BICUBLIN       (1 <<  6)
#define MAK_SWS_GAUSS          (1 <<  7)
#define MAK_SWS_SINC           (1 <<  8)
#define MAK_SWS_LANCZOS        (1 <<  9)
#define MAK_SWS_SPLINE         (1 << 10)

struct sws_opts {
    int scaler;
    float lum_gblur;
    float chr_gblur;
    int chr_vshift;
    int chr_hshift;
    float chr_sharpen;
    float lum_sharpen;
    bool fast;
    bool bitexact;
    bool zimg;
};

#define OPT_BASE_STRUCT struct sws_opts
const struct m_sub_options sws_conf = {
    .opts = (const m_option_t[]) {
        {"scaler", OPT_CHOICE(scaler,
            {"fast-bilinear",   MAK_SWS_FAST_BILINEAR},
            {"bilinear",        MAK_SWS_BILINEAR},
            {"bicubic",         MAK_SWS_BICUBIC},
            {"x",               MAK_SWS_X},
            {"point",           MAK_SWS_POINT},
            {"area",            MAK_SWS_AREA},
            {"bicublin",        MAK_SWS_BICUBLIN},
            {"gauss",           MAK_SWS_GAUSS},
            {"sinc",            MAK_SWS_SINC},
            {"lanczos",         MAK_SWS_LANCZOS},
            {"spline",          MAK_SWS_SPLINE})},
        {"lgb", OPT_FLOAT(lum_gblur), M_RANGE(0, 100.0)},
        {"cgb", OPT_FLOAT(chr_gblur), M_RANGE(0, 100.0)},
        {"cvs", OPT_INT(chr_vshift), M_RANGE(-100, 100)},
        {"chs", OPT_INT(chr_hshift), M_RANGE(-100, 100)},
        {"ls", OPT_FLOAT(lum_sharpen), M_RANGE(-100.0, 100.0)},
        {"cs", OPT_FLOAT(chr_sharpen), M_RANGE(-100.0, 100.0)},
        {"fast", OPT_BOOL(fast)},
        {"bitexact", OPT_BOOL(bitexact)},
        {"allow-zimg", OPT_BOOL(zimg)},
        {0}
    },
    .size = sizeof(struct sws_opts),
    .defaults = &(const struct sws_opts){
        .scaler = MAK_SWS_LANCZOS,
        .zimg = true,
    },
};

/* ---- sws_utils.h ABI ---------------------------------------------------*/

/* Same numeric value as upstream (SWS_BILINEAR == 1 << 1). Kept so any
 * reader of the public symbol sees a sane flag rather than 0. */
const int mp_sws_fast_flags = MAK_SWS_BILINEAR;

bool mp_sws_supported_format(int imgfmt)
{
    (void)imgfmt;
    return false;
}

int mp_image_sw_blur_scale(struct mp_image *dst, struct mp_image *src,
                           float gblur)
{
    (void)dst; (void)src; (void)gblur;
    return -1;
}

struct mp_sws_context *mp_sws_alloc(void *talloc_ctx)
{
    /* Return a zeroed-but-valid context so callers that immediately set
     * fields and later call mp_sws_scale() (which fails) don't crash on a
     * NULL deref. Mirrors upstream: a talloc child of talloc_ctx. */
    struct mp_sws_context *ctx =
        talloc_zero(talloc_ctx, struct mp_sws_context);
    ctx->log = mp_null_log;
    ctx->cached = talloc_zero(ctx, struct mp_sws_context);
    return ctx;
}

void mp_sws_enable_cmdline_opts(struct mp_sws_context *ctx, struct mpv_global *g)
{
    (void)ctx; (void)g;
}

int mp_sws_reinit(struct mp_sws_context *ctx)
{
    (void)ctx;
    return -1;
}

int mp_sws_scale(struct mp_sws_context *ctx, struct mp_image *dst,
                 struct mp_image *src)
{
    (void)ctx; (void)dst; (void)src;
    return -1;
}

bool mp_sws_supports_formats(struct mp_sws_context *ctx,
                             int imgfmt_out, int imgfmt_in)
{
    (void)ctx; (void)imgfmt_out; (void)imgfmt_in;
    return false;
}

struct mp_image *mp_img_swap_to_native(struct mp_image *img)
{
    /* No swscale; return the image unmodified (identity). */
    return img;
}

/* ---- filters/f_swscale.h ABI ------------------------------------------
 * f_swscale.c is no longer compiled, but f_autoconvert.c and
 * f_auto_filters.c still reference these three exports. */

struct mp_sws_filter *mp_sws_filter_create(struct mp_filter *parent)
{
    (void)parent;
    return NULL;
}

int mp_sws_find_best_out_format(struct mp_sws_filter *sws,
                                int in_format, int *out_formats,
                                int num_out_formats)
{
    (void)sws; (void)in_format; (void)out_formats; (void)num_out_formats;
    return 0;
}

bool mp_sws_supports_input(int imgfmt)
{
    (void)imgfmt;
    return false;
}

// vim: ts=4 sw=4 et tw=80
'''


def patch_sws_utils(path):
    if os.path.exists(path):
        with open(path) as f:
            existing = f.read()
        if MARKER in existing:
            print(f'Already patched: {path}')
            return
    with open(path, 'w') as f:
        f.write(SWS_UTILS_STUB)
    print(f'Patched: {path} (overwritten with no-swscale stub TU)')


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <mpv_src_dir>')
        sys.exit(1)
    src = sys.argv[1]
    patch_meson(os.path.join(src, 'meson.build'))
    patch_av_log(os.path.join(src, 'common', 'av_log.c'))
    patch_sws_utils(os.path.join(src, 'video', 'sws_utils.c'))


if __name__ == '__main__':
    main()
