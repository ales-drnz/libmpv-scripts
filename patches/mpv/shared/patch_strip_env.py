#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Remove the env:// protocol and the env property of mpv 0.42.0.

mpv 0.42.0 adds two ways to read the environment of the process:

    env://NAME   stream/stream_env.c, a stream whose data is the value of
                 the environment variable NAME (stream_info_env).
    env          player/command.c, a read-only property that lists every
                 variable, and env/NAME one of them (mp_property_env).

In a library inside an app the environment is the app's: tokens, paths and
settings it never meant to hand to whatever chooses what the player opens or
which properties a string expands. A playlist entry or a URL from a server
should not be a way to read them, and neither should a property expansion
(${env/NAME}) in text an app passes through. The kit uses neither, so both
leave the build:

    meson.build          'stream/stream_env.c' out of the sources.
    stream/stream.c      &stream_info_env out of stream_list[] and its
                         extern declaration out.
    player/command.c     mp_property_env() out, and its row of
                         mp_properties_base[]: get_property("env") then
                         fails as for any unknown property.

stream/stream_bstr.c stays: stream_memory.c (memory://) opens through it
too. env:// is then a protocol no stream of mpv takes, and FFmpeg has none
of that name either.

Required, not a toggle: it is a decision on what the library exposes, not
a size reduction. Each edited file carries the marker, so a second run is a
no-op. Applied on every platform via apply_mpv_patches_common().

Usage: patch_strip_env.py <mpv source dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = 'MAK_STRIP_ENV_PATCH_V1'

MESON_OLD = "    'stream/stream_env.c',\n"
MESON_NEW = "    # " + MARKER + ": stream/stream_env.c (env://) removed.\n"

STREAM_EXTERN = "extern const stream_info_t stream_info_env;\n"
STREAM_ENTRY_OLD = (
    "    &stream_info_ffmpeg_unsafe,\n"
    "    &stream_info_env,\n"
    "};\n"
)
STREAM_ENTRY_NEW = (
    "    &stream_info_ffmpeg_unsafe,\n"
    "    /* " + MARKER + ": &stream_info_env (env://) removed. */\n"
    "};\n"
)

PROP_FN_OLD = r'''static int mp_property_env(void *ctx, struct m_property *prop,
                           int action, void *arg)
{
    switch (action) {
    case M_PROPERTY_GET_TYPE:
        *(struct m_option *)arg = (struct m_option){.type = CONF_TYPE_NODE};
        return M_PROPERTY_OK;
    case M_PROPERTY_GET:
    case M_PROPERTY_GET_NODE: {
        struct mpv_node node;
        node_init(&node, MPV_FORMAT_NODE_MAP, NULL);
        for (char **env = environ; env && *env; env++) {
            char *sep = strchr(*env, '=');
            if (!sep)
                continue;
            bstr key = { .start = *env, .len = sep - *env };
            struct mpv_node *np = node_map_badd(&node, key, MPV_FORMAT_NONE);
            np->format = MPV_FORMAT_STRING;
            np->u.string = talloc_strdup(node.u.list, sep + 1);
        }
        *(struct mpv_node *)arg = node;
        return M_PROPERTY_OK;
    }
    case M_PROPERTY_KEY_ACTION: {
        struct m_property_action_arg *ka = arg;
        char *val = getenv(ka->key);
        return m_property_strdup_ro(ka->action, ka->arg, val);
    }
    }
    return M_PROPERTY_NOT_IMPLEMENTED;
}

'''
PROP_FN_NEW = ('/* ' + MARKER + ': mp_property_env (the env property) '
               'removed. */\n\n')
PROP_ROW_OLD = '    {"env", mp_property_env},\n'


def apply(p):
    p.edits('meson.build', [('stream_env.c source', MESON_OLD, MESON_NEW)])
    p.edits('stream/stream.c', [
        ('stream_info_env extern', STREAM_EXTERN, ''),
        ('stream_list[] env entry', STREAM_ENTRY_OLD, STREAM_ENTRY_NEW),
    ])
    p.edits('player/command.c', [
        ('mp_property_env()', PROP_FN_OLD, PROP_FN_NEW),
        ('mp_properties_base[] env row', PROP_ROW_OLD, ''),
    ])


anchor.main(apply, 'patch_strip_env', marker=MARKER, usage='<mpv source dir>')
