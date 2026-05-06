// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// TestAvailabilityByHost locks the per-host feasibility matrix.
func TestAvailabilityByHost(t *testing.T) {
	saved := hostOS
	defer func() { hostOS = saved }()
	get := func(k string) Target { tg, _ := targetByKey(k); return tg }

	hostOS = "windows"
	for _, k := range []string{"macos", "ios"} { // only Apple is off-limits
		if get(k).Available() {
			t.Errorf("%s must be unavailable on Windows", k)
		}
	}
	// Android (Docker) + checksums (Go self-exec) now work on Windows too.
	for _, k := range []string{"windows-x86_64", "windows-arm64", "linux-x86_64", "verify", "android", "checksums"} {
		if !get(k).Available() {
			t.Errorf("%s should be available on Windows", k)
		}
	}

	hostOS = "linux"
	if get("macos").Available() || get("ios").Available() {
		t.Error("Apple targets must be unavailable on Linux")
	}
	for _, k := range []string{"android", "checksums", "windows-x86_64", "linux-aarch64", "verify"} {
		if !get(k).Available() {
			t.Errorf("%s should be available on Linux", k)
		}
	}

	hostOS = "darwin"
	for _, k := range []string{"macos", "ios", "android", "checksums", "windows-x86_64", "linux-x86_64", "verify"} {
		if !get(k).Available() {
			t.Errorf("%s should be available on macOS", k)
		}
	}
}

// focusCell parks the grid cursor on the cell with the given target key.
func focusCell(m *model, key string) bool {
	for bi, band := range m.selBands() {
		for ci, c := range band {
			for ri, idx := range c.items {
				if m.targets[idx].Key == key {
					m.onAllBin, m.onTabs, m.onBuild = false, false, false
					m.selBand, m.selCol, m.selRow = bi, ci, ri
					return true
				}
			}
		}
	}
	return false
}

// TestGroupAllCoversArches: selecting a group "all" makes its arches show
// checked + covered (locked), while the "all" cell itself isn't covered.
func TestGroupAllCoversArches(t *testing.T) {
	m := newTestModel()
	wAll := targetIndex(m, "windows") // group "all" (aggregate)
	wX := targetIndex(m, "windows-x86_64")
	m.selected[wAll] = true

	if !m.cellChecked(wX) {
		t.Error("arch should render checked when its group-all is selected")
	}
	if !m.cellCovered(wX) || !m.cellLocked(wX) {
		t.Error("arch should be covered + locked when its group-all is selected")
	}
	if m.cellCovered(wAll) {
		t.Error("the group-all cell must not be covered by itself")
	}
}

// TestToggleGroupAllClearsArches: turning a group "all" on drops any per-arch
// selections in that group (they become covered).
func TestToggleGroupAllClearsArches(t *testing.T) {
	m := newTestModel()
	wX := targetIndex(m, "windows-x86_64")
	m.selected[wX] = true
	if !focusCell(&m, "windows") {
		t.Fatal("windows 'all' cell not found")
	}
	m.activateFocused(m.selBands())

	if !m.selected[targetIndex(m, "windows")] {
		t.Fatal("group-all should be selected after toggle")
	}
	if m.selected[wX] {
		t.Error("the per-arch selection should be cleared when group-all turns on")
	}
}

// TestCoveredArchNotToggleable: a covered (locked) arch can't be independently
// selected.
func TestCoveredArchNotToggleable(t *testing.T) {
	m := newTestModel()
	m.selected[targetIndex(m, "windows")] = true // covers the arches
	if !focusCell(&m, "windows-x86_64") {
		t.Fatal("windows-x86_64 cell not found")
	}
	m.activateFocused(m.selBands())
	if m.selected[targetIndex(m, "windows-x86_64")] {
		t.Error("a covered arch must not become independently selected")
	}
}

// TestSelectedCountExcludesAllRow: the "(N selected)" count counts the covered
// arches but not the aggregate "all" row itself.
func TestSelectedCountExcludesAllRow(t *testing.T) {
	m := newTestModel()
	m.selected = map[int]bool{}
	m.selected[targetIndex(m, "windows")] = true // group "all" (covers 2 arches)
	if got := m.selectedCount(); got != 2 {
		t.Errorf("windows-all should count its 2 arches (not the all row); got %d", got)
	}
}

