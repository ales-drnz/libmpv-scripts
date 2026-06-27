// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// userSettings is the persisted, user-customizable build configuration. It is
// stored as JSON in the user's config dir and is the single source of truth for
// the Settings screen.
//
// Each Settings section (decoders, filters, patches, …) stores its choice as a
// DELTA from that section's curated defaults — so new defaults added in a
// future release are picked up automatically rather than frozen into a saved
// snapshot. The set of sections is defined entirely by toggleSections(); this
// struct stays generic so adding a section needs no schema change.
type userSettings struct {
	// Flavor is the build flavor: "audio" (default, the historical audio-only
	// library) or "video" (video-capable). It selects which Settings sections
	// are shown and is exported to the build as MPV_FLAVOR.
	Flavor string `json:"flavor,omitempty"`
	// Sections maps a section key ("decoders", "filters", "patches", …) to its
	// delta from defaults. Absent / empty ⇒ that section is at defaults.
	Sections map[string]sectionDelta `json:"sections"`
	// On a build failure, mark every still-queued build as skipped instead of
	// attempting it. Opt-in.
	SkipOnFailure bool `json:"skipOnFailure"`
	// After every build of an OS finishes successfully, delete that OS's
	// builds/work/<OS>/ tree to reclaim space. Opt-in. Cleaned per-OS, not
	// per-arch, so arches that share a cached toolchain/deps tree within one OS
	// aren't wiped mid-OS.
	CleanWorkAfterBuild bool `json:"cleanWorkAfterBuild"`
	// Force the Android build through Docker even on macOS. By default Android
	// builds NATIVELY on an Apple-Silicon host (the macOS NDK is native arm64 →
	// no Docker/emulation, much faster); set this to pin it to the Docker image
	// instead. Only meaningful on macOS — elsewhere Android always uses Docker.
	ForceAndroidDocker bool `json:"forceAndroidDocker"`
}

// sectionDelta records the per-section difference from the curated defaults.
type sectionDelta struct {
	Disabled []string `json:"disabled"` // default-on items turned off
	Enabled  []string `json:"enabled"`  // non-default items turned on
}

func defaultSettings() userSettings {
	// Everything at defaults (no override file), audio flavor, auto-skip off —
	// the long-standing behaviour.
	return userSettings{Flavor: flavorAudio, Sections: map[string]sectionDelta{}, SkipOnFailure: false, CleanWorkAfterBuild: false}
}

// settingsPath returns <user-config>/libmpv-build/settings.json.
func settingsPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "libmpv-build", "settings.json"), nil
}

// loadSettings reads the persisted settings, falling back to defaults when the
// file is absent or unreadable.
func loadSettings() userSettings {
	p, err := settingsPath()
	if err != nil {
		return defaultSettings()
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return defaultSettings()
	}
	us := defaultSettings()
	if json.Unmarshal(data, &us) != nil {
		return defaultSettings()
	}
	if us.Sections == nil {
		us.Sections = map[string]sectionDelta{}
	}
	us.Flavor = flavorOrDefault(us.Flavor)
	return us
}

// save persists the settings JSON and (re)generates the override script the
// build reads. When every section is at defaults the override script is removed
// so the curated lists are used verbatim.
func (us userSettings) save(scriptsRoot string) error {
	p, err := settingsPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(us, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(p, data, 0o644); err != nil {
		return err
	}
	return us.writeOverride(scriptsRoot)
}

// ── resolution ───────────────────────────────────────────────────────────────

func contains(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

// enabledSet resolves the on/off state of every toggle across all sections,
// keyed by the namespaced "section:name". Required items are always on.
func (us userSettings) enabledSet() map[string]bool {
	out := map[string]bool{}
	for _, sec := range toggleSections() {
		d := us.Sections[sec.Key]
		for _, it := range sec.items() {
			on := it.DefaultOn
			if contains(d.Disabled, it.Name) {
				on = false
			}
			if contains(d.Enabled, it.Name) {
				on = true
			}
			if it.Required {
				on = true
			}
			out[nsKey(sec.Key, it.Name)] = on
		}
	}
	return out
}

// settingsFromEnabled folds a namespaced on-map back into per-section deltas,
// keeping the SkipOnFailure flag from the receiver.
func (us userSettings) settingsFromEnabled(enabled map[string]bool) userSettings {
	res := userSettings{Flavor: flavorOrDefault(us.Flavor), Sections: map[string]sectionDelta{}, SkipOnFailure: us.SkipOnFailure, CleanWorkAfterBuild: us.CleanWorkAfterBuild, ForceAndroidDocker: us.ForceAndroidDocker}
	for _, sec := range toggleSections() {
		var d sectionDelta
		for _, it := range sec.items() {
			if it.Required {
				continue // never recorded; always on
			}
			on := enabled[nsKey(sec.Key, it.Name)]
			if it.DefaultOn && !on {
				d.Disabled = append(d.Disabled, it.Name)
			}
			if !it.DefaultOn && on {
				d.Enabled = append(d.Enabled, it.Name)
			}
		}
		if len(d.Disabled) > 0 || len(d.Enabled) > 0 {
			res.Sections[sec.Key] = d
		}
	}
	return res
}

// isDefaultSelection reports whether every section is at its defaults.
func (us userSettings) isDefaultSelection() bool { return len(us.Sections) == 0 }

const overrideRelPath = "scripts/shared/_user_overrides.sh"

// writeOverride regenerates scripts/shared/_user_overrides.sh from the sections
// that differ from their defaults, or removes it when everything is default.
// _flavor.sh sources this file, so the re-exported values win.
func (us userSettings) writeOverride(scriptsRoot string) error {
	path := filepath.Join(scriptsRoot, overrideRelPath)

	enabled := us.enabledSet()
	var lines []string
	// Flavor first: a non-default (video) flavor must always emit MPV_FLAVOR,
	// even when every section is at defaults — otherwise the shell would fall
	// back to audio. The audio default emits nothing (file may be removed).
	flavor := flavorOrDefault(us.Flavor)
	if flavor != flavorAudio {
		lines = append(lines, fmt.Sprintf("export MPV_FLAVOR=%q", flavor))
	}
	for _, sec := range toggleSections() {
		items := sec.items()
		sel := make(map[string]bool, len(items))
		for _, it := range items {
			sel[it.Name] = enabled[nsKey(sec.Key, it.Name)]
		}
		if sectionAtDefault(sel, items) {
			continue
		}
		lines = append(lines, sec.emit(sel, items)...)
	}

	if len(lines) == 0 {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}

	var b strings.Builder
	b.WriteString("# Generated by the libmpv build TUI — Settings.\n")
	b.WriteString("# Do not edit by hand: run `./build`, open Settings, and toggle there.\n")
	b.WriteString("# Delete this file (or reset in Settings) to restore the curated defaults.\n")
	b.WriteString("# Sourced by scripts/shared/_flavor.sh.\n\n")
	for _, ln := range lines {
		writeLine(&b, ln)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(b.String()), 0o644)
}
