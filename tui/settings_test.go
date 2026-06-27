// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

func deltaSettings(sec string, disabled ...string) userSettings {
	us := defaultSettings()
	us.Sections[sec] = sectionDelta{Disabled: disabled}
	return us
}

// TestEnabledSetAppliesDelta verifies the saved delta turns items off — every
// item is freely toggleable now (full modularity; the build audit adapts).
func TestEnabledSetAppliesDelta(t *testing.T) {
	us := deltaSettings("decoders", "aac", "ac3")
	en := us.enabledSet()
	if en["decoders:aac"] {
		t.Error("aac should be disable-able (no longer locked)")
	}
	if en["decoders:ac3"] {
		t.Error("ac3 should be disabled")
	}
	if !en["decoders:flac"] {
		t.Error("flac (untouched) should stay enabled")
	}
}

// TestDirtyClearsWhenRevertedToSaved: the unsaved indicator is computed, so
// toggling something and back to its saved value clears it.
func TestDirtyClearsWhenRevertedToSaved(t *testing.T) {
	m := newTestModel()
	m = m.gotoSettings()
	if m.isDirty() {
		t.Fatal("fresh settings should not be dirty")
	}
	m.setEnabled["decoders:ac3"] = false
	if !m.isDirty() {
		t.Error("toggling an item off should be dirty")
	}
	m.setEnabled["decoders:ac3"] = true // back to saved
	if m.isDirty() {
		t.Error("reverting to the saved value should clear dirty")
	}
}

// TestSettingsAllMasterToggle: the per-tab "All" row is on by default; toggling
// it off clears the tab, toggling it on re-selects everything.
func TestSettingsAllMasterToggle(t *testing.T) {
	m := newTestModel()
	m = m.gotoSettings() // Decoders tab, all on by default
	if m.setRows[m.setCur].name != "@all" {
		t.Fatalf("cursor should start on the @all row, got %q", m.setRows[m.setCur].name)
	}
	if on, total := m.countTab(0); on != total || total == 0 {
		t.Fatalf("decoders should start all-on: %d/%d", on, total)
	}
	m.toggleCurrent() // off → clear
	if on, _ := m.countTab(0); on != 0 {
		t.Errorf("@all off should clear the tab, got %d enabled", on)
	}
	m.toggleCurrent() // on → select all
	if on, total := m.countTab(0); on != total {
		t.Errorf("@all on should select all, got %d/%d", on, total)
	}
}

// TestNoLockedToggles locks in the "max modularity" invariant: no item in any
// section is Required, so the UI never shows a locked row.
func TestNoLockedToggles(t *testing.T) {
	for _, sec := range toggleSections() {
		for _, it := range sec.items() {
			if it.Required {
				t.Errorf("%s:%s is Required — expected everything toggleable", sec.Key, it.Name)
			}
		}
	}
}

// TestWriteOverrideRoundTrip checks the generated shell snippet across all three
// sections: enabled-CSV for ffmpeg, disabled-list for patches, required kept.
func TestWriteOverrideRoundTrip(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "scripts", "shared"), 0o755); err != nil {
		t.Fatal(err)
	}
	us := defaultSettings()
	us.Sections["decoders"] = sectionDelta{Disabled: []string{"ac3"}}
	us.Sections["filters"] = sectionDelta{Disabled: []string{"chorus"}}
	us.Sections["patches"] = sectionDelta{Disabled: []string{"pcm_tap"}}

	if err := us.writeOverride(root); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(root, overrideRelPath))
	if err != nil {
		t.Fatalf("override not written: %v", err)
	}
	s := string(data)

	decLine := lineWith(s, "AUDIO_DECODERS=")
	if csvHas(decLine, "ac3") {
		t.Errorf("ac3 should be absent from decoders: %s", decLine)
	}
	for _, req := range []string{"aac", "flac", "mp3", "opus", "vorbis", "alac"} {
		if !csvHas(decLine, req) {
			t.Errorf("required decoder %q missing: %s", req, decLine)
		}
	}
	if csvHas(lineWith(s, "AUDIO_FILTERS="), "chorus") {
		t.Error("chorus should be absent from filters")
	}
	patchLine := lineWith(s, "DISABLED_PATCHES=")
	if !strings.Contains(patchLine, "pcm_tap") {
		t.Errorf("DISABLED_PATCHES should list pcm_tap: %q", patchLine)
	}
	if strings.Contains(patchLine, "libsmb2") {
		t.Error("required patch libsmb2 must never appear in DISABLED_PATCHES")
	}
}

// TestWriteOverrideRemovedAtDefault verifies the override file is removed when
// every section returns to defaults.
func TestWriteOverrideRemovedAtDefault(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, overrideRelPath)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := defaultSettings().writeOverride(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("override file should be removed when everything is default")
	}
}

