# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""The playlist prefetch: an on_prefetch hook that leaves the playloop
running, and the observable prefetch lifecycle.

Upstream prefetch_next (player/loadfile.c) opens the next playlist entry's
raw filename on the opener thread and runs no hook, so a client that
resolves its URLs in on_load (plex-transcode://, signed URLs) sees the
prefetch fail with "No protocol handler found". Upstream exposes none of
the prefetch state either.

===== The on_prefetch hook =====

prefetch_next starts the on_prefetch hook for the next entry and returns.
While the hook runs, the prefetch-open-filename property holds the URL the
prefetch will open (the entry's filename, normalized like
stream-open-filename) and the client may rewrite it; prefetch-playlist-
entry-id is the entry's playlist id. mak_prefetch_tick, the first call of
handle_update_cache, runs on every pass of the playloop and of mp_idle: once
every client continued the hook, it opens the entry with that URL. The
playing entry keeps playing meanwhile, and path, filename,
stream-open-filename and file-local-options stay its own.

The earlier patches ran on_load for the next entry in a nested
process_hooks, whose mp_idle pump feeds no audio: the output ran dry while
the client resolved (F9), playlist-next and stop waited for it, and the
client's file-local-options landed on the playing entry (F241).

===== Cancel and the late continue =====

A transition (play_current_file, the player going idle or quitting), a
stop, or the entry removed or no longer next cancels a running hook: the
entry and the URL are dropped, prefetch-state goes idle and
prefetch-open-filename turns unavailable, for a read and for a write. mpv
cannot take back the event, so the hook stays cancelled until the clients
continue it, and that continue opens nothing. No new on_prefetch starts
before: mpv sends every event of a handler with the same id (h->seq), so a
client could not tell a new hook from the one it still holds.

Without a client on on_prefetch the hook is complete as it starts and the
open starts at once, as upstream.

===== prefetch-state =====

    idle     no prefetch
    loading  prefetch_next fired: the hook runs, or the opener opens the
             entry and the secondary cache fills
    ready    the prefetch demuxer is open and its reader idles (the cache
             reached cache-secs): gapless is armed
    used     the transition took the prefetched stream; it stays until the
             next prefetch or going idle, so the property queue does not
             coalesce it away
    failed   the prefetch open failed, said as soon as the opener returns;
             it stays like used

prefetch-cache-duration is the time buffered ahead in the prefetch demuxer
while loading or ready, 0 otherwise. Going idle drops the prefetch, so no
demuxer stays open in idle.

===== Per-file options =====

The opener reads the global options, which during playback hold the
per-file options of the playing entry. prefetch_next skips an entry whose
per-file options differ from the playing one's (same names and values in
the same order), so its HTTP headers never reach another host. That
transition opens the entry from scratch.

===== Entry lifetime and players =====

The hook holds its entry (reserved += 1) until it returns or is cancelled,
as play_current_file holds the playing one: a playlist-remove or
playlist-clear sent meanwhile cannot free it. The hook state lives in the
MPContext and only its core thread touches it, so two players in one
process prefetch independently.

Files patched
=============

    player/core.h       MPContext fields, mak_prefetch_tick
    player/command.c    prefetch-state, prefetch-cache-duration,
                        prefetch-open-filename, prefetch-playlist-entry-id
                        (prefetch/prefetch_command_insert.c)
    player/loadfile.c   prefetch_next and the hook
                        (prefetch/mak_prefetch_insert.c), the transitions
    player/playloop.c   mak_prefetch_tick at the top of handle_update_cache

Usage: patch_prefetch.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = 'MAK_PREFETCH_PATCH_V1'

CORE = 'player/core.h'
COMMAND = 'player/command.c'
LOADFILE = 'player/loadfile.c'
PLAYLOOP = 'player/playloop.c'

# The markers of patch_prefetch_hook.py and patch_prefetch_state.py, which
# this patch replaces: a tree they patched must be extracted again.
OLD_MARKERS = ('MAK_PREFETCH_HOOK_PATCH', 'MAK_PREFETCH_STATE_PATCH')


# ─── core.h ────────────────────────────────────────────────────────────

CORE_FIELDS = (
    '    struct mp_als *als_state; // lazily initialized on first use\n'
    '} MPContext;'
)

