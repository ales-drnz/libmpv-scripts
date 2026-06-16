/* MAK_WAVEFORM_PATCH ─── bulk-analysis scan engine.
 *
 * The decode engine shared by the waveform analyzer and the offline loudness
 * scan: ONE pass over the source. On mak_scan_start() it spawns a detached
 * coordinator that probes the URL, classifies it, and either
 *   - BULK: partitions the track across MAK_WAVEFORM_WORKERS worker threads on
 *     disjoint sample regions, decodes each to mono Float32, and drives the
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
 * mpv's demuxer. The coordinator takes its own copy of the URL. */
void mak_scan_start(const char *url, double duration_secs,
                    const char *format_name, bool is_network,
                    bool seekable);

#endif
