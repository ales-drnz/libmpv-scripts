// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// setRow is one line in the settings list: either a non-selectable category
// header (header != "") or a toggleable entry. Entries whose name starts with
// "@" are behavior actions rather than ffmpeg catalog items.
type setRow struct {
	header    string
	name      string
	title     string
	desc      string
	appleOnly bool
	required  bool
	spacer    bool // blank visual gap (non-selectable)
}

func (r setRow) isHeader() bool { return r.header != "" }

// totalSettingsTabs counts the Settings sub-tabs visible for the active flavor.
func (m model) totalSettingsTabs() int { return len(m.visibleSections()) }

// settingsTabLabels are the sub-tab labels: one per section in the active flavor.
func (m model) settingsTabLabels() []string {
	secs := m.visibleSections()
	out := make([]string, 0, len(secs))
	for _, s := range secs {
		out = append(out, s.Label)
	}
	return out
}

// rebuildSetRows flattens the active section into header + entry rows.
func (m *model) rebuildSetRows() {
	m.setRows = nil
	secs := m.visibleSections()
	if m.setTab < 0 || m.setTab >= len(secs) {
		return
	}
	sec := secs[m.setTab]
	// Master "All" toggle for the whole tab (on by default). Turning it off
	// clears the tab so you can pick items one at a time.
	m.setRows = append(m.setRows, setRow{
		name: "@all", title: "All",
		desc: "Enable or disable every item in this tab",
	})
	// Group by category in first-seen order (robust to interleaving).
	var order []string
	groups := map[string][]toggle{}
	for _, it := range sec.items() {
		if _, ok := groups[it.Category]; !ok {
			order = append(order, it.Category)
		}
		groups[it.Category] = append(groups[it.Category], it)
	}
	for _, cat := range order {
		m.setRows = append(m.setRows, setRow{spacer: true}) // gap before each category
		m.setRows = append(m.setRows, setRow{header: cat})
		for _, it := range groups[cat] {
			m.setRows = append(m.setRows, setRow{
				name: nsKey(sec.Key, it.Name), title: it.Title, desc: it.Desc,
				appleOnly: it.AppleOnly, required: it.Required,
			})
		}
	}
}

// rowSelectable reports whether the cursor may land on row i. Headers and
// required (locked) entries are skipped — required items are shown opaque and
// are not interactive.
func (m model) rowSelectable(i int) bool {
	if i < 0 || i >= len(m.setRows) {
		return false
	}
	r := m.setRows[i]
	return !r.isHeader() && !r.spacer && !r.required
}

func (m model) firstSelectableRow() int {
	for i := range m.setRows {
		if m.rowSelectable(i) {
			return i
		}
	}
	return 0
}

// moveSetCur advances the cursor by dir (±1), skipping non-selectable rows.
func (m *model) moveSetCur(dir int) {
	i := m.setCur
	for {
		i += dir
		if i < 0 || i >= len(m.setRows) {
			return // out of range → leave cursor put
		}
		if m.rowSelectable(i) {
			m.setCur = i
			return
		}
	}
}

// countTab returns (on, total) toggleable items for a section tab. Returns
// (0,0) for the Behavior tab.
func (m model) countTab(tab int) (on, total int) {
	secs := m.visibleSections()
	if tab < 0 || tab >= len(secs) {
		return 0, 0
	}
	sec := secs[tab]
	for _, it := range sec.items() {
		total++
		if m.setEnabled[nsKey(sec.Key, it.Name)] {
			on++
		}
	}
	return
}

func (m *model) toggleAllInTab(on bool) {
	secs := m.visibleSections()
	if m.setTab >= len(secs) {
		return
	}
	sec := secs[m.setTab]
	for _, it := range sec.items() {
		key := nsKey(sec.Key, it.Name)
		if it.Required {
			m.setEnabled[key] = true
			continue
		}
		m.setEnabled[key] = on
	}
}

func (m *model) resetSelection() {
	m.setEnabled = defaultSettings().enabledSet()
	m.setNotice = "all sections reset to defaults (confirm on exit)"
}

