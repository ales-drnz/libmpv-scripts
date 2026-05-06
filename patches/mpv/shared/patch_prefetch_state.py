#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patches mpv to expose the background prefetch lifecycle as a clean,
observable string property `prefetch-state`.

Problem
=======

Upstream mpv tracks the prefetch state internally across three fields in
`MPContext` (`open_active`, `open_for_prefetch`, `open_done`) plus the
secondary demuxer's reader state, but does not expose any of it through
the client API. Clients that want to show "Prefetching…" UI, or verify
that gapless transitions are reusing a buffered stream, are forced to
parse the internal MP_VERBOSE log lines — a brittle mechanism that
breaks silently across backends (Plex DASH, Jellyfin HLS, raw HTTP, SMB,
local files) whenever the log format changes between mpv releases.

This patch adds a proper observable property so the client can use
`mpv_observe_property("prefetch-state", MPV_FORMAT_STRING)` and receive
change events at the key transitions.

States
======

    idle     — no background prefetch active
    loading  — prefetch_next() fired; opener thread is creating the
               demuxer and the secondary cache is filling
    ready    — secondary demuxer is open AND its reader reports idle
               (= cache has hit cache-secs and the demuxer is no longer
                  requesting data). Gapless is armed.
    used     — a transition into the prefetched stream just happened
               (the "Using prefetched/prefetching URL." code path). The
               state PERSISTS at `used` until the next prefetch_next (or
               a cancel) naturally clears it — back-to-back used→idle
               would be coalesced by mpv's property-change queue and the
               observer would never see the `used` value.
    failed   — opener thread completed but the demuxer creation failed
               (network error, codec unsupported, hook abort). Same
               persistence model as `used`: the state holds at `failed`
               until the next prefetch_next (loading) or cancel
               naturally clears it, so observers reliably see the
               failure event.

Transitions wired
=================

    prefetch_next()                 → loading
    handle_update_cache() polling   → ready (once open_done && reader idle)
    open_demux_reentrant()
      ├─ "Using prefetched" branch  → used (persists)
      ├─ "Prefetched URL failed"    → failed (persists)
      ├─ "Aborting…" / "Dropping…"  → idle
      └─ cancel path                → idle
    cancel_open()                   → idle (unless already `failed`)

Files patched
=============

    player/core.h       adds the enum + MPContext field
    player/command.c    registers `prefetch-state` in mp_properties_base
    player/loadfile.c   helper + transition calls
    player/playloop.c   polls for ready inside handle_update_cache

Usage
=====

    python3 patch_prefetch_state.py <mpv_source_dir>
