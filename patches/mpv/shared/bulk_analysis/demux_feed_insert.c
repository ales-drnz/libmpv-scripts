
/* MAK_WAVEFORM_PATCH_V2 ─── attach the bulk analysis packet feed (see
 * demux/mak_demux_feed.h). The attach only marks where the cached packets
 * of [sh] end in the range the demuxer is filling and leaves the feed on the
 * demuxer, so add_packet_locked() queues every new one; the consumer copies
 * the cached ones itself, a batch at a time (mak_demux_feed_replay). */

struct mak_demux_feed *mak_demux_feed_attach(struct demuxer *demuxer,
                                             struct sh_stream *sh)
{
    struct demux_internal *in = demuxer->in;
    if (!sh || !sh->ds || sh->ds->in != in)
        return NULL;   /* no stream, or one of another demuxer (external) */
    struct demux_stream *ds = sh->ds;

    mp_mutex_lock(&in->lock);
    /* Only where the feed can cover the whole file: a seekable cache in
     * memory (a disk cache would be read back from disk under the lock), a file
     * the forward cache can hold (beyond it the demuxer only reads at the
     * playback pace), and a plain demuxer (a timeline's packets carry their
     * own codec and segment bounds). A size the stream does not report
     * passes here: read_packet() cuts the feed if the cache fills up before
     * the end. The packet overhead the cache counts can still fill it short
     * of the end of a file of known size close to the limit: the rest then
     * comes at the pace playback frees the cache, which still ends in one
     * clean pass. */
    bool usable = in->seekable_cache && ds->selected &&
                  !in->d_user->opts->disk_cache &&
                  in->d_thread->desc != &demuxer_desc_timeline &&
                  (in->stream_size <= 0 ||
                   (uint64_t)in->stream_size <= (uint64_t)in->max_bytes);
    /* The range the demuxer is filling must start the file, or be about to
     * read it: right after the open, the first read marks the queue as the
     * start (after_seek_to_start) only when it happens. Another cached range
     * that starts the file ends where a seek left it, so the pass could not
     * go on from it. */
    struct demux_queue *q = ds->queue;
    bool has_bof = usable && q && q->range == in->current_range &&
                   (q->is_bof || (!q->head && in->after_seek_to_start)) &&
                   !(q->is_eof && !q->head);
    if (!has_bof) {
        mp_mutex_unlock(&in->lock);
        return NULL;
    }
    if (in->mak_feed) {
        mak_demux_feed_owner_release(in->mak_feed);
        in->mak_feed = NULL;
    }
    if (!in->mak_guard)
        in->mak_guard = mak_feed_guard_new(in);
    struct mak_demux_feed *f =
        in->mak_guard ? mak_demux_feed_new(ds->index) : NULL;
    if (!f) {
        mp_mutex_unlock(&in->lock);
        return NULL;
    }

    struct mak_feed_replay *r = mak_demux_feed_replay_state(f);
    mak_feed_guard_ref(in->mak_guard);
    r->guard = in->mak_guard;
    r->queue = q;
    r->next = q->head;
    r->next_cum = q->head ? q->head->cum_pos : q->tail_cum_pos;
    r->end_cum = q->tail_cum_pos;
    r->active = q->head != NULL;
    r->bof = q->head && q->is_bof;
    r->stream_size = in->stream_size > 0 ? in->stream_size : -1;
#ifdef MAK_DEMUX_READ_ERROR
    r->read_error = in->mak_read_error;  /* the reading may be over already */
#endif
    mak_demux_feed_continue(f, q, r->active);

    in->mak_feed = f;
    mp_mutex_unlock(&in->lock);
    return f;
}

enum mak_feed_item mak_demux_feed_replay(struct mak_demux_feed *f,
                                         struct demux_packet **out, int max,
                                         int *n)
{
    struct mak_feed_replay *r = mak_demux_feed_replay_state(f);
    *n = 0;
    if (r->bof) {
        r->bof = false;
        return MAK_FEED_BOF;
    }
    if (!r->active) {
        bool eof = r->eof;
        r->eof = false;
        return eof ? MAK_FEED_EOF : MAK_FEED_REPLAYED;
    }

    struct demux_internal *in = mak_feed_guard_lock(r->guard);
    if (!in) {
        mak_feed_guard_unlock(r->guard);
        r->active = false;
        return MAK_FEED_CLOSED;
    }
    mp_mutex_lock(&in->lock);
    enum mak_feed_item res = MAK_FEED_PACKET;
    struct demux_queue *q = r->queue;
    /* A cut feed or one no longer attached may have lost its queue (a seek
     * cuts before the queue's range can be freed). Otherwise the queue only
     * loses packets at its head: the next one is still there as long as the
     * head did not pass it. */
    if (in->mak_feed != f || mak_demux_feed_ended(f) || !q->head ||
        q->head->cum_pos > r->next_cum)
    {
        res = MAK_FEED_GAP;
    } else {
        struct demux_packet *dp = r->next;
        while (dp && dp->cum_pos < r->end_cum && *n < max) {
            struct demux_packet *copy = read_packet_from_cache(in, dp);
            if (!copy) {
                res = MAK_FEED_GAP;
                break;
            }
            out[(*n)++] = copy;
            dp = dp->next;
        }
        r->next = dp;
        r->next_cum = dp ? dp->cum_pos : r->end_cum;
        if (res == MAK_FEED_PACKET && (!dp || dp->cum_pos >= r->end_cum)) {
            /* The last batch: the end of file follows when the demuxer read
             * nothing after it. */
            r->active = false;
            r->eof = !dp && q->is_eof;
        }
    }
    mp_mutex_unlock(&in->lock);
    mak_feed_guard_unlock(r->guard);

    if (res == MAK_FEED_GAP) {
        for (int i = 0; i < *n; i++)
            free_demux_packet(out[i]);
        *n = 0;
        r->active = false;
        return MAK_FEED_GAP;
    }
    if (*n == 0)
        return mak_demux_feed_replay(f, out, max, n);
    return MAK_FEED_PACKET;
}