// TestSettingsDeltaRoundTrip checks settingsFromEnabled reconstructs the delta.
func TestSettingsDeltaRoundTrip(t *testing.T) {
	base := defaultSettings()
	en := base.enabledSet()
	en["decoders:ac3"] = false // disable a default-on decoder
	got := base.settingsFromEnabled(en)
	if !contains(got.Sections["decoders"].Disabled, "ac3") {
		t.Errorf("expected ac3 in decoders.Disabled, got %+v", got.Sections["decoders"])
	}
	en["decoders:aac"] = false // also disable-able now (not locked)
	got = base.settingsFromEnabled(en)
	if !contains(got.Sections["decoders"].Disabled, "aac") {
		t.Error("aac should be recorded as disabled (no longer locked)")
	}
}

// TestVideoFlavorOverride: a video build at defaults must emit MPV_FLAVOR (and
// nothing else, so the shell uses its curated VIDEO_DECODERS verbatim); a
// trimmed video selection emits a VIDEO_DECODERS line without the dropped codec.
func TestVideoFlavorOverride(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "scripts", "shared"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Default video flavor → only the flavor line.
	us := defaultSettings()
	us.Flavor = flavorVideo
	if err := us.writeOverride(root); err != nil {
		t.Fatal(err)
	}
	s := readFileStr(t, filepath.Join(root, overrideRelPath))
	if !strings.Contains(s, `export MPV_FLAVOR="video"`) {
		t.Errorf("video flavor must export MPV_FLAVOR=video, got:\n%s", s)
	}
	if strings.Contains(s, "VIDEO_DECODERS=") {
		t.Errorf("an all-default video selection must NOT emit VIDEO_DECODERS, got:\n%s", s)
	}
	// Trim one video decoder → VIDEO_DECODERS appears without it.
	us.Sections["video-decoders"] = sectionDelta{Disabled: []string{"theora"}}
	if err := us.writeOverride(root); err != nil {
		t.Fatal(err)
	}
	s = readFileStr(t, filepath.Join(root, overrideRelPath))
	vidLine := lineWith(s, "VIDEO_DECODERS=")
	if csvHas(vidLine, "theora") {
		t.Errorf("theora should be absent from VIDEO_DECODERS: %s", vidLine)
	}
	if !csvHas(vidLine, "h264") {
		t.Errorf("h264 (untouched) should stay in VIDEO_DECODERS: %s", vidLine)
	}
}

// TestAudioFlavorNoMpvFlavor: the audio default emits no override at all (so the
// shell falls back to MPV_FLAVOR=audio + the curated lists).
func TestAudioFlavorNoMpvFlavor(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "scripts", "shared"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := defaultSettings().writeOverride(root); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, overrideRelPath)); !os.IsNotExist(err) {
		t.Error("audio default must not write an override file")
	}
}

// TestVideoCatalogMatchesShell guards the load-bearing invariant: the TUI's
// ffVideoDecoder catalog and the shell's VIDEO_DECODERS list must hold the exact
// same set of tokens. If they drift, an "all-default" video selection would
// emit nothing while the shell built a different set (or the audit would trip).
func TestVideoCatalogMatchesShell(t *testing.T) {
	shell := parseShellList(t, "VIDEO_DECODERS")
	var cat []string
	for _, it := range ffmpegCatalog() {
		if it.Kind == ffVideoDecoder {
			cat = append(cat, it.Name)
		}
	}
	sort.Strings(shell)
	sort.Strings(cat)
	if strings.Join(shell, ",") != strings.Join(cat, ",") {
		t.Errorf("ffVideoDecoder catalog and shell VIDEO_DECODERS diverged.\n shell: %v\n catalog: %v", shell, cat)
	}
}

// parseShellList extracts the comma-joined tokens a `NAME=`/`NAME+=` shell
// variable accumulates across its quoted assignments in _flavor.sh.
func parseShellList(t *testing.T, name string) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "scripts", "shared", "_flavor.sh"))
	if err != nil {
		t.Fatalf("reading shell script: %v", err)
	}
	re := regexp.MustCompile(name + `\+?="([^"]*)"`)
	var out []string
	for _, mtch := range re.FindAllStringSubmatch(string(data), -1) {
		for _, tok := range strings.Split(mtch[1], ",") {
			if tok = strings.TrimSpace(tok); tok != "" {
				out = append(out, tok)
			}
		}
	}
	if len(out) == 0 {
		t.Fatalf("no tokens parsed for %s", name)
	}
	return out
}

func readFileStr(t *testing.T, p string) string {
	t.Helper()
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("reading %s: %v", p, err)
	}
	return string(data)
}

func lineWith(s, sub string) string {
	for _, ln := range strings.Split(s, "\n") {
		if strings.Contains(ln, sub) {
			return ln
		}
	}
	return ""
}

// csvHas reports whether tok is one of the comma-separated tokens inside the
// quoted value of a `export VAR="a,b,c"` line.
func csvHas(line, tok string) bool {
	i := strings.Index(line, `"`)
	if i < 0 {
		return false
	}
	body := strings.Trim(line[i:], `"`)
	for _, t := range strings.Split(body, ",") {
		if t == tok {
			return true
		}
	}
	return false
}
