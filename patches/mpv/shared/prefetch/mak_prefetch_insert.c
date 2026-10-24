/* MAK_PREFETCH_PATCH_V1 ─── the playlist prefetch, with an on_prefetch hook
 * that runs while the current entry plays.
 *
 * Upstream prefetch_next opens the next entry's filename at once. Here it
 * first runs the on_prefetch hook, so a client can resolve the URL the
 * prefetch opens (prefetch-open-filename), as it does in on_load for the
 * entry that starts. mp_hook_start sends the event and returns; every pass
 * of the playloop and of mp_idle calls mak_prefetch_tick (first thing in
 * handle_update_cache), which opens the entry once every client continued
 * the hook. Meanwhile the playloop decodes and feeds the audio output as
 * usual. The hook used to run in a nested process_hooks, whose mp_idle
 * pump feeds no audio: the output ran dry, and playlist-next and stop
 * waited for the client (F9).
 *
 * mak_prefetch_hook: 0 none, 1 running for mak_prefetch_entry, 2 cancelled.
 * A transition (play_current_file, the player going idle or quitting), a
 * stop, or the entry removed or no longer next cancels a running hook: the
 * entry and the URL are dropped, prefetch-state goes idle and
 * prefetch-open-filename turns unavailable. mpv cannot take the event
 * back, so the hook stays cancelled until the clients continue it, and
 * that late continue opens nothing. No new hook starts before: mpv sends
 * every event of one handler with the same id, so a client could not tell
 * a new hook from the one it holds. A cancelled hook still goes on to the
 * next client registered on on_prefetch, which finds
 * prefetch-open-filename unavailable.
 *
 * Without a client on on_prefetch the hook is complete as it starts, and
 * the open starts at once, as upstream. */

/* True when both entries carry the same per-file options, in the same
 * order. */
static bool mak_same_file_params(struct playlist_entry *a,
                                 struct playlist_entry *b)
{
    if (!a || a->num_params != b->num_params)
        return false;
    for (int n = 0; n < a->num_params; n++) {
        if (!bstr_equals(a->params[n].name, b->params[n].name) ||
            !bstr_equals(a->params[n].value, b->params[n].value))
            return false;
    }
    return true;
}

/* Sets prefetch-state: 0 idle, 1 loading, 2 ready, 3 used, 4 failed.
 * Core thread only, as mp_notify_property. */
static void mak_set_prefetch_state(struct MPContext *mpctx, int state)
{
    if (mpctx->mak_prefetch_state == state)
        return;
    mpctx->mak_prefetch_state = state;
    mp_notify_property(mpctx, "prefetch-state");
    /* prefetch-cache-duration means something only while loading or
     * ready: reset it on the other states, so a stale value does not
     * linger. */
    if (state != 1 && state != 2 &&
        mpctx->mak_prefetch_cache_duration != 0) {
        mpctx->mak_prefetch_cache_duration = 0;
        mp_notify_property(mpctx, "prefetch-cache-duration");
    }
}

/* The hook leaves its entry and its URL. */
static void mak_prefetch_release(struct MPContext *mpctx)
{
    if (mpctx->mak_prefetch_entry)
        playlist_entry_unref(mpctx->mak_prefetch_entry);
    mpctx->mak_prefetch_entry = NULL;
    TA_FREEP(&mpctx->mak_prefetch_url);
    mp_notify_property(mpctx, "prefetch-open-filename");
    mp_notify_property(mpctx, "prefetch-playlist-entry-id");
}

/* Cancels a running hook: its late continue opens nothing. */
static void mak_prefetch_cancel(struct MPContext *mpctx)
{
    if (mpctx->mak_prefetch_hook != 1)
        return;
    MP_VERBOSE(mpctx, "Prefetch hook cancelled.\n");
    mak_prefetch_release(mpctx);
    mpctx->mak_prefetch_hook = 2;
    mak_set_prefetch_state(mpctx, 0 /* idle */);
}

/* Whether the entry of the running hook is still the one to prefetch. */
static bool mak_prefetch_wanted(struct MPContext *mpctx)
{
    struct playlist_entry *e = mpctx->mak_prefetch_entry;
    return !e->removed && !mpctx->stop_play && !mpctx->open_active &&
           mpctx->opts->prefetch_open &&
           mp_next_file(mpctx, +1, false, false) == e;
}