// TestSkipOptionNavAndToggle: on the Tools tab, the two build options sit ABOVE
// the action cells (Skip → Clean-work → grid), and space toggles them.
func TestSkipOptionNavAndToggle(t *testing.T) {
	m := newTestModel()
	m.buildTab = 1  // Tools tab
	m.onSkip = true // options are the top of Tools (landed here from the strip)

	before := m.settings.SkipOnFailure
	m = press(m, " ") // toggle skip
	if m.settings.SkipOnFailure == before {
		t.Error("space on the skip option should toggle SkipOnFailure")
	}
	m = pressKey(m, tea.KeyDown) // skip → clean-work option
	if !m.onCleanWork {
		t.Fatal("down from skip should reach the clean-work option")
	}
	m = pressKey(m, tea.KeyDown) // clean-work → into the Tools grid
	if m.onSkip || m.onCleanWork {
		t.Fatal("down from clean-work should enter the Tools grid")
	}
	m = pressKey(m, tea.KeyUp) // grid top → clean-work option (above the grid)
	if !m.onCleanWork {
		t.Fatal("up from the Tools grid top should return to the clean-work option")
	}
}

// TestBuildTabSwitch: ←→ on the build sub-tab strip switches Compile/Tools.
func TestBuildTabSwitch(t *testing.T) {
	m := newTestModel()
	m.onBuildTabs = true
	m.buildTab = 0
	m = pressKey(m, tea.KeyRight)
	if m.buildTab != 1 {
		t.Errorf("right on the strip should switch to Tools; buildTab=%d", m.buildTab)
	}
	m = pressKey(m, tea.KeyLeft)
	if m.buildTab != 0 {
		t.Errorf("left should switch back to Compile; buildTab=%d", m.buildTab)
	}
	// down → into the active tab's content (Compile → All binaries)
	m = pressKey(m, tea.KeyDown)
	if m.onBuildTabs || !m.onAllBin {
		t.Errorf("down from strip (Compile) should land on All binaries")
	}
}

// TestPublishCellsAreActions: Checksums / Verify are one-shot actions (run on
// activate), not toggleable build targets.
func TestPublishCellsAreActions(t *testing.T) {
	m := newTestModel()
	if !m.isAction(targetIndex(m, "checksums")) {
		t.Error("checksums should be an action")
	}
	if !m.isAction(targetIndex(m, "verify")) {
		t.Error("verify should be an action")
	}
	if m.isAction(targetIndex(m, "macos-arm64")) {
		t.Error("macos-arm64 is a build target, not an action")
	}
}

// TestAllBinariesCoversAndResolves: "All binaries" covers every cell and
// resolves the build to group-alls + publish (no per-arch duplicates).
func TestAllBinariesCoversAndResolves(t *testing.T) {
	m := newTestModel()
	m.allBinaries = true
	for i := range m.targets {
		covered := m.cellCovered(i)
		if m.targets[i].Group == "Tools" { // Checksums + Verify stay opt-in
			if covered {
				t.Errorf("%s (Publish) must NOT be covered by All binaries", m.targets[i].Key)
			}
			continue
		}
		if !covered {
			t.Errorf("%s should be covered under All binaries", m.targets[i].Key)
		}
	}
	keys := m.allBinaryKeys()
	for _, k := range keys {
		if k == "verify" || k == "checksums" {
			t.Errorf("Publish step %q must not be in All-binaries build keys", k)
		}
	}
	has := func(k string) bool {
		for _, x := range keys {
			if x == k {
				return true
			}
		}
		return false
	}
	// windows + linux are always available (Docker) on any host.
	if !has("windows") || !has("linux") {
		t.Errorf("expected windows + linux group-alls in build keys: %v", keys)
	}
	if has("windows-x86_64") {
		t.Errorf("per-arch keys must not appear (covered by group-all): %v", keys)
	}
}