CORE_FIELDS_NEW = (
    '    struct mp_als *als_state; // lazily initialized on first use\n'
    '\n'
    '    /* ' + MARKER + ' ─── the playlist prefetch (player/loadfile.c).\n'
    '     * Core thread only.\n'
    '     * mak_prefetch_state backs prefetch-state: 0 idle, 1 loading,\n'
    '     * 2 ready, 3 used, 4 failed. mak_prefetch_cache_duration backs\n'
    '     * prefetch-cache-duration.\n'
    '     * mak_prefetch_hook is the on_prefetch hook: 0 none; 1 running for\n'
    '     * mak_prefetch_entry (held with reserved += 1), which opens\n'
    '     * mak_prefetch_url (prefetch-open-filename) once the clients\n'
    '     * continue it; 2 cancelled, its late continue opens nothing. */\n'
    '    int mak_prefetch_state;\n'
    '    double mak_prefetch_cache_duration;\n'
    '    int mak_prefetch_hook;\n'
    '    struct playlist_entry *mak_prefetch_entry;\n'
    '    char *mak_prefetch_url;\n'
    '} MPContext;'
)

CORE_DECL = 'void prefetch_next(struct MPContext *mpctx);\n'

CORE_DECL_NEW = CORE_DECL + (
    '/* ' + MARKER + ': the prefetch hook and state, on every pass of the\n'
    ' * playloop and of mp_idle (player/loadfile.c). */\n'
    'void mak_prefetch_tick(struct MPContext *mpctx);\n'
)


# ─── command.c ─────────────────────────────────────────────────────────

COMMAND_TABLE = (
    '    {"demuxer-cache-state", mp_property_demuxer_cache_state},\n'
    '    {"cache-buffering-state", mp_property_cache_buffering},\n'
)

COMMAND_TABLE_NEW = COMMAND_TABLE + (
    '    /* ' + MARKER + ' */\n'
    '    {"prefetch-state", mp_property_prefetch_state},\n'
    '    {"prefetch-cache-duration", mp_property_prefetch_cache_duration},\n'
    '    {"prefetch-open-filename", mp_property_prefetch_open_filename},\n'
    '    {"prefetch-playlist-entry-id", mp_property_prefetch_playlist_entry_id},\n'
)

COMMAND_GETTERS = (
    'static int mp_property_cache_buffering(void *ctx, struct m_property *prop,'
)


# ─── loadfile.c ────────────────────────────────────────────────────────

WAKEUP_DEMUX = (
    'static void wakeup_demux(void *pctx)\n'
    '{\n'
    '    struct MPContext *mpctx = pctx;\n'
    '    mp_wakeup_core(mpctx);\n'
    '}\n'
)

WAKEUP_DEMUX_NEW = WAKEUP_DEMUX + (
    '\n'
    '/* ' + MARKER + ': sets prefetch-state, defined with prefetch_next. */\n'
    'static void mak_set_prefetch_state(struct MPContext *mpctx, int state);\n'
)

# Pristine prefetch_next of mpv v0.41.0, replaced by mak_prefetch_insert.c.
PREFETCH_NEXT = (
    'void prefetch_next(struct MPContext *mpctx)\n'
    '{\n'
    '    if (!mpctx->opts->prefetch_open || mpctx->open_active)\n'
    '        return;\n'
    '\n'
    '    struct playlist_entry *new_entry = mp_next_file(mpctx, +1, false, false);\n'
    '    if (new_entry && new_entry->filename) {\n'
    '        MP_VERBOSE(mpctx, "Prefetching: %s\\n", new_entry->filename);\n'
    '        start_open(mpctx, new_entry->filename, new_entry->stream_flags, true);\n'
    '    }\n'
    '}\n'
)

# open_demux_reentrant: what the transition did with the prefetch.
TRANSITIONS = [
    # The transition takes the prefetched stream. used stays (see above).
    (
        'transition uses the prefetch',
        '            MP_VERBOSE(mpctx, "Using prefetched/prefetching URL.\\n");\n',
        '            MP_VERBOSE(mpctx, "Using prefetched/prefetching URL.\\n");\n'
        '            /* ' + MARKER + ' */\n'
        '            mak_set_prefetch_state(mpctx, 3 /* used */);\n',
    ),
    # The prefetch open failed. Before the cancel_open below, which leaves a
    # failed state alone.
    (
        'transition after a failed prefetch',
        '            if (correct_url && failed) {\n'
        '                MP_VERBOSE(mpctx, "Prefetched URL failed, retrying.\\n");\n',
        '            if (correct_url && failed) {\n'
        '                MP_VERBOSE(mpctx, "Prefetched URL failed, retrying.\\n");\n'
        '                /* ' + MARKER + ' */\n'
        '                mak_set_prefetch_state(mpctx, 4 /* failed */);\n',
    ),
    # Every branch that drops the prefetch (wrong URL, options changed)
    # ends in this cancel_open.
    (
        'transition drops the prefetch',
        '            }\n'
        '            cancel_open(mpctx);\n'
        '        }\n'
        '    }\n',
        '            }\n'
        '            cancel_open(mpctx);\n'
        '            /* ' + MARKER + ' */\n'
        '            if (mpctx->mak_prefetch_state != 4 /* failed */)\n'
        '                mak_set_prefetch_state(mpctx, 0 /* idle */);\n'
        '        }\n'
        '    }\n',
    ),
]