// isDirty reports whether the staged Settings edits differ from the persisted
// state. It is computed (not a sticky flag) so toggling something off and back
// to its original value clears the "unsaved" indicator. Flavor is NOT part of
// this — it lives on the Select page and persists immediately.
func (m model) isDirty() bool {
	saved := m.settings.enabledSet()
	for k, v := range m.setEnabled {
		if saved[k] != v {
			return true
		}
	}
	return false
}

// persistSettings folds the staged edit state into the persisted settings and
// writes them (JSON + the ffmpeg override script). No-op without a build ctx.
// Flavor and SkipOnFailure are owned by the build page, so settingsFromEnabled
// preserves them.
func (m *model) persistSettings() {
	m.settings = m.settings.settingsFromEnabled(m.setEnabled)
	if m.ctx != nil {
		_ = m.settings.save(m.ctx.scriptsRoot)
	}
}

// cycleTab switches the active sub-tab by dir, rebuilding the row list.
func (m *model) cycleTab(dir int) {
	n := m.totalSettingsTabs()
	m.setTab = (m.setTab + dir + n) % n
	m.rebuildSetRows()
	m.setCur = m.firstSelectableRow()
	m.setScroll = 0
	m.setNotice = ""
}

// keySetTabs handles navigation while the cursor is in the sub-tab strip
// (Decoders/Filters/Behavior), one level below the header.
func (m model) keySetTabs(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "esc", "q":
		return m.requestLeaveSettings(scSelect)
	case "left", "h":
		if m.setTab > 0 {
			m.cycleTab(-1)
		}
	case "right", "l", "tab":
		if m.setTab < m.totalSettingsTabs()-1 {
			m.cycleTab(1)
		}
	case "up", "k":
		return m.enterHeaderTabs(), nil // up → top header strip
	case "down", "j", "enter", " ":
		m.onSetTabs = false // down → into the list
	}
	return m, nil
}

func (m model) keySettings(k string) (tea.Model, tea.Cmd) {
	if m.onTabs {
		return m.keyHeaderTabs(k)
	}
	if m.onSetTabs {
		return m.keySetTabs(k)
	}
	switch k {
	case "esc", "q":
		return m.requestLeaveSettings(scSelect)
	case "tab", "right", "l":
		m.cycleTab(1)
	case "shift+tab", "left", "h":
		m.cycleTab(-1)
	case "up", "k":
		if m.setCur <= m.firstSelectableRow() {
			m.onSetTabs = true // up from the first row → into the sub-tab strip
		} else {
			m.moveSetCur(-1)
		}
	case "down", "j":
		m.moveSetCur(1)
	case "pgup":
		for i := 0; i < 8; i++ {
			m.moveSetCur(-1)
		}
	case "pgdown":
		for i := 0; i < 8; i++ {
			m.moveSetCur(1)
		}
	case "home", "g":
		m.setCur = m.firstSelectableRow()
	case "end", "G":
		for i := 0; i < len(m.setRows); i++ {
			m.moveSetCur(1)
		}
	case "a":
		if m.setTab < m.totalSettingsTabs() {
			m.toggleAllInTab(true)
			m.setNotice = "all enabled"
		}
	case "n":
		if m.setTab < m.totalSettingsTabs() {
			m.toggleAllInTab(false)
			m.setNotice = "all optional disabled"
		}
	case "r":
		m.resetSelection()
	case " ", "enter":
		m.toggleCurrent()
	}
	m = m.clampSetScroll(m.settingsListHeight())
	return m, nil
}

// settingsListHeight is the number of list rows visible at once (must match
// the window math in viewSettings).
func (m model) settingsListHeight() int {
	h := m.height - 10 // header(2) + subtabs(2) + footer desc + rule + help + margins
	if h < 4 {
		h = 4
	}
	return h
}