"""
import sys
import os


# Shared marker that makes every sub-patch idempotent: if the marker is
# present in the file, that file is already patched. Lets the build run
# multiple times against the same source tree without double-patching.
MARKER = 'MAK_PREFETCH_STATE_PATCH_V1'


# ─── core.h ────────────────────────────────────────────────────────────

CORE_PRISTINE = (
    '    struct mp_als *als_state; // lazily initialized on first use\n'
    '} MPContext;'
)

CORE_PATCHED = (
    '    struct mp_als *als_state; // lazily initialized on first use\n'
    '\n'
    '    /* ' + MARKER + ' ─── prefetch lifecycle state.\n'
    '     *\n'
    '     * Exposed via the `prefetch-state` read-only property. Written\n'
    '     * only from the core thread via mak_set_prefetch_state() in\n'
    '     * loadfile.c; read from command.c\'s property getter and from\n'
    '     * the polling hook in playloop.c. Values:\n'
    '     *   0 = idle, 1 = loading, 2 = ready, 3 = used, 4 = failed. */\n'
    '    int mak_prefetch_state;\n'
    '\n'
    '    /* ' + MARKER + ' ─── seconds of audio buffered ahead in the\n'
    '     * background-prefetch demuxer (end - reader). Exposed via the\n'
    '     * read-only `prefetch-cache-duration` property so a client can\n'
    '     * render a determinate "Prefetching X%" bar (divide by the\n'
    '     * configured cache-secs target). Updated by the loading poll;\n'
    '     * reset to 0 when prefetch leaves loading/ready. */\n'
    '    double mak_prefetch_cache_duration;\n'
    '} MPContext;'
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

COMMAND_PRISTINE = (
    '    {"demuxer-cache-state", mp_property_demuxer_cache_state},\n'
    '    {"cache-buffering-state", mp_property_cache_buffering},'
)

COMMAND_PATCHED = (
    '    {"demuxer-cache-state", mp_property_demuxer_cache_state},\n'
    '    {"cache-buffering-state", mp_property_cache_buffering},\n'
    '    /* ' + MARKER + ' */\n'
    '    {"prefetch-state", mp_property_prefetch_state},\n'
    '    {"prefetch-cache-duration", mp_property_prefetch_cache_duration},'
)

COMMAND_GETTER_ANCHOR = (
    'static int mp_property_cache_buffering(void *ctx, struct m_property *prop,'
)

COMMAND_GETTER_INSERT = (
    '/* ' + MARKER + ' ─── read-only string:\n'
    ' *   idle | loading | ready | used | failed.\n'
    ' * Observe with mpv_observe_property to receive change events at\n'
    ' * every transition of the background prefetch lifecycle. */\n'
    'static int mp_property_prefetch_state(void *ctx, struct m_property *prop,\n'
    '                                      int action, void *arg)\n'
    '{\n'
    '    MPContext *mpctx = ctx;\n'
    '    const char *name;\n'
    '    switch (mpctx->mak_prefetch_state) {\n'
    '        case 1:  name = "loading"; break;\n'
    '        case 2:  name = "ready";   break;\n'
    '        case 3:  name = "used";    break;\n'
    '        case 4:  name = "failed";  break;\n'
    '        default: name = "idle";    break;\n'
    '    }\n'
    '    return m_property_strdup_ro(action, arg, name);\n'
    '}\n'
    '\n'
    '/* ' + MARKER + ' ─── read-only double: seconds of audio buffered ahead\n'
    ' * in the background-prefetch demuxer. 0 when no prefetch is in\n'
    ' * flight. Observe alongside `prefetch-state` for a determinate\n'
    ' * "Prefetching X%" bar (divide by the cache-secs target). */\n'
    'static int mp_property_prefetch_cache_duration(void *ctx,\n'
    '                                               struct m_property *prop,\n'
    '                                               int action, void *arg)\n'
    '{\n'
    '    MPContext *mpctx = ctx;\n'
    '    return m_property_double_ro(action, arg,\n'
    '                                mpctx->mak_prefetch_cache_duration);\n'
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


# ─── loadfile.c ────────────────────────────────────────────────────────
#
# We add a helper near the top of the file and invoke it at five call
# sites. Anchoring on the exact pristine strings lets us fail loud if
# upstream refactors any of them.

LOADFILE_HELPER_ANCHOR = (
    'static void wakeup_demux(void *pctx)\n'
    '{\n'
    '    struct MPContext *mpctx = pctx;\n'
    '    mp_wakeup_core(mpctx);\n'
    '}'
)

LOADFILE_HELPER_INSERT = LOADFILE_HELPER_ANCHOR + '\n\n' + (
    '/* ' + MARKER + ' ─── transition helper for the prefetch-state property.\n'
    ' *\n'
    ' * Must only be called from the core thread — mp_notify_property\n'
    ' * touches the client event queue and is not thread-safe against\n'
    ' * concurrent writers. All documented call sites satisfy this: they\n'
    ' * live in prefetch_next, open_demux_reentrant, cancel_open, and\n'
    ' * the polling hook invoked from handle_update_cache. */\n'
    'static void mak_set_prefetch_state(struct MPContext *mpctx, int state)\n'
    '{\n'
    '    if (mpctx->mak_prefetch_state == state)\n'
    '        return;\n'
    '    mpctx->mak_prefetch_state = state;\n'
    '    mp_notify_property(mpctx, "prefetch-state");\n'
    '    /* cache-duration is meaningful only while loading/ready; reset it\n'
    '     * when leaving those states so a stale value does not linger on\n'
    '     * idle/used/failed. */\n'
    '    if (state != 1 && state != 2 &&\n'
    '        mpctx->mak_prefetch_cache_duration != 0) {\n'
    '        mpctx->mak_prefetch_cache_duration = 0;\n'
    '        mp_notify_property(mpctx, "prefetch-cache-duration");\n'
    '    }\n'
    '}\n'
    '\n'
    '/* ' + MARKER + ' ─── ready-detection poll, invoked from\n'
    ' * handle_update_cache. Safe to call every tick: bails out early if\n'
    ' * the state isn\'t LOADING so the demux_get_reader_state call only\n'
    ' * happens during the narrow window when it matters. */\n'
    'void mak_poll_prefetch_ready(struct MPContext *mpctx)\n'
    '{\n'
    '    if (mpctx->mak_prefetch_state != 1 /* loading */)\n'
    '        return;\n'
    '    if (!mpctx->open_active || !mpctx->open_for_prefetch)\n'
    '        return;\n'
    '    if (!atomic_load(&mpctx->open_done))\n'
    '        return;\n'
    '    struct demuxer *d = mpctx->open_res_demuxer;\n'
    '    if (!d)\n'
    '        return;\n'
    '    struct demux_reader_state s;\n'
    '    demux_get_reader_state(d, &s);\n'
    '    /* Publish how much is buffered ahead (end - reader) for a\n'
    '     * determinate prefetch progress bar. */\n'
    '    double dur = 0;\n'
    '    if (s.ts_info.end != MP_NOPTS_VALUE &&\n'
    '        s.ts_info.reader != MP_NOPTS_VALUE)\n'
    '        dur = s.ts_info.end - s.ts_info.reader;\n'
    '    if (dur < 0)\n'
    '        dur = 0;\n'
    '    if (mpctx->mak_prefetch_cache_duration != dur) {\n'
    '        mpctx->mak_prefetch_cache_duration = dur;\n'
    '        mp_notify_property(mpctx, "prefetch-cache-duration");\n'
    '    }\n'
    '    /* Reader reports idle when it stops fetching because the cache\n'
    '     * has reached cache-secs, which is exactly the "ready" moment we\n'
    '     * want to surface. */\n'
    '    if (s.idle)\n'
    '        mak_set_prefetch_state(mpctx, 2 /* ready */);\n'
    '}'
)

# Transition call sites. Each is a (pristine, patched) pair.

LOADFILE_CALL_SITES = [
    # 1. prefetch_next: emit loading right after start_open, regardless of
    #    whether the existing on_load-hook patch is applied (the trailing
    #    call to start_open is identical in both variants). We anchor on
    #    the literal `MP_VERBOSE(mpctx, "Prefetching: %s\n"` line since
    #    it's present in both the pristine and the hook-patched version.
    (
        'MP_VERBOSE(mpctx, "Prefetching: %s\\n", new_entry->filename);',
        'MP_VERBOSE(mpctx, "Prefetching: %s\\n", new_entry->filename);\n'
        '        /* ' + MARKER + ' */\n'
        '        mak_set_prefetch_state(mpctx, 1 /* loading */);',
    ),
# 2. open_demux_reentrant success path — the prefetched demuxer is
    #    being consumed. Transition to `used` and LEAVE the state there:
    #    mpv coalesces rapid property changes (observers read the
    #    current value on wake-up), so back-to-back used→idle would
    #    hide the `used` event entirely. Instead we let `used` persist
    #    until the next prefetch_next (loading) or cancel_open (idle)
    #    naturally clears it.
    (
        'MP_VERBOSE(mpctx, "Using prefetched/prefetching URL.\\n");',
        'MP_VERBOSE(mpctx, "Using prefetched/prefetching URL.\\n");\n'
        '            /* ' + MARKER + ' */\n'
        '            mak_set_prefetch_state(mpctx, 3 /* used */);',
    ),
    # 3. Failure path — opener thread completed but the demuxer creation
    #    failed (network error, unsupported codec, on_load hook abort).
    #    Set `failed` BEFORE the trailing cancel_open transition so the
    #    state persists past the cancel. The trailing transition is
    #    state-aware and won't overwrite a `failed` value.
    (
        'if (correct_url && failed) {\n'
        '                MP_VERBOSE(mpctx, "Prefetched URL failed, retrying.\\n");',
        'if (correct_url && failed) {\n'
        '                MP_VERBOSE(mpctx, "Prefetched URL failed, retrying.\\n");\n'
        '                /* ' + MARKER + ' */\n'
        '                mak_set_prefetch_state(mpctx, 4 /* failed */);',
    ),
    # 4. Drop / abort paths: any of the four "wrong URL / options changed"
    #    branches resets us to idle. Anchor on the closing `cancel_open`
    #    call since all four paths funnel there. The transition is
    #    guarded against the `failed` state so call site #3 above can
    #    persist its event past the cancel.
    (
        '            }\n'
        '            cancel_open(mpctx);\n'
        '        }\n'
        '    }',
        '            }\n'
        '            cancel_open(mpctx);\n'
        '            /* ' + MARKER + ' */\n'
        '            if (mpctx->mak_prefetch_state != 4 /* failed */)\n'
        '                mak_set_prefetch_state(mpctx, 0 /* idle */);\n'
        '        }\n'
        '    }',
    ),
]

# Optional call site, applied only when the anchor is present. patch_prefetch_
# hook.py inserts a `stop_play || open_active` early-bail into prefetch_next,
# BELOW the `loading` transition at call site 1. On that bail nothing else
# resets the state, so `loading` would latch with no opener thread running
# until the next prefetch/cancel. Reset to idle before the bail returns. The
# pristine prefetch_next has no such bail, so this is a no-op there — which
# keeps this patch independent of patch_prefetch_hook.py.
LOADFILE_OPTIONAL_CALL_SITES = [
    (
        '        if (mpctx->stop_play || mpctx->open_active) {\n'
        '            talloc_free(resolved_url);\n'
        '            return;\n'
        '        }',
        '        if (mpctx->stop_play || mpctx->open_active) {\n'
        '            /* ' + MARKER + ' */\n'
        '            mak_set_prefetch_state(mpctx, 0 /* idle */);\n'
        '            talloc_free(resolved_url);\n'
        '            return;\n'
        '        }',
    ),
]


def patch_loadfile_c(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if LOADFILE_HELPER_ANCHOR not in text:
        raise RuntimeError(
            f'Pristine anchor (wakeup_demux) not found in {path}.'
        )
    text = text.replace(LOADFILE_HELPER_ANCHOR, LOADFILE_HELPER_INSERT, 1)
    for pristine, patched in LOADFILE_CALL_SITES:
        if pristine not in text:
            raise RuntimeError(
                f'Pristine anchor not found in {path}:\n{pristine[:120]}'
            )
        text = text.replace(pristine, patched, 1)
    for pristine, patched in LOADFILE_OPTIONAL_CALL_SITES:
        if pristine in text:
            text = text.replace(pristine, patched, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


# ─── playloop.c ────────────────────────────────────────────────────────

PLAYLOOP_FORWARD_DECL = (
    '/* ' + MARKER + ' ─── exported from loadfile.c to poll the secondary\n'
    ' * demuxer\'s reader idle state and transition LOADING → READY. */\n'
    'void mak_poll_prefetch_ready(struct MPContext *mpctx);\n'
    '\n'
    'static void handle_update_cache(struct MPContext *mpctx)'
)

PLAYLOOP_PRISTINE = (
    'static void handle_update_cache(struct MPContext *mpctx)'
)

PLAYLOOP_READY_CALL_ANCHOR = (
    'static void handle_update_cache(struct MPContext *mpctx)\n'
    '{\n'
    '    bool force_update = false;\n'
    '    struct MPOpts *opts = mpctx->opts;\n'
    '\n'
    '    if (!mpctx->demuxer || mpctx->encode_lavc_ctx) {\n'
    '        clear_underruns(mpctx);\n'
    '        return;\n'
    '    }'
)

PLAYLOOP_READY_CALL_INSERT = PLAYLOOP_READY_CALL_ANCHOR + '\n\n' + (
    '    /* ' + MARKER + ' ─── check whether the background prefetch\n'
    '     * finished filling its cache since the last tick; if so,\n'
    '     * transition the observable property LOADING → READY. Cheap: the\n'
    '     * poll bails out after a single field compare unless a prefetch\n'
    '     * is actually in flight. */\n'
    '    mak_poll_prefetch_ready(mpctx);'
)


def patch_playloop_c(path):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    # Forward-declare the helper from loadfile.c at the point of the
    # first static definition of handle_update_cache. Using the full
    # signature as anchor ensures we inject exactly once.
    if PLAYLOOP_PRISTINE not in text:
        raise RuntimeError(
            f'Pristine anchor (handle_update_cache) not found in {path}.'
        )
    text = text.replace(PLAYLOOP_PRISTINE, PLAYLOOP_FORWARD_DECL, 1)
    if PLAYLOOP_READY_CALL_ANCHOR not in text:
        raise RuntimeError(
            f'Pristine anchor (handle_update_cache body) not found in {path}.'
        )
    text = text.replace(
        PLAYLOOP_READY_CALL_ANCHOR, PLAYLOOP_READY_CALL_INSERT, 1
    )
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
    patch_loadfile_c(os.path.join(src, 'player', 'loadfile.c'))
    patch_playloop_c(os.path.join(src, 'player', 'playloop.c'))


if __name__ == '__main__':
    main()
