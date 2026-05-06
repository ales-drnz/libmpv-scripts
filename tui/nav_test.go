// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// press feeds a key string through the model's key handler and returns the
// updated model.
func press(m model, k string) model {
	mm, _ := m.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)})
	return mm.(model)
}

// pressKey feeds a named key (e.g. "up", "enter") through the handler.
func pressKey(m model, t tea.KeyType) model {
	mm, _ := m.handleKey(tea.KeyMsg{Type: t})
	return mm.(model)
}

func newTestModel() model {
	return initialModel(nil)
}

// exactlyOneCursorZone asserts the single-cursor invariant: at most one of the
// header strip / sub-tab strip / grid-or-list holds focus at a time. (onTabs
// and onSetTabs are the two "strip" zones; when both are false the content has
// the cursor.)
func assertOneZone(t *testing.T, m model) {
	t.Helper()
	if m.onTabs && m.onSetTabs {
		t.Fatalf("two cursor zones active at once: onTabs && onSetTabs")
	}
}

func TestHeaderReachableFromSettingsList(t *testing.T) {
	m := newTestModel()
	m = m.gotoSettings() // in the Decoders list
	assertOneZone(t, m)
	if m.onTabs || m.onSetTabs {
		t.Fatal("should start in the list")
	}
	// up → sub-tab strip
	m = pressKey(m, tea.KeyUp)
	if !m.onSetTabs || m.onTabs {
		t.Fatalf("up from list should land on sub-tab strip; onSetTabs=%v onTabs=%v", m.onSetTabs, m.onTabs)
	}
	assertOneZone(t, m)
	// up again → header strip (the user's reported gap)
	m = pressKey(m, tea.KeyUp)
	if !m.onTabs || m.onSetTabs {
		t.Fatalf("up from sub-tabs should reach header; onTabs=%v onSetTabs=%v", m.onTabs, m.onSetTabs)
	}
	assertOneZone(t, m)
}

func TestHeaderArrowSwitchesSectionLive(t *testing.T) {
	m := newTestModel()
	// On the Build screen: up → All-binaries, up → Compile/Tools strip, up → header.
	m = pressKey(m, tea.KeyUp)
	if !m.onAllBin {
		t.Fatal("up from grid should reach the All-binaries control")
	}
	m = pressKey(m, tea.KeyUp)
	if !m.onBuildTabs {
		t.Fatal("up from All-binaries should reach the Compile/Tools strip")
	}
	m = pressKey(m, tea.KeyUp)
	if !m.onTabs {
		t.Fatal("up from the build strip should reach the header strip")
	}
	if m.screen != scSelect {
		t.Fatalf("still on Build; screen=%d", m.screen)
	}
	// right → live switch to Settings, staying on the header strip
	m = pressKey(m, tea.KeyRight)
	if m.screen != scSettings {
		t.Fatalf("right on header should switch to Settings; screen=%d", m.screen)
	}
	if !m.onTabs {
		t.Fatal("should stay on the header strip after switching")
	}
	// right again → Dependencies
	m = pressKey(m, tea.KeyRight)
	if m.screen != scDeps {
		t.Fatalf("right again should switch to Dependencies; screen=%d", m.screen)
	}
	// right at the end → clamp (stay on Dependencies)
	m = pressKey(m, tea.KeyRight)
	if m.screen != scDeps {
		t.Fatalf("right at end should clamp; screen=%d", m.screen)
	}
	// left → back to Settings
	m = pressKey(m, tea.KeyLeft)
	if m.screen != scSettings {
		t.Fatalf("left should go back to Settings; screen=%d", m.screen)
	}
}

func TestBuildGridNoCursorWhileOnStrips(t *testing.T) {
	m := newTestModel()
	// up → All binaries (Compile tab); the grid shows no cursor.
	m = pressKey(m, tea.KeyUp)
	if !m.onAllBin {
		t.Fatal("expected All-binaries focus")
	}
	if gridHasCursor(m) {
		t.Fatal("grid still shows a cursor while on the All-binaries control")
	}
	// up → Compile/Tools strip: still no grid cursor.
	m = pressKey(m, tea.KeyUp)
	if !m.onBuildTabs {
		t.Fatal("expected build sub-tab strip focus")
	}
	if gridHasCursor(m) {
		t.Fatal("grid still shows a cursor while on the build strip")
	}
	// up → header strip.
	m = pressKey(m, tea.KeyUp)
	if !m.onTabs {
		t.Fatal("expected header focus")
	}
	// three downs → back into the grid; the cursor returns.
	m = pressKey(m, tea.KeyDown) // → build strip
	m = pressKey(m, tea.KeyDown) // → All binaries
	m = pressKey(m, tea.KeyDown) // → grid
	if m.onTabs || m.onBuildTabs || m.onAllBin {
		t.Fatal("three downs should land back in the grid")
	}
	if !gridHasCursor(m) {
		t.Fatal("grid should show a cursor after dropping back in")
	}
}

// gridHasCursor reports whether any grid row (below the All-binaries control)
// renders the ▸ focus marker.
func gridHasCursor(m model) bool {
	out := m.viewSelect()
	lines := splitLines(out)
	// drop the header + All-binaries area; count ▸ only in the bands.
	n := 0
	for _, ln := range lines {
		if countRune(ln, '▷') > 0 {
			n++
		}
	}
	// The All-binaries control also uses ▸ when focused; subtract that case.
	if m.onAllBin {
		n--
	}
	return n > 0
}

func splitLines(s string) []string {
	var out, cur = []string{}, ""
	for _, r := range s {
		if r == '\n' {
			out = append(out, cur)
			cur = ""
			continue
		}
		cur += string(r)
	}
	return append(out, cur)
}

func targetIndex(m model, key string) int {
	for i, t := range m.targets {
		if t.Key == key {
			return i
		}
	}
	return -1
}

func TestBuildScreenSelectionGatingAndLock(t *testing.T) {
	m := newTestModel()
	li := targetIndex(m, "linux-x86_64")
	la := targetIndex(m, "linux") // the "all" aggregate cell
	if li < 0 || la < 0 {
		t.Fatal("expected linux targets in the menu")
	}
	m.selected[li] = true
	m.run = []*item{{t: m.targets[li], status: stBuilding}}
	m.running = 0
	m.screen = scDash

	// Only the selected per-arch cell maps to a run item; the unselected
	// aggregate cell stays opaque even though it shares the arch.
	if len(m.cellRunItems(li)) == 0 {
		t.Error("selected linux-x86_64 cell should map to a run item")
	}
	if len(m.cellRunItems(la)) != 0 {
		t.Error("unselected 'linux all' cell must stay opaque (no run items)")
	}

	// While building the top sections are locked: 'b' must not leave.
	if !m.buildActive() {
		t.Fatal("build should be active")
	}
	if got := press(m, "b"); got.screen != scDash {
		t.Errorf("b must be ignored while building; screen=%d", got.screen)
	}

	// Enter on the focused (selected, in-run) cell opens its log.
	m.focusFirstRunCell()
	if got := pressKey(m, tea.KeyEnter); got.screen != scLog {
		t.Errorf("enter on a running build should open the log; screen=%d", got.screen)
	}

	// Once finished, the sections unlock and 'b' returns to the selector.
	m.run[0].status = stDone
	m.running = -1
	if m.buildActive() {
		t.Fatal("build should be finished")
	}
	if got := press(m, "b"); got.screen != scSelect {
		t.Errorf("b should return to the selector once done; screen=%d", got.screen)
	}
}

func countRune(s string, r rune) int {
	n := 0
	for _, c := range s {
		if c == r {
			n++
		}
	}
	return n
}