/* Follows the hook: cancels it when its entry is no longer wanted, and once
 * every client continued it opens the entry with the URL they left, unless
 * it was cancelled. */
static void mak_prefetch_poll_hook(struct MPContext *mpctx)
{
    if (mpctx->mak_prefetch_hook == 1 && !mak_prefetch_wanted(mpctx))
        mak_prefetch_cancel(mpctx);
    if (!mpctx->mak_prefetch_hook ||
        !mp_hook_test_completion(mpctx, "on_prefetch"))
        return;
    bool cancelled = mpctx->mak_prefetch_hook == 2;
    mpctx->mak_prefetch_hook = 0;
    if (cancelled) {
        MP_VERBOSE(mpctx, "Cancelled prefetch hook returned.\n");
        return;
    }
    start_open(mpctx, mpctx->mak_prefetch_url,
               mpctx->mak_prefetch_entry->stream_flags, true);
    mak_prefetch_release(mpctx);
}

/* The ready and failed poll of prefetch-state. Cheap unless a prefetch
 * open is in flight. */
static void mak_poll_prefetch_ready(struct MPContext *mpctx)
{
    if (mpctx->mak_prefetch_state != 1 /* loading */)
        return;
    if (!mpctx->open_active || !mpctx->open_for_prefetch)
        return;
    if (!atomic_load(&mpctx->open_done))
        return;
    struct demuxer *d = mpctx->open_res_demuxer;
    if (!d) {
        /* The opener returned without a demuxer: the prefetch open
         * failed. Say so now rather than at the transition. open_active
         * stays set until then, so no new prefetch overwrites it. */
        mak_set_prefetch_state(mpctx, 4 /* failed */);
        return;
    }
    struct demux_reader_state s;
    demux_get_reader_state(d, &s);
    /* How much is buffered ahead (end - reader), for a determinate
     * prefetch progress bar. */
    double dur = 0;
    if (s.ts_info.end != MP_NOPTS_VALUE &&
        s.ts_info.reader != MP_NOPTS_VALUE)
        dur = s.ts_info.end - s.ts_info.reader;
    if (dur < 0)
        dur = 0;
    if (mpctx->mak_prefetch_cache_duration != dur) {
        mpctx->mak_prefetch_cache_duration = dur;
        mp_notify_property(mpctx, "prefetch-cache-duration");
    }
    /* The reader idles once the cache reached cache-secs: the prefetch is
     * ready. */
    if (s.idle)
        mak_set_prefetch_state(mpctx, 2 /* ready */);
}

/* Called first in handle_update_cache, so on every pass of the playloop
 * and of mp_idle, with or without a demuxer. */
void mak_prefetch_tick(struct MPContext *mpctx)
{
    mak_prefetch_poll_hook(mpctx);
    mak_poll_prefetch_ready(mpctx);
}

void prefetch_next(struct MPContext *mpctx)
{
    /* One hook at a time (see above); a stop cancels it anyway. */
    if (mpctx->mak_prefetch_hook || mpctx->stop_play)
        return;

    if (!mpctx->opts->prefetch_open || mpctx->open_active)
        return;

    struct playlist_entry *new_entry = mp_next_file(mpctx, +1, false, false);
    /* The opener reads the global options, which hold the per-file
     * options of the playing entry. An entry with other ones would
     * send them and keep them after the transition, so it is not
     * prefetched. No log: this runs on every tick at end of file. */
    if (new_entry && !mak_same_file_params(mpctx->playing, new_entry))
        return;
    if (new_entry && new_entry->filename) {
        MP_VERBOSE(mpctx, "Prefetching: %s\n", new_entry->filename);
        mak_set_prefetch_state(mpctx, 1 /* loading */);
        /* Held until the hook returns, as play_current_file holds its
         * entry: a client command can remove it meanwhile. */
        new_entry->reserved += 1;
        mpctx->mak_prefetch_entry = new_entry;
        mpctx->mak_prefetch_url = talloc_strdup(mpctx, new_entry->filename);
        mpctx->mak_prefetch_hook = 1;
        mp_notify_property(mpctx, "prefetch-open-filename");
        mp_notify_property(mpctx, "prefetch-playlist-entry-id");
        mp_hook_start(mpctx, "on_prefetch");
        /* Without a client the hook is already complete: open now. */
        mak_prefetch_poll_hook(mpctx);
    }
}
