// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

// PatchItem is one source patch applied to mpv/ffmpeg during the build that the
// user can turn on or off from Settings ▸ Patches. The ID matches the token the
// build scripts check in DISABLED_PATCHES (see scripts/shared/_audio_only.sh).
//
// Only the "feature" and size-reduction patches are listed. Three of them act
// on one platform only and are no-ops elsewhere: strip_win_resources and
// timer_resolution on Windows, audiotrack on Android. The per-platform
// build-correctness patches (Apple/iOS/Windows/Android fixups, rubberband,
// libplacebo) and the structural patch_optional_deps are always applied and
// aren't user-toggleable, so they're not listed here. Everything listed is
// freely toggleable: the build's config audit adapts to the selection, so no
// entry needs to be locked.
type PatchItem struct {
	ID        string // token in DISABLED_PATCHES, e.g. "pcm_tap"
	Title     string
	Desc      string
	Category  string // "mpv runtime" or "FFmpeg"
	Required  bool   // locked — build/config audit depends on it
	DefaultOn bool
}

// patchesCatalog lists the toggleable source patches, in display order.
//
// Two flavours share the DefaultOn:true + DISABLED_PATCHES mechanism:
//   - feature patches (mpv runtime / FFmpeg): DefaultOn means the FEATURE is
//     added; unchecking removes it.
//   - "Size reduction" strip patches: DefaultOn means the STRIP is applied (the
//     subsystem is removed for a smaller audio-only binary); unchecking RESTORES
//     the feature (and, for libass, rebuilds the whole font stack). The build
//     scripts gate every coupled step on the same patch_on <id>, so a toggle is
//     self-consistent across ffmpeg configure, the font-stack build and the
//     config audit.
func patchesCatalog() []PatchItem {
	return []PatchItem{
		// ── Size reduction (audio-only strips — DefaultOn = removed) ────────
		// Default-applied; uncheck to restore the corresponding feature.
		{ID: "strip_swscale", Title: "Strip libswscale", Desc: "Drop the pixel scaler (~1.5M) — audio-only never scales. Restoring it also needs ‘Strip GPU/render’ off (terminal VOs include libswscale).", Category: "Size reduction", DefaultOn: true},
		{ID: "strip_libass", Title: "Strip libass + font stack", Desc: "Remove subtitle/OSD text render + the freetype/harfbuzz/fontconfig/fribidi/libass chain (~2.5M). To restore subtitles you must ALSO uncheck ‘Strip GPU/render’ — libass needs the subtitle decode/draw infra that patch removes.", Category: "Size reduction", DefaultOn: true},
		{ID: "strip_mpv_dead", Title: "Strip GPU/render/screenshot", Desc: "Remove the GPU/shader render stack, screenshot, encode mode, bitmap-sub decode and terminal VOs (~0.7M). Uncheck to restore mpv's video paths.", Category: "Size reduction", DefaultOn: true},
		{ID: "strip_win_resources", Title: "Strip Windows icon/resources", Desc: "Drop the mpv icon/manifest/version from the Windows DLL (~267K). No-op on non-Windows targets.", Category: "Size reduction", DefaultOn: true},

		// ── mpv runtime (applied via apply_mpv_patches_common) ──────────────
		// (patch_optional_deps is build infrastructure — always applied, not a
		// user-facing toggle, so it isn't listed here.)
		{ID: "afmt_reset", Title: "Audio-format reset", Desc: "Reset the audio-format property to auto via the API", Category: "mpv runtime", DefaultOn: true},
		{ID: "prefetch", Title: "Prefetch hook and state", Desc: "An on_prefetch hook that resolves the URL of the next entry while the current one plays (e.g. Plex URLs), and the observable 'prefetch-state' for a Prefetching… UI", Category: "mpv runtime", DefaultOn: true},
		{ID: "audio_output_state", Title: "Audio-output state", Desc: "Observable 'audio-output-state' (connecting/failed)", Category: "mpv runtime", DefaultOn: true},
		{ID: "embedded_cover_art", Title: "Embedded cover art", Desc: "Expose embedded album-art bytes + MIME as properties", Category: "mpv runtime", DefaultOn: true},
		{ID: "pcm_tap", Title: "PCM tap (visualizer)", Desc: "'pcm-tap-frame' post-DSP samples for spectrum visualizers", Category: "mpv runtime", DefaultOn: true},
		{ID: "bulk_analysis", Title: "Bulk waveform analysis", Desc: "Whole-file min/max waveform envelope on load", Category: "mpv runtime", DefaultOn: true},
		{ID: "loudness_scan", Title: "Offline loudness scan", Desc: "EBU R128 integrated/LRA/true-peak on load (ReplayGain for untagged files). Rides Bulk waveform analysis — disabled with it.", Category: "mpv runtime", DefaultOn: true},
		{ID: "filter_label_tap", Title: "Per-filter audio tap", Desc: "Pre/post tap per filter for plug-in–style meters", Category: "mpv runtime", DefaultOn: true},
		{ID: "chain_eof", Title: "Keep EOF on filter changes", Desc: "Refresh-seek when an af change frees a filter holding the end of file, so playback does not stall at the end", Category: "mpv runtime", DefaultOn: true},
		{ID: "lavfi_eof_passthrough", Title: "EOF before data through lavfi", Desc: "Pass an EOF that reaches a new audio filter before any data straight on, so a filter that takes no float (hdcd) is not disabled", Category: "mpv runtime", DefaultOn: true},
		{ID: "hotplug_core_thread", Title: "Audio output and hotplug on the core thread", Desc: "Close the audio output and the audio device watcher on the thread that created them, so a libmpv destroyed from another thread does not crash on Windows (WASAPI is COM)", Category: "mpv runtime", DefaultOn: true},
		{ID: "playlist_prev_dos_path", Title: "playlist-prev-playlist on Windows paths", Desc: "Build the playlist-path prefixes as copies, so playlist-prev-playlist does not touch freed memory on Windows", Category: "mpv runtime", DefaultOn: true},
		{ID: "chapter_list_reset", Title: "Current chapter after a new chapter-list", Desc: "Forget the last chapter seek when chapter-list is set, so a shorter list does not leave chapter past its end or make chapter-metadata read beyond it (a crash)", Category: "mpv runtime", DefaultOn: true},
		{ID: "af_command_args", Title: "af-command keeps its value", Desc: "A successful af-command updates the arguments af and the filter keep, so a seek, a track switch or the next file keeps the value set live and af reads it; 'af-command-saves-args' tells a client the patch is in", Category: "mpv runtime", DefaultOn: true},
		{ID: "read_error", Title: "Read errors at the end of a file", Desc: "Tell a file cut short by a read error from one that ended: 'demuxer-read-error', 'demuxer-skipped-segments' and two END_FILE fields. Its FFmpeg side keeps a cut HTTP body short after a failed reconnect, and counts the HLS and DASH segments lost to errors", Category: "mpv runtime", DefaultOn: true},
		{ID: "timer_resolution", Title: "Windows timer-resolution fix", Desc: "Stop mpv pinning the system-wide 1 ms timer at init (it fights DWM frame-pacing → host UI micro-stutter). No-op on non-Windows targets.", Category: "mpv runtime", DefaultOn: true},
		{ID: "audiotrack", Title: "Android AudioTrack output fixes", Desc: "Fix mpv's default Android output: the thread waits instead of spinning when there is nothing to play, audio-stream-silence feeds silence, a track that dies with audioserver reloads the output instead of going silent, and a pause no longer drops the audio the track held. No-op on non-Android targets.", Category: "mpv runtime", DefaultOn: true},

		// ── FFmpeg (applied via apply_ffmpeg_patches) ───────────────────────
		{ID: "libsmb2", Title: "SMB2 / NAS playback", Desc: "Adds the libsmb2 protocol (Samba/NAS)", Category: "FFmpeg", DefaultOn: true},
		{ID: "advanced_editlist", Title: "Fragmented-MP4 edit lists", Desc: "Honor edit lists on fragmented MP4 (correct trim/gapless)", Category: "FFmpeg", DefaultOn: true},
		{ID: "dash_keepalive", Title: "DASH HTTP keep-alive", Desc: "Reuse connections in the DASH demuxer (Plex/Jellyfin)", Category: "FFmpeg", DefaultOn: true},
		{ID: "embed_cacert", Title: "Embedded CA certificates", Desc: "Compile the Mozilla CA root store into libmpv so HTTPS verification works with no on-device cert file (sandboxed macOS, iOS, Android)", Category: "FFmpeg", DefaultOn: true},
	}
}
