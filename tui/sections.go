// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"fmt"
	"strings"
)

// ── Modular Settings sections ────────────────────────────────────────────────
//
// Everything the user can toggle in Settings — ffmpeg decoders, ffmpeg filters,
// source patches, and anything added later — is modelled the same way: a
// `section` with a catalog of `toggle`s and a rule for how its selection is
// written into the build override script (scripts/shared/_user_overrides.sh).
//
// To add a whole new tab of options you only add ONE entry to
// `toggleSections()` (plus its catalog). The Settings UI, persistence, the
// override file and the reset logic all pick it up automatically — there is no
// per-section special-casing anywhere else.

// toggle is a single switchable build option.
type toggle struct {
	Name      string // stable id within its section (ffmpeg token / patch id)
	Title     string // short human label
	Desc      string // one-line description
	Category  string // grouping within the section
	AppleOnly bool   // only compiles on macOS/iOS
	Required  bool   // locked on — the build/config audit depends on it
	DefaultOn bool   // part of the curated default set
}

// Build flavors. The selected flavor decides which sections are shown in the
// Settings UI and what kind of libmpv the build produces (see MPV_FLAVOR in
// scripts/shared/_flavor.sh).
const (
	flavorAudio = "audio"
	flavorVideo = "video"
)

// flavorOrDefault normalises an empty/unknown flavor to the audio default.
func flavorOrDefault(f string) string {
	if f == flavorVideo {
		return flavorVideo
	}
	return flavorAudio
}

// section is one Settings tab.
type section struct {
	Key   string // stable id, namespaces the toggles ("decoders", …)
	Label string // tab label
	items func() []toggle
	// Flavors lists the build flavors this section appears in. Empty ⇒ every
	// flavor (the shared audio sections). A video-only section lists
	// {flavorVideo}. This is the ONE place flavor membership is declared — the
	// UI, persistence and override generation all derive from it.
	Flavors []string
	// emit returns the shell line(s) this section contributes to the override
	// script, given the resolved on/off state of its items (keyed by raw Name).
	// Only called for sections that differ from their defaults.
	emit func(sel map[string]bool, items []toggle) []string
}

// inFlavor reports whether this section is shown in flavor f.
func (s section) inFlavor(f string) bool {
	if len(s.Flavors) == 0 {
		return true // shared across all flavors
	}
	return contains(s.Flavors, f)
}

// toggleSections is the single registry of ALL Settings sections across every
// flavor. Persistence iterates this so a flavor's deltas round-trip even while
// the other flavor is active; the UI shows only visibleSections(flavor). Add a
// section here (with its Flavors) and the UI, persistence, override file and
// reset logic all pick it up — there is no per-section special-casing.
func toggleSections() []section {
	return []section{
		{Key: "decoders", Label: "Decoders", items: ffToggles(ffDecoder), emit: emitEnabledCSV("AUDIO_DECODERS")},
		{Key: "filters", Label: "Filters", items: ffToggles(ffFilter), emit: emitEnabledCSV("AUDIO_FILTERS")},
		{Key: "video-decoders", Label: "Video Decoders", items: ffToggles(ffVideoDecoder), Flavors: []string{flavorVideo}, emit: emitEnabledCSV("VIDEO_DECODERS")},
		{Key: "patches", Label: "Patches", items: patchToggles, emit: emitDisabledList("DISABLED_PATCHES")},
	}
}

// sectionsForFlavor filters the full registry down to the sections shown for
// flavor f (used by the Settings UI).
func sectionsForFlavor(f string) []section {
	f = flavorOrDefault(f)
	var out []section
	for _, s := range toggleSections() {
		if s.inFlavor(f) {
			out = append(out, s)
		}
	}
	return out
}

// visibleSections are the Settings sub-tabs for the active build flavor. The
// flavor is chosen on the Select page (next to Build) and persisted, so Settings
// just reflects it — the Video Decoders tab appears only in the video flavor.
func (m model) visibleSections() []section { return sectionsForFlavor(m.settings.Flavor) }

// nsKey namespaces a toggle so the global enabled-map never collides across
// sections.
func nsKey(sectionKey, name string) string { return sectionKey + ":" + name }

// ── catalog adapters ─────────────────────────────────────────────────────────

func ffToggles(kind FFKind) func() []toggle {
	return func() []toggle {
		var out []toggle
		for _, it := range ffmpegCatalog() {
			if it.Kind != kind {
				continue
			}
			out = append(out, toggle{
				Name: it.Name, Title: it.Title, Desc: it.Desc, Category: it.Category,
				AppleOnly: it.AppleOnly, Required: it.Required, DefaultOn: it.DefaultOn,
			})
		}
		return out
	}
}

func patchToggles() []toggle {
	var out []toggle
	for _, p := range patchesCatalog() {
		out = append(out, toggle{
			Name: p.ID, Title: p.Title, Desc: p.Desc, Category: p.Category,
			Required: p.Required, DefaultOn: p.DefaultOn,
		})
	}
	return out
}

// ── override emitters ────────────────────────────────────────────────────────

// emitEnabledCSV writes the comma-joined list of ENABLED items (catalog order):
//
//	export VAR="aac,flac,…"
func emitEnabledCSV(varName string) func(map[string]bool, []toggle) []string {
	return func(sel map[string]bool, items []toggle) []string {
		var on []string
		for _, it := range items {
			if sel[it.Name] {
				on = append(on, it.Name)
			}
		}
		return []string{fmt.Sprintf("export %s=%q", varName, strings.Join(on, ","))}
	}
}

// emitDisabledList writes the space-joined list of DEFAULT-ON items the user
// turned OFF:
//
//	export VAR="pcm_tap dash_keepalive"
func emitDisabledList(varName string) func(map[string]bool, []toggle) []string {
	return func(sel map[string]bool, items []toggle) []string {
		var off []string
		for _, it := range items {
			if it.DefaultOn && !sel[it.Name] {
				off = append(off, it.Name)
			}
		}
		return []string{fmt.Sprintf("export %s=%q", varName, strings.Join(off, " "))}
	}
}

// sectionAtDefault reports whether every item matches its default state.
func sectionAtDefault(sel map[string]bool, items []toggle) bool {
	for _, it := range items {
		on := sel[it.Name]
		if it.Required {
			on = true
		}
		if on != it.DefaultOn {
			return false
		}
	}
	return true
}
