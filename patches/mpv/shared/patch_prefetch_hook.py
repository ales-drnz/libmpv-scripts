# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patch mpv's prefetch_next to run the `on_load` hook before spawning the
opener thread, safely guarded against re-entry.

mpv's prefetch_next (player/loadfile.c) deliberately skips the hook pipeline:
it calls `start_open(..., for_prefetch=true)` directly on the next playlist
entry's raw filename. Any `on_load` hook registered via the client API
(mpv_hook_add) never fires for prefetched files, so clients that rely on
on_load to rewrite `stream-open-filename` for custom URL schemes
(e.g. plex-transcode:// → resolved HLS URL) see the prefetch path reach the
stream layer with an unresolved URL and fail with "No protocol handler found".

This patch mirrors the normal playback path (`play_current_file`) inside
`prefetch_next`: it temporarily points `mpctx->filename` and
`mpctx->stream_open_filename` at the prefetch URL, runs `process_hooks`
synchronously on the core thread, reads the possibly-rewritten URL back,
restores the previous state, and only then spawns the opener thread.

===== Re-entry guard =====

`process_hooks` is implemented as a busy loop that pumps `mp_idle` until the
hook signals completion (player/loadfile.c `process_hooks`). `mp_idle` calls
`handle_update_cache` (player/playloop.c), which at end-of-file calls
`prefetch_next` again:

    handle_update_cache()
        ...
        if (s.eof && !busy)
            prefetch_next(mpctx);     // <-- re-enters us!

Without a guard, the chain prefetch_next → process_hooks → mp_idle →
handle_update_cache → prefetch_next recurses until the core thread stack
overflows (SIGBUS / stack guard violation).

The fix is a function-scope `static bool` set to true only while we are
inside our nested `process_hooks` call. prefetch_next runs exclusively on
the mpv core thread, so the static is single-threaded and safe. Any
re-entry attempt (from handle_update_cache via mp_idle) bails out
immediately via the guard.

===== NULL-masking mpctx->demuxer =====

The property setter `mp_property_stream_open_filename` (player/command.c)
refuses to accept new values while a demuxer is already attached:

    case M_PROPERTY_SET: {
        if (mpctx->demuxer)
            return M_PROPERTY_ERROR;
        ...
    }

This guard is there to prevent hook-driven URL rewrites from racing with
the currently-playing stream. In `play_current_file`, `mpctx->demuxer` is
still NULL when the on_load hook fires, so the setter accepts the rewrite.

During prefetch, however, the current track's demuxer is very much alive:
the hook would fire against a non-NULL `mpctx->demuxer`, the setter would
return M_PROPERTY_ERROR, the Dart `setRawProperty` call would no-op, and
mpv would end up opening the raw `plex-transcode://` URL.

The workaround: save `mpctx->demuxer`, set it to NULL around the
`process_hooks` call, then restore it. It's safe because:
  - The re-entry guard above prevents nested prefetch_next from running
    (so no recursive path touches mpctx->demuxer).
  - `handle_update_cache` (the function called from mp_idle inside
    process_hooks) short-circuits on `!mpctx->demuxer` and does nothing.
  - The current playback's audio chain reads from its own demuxer handle
    (`mpctx->ao_chain->...`), not by dereferencing mpctx->demuxer again.
  - We hold mpctx->demuxer=NULL only for the duration of the synchronous
    hook pump — typically <100 ms — before restoring it.

===== Memory =====

The prefetch URL is talloc'd locally (`owned_url`) with parent=NULL. The
hook may replace `stream_open_filename` by calling the mpv property setter
`mp_property_stream_open_filename`, which does:

    mpctx->stream_open_filename =
        talloc_strdup(mpctx->stream_open_filename, *(char **)arg);

i.e. the new allocation becomes a talloc child of `owned_url`. When we
later call `talloc_free(owned_url)`, talloc frees the root and all its
children (including any replacement the hook allocated). Zero double-free,
zero leak.

We snapshot the final string via talloc_strdup into `resolved_url` (also
parent=NULL) before restoring mpctx->filename / stream_open_filename to the
saved pointers, so the URL we hand to start_open() survives the cleanup.
"""
import sys

fn = sys.argv[1]  # path to player/loadfile.c
with open(fn) as f:
    content = f.read()

MARKER = 'mpv_audio_kit: prefetch_next with on_load hook, re-entry guard, demuxer mask'

# Pristine prefetch_next from mpv v0.41.0 (player/loadfile.c).
PRISTINE = (
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
    '}'
)

PATCHED = (
    'void prefetch_next(struct MPContext *mpctx)\n'
    '{\n'
    '    /* mpv_audio_kit: prefetch_next with on_load hook, re-entry guard, demuxer mask.\n'
    '     *\n'
    '     * process_hooks() below pumps mp_idle, which calls handle_update_cache,\n'
    '     * which at end-of-file calls prefetch_next again. Without this guard we\n'
    '     * recurse until the core thread stack overflows. prefetch_next runs only\n'
    '     * on the mpv core thread, so a function-scope static is safe. */\n'
    '    static bool mak_in_prefetch_hooks = false;\n'
    '    if (mak_in_prefetch_hooks)\n'
    '        return;\n'
    '\n'
    '    if (!mpctx->opts->prefetch_open || mpctx->open_active)\n'
    '        return;\n'
    '\n'
    '    struct playlist_entry *new_entry = mp_next_file(mpctx, +1, false, false);\n'
    '    if (new_entry && new_entry->filename) {\n'
    '        MP_VERBOSE(mpctx, "Prefetching: %s\\n", new_entry->filename);\n'
    '\n'
    '        /* Run on_load hooks during prefetch so custom URL schemes\n'
    '         * (e.g. plex-transcode://) can be rewritten before the opener\n'
    '         * thread runs. Mirrors the normal play_current_file() path. */\n'
    '        char *saved_filename = mpctx->filename;\n'
    '        char *saved_sof = mpctx->stream_open_filename;\n'
    '        char *owned_url = talloc_strdup(NULL, new_entry->filename);\n'
    '        mpctx->filename = owned_url;\n'
    '        mpctx->stream_open_filename = owned_url;\n'
    '\n'
    '        /* NULL-mask the current demuxer so that the stream-open-filename\n'
    '         * property setter accepts the hook-driven rewrite. The setter in\n'
    '         * command.c refuses when mpctx->demuxer != NULL. The re-entry\n'
    '         * guard above prevents nested prefetch_next from touching the\n'
    '         * demuxer while it is temporarily NULL, and handle_update_cache\n'
    '         * inside mp_idle short-circuits on !mpctx->demuxer. */\n'
    '        struct demuxer *saved_demuxer = mpctx->demuxer;\n'
    '        mpctx->demuxer = NULL;\n'
    '\n'
    '        mak_in_prefetch_hooks = true;\n'
    '        process_hooks(mpctx, "on_load");\n'
    '        mak_in_prefetch_hooks = false;\n'
    '\n'
    '        mpctx->demuxer = saved_demuxer;\n'
    '\n'
    '        char *resolved_url = talloc_strdup(NULL, mpctx->stream_open_filename);\n'
    '        mpctx->filename = saved_filename;\n'
    '        mpctx->stream_open_filename = saved_sof;\n'
    '        talloc_free(owned_url);\n'
    '\n'
    '        if (mpctx->stop_play || mpctx->open_active) {\n'
    '            talloc_free(resolved_url);\n'
    '            return;\n'
    '        }\n'
    '\n'
    '        start_open(mpctx, resolved_url, new_entry->stream_flags, true);\n'
    '        talloc_free(resolved_url);\n'
    '    }\n'
    '}'
)

if MARKER in content:
    print('Patched loadfile.c: prefetch_next already patched (skipped)')
    sys.exit(0)

# Apply-order contract: this patch MUST run before patch_prefetch_state.py.
# That patch inserts its `loading` transition immediately after the
# MP_VERBOSE("Prefetching") line that our PRISTINE anchor matches verbatim;
# if it ran first our anchor would no longer match and we'd hard-fail with a
# misleading "clean the source" message. Detect the inversion explicitly.
if 'MAK_PREFETCH_STATE_PATCH_V1' in content:
    print(
        'ERROR: patch_prefetch_state.py ran before patch_prefetch_hook.py '
        '(wrong apply order). Apply the hook patch first — see '
        'apply_mpv_patches_common() in _audio_only.sh.',
        file=sys.stderr,
    )
    sys.exit(1)

if PRISTINE not in content:
    print(
        'ERROR: could not find pristine prefetch_next in %s.\n'
        'Clean the extracted mpv source and rebuild:\n'
        '    rm -rf "$BUILD_DIR/src/mpv-<version>"' % fn,
        file=sys.stderr,
    )
    sys.exit(1)

content = content.replace(PRISTINE, PATCHED, 1)

with open(fn, 'w') as f:
    f.write(content)
print('Patched loadfile.c: prefetch_next on_load hook + re-entry guard applied')
