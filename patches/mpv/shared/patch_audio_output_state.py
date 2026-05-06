#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patches mpv to expose the audio-output lifecycle as a clean, observable
string property `audio-output-state`.

Problem
=======

The wrapper-side workaround for detecting "audio output failed to
initialize" is a 1-second delayed poll on `audio-out-params/format`
scheduled every time `core-idle` flips to false. The workaround works in
the common case but is fragile:

  - **False positive on slow init.** A legitimate slow `ao_init` (e.g.
    coreaudio waiting on the device, pipewire negotiation) reads as
    "failed" if the format isn't populated within the polling window.
  - **False negative on fast end.** If the file is unloaded before the
    timer fires (very short tracks, rapid skips), the timer fires after
    the AO has already been torn down and reads "failed" against a
    transient empty state.
  - **No "still trying" signal.** The wrapper has no way to render a
    "connecting…" UI; it only has the binary "format is empty / not
    empty" inference.

Upstream mpv tracks the AO lifecycle internally via `ao_init_best()` →
`mpctx->ao` (NULL on failure, non-NULL on success) and `uninit_audio_out()`,
but does not expose the state through the client API. This patch adds a
read-only string property `audio-output-state` so a client can call
`mpv_observe_property("audio-output-state", MPV_FORMAT_STRING)` and receive
change events at every transition.

States
======

    closed        — no AO active (file not loaded, or unloaded). Default.
    initializing  — `ao_init_best()` in flight.
    active        — `ao_init_best()` succeeded, AO is producing samples.
    failed        — `ao_init_best()` returned NULL; details in the log.

Transitions wired
=================

    reinit_audio_filters_and_output() right before ao_init_best → initializing
    reinit_audio_filters_and_output() after ao_init_best success → active
    reinit_audio_filters_and_output() ao_init failure path       → failed
    uninit_audio_out() tail                                      → closed

`failed` persistence
====================

The AO-init failure path sets `failed` and then `goto init_error`, whose
cleanup calls uninit_audio_out(). uninit_audio_out() runs on every AO
teardown, so an unconditional `closed` write there would overwrite the
just-set `failed` in the SAME core-thread playloop tick — and because the
property getter is read lazily once at end-of-tick, the observer would
only ever see `closed`. The `failed` event would be unobservable.

So the uninit_audio_out() tail writes `closed` only when the current
state is not `failed`; `failed` then persists until the next init's
`initializing` edge naturally clears it (the same persistence model the
`used`/`failed` prefetch states use). The three non-failure `goto
init_error` paths (filter-setup, format-retry) never set `failed`, so
they still report `closed` correctly.

Files patched
=============

    player/core.h       adds the MPContext field
    player/command.c    registers `audio-output-state` in mp_properties_base
    player/audio.c      helper + transition calls

Usage
=====

    python3 patch_audio_output_state.py <mpv_source_dir>

