/* MAK_WAVEFORM_PATCH ─── bulk-analysis scan engine.
 *
 * The decode engine shared by the waveform analyzer and the offline loudness
 * scan: ONE pass over the source. On mak_scan_start() it spawns a detached
 * coordinator that probes the URL, classifies it, and either
 *   - BULK: partitions the track across MAK_WAVEFORM_WORKERS worker threads on
 *     disjoint sample regions, decodes each to mono Float32 (the same average
 *     downmix the af-tap uses, mak_downmix_mono), and drives the
 *     waveform product (incremental publish + final commit) while the loudness
 *     accumulator rides the same decode; or
 *   - hands a playback-grown source (adaptive / live / non-seekable) to the
 *     waveform product's PROGRESSIVE / ROLLING strategy (grown by the af-tap).
 *
 * The engine owns the threading, decode, source classification, and the
 * generation/cancellation lifecycle. It is product-agnostic in spirit: the
 * waveform STATE lives in mak_waveform.c (which the engine calls through the
 * "scan-engine interface" in mak_waveform.h), and the loudness accumulator is
 * woven into the worker/coordinator here by patch_loudness_scan.py (optional —
 * the engine compiles and links standalone without it).
 *
 * Dependency direction: mak_scan → mak_waveform (→ mak_loudness, woven). The
 * waveform product never calls back into the engine. */
#ifndef MP_AUDIO_MAK_SCAN_H_
#define MP_AUDIO_MAK_SCAN_H_

#include <stdbool.h>

/* Which audio stream of the source the analysis decodes: the one the player
 * plays, as the core knows it, for the coordinator to find again in its own
 * open of the source. Each index is -1 when unknown. */
struct mak_scan_track {
    int lavf_index;  /* stream index, when mpv opened the source with lavf */
    int mkv_id;      /* Matroska track number, with mpv's Matroska demuxer */
    int ordinal;     /* position among the audio streams of the source */
    /* Where playback time starts in the source's timestamps: mpv's demuxer
     * start time, which it subtracts from them (rebase-start-time, on by
     * default). The analysis places samples on the same axis. */
    double start_secs;
};

/* Begin analysis for the just-loaded file. No-op if neither the waveform nor
 * the loudness gate is set, or if [url] is null/empty. Bumps the generation
 * counter so any in-flight coordinator/workers self-cancel.
 *
 * Classification uses what mpv ALREADY knows (passed in by the caller) so a
 * network adaptive source is never re-opened here. Re-opening a Jellyfin/Plex
 * HLS transcode would be a second concurrent open of the same live transcode:
 * the server kills+restarts it on each init-segment request, so the probe and
 * the player's own open kill each other → HTTP 500 → no waveform + desync.
 * Strategy:
 *   - **HTTP + non-seekable + not adaptive, with [duration_hint] > 0** (a
 *     transcode that tells no length, the per-file option
 *     waveform-duration-hint): decoded from [demuxer]'s cache like a
 *     seekable HTTP file below, on an axis of [duration_hint] seconds, and
 *     never re-opened (see mak_feed.h). Grown from playback on that axis
 *     when the cache cannot be fed.
 *   - **network + adaptive** ([format_name] hls/dash/applehttp) OR
 *     **network + non-seekable**: arm PROGRESSIVE ([duration_secs] > 0) or
 *     ROLLING (unknown) DIRECTLY — grown from playback by the af-tap, NO
 *     second open of [url].
 *   - **everything else** (local file, or a seekable HTTP byte-range part —
 *     e.g. a Plex/Jellyfin DIRECT-PLAY original file): hand to the coordinator,
 *     which probes [url] with libav and BULK-decodes a complete seekable file
 *     up-front (re-opening a local/static file is harmless — no transcode to
 *     kill). A *local* adaptive source (local .m3u8) still goes progressive via
 *     the coordinator's own probe.
 *
 * [format_name] is the lavf format name (mpv's `demuxer->filetype`, e.g.
 * "hls" / "flac"; may be NULL). [is_network] / [seekable] come straight from
 * mpv's demuxer. The coordinator takes its own copy of the URL.
 *
 * [global] and [log] are the core's (mpctx->global / mpctx->log). The
 * coordinator and its workers re-open [url] with the SAME network options mpv
 * uses for its own lavf opens (mp_setup_av_network_options: tls-verify,
 * tls-ca-file, http-header-fields incl. file-local ones, user-agent, cookies,
 * proxy, stream-lavf-o). They are snapshotted here, on the core thread, so
 * the detached coordinator never reads the core's config and a file-local
 * header set for this track is the one that rides the re-open.
 *
 * A seekable network file whose [demuxer] keeps a seekable cache is not
 * re-opened at all: the analysis decodes [audio]'s packets from that cache
 * (mak_feed.h), so the file is downloaded once. [demuxer] and [audio] may be
 * NULL; the re-open then applies as before.
 *
 * [audio] is the track the player plays: the re-open decodes the same
 * stream of [url]. A track of another source (an external audio file) is not
 * in [url]: its waveform grows from playback and the loudness scan reports
 * unavailable. */
struct mpv_global;
struct mp_log;
struct demuxer;
struct sh_stream;
void mak_scan_start(const char *url, double duration_secs,
                    double duration_hint,
                    const char *format_name, bool is_network,
                    bool seekable, struct mpv_global *global,
                    struct mp_log *log, struct demuxer *demuxer,
                    struct sh_stream *audio);

/* The loaded file is closing (stop, the next file, an error, the end of the
 * playlist), called by the core before the demuxer goes. An analysis still
 * running for it stops: its threads exit at their next generation check (a
 * 4096-sample budget, or the interrupt callback of a blocked read), and the
 * waveform and the loudness scan turn failed, as when a cache-fed pass loses
 * its demuxer. A finished result stays. Core thread. */
void mak_scan_file_closed(void);

/* Core lifetime bracket, called from mp_create / mp_destroy. When the last
 * core goes away, the in-flight analysis is cancelled and its detached
 * threads are drained (bounded), so none outlives the libav and TLS state
 * that process teardown frees. */
void mak_scan_core_acquire(void);
void mak_scan_core_release(void);

/* Count an analysis thread started outside this file (the cache-fed engine)
 * in the drain above. Leave is its last touch of shared state. */
void mak_scan_thread_enter(void);
void mak_scan_thread_leave(void);

/* Re-open [url] for generation [gen] with the coordinator, as mak_scan_start
 * does for a source it does not feed from the cache. For the cache-fed engine
 * when its pass cannot cover the file. Copies [url], [net_opts] and [track]
 * (the stream to decode). */
struct AVDictionary;
void mak_scan_reopen(int gen, const char *url, double duration_secs,
                     const struct AVDictionary *net_opts,
                     const struct mak_scan_track *track);

#endif
