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

// section is one Settings tab.
type section struct {
	Key   string // stable id, namespaces the toggles ("decoders", …)
	Label string // tab label
	items func() []toggle
	// emit returns the shell line(s) this section contributes to the override
	// script, given the resolved on/off state of its items (keyed by raw Name).
	// Only called for sections that differ from their defaults.
	emit func(sel map[string]bool, items []toggle) []string
}

// toggleSections is the single registry of Settings sections. Add one here to
// add a tab — nothing else to touch.
func toggleSections() []section {
	return []section{
		{Key: "decoders", Label: "Decoders", items: ffToggles(ffDecoder), emit: emitEnabledCSV("AUDIO_DECODERS")},
		{Key: "filters", Label: "Filters", items: ffToggles(ffFilter), emit: emitEnabledCSV("AUDIO_FILTERS")},
		{Key: "patches", Label: "Patches", items: patchToggles, emit: emitDisabledList("DISABLED_PATCHES")},
	}
}

func numToggleSections() int { return len(toggleSections()) }

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
