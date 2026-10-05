
/* MAK_WAVEFORM_PATCH ─── attach the bulk analysis packet feed (see
 * demux/mak_demux_feed.h). Replays the cached packets of [sh] in media order,
 * one cached range after the other, then leaves the feed on the demuxer so
 * add_packet_locked() queues every new one. */
static int mak_feed_range_cmp(const void *a, const void *b)
{
    const struct demux_cached_range *ra = *(struct demux_cached_range *const *)a;
    const struct demux_cached_range *rb = *(struct demux_cached_range *const *)b;
    double sa = ra->seek_start, sb = rb->seek_start;
    if (sa == MP_NOPTS_VALUE || sb == MP_NOPTS_VALUE)
        return (sa == MP_NOPTS_VALUE) - (sb == MP_NOPTS_VALUE);
    return sa < sb ? -1 : sa > sb;
}

struct mak_demux_feed *mak_demux_feed_attach(struct demuxer *demuxer,
                                             struct sh_stream *sh)
{
    struct demux_internal *in = demuxer->in;
    if (!sh || !sh->ds || sh->ds->in != in)
        return NULL;   /* no stream, or one of another demuxer (external) */
    struct demux_stream *ds = sh->ds;

    mp_mutex_lock(&in->lock);
    if (!in->seekable_cache || !ds->selected) {
        mp_mutex_unlock(&in->lock);
        return NULL;
    }
    if (in->mak_feed) {
        mak_demux_feed_owner_release(in->mak_feed);
        in->mak_feed = NULL;
    }
    struct mak_demux_feed *f = mak_demux_feed_new(ds->index);
    if (!f) {
        mp_mutex_unlock(&in->lock);
        return NULL;
    }

    struct demux_cached_range **ranges =
        talloc_memdup(NULL, in->ranges, in->num_ranges * sizeof(in->ranges[0]));
    int num_ranges = ranges ? in->num_ranges : 0;
    if (num_ranges > 1)
        qsort(ranges, num_ranges, sizeof(ranges[0]), mak_feed_range_cmp);
    for (int n = 0; n < num_ranges; n++) {
        struct demux_queue *queue = ranges[n]->streams[ds->index];
        for (struct demux_packet *dp = queue->head; dp; dp = dp->next) {
            mak_demux_feed_push_owned(f, read_packet_from_cache(in, dp), queue,
                                      queue->is_bof);
        }
        if (queue->is_eof && queue->head)
            mak_demux_feed_mark(f, MAK_FEED_EOF);
    }
    talloc_free(ranges);

    in->mak_feed = f;
    mp_mutex_unlock(&in->lock);
    return f;
}