func (m *model) toggleCurrent() {
	if m.setCur < 0 || m.setCur >= len(m.setRows) {
		return
	}
	r := m.setRows[m.setCur]
	if r.isHeader() {
		return
	}
	switch r.name {
	case "@all":
		on, total := m.countTab(m.setTab)
		m.toggleAllInTab(on != total) // all on → turn off; otherwise → turn all on
		m.setNotice = ""
	default:
		if r.required {
			// Required rows aren't selectable, so this is unreachable in
			// practice; keep the guard for safety.
			return
		}
		m.setEnabled[r.name] = !m.setEnabled[r.name]
		m.setNotice = ""
	}
}

// ── render ───────────────────────────────────────────────────────────────────

func (m model) viewSettings() string {
	var b strings.Builder
	hfocus := -1
	if m.onTabs {
		hfocus = m.tabCur
	}
	writeLine(&b, renderHeader(1, hfocus, m.width, false))

	// sub-tab strip — same filled-accent styling as the header tabs, and
	// focusable: the cursor moves up here from the list.
	labels := m.settingsTabLabels()
	cells := make([]string, len(labels))
	for i, name := range labels {
		on, total := m.countTab(i)
		label := fmt.Sprintf("%s %d/%d", name, on, total)
		switch {
		case m.onSetTabs && i == m.setTab:
			cells[i] = tabFocusStyle.Render(label)
		case i == m.setTab:
			cells[i] = subTabActiveStyle.Render(label) // active section → red
		default:
			cells[i] = tabInactiveStyle.Render(label)
		}
	}
	dirty := ""
	if m.isDirty() {
		dirty = "  " + warnStyle.Render("● unsaved changes")
	}
	writeLine(&b, lipgloss.JoinHorizontal(lipgloss.Left, cells...), dirty)
	b.WriteByte('\n')

	// list window
	listH := m.settingsListHeight()
	descW := m.width - 36 // -2 for the scrollbar gutter (bar + padding)
	if descW < 10 {
		descW = 10
	}
	// Single cursor: the list shows a focused row only when neither the header
	// strip nor the sub-tab strip holds the cursor.
	listFocused := !m.onTabs && !m.onSetTabs
	lines := make([]string, len(m.setRows))
	for i, r := range m.setRows {
		switch {
		case r.spacer:
			lines[i] = ""
		case r.isHeader():
			lines[i] = hdrStyle.Render("  " + r.header)
		default:
			lines[i] = m.renderSetItem(r, listFocused && i == m.setCur, descW)
		}
	}
	start := clampInt(m.setScroll, 0, maxInt(0, len(lines)-listH))
	writeLine(&b, scrollView(lines, listH, start))

	// footer: focused desc + notice + help
	var foot string
	if m.setNotice != "" {
		foot = warnStyle.Render("• " + m.setNotice)
	} else if m.setCur < len(m.setRows) && !m.setRows[m.setCur].isHeader() {
		r := m.setRows[m.setCur]
		foot = dimStyle.Render(r.desc)
	}
	b.WriteByte('\n')
	writeLine(&b, truncate(foot, m.width))

	var help string
	if m.onTabs {
		help = helpBar(
			[2]string{"←→", "switch section"},
			[2]string{"↓/⏎", "sub-tabs"},
			[2]string{"esc", "back"},
		)
	} else if m.onSetTabs {
		help = helpBar(
			[2]string{"←→", "pick tab"},
			[2]string{"↑", "sections"},
			[2]string{"↓/⏎", "into list"},
			[2]string{"esc", "exit"},
		)
	} else {
		help = helpBar(
			[2]string{"↑↓", "move"},
			[2]string{"space", "toggle"},
			[2]string{"a/n", "all/none"},
			[2]string{"r", "reset"},
			[2]string{"esc", "exit"},
		)
	}
	return m.anchorBottom(b.String(), hrule(m.width)+"\n"+help)
}

// ── unsaved-changes dialog ───────────────────────────────────────────────────

var confirmButtons = []string{"Save", "Discard", "Keep editing"}