PLAY_CURRENT_FILE = (
    '    mp_assert(mpctx->stop_play);\n'
    '    mpctx->stop_play = 0;\n'
)

PLAY_CURRENT_FILE_NEW = PLAY_CURRENT_FILE + (
    '    /* ' + MARKER + ' ─── a file starts: a prefetch hook still running\n'
    '     * is for this entry, which gets its own on_load, or for one that no\n'
    '     * longer follows. */\n'
    '    mak_prefetch_cancel(mpctx);\n'
)

# mp_play_files going idle (stop, end of playlist, playlist-clear).
# Upstream keeps the prefetched demuxer open in idle.
GOING_IDLE = (
    '        mpctx->stop_play = new_entry ? PT_NEXT_ENTRY : PT_STOP;\n'
)

GOING_IDLE_NEW = GOING_IDLE + (
    '        /* ' + MARKER + ' ─── going idle: cancel the prefetch hook and\n'
    '         * drop the prefetch, so no demuxer stays open in idle and\n'
    '         * prefetch-state reads idle. */\n'
    '        if (!new_entry) {\n'
    '            mak_prefetch_cancel(mpctx);\n'
    '            cancel_open(mpctx);\n'
    '            mak_set_prefetch_state(mpctx, 0 /* idle */);\n'
    '        }\n'
)

# mp_play_files quitting: the hook gives its entry back.
QUITTING = (
    '    cancel_open(mpctx);\n'
    '\n'
    '    if (mpctx->encode_lavc_ctx) {\n'
)

QUITTING_NEW = (
    '    /* ' + MARKER + ': the prefetch hook gives its entry back. */\n'
    '    mak_prefetch_cancel(mpctx);\n'
    + QUITTING
)


# ─── playloop.c ────────────────────────────────────────────────────────

UPDATE_CACHE = (
    'static void handle_update_cache(struct MPContext *mpctx)\n'
    '{\n'
    '    bool force_update = false;\n'
    '    struct MPOpts *opts = mpctx->opts;\n'
    '\n'
)

UPDATE_CACHE_NEW = UPDATE_CACHE + (
    '    /* ' + MARKER + ' ─── the prefetch hook and the ready and failed\n'
    '     * poll of prefetch-state, also without a demuxer (mp_idle runs\n'
    '     * this between two files and in idle). */\n'
    '    mak_prefetch_tick(mpctx);\n'
    '\n'
)


def apply(p):
    for rel in (CORE, COMMAND, LOADFILE, PLAYLOOP):
        if any(m in p.text(rel) for m in OLD_MARKERS):
            p.fail(f'{rel} carries the prefetch patches of an older release '
                   '(patch_prefetch_hook.py, patch_prefetch_state.py): '
                   'extract the mpv source again')
    p.edits(CORE, [
        ('MPContext end', CORE_FIELDS, CORE_FIELDS_NEW),
        ('prefetch_next declaration', CORE_DECL, CORE_DECL_NEW),
    ])
    p.edits(COMMAND, [
        ('property table', COMMAND_TABLE, COMMAND_TABLE_NEW),
        ('property getters', COMMAND_GETTERS,
         p.asset('prefetch/prefetch_command_insert.c') + COMMAND_GETTERS),
    ])
    p.edits(LOADFILE, [
        ('wakeup_demux', WAKEUP_DEMUX, WAKEUP_DEMUX_NEW),
        ('prefetch_next', PREFETCH_NEXT,
         p.asset('prefetch/mak_prefetch_insert.c')),
    ] + TRANSITIONS + [
        ('play_current_file start', PLAY_CURRENT_FILE, PLAY_CURRENT_FILE_NEW),
        ('mp_play_files going idle', GOING_IDLE, GOING_IDLE_NEW),
        ('mp_play_files quitting', QUITTING, QUITTING_NEW),
    ])
    p.edits(PLAYLOOP, [('handle_update_cache', UPDATE_CACHE, UPDATE_CACHE_NEW)])


anchor.main(apply, 'patch_prefetch', marker=MARKER)
