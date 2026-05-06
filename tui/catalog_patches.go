// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

// PatchItem is one source patch applied to mpv/ffmpeg during the build that the
// user can turn on or off from Settings ▸ Patches. The ID matches the token the
// build scripts check in DISABLED_PATCHES (see scripts/shared/_audio_only.sh).
//
// Only the cross-platform "feature" patches are listed — the per-platform
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
func patchesCatalog() []PatchItem {
	return []PatchItem{
		// ── mpv runtime (applied via apply_mpv_patches_common) ──────────────
		// (patch_optional_deps is build infrastructure — always applied, not a
		// user-facing toggle, so it isn't listed here.)
		{ID: "afmt_reset", Title: "Audio-format reset", Desc: "Reset the audio-format property to auto via the API", Category: "mpv runtime", DefaultOn: true},
		{ID: "prefetch_hook", Title: "Prefetch on_load hook", Desc: "Run on_load hooks for prefetched files (e.g. Plex URLs)", Category: "mpv runtime", DefaultOn: true},
		{ID: "prefetch_state", Title: "Prefetch-state property", Desc: "Observable 'prefetch-state' for a Prefetching… UI", Category: "mpv runtime", DefaultOn: true},
		{ID: "audio_output_state", Title: "Audio-output state", Desc: "Observable 'audio-output-state' (connecting/failed)", Category: "mpv runtime", DefaultOn: true},
		{ID: "embedded_cover_art", Title: "Embedded cover art", Desc: "Expose embedded album-art bytes + MIME as properties", Category: "mpv runtime", DefaultOn: true},
		{ID: "pcm_tap", Title: "PCM tap (visualizer)", Desc: "'pcm-tap-frame' post-DSP samples for spectrum visualizers", Category: "mpv runtime", DefaultOn: true},
		{ID: "bulk_analysis", Title: "Bulk waveform analysis", Desc: "Whole-file min/max waveform envelope on load", Category: "mpv runtime", DefaultOn: true},
		{ID: "filter_label_tap", Title: "Per-filter audio tap", Desc: "Pre/post tap per filter for plug-in–style meters", Category: "mpv runtime", DefaultOn: true},

		// ── FFmpeg (applied via apply_ffmpeg_patches) ───────────────────────
		{ID: "libsmb2", Title: "SMB2 / NAS playback", Desc: "Adds the libsmb2 protocol (Samba/NAS)", Category: "FFmpeg", DefaultOn: true},
		{ID: "advanced_editlist", Title: "Fragmented-MP4 edit lists", Desc: "Honor edit lists on fragmented MP4 (correct trim/gapless)", Category: "FFmpeg", DefaultOn: true},
		{ID: "dash_keepalive", Title: "DASH HTTP keep-alive", Desc: "Reuse connections in the DASH demuxer (Plex/Jellyfin)", Category: "FFmpeg", DefaultOn: true},
	}
}
