/* MAK_PREFETCH_PATCH_V1 ─── read-only string, the lifecycle of the playlist
 * prefetch: idle | loading | ready | used | failed. Observe it to get an
 * event at every transition. */
static int mp_property_prefetch_state(void *ctx, struct m_property *prop,
                                      int action, void *arg)
{
    MPContext *mpctx = ctx;
    const char *name;
    switch (mpctx->mak_prefetch_state) {
        case 1:  name = "loading"; break;
        case 2:  name = "ready";   break;
        case 3:  name = "used";    break;
        case 4:  name = "failed";  break;
        default: name = "idle";    break;
    }
    return m_property_strdup_ro(action, arg, name);
}

/* MAK_PREFETCH_PATCH_V1 ─── read-only double: seconds of audio buffered
 * ahead in the prefetch demuxer, 0 when no prefetch is in flight. Divided by
 * the cache-secs target it gives a determinate "Prefetching X%" bar. */
static int mp_property_prefetch_cache_duration(void *ctx,
                                               struct m_property *prop,
                                               int action, void *arg)
{
    MPContext *mpctx = ctx;
    return m_property_double_ro(action, arg,
                                mpctx->mak_prefetch_cache_duration);
}

/* MAK_PREFETCH_PATCH_V1 ─── the URL the prefetch opens, while the
 * on_prefetch hook runs: the next entry's filename, which the hook may
 * rewrite, as stream-open-filename in on_load. Unavailable outside the hook
 * and once a transition cancelled it, for a read and for a write. */
static int mp_property_prefetch_open_filename(void *ctx,
                                              struct m_property *prop,
                                              int action, void *arg)
{
    MPContext *mpctx = ctx;
    if (mpctx->mak_prefetch_hook != 1 || !mpctx->mak_prefetch_url)
        return M_PROPERTY_UNAVAILABLE;
    switch (action) {
    case M_PROPERTY_SET: {
        if (!*(char **)arg)
            return M_PROPERTY_ERROR;
        char *url = talloc_strdup(mpctx, *(char **)arg);
        talloc_free(mpctx->mak_prefetch_url);
        mpctx->mak_prefetch_url = url;
        mp_notify_property(mpctx, prop->name);
        return M_PROPERTY_OK;
    }
    case M_PROPERTY_GET_TYPE:
    case M_PROPERTY_GET: {
        char *path = mp_normalize_path(NULL, mpctx->mak_prefetch_url);
        int r = m_property_strdup_ro(action, arg, path);
        talloc_free(path);
        return r;
    }
    }
    return M_PROPERTY_NOT_IMPLEMENTED;
}

/* MAK_PREFETCH_PATCH_V1 ─── read-only: the playlist entry id of the entry
 * the on_prefetch hook runs for, as in playlist/N/id. Unavailable when
 * prefetch-open-filename is. */
static int mp_property_prefetch_playlist_entry_id(void *ctx,
                                                  struct m_property *prop,
                                                  int action, void *arg)
{
    MPContext *mpctx = ctx;
    if (mpctx->mak_prefetch_hook != 1 || !mpctx->mak_prefetch_entry)
        return M_PROPERTY_UNAVAILABLE;
    return m_property_int64_ro(action, arg, mpctx->mak_prefetch_entry->id);
}