func (m model) keyConfirm(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "left", "h":
		m.confirmCur = (m.confirmCur - 1 + len(confirmButtons)) % len(confirmButtons)
	case "right", "l", "tab":
		m.confirmCur = (m.confirmCur + 1) % len(confirmButtons)
	case "esc":
		m.confirmPending = false // esc = keep editing
	case "enter", " ":
		switch m.confirmCur {
		case 0: // Save
			m.persistSettings()
			m.confirmPending = false
			return m.navTo(m.confirmDest), nil
		case 1: // Discard — drop staged edits, revert to persisted state
			m.setEnabled = m.settings.enabledSet()
			m.confirmPending = false
			return m.navTo(m.confirmDest), nil
		case 2: // Keep editing
			m.confirmPending = false
		}
	}
	return m, nil
}

func (m model) viewConfirm() string {
	title := lipgloss.NewStyle().Bold(true).Foreground(cWarn).Render("Unsaved changes")
	body := textStyle.Render("You changed the build component selection.") + "\n" +
		dimStyle.Render("Saving writes a personal, independent override —\n"+
			"the curated defaults are never modified, and you can\n"+
			"reset to them anytime.")

	btns := make([]string, len(confirmButtons))
	for i, label := range confirmButtons {
		st := lipgloss.NewStyle().Foreground(cDim).Padding(0, 2).
			Border(lipgloss.RoundedBorder()).BorderForeground(cBorder)
		if i == m.confirmCur {
			st = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#1A1B26")).
				Background(cAccent).Padding(0, 2).
				Border(lipgloss.RoundedBorder()).BorderForeground(cAccent)
		}
		btns[i] = st.Render(label)
	}
	row := lipgloss.JoinHorizontal(lipgloss.Center, btns...)

	help := helpBar(
		[2]string{"←→", "choose"},
		[2]string{"⏎", "confirm"},
		[2]string{"esc", "keep editing"},
	)
	content := lipgloss.JoinVertical(lipgloss.Center, title, "", body, "", row, "", help)

	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(cWarn).
		Padding(1, 3).
		Render(content)

	if m.width <= 0 || m.height <= 0 {
		return box
	}
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, box)
}

func (m model) renderSetItem(r setRow, focused bool, descW int) string {
	titleW := 24

	// Required entries are locked: rendered fully opaque (faint) and never
	// focusable, so they read as "always on, not editable".
	if r.required {
		line := "  " + faintStyle.Render(boxOn+" "+padTrunc(r.title, titleW)+" "+
			truncate(r.desc, descW)+"  · locked, always on")
		return line
	}

	on := m.setEnabled[r.name]
	box := boxOff
	boxStyle := dimStyle
	switch {
	case r.name == "@all":
		onN, total := m.countTab(m.setTab)
		switch {
		case total > 0 && onN == total:
			box, boxStyle = boxOn, okStyle
		case onN == 0:
			box, boxStyle = boxOff, dimStyle
		default:
			box, boxStyle = boxPartial, warnStyle // partial selection
		}
	case on:
		box, boxStyle = boxOn, okStyle
	}

	tag := ""
	if r.appleOnly {
		tag += " apple"
	}

	if focused {
		// Show the same columns as a normal row (box · title · description ·
		// tag) but inside the highlight bar, so the selector never hides the
		// description.
		content := "▷ " + box + " " + padTrunc(r.title, titleW) + " " +
			truncate(r.desc, descW) + tag
		return hiStyle.Render(padTrunc(content, maxInt(1, m.width-2)))
	}
	return "  " + boxStyle.Render(box) + " " +
		textStyle.Render(padTrunc(r.title, titleW)) + " " +
		dimStyle.Render(truncate(r.desc, descW)) + faintStyle.Render(tag)
}

// clampSetScroll keeps the cursor row inside the visible window.
func (m model) clampSetScroll(listH int) model {
	if m.setCur < m.setScroll {
		m.setScroll = m.setCur
	}
	if m.setCur >= m.setScroll+listH {
		m.setScroll = m.setCur - listH + 1
	}
	if m.setScroll < 0 {
		m.setScroll = 0
	}
	return m
}