The patch is independent of patch_prefetch_state.py — both can be applied
to the same source tree in either order. Each anchors on a different
MPContext field (this patch anchors on `audio_status`; prefetch_state
anchors on `als_state`).
"""
import sys
import os


# Shared marker that makes every sub-patch idempotent. If the marker is
# present in the file, the file is already patched; safe to re-run the
# build pipeline against the same extracted mpv tree.
MARKER = 'MAK_AUDIO_OUTPUT_STATE_PATCH_V1'


# ─── core.h ────────────────────────────────────────────────────────────

# Anchor on the `audio_status` field — stable, directly conceptually
# adjacent to the new state, and disjoint from `patch_prefetch_state.py`'s
# `als_state` anchor so the two patches compose cleanly.
CORE_PRISTINE = (
    '    enum playback_status video_status, audio_status;\n'
    '    bool restart_complete;'
)

CORE_PATCHED = (
    '    enum playback_status video_status, audio_status;\n'
    '\n'
    '    /* ' + MARKER + ' ─── observable audio output lifecycle.\n'
    '     *\n'
    '     * Exposed via the read-only `audio-output-state` property. Written\n'
    '     * only from the core thread via mak_set_audio_output_state() in\n'
    '     * audio.c; read from command.c\'s property getter. Values:\n'
    '     *   0 = closed, 1 = initializing, 2 = active, 3 = failed. */\n'
    '    int mak_audio_output_state;\n'
    '\n'
    '    bool restart_complete;'
)


def patch_core_h(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if CORE_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor not found in {path} — mpv source may have changed.'
        )
    with open(path, 'w') as f:
        f.write(text.replace(CORE_PRISTINE, CORE_PATCHED, 1))
    print(f'Patched: {path}')


# ─── command.c ─────────────────────────────────────────────────────────

# Insert the property registration right after `audio-out-params`. Stable
# anchor and groups our property with the other audio-output-related
# entries for readability.
COMMAND_PRISTINE = (
    '    {"audio-params", mp_property_audio_params},\n'
    '    {"audio-out-params", mp_property_audio_out_params},'
)

COMMAND_PATCHED = (
    '    {"audio-params", mp_property_audio_params},\n'
    '    {"audio-out-params", mp_property_audio_out_params},\n'
    '    /* ' + MARKER + ' */\n'
    '    {"audio-output-state", mp_property_audio_output_state},'
)

# Insert the getter just before mp_property_audio_params — same
# neighbourhood, stable, and unaffected by other patches in scripts/.
COMMAND_GETTER_ANCHOR = (
    'static int mp_property_audio_params(void *ctx, struct m_property *prop,'
)

COMMAND_GETTER_INSERT = (
    '/* ' + MARKER + ' ─── read-only string property: closed | initializing |\n'
    ' * active | failed. Observe with mpv_observe_property to receive change\n'
    ' * events at every transition of the audio output lifecycle. */\n'
    'static int mp_property_audio_output_state(void *ctx, struct m_property *prop,\n'
    '                                          int action, void *arg)\n'
    '{\n'
    '    MPContext *mpctx = ctx;\n'
    '    const char *name;\n'
    '    switch (mpctx->mak_audio_output_state) {\n'
    '        case 1:  name = "initializing"; break;\n'
    '        case 2:  name = "active";       break;\n'
    '        case 3:  name = "failed";       break;\n'
    '        default: name = "closed";       break;\n'
    '    }\n'
    '    return m_property_strdup_ro(action, arg, name);\n'
    '}\n'
    '\n'
    + COMMAND_GETTER_ANCHOR
)


def patch_command_c(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if COMMAND_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (property table) not found in {path}.'
        )
    if COMMAND_GETTER_ANCHOR not in text:
        raise RuntimeError(
            f'Pristine anchor (getter insertion point) not found in {path}.'
        )
    text = text.replace(COMMAND_PRISTINE, COMMAND_PATCHED, 1)
    text = text.replace(COMMAND_GETTER_ANCHOR, COMMAND_GETTER_INSERT, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── audio.c ───────────────────────────────────────────────────────────
#
# We add a small helper near the top of the file (before the first
# function definition) and invoke it at four call sites: before
# ao_init_best, on success, on failure, and on uninit.

# Anchor on the includes block — `core.h` and `command.h` are the last
# includes in audio.c and stable across releases.
AUDIO_HELPER_ANCHOR = (
    '#include "core.h"\n'
    '#include "command.h"'
)

AUDIO_HELPER_INSERT = AUDIO_HELPER_ANCHOR + '\n\n' + (
    '/* ' + MARKER + ' ─── transition helper for the audio-output-state\n'
    ' * property. Must only be called from the core thread —\n'
    ' * mp_notify_property touches the client event queue and is not\n'
    ' * thread-safe against concurrent writers. All four documented call\n'
    ' * sites (reinit_audio_filters_and_output + uninit_audio_out) satisfy\n'
    ' * this. */\n'
    'static void mak_set_audio_output_state(struct MPContext *mpctx, int state)\n'
    '{\n'
    '    if (mpctx->mak_audio_output_state == state)\n'
    '        return;\n'
    '    mpctx->mak_audio_output_state = state;\n'
    '    mp_notify_property(mpctx, "audio-output-state");\n'
    '}'
)

# Transition call sites. Each is (pristine, patched).

AUDIO_CALL_SITES = [
    # 1. reinit_audio_chain_src: emit `initializing` right before
    #    ao_init_best. We anchor on the line that sets ao_filter_fmt
    #    immediately above the ao_init_best call — stable and unique.
    (
        '    mpctx->ao_filter_fmt = out_fmt;\n'
        '\n'
        '    mpctx->ao = ao_init_best(mpctx->global, ao_flags, mp_wakeup_core_cb,',
        '    mpctx->ao_filter_fmt = out_fmt;\n'
        '\n'
        '    /* ' + MARKER + ' */\n'
        '    mak_set_audio_output_state(mpctx, 1 /* initializing */);\n'
        '\n'
        '    mpctx->ao = ao_init_best(mpctx->global, ao_flags, mp_wakeup_core_cb,',
    ),
    # 2. ao_init_best success — emit `active` right before the MP_INFO log
    #    line that prints the format. Anchor on the language-invariant
    #    MP_INFO call (unique in audio.c) rather than the size-sensitive
    #    `char tmp[192];` declaration above it.
    (
        '    MP_INFO(mpctx, "AO: [%s] %s\\n", ao_get_name(mpctx->ao),',
        '    /* ' + MARKER + ' */\n'
        '    mak_set_audio_output_state(mpctx, 2 /* active */);\n'
        '\n'
        '    MP_INFO(mpctx, "AO: [%s] %s\\n", ao_get_name(mpctx->ao),',
    ),
    # 3. ao_init_best failure — emit `failed` right after the
    #    MPV_ERROR_AO_INIT_FAILED assignment. Anchor on that language-
    #    invariant line (unique) + its `goto init_error`, not on the
    #    English MP_ERR string, so a wording change upstream can't drift
    #    the anchor.
    (
        '        mpctx->error_playing = MPV_ERROR_AO_INIT_FAILED;\n'
        '        goto init_error;',
        '        mpctx->error_playing = MPV_ERROR_AO_INIT_FAILED;\n'
        '        /* ' + MARKER + ' */\n'
        '        mak_set_audio_output_state(mpctx, 3 /* failed */);\n'
        '        goto init_error;',
    ),
    # 4. uninit_audio_out tail — emit `closed` after the AO is torn down.
    #    Anchor on the line that NULLs mpctx->ao + the trailing TA_FREEP
    #    so we land outside the `if (mpctx->ao)` block. Guarded so it does
    #    NOT overwrite a `failed` set on the AO-init failure path (this
    #    function runs as part of that path's cleanup, in the same tick);
    #    `failed` then persists until the next init's `initializing` edge.
    #    See the "`failed` persistence" note in the module docstring.
    (
        '    mpctx->ao = NULL;\n'
        '    TA_FREEP(&mpctx->ao_filter_fmt);\n'
        '}',
        '    mpctx->ao = NULL;\n'
        '    TA_FREEP(&mpctx->ao_filter_fmt);\n'
        '    /* ' + MARKER + ' */\n'
        '    if (mpctx->mak_audio_output_state != 3 /* failed */)\n'
        '        mak_set_audio_output_state(mpctx, 0 /* closed */);\n'
        '}',
    ),
]


def patch_audio_c(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if AUDIO_HELPER_ANCHOR not in text:
        raise RuntimeError(
            f'Pristine anchor (audio.c includes) not found in {path}.'
        )
    text = text.replace(AUDIO_HELPER_ANCHOR, AUDIO_HELPER_INSERT, 1)
    for pristine, patched in AUDIO_CALL_SITES:
        if pristine not in text:
            raise RuntimeError(
                f'Pristine anchor not found in {path}:\n{pristine[:120]}'
            )
        text = text.replace(pristine, patched, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <mpv_src_dir>')
        sys.exit(1)
    src = sys.argv[1]
    patch_core_h(os.path.join(src, 'player', 'core.h'))
    patch_command_c(os.path.join(src, 'player', 'command.c'))
    patch_audio_c(os.path.join(src, 'player', 'audio.c'))


if __name__ == '__main__':
    main()
