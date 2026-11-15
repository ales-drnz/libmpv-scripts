// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// feed_queue_test <mode>: white-box test of the packet queue of
// demux/mak_demux_feed.c, between the demuxer that pushes and the scan
// thread of the cache-fed analysis that pops (audio/mak_feed.c). The
// demuxer side is played by the test, as add_packet_locked() and
// read_packet() of the patched demux.c call it; the packets are stubs.
// What each pop returns decides how the pass ends: a GAP hands it over (the
// re-open, or the waveform grown from playback for a stream on a hinted
// length), CLOSED marks it failed.
//   cutlate  three packets queued and not popped yet (a consumer behind the
//            download, as under valgrind), then the cache fills and cuts
//            the feed, and the next packet the demuxer reads makes the push
//            fail and the demuxer let go (owner release). The pop still
//            reports the GAP of the cut. r26 before the fix dropped it with
//            the queue and reported CLOSED: analysis_hint_test full failed
//            the waveform and the loudness instead of growing from
//            playback, two runs in three on CI under valgrind.
//   cutstop  the same, the demuxer gone without a push after the cut (the
//            player stopped): the GAP as well.
//   stop     no cut, the demuxer gone with packets queued: CLOSED, the
//            pass failed (analysis_close_test feedstop), as before.
//   eof      the demuxer gone after an EOF was queued: the queue is drained
//            in order to the EOF, a pass that finished.
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "demux/mak_demux_feed.c"

// The stubs of the demuxer's packet functions the queue calls.
static int live_packets;

void free_demux_packet(struct demux_packet *dp)
{
    if (dp) {
        live_packets--;
        free(dp);
    }
}

struct demux_packet *demux_copy_packet(struct demux_packet_pool *pool,
                                       struct demux_packet *dp)
{
    (void)pool;
    struct demux_packet *c = malloc(sizeof(*c));
    if (!c)
        return NULL;
    *c = *dp;
    live_packets++;
    return c;
}

size_t demux_packet_estimate_total_size(struct demux_packet *dp)
{
    (void)dp;
    return 1000;
}

int64_t mp_time_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static int failures;

static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s ", ok ? "ok  " : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    fflush(stdout);
    failures += !ok;
}

static const char *item_name(enum mak_feed_item it)
{
    switch (it) {
    case MAK_FEED_PACKET: return "PACKET";
    case MAK_FEED_BOF: return "BOF";
    case MAK_FEED_GAP: return "GAP";
    case MAK_FEED_EOF: return "EOF";
    case MAK_FEED_CLOSED: return "CLOSED";
    case MAK_FEED_TIMEOUT: return "TIMEOUT";
    default: return "other";
    }
}

// One packet read by the demuxer, as add_packet_locked() queues it: false
// when the push failed and the demuxer let go of the feed.
static bool demux_push(struct mak_demux_feed *f, const void *queue, bool bof,
                       double pts)
{
    struct demux_packet dp = { .pts = pts, .dts = pts, .duration = 0.02,
                               .pos = -1, .stream = 0 };
    if (mak_demux_feed_push(f, &dp, queue, bof))
        return true;
    mak_demux_feed_owner_release(f);
    return false;
}

// Pops one item, freeing its packet.
static enum mak_feed_item pop(struct mak_demux_feed *f)
{
    struct demux_packet *dp;
    enum mak_feed_item it = mak_demux_feed_pop(f, &dp, MP_TIME_MS_TO_NS(10));
    free_demux_packet(dp);
    return it;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s cutlate|cutstop|stop|eof\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    int q;   // the cache queue, by address
    struct mak_demux_feed *f = mak_demux_feed_new(0);
    for (int n = 0; n < 3; n++)
        demux_push(f, &q, n == 0, n * 0.02);
    check(pop(f) == MAK_FEED_BOF, "the pass starts the file");
    check(pop(f) == MAK_FEED_PACKET, "its first packet decodes");

    enum mak_feed_item end;
    if (!strcmp(mode, "cutlate") || !strcmp(mode, "cutstop")) {
        // read_packet(): the cache of a stream of unknown size is full.
        mak_demux_feed_cut(f);
        if (!strcmp(mode, "cutlate"))
            check(!demux_push(f, &q, false, 0.06),
                  "the push after the cut fails and the demuxer lets go");
        else
            mak_demux_feed_owner_release(f);
        end = pop(f);
        check(end == MAK_FEED_GAP, "the pass ends on the GAP of the cut (%s)",
              item_name(end));
    } else if (!strcmp(mode, "stop")) {
        mak_demux_feed_owner_release(f);
        end = pop(f);
        check(end == MAK_FEED_CLOSED, "the demuxer gone mid-pass is CLOSED (%s)",
              item_name(end));
    } else if (!strcmp(mode, "eof")) {
        mak_demux_feed_mark(f, MAK_FEED_EOF);
        mak_demux_feed_owner_release(f);
        enum mak_feed_item a = pop(f), b = pop(f);
        end = pop(f);
        check(a == MAK_FEED_PACKET && b == MAK_FEED_PACKET && end == MAK_FEED_EOF,
              "the queue drains to its EOF (%s %s %s)", item_name(a), item_name(b),
              item_name(end));
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    end = pop(f);
    check(end == MAK_FEED_CLOSED, "then the feed is closed (%s)", item_name(end));
    mak_demux_feed_close(f);
    check(live_packets == 0, "no packet left (%d)", live_packets);
    printf("RESULT %s (%d)\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}
