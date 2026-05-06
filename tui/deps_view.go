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

func (m model) keyDeps(k string) (tea.Model, tea.Cmd) {
	if m.onTabs {
		return m.keyHeaderTabs(k)
	}
	lines := m.depLines()
	page := m.depViewHeight()
	maxScroll := maxInt(0, len(lines)-page)
	switch k {
	case "esc", "q":
		m.screen = scSelect
	case "up", "k":
		if m.depScroll == 0 {
			return m.enterHeaderTabs(), nil // at the top → up into the header strip
		}
		m.depScroll--
	case "down", "j":
		if m.depScroll < maxScroll {
			m.depScroll++
		}
	case "pgup":
		m.depScroll = maxInt(0, m.depScroll-page)
	case "pgdown", " ":
		m.depScroll = clampInt(m.depScroll+page, 0, maxScroll)
	case "home", "g":
		m.depScroll = 0
	case "end", "G":
		m.depScroll = maxScroll
	}
	return m, nil
}

func (m model) depViewHeight() int {
	h := m.height - 8 // header(2) + intro(2) + rule + footer + margins
	if h < 4 {
		h = 4
	}
	return h
}

// depVersion resolves the version to display: the live pin from _versions.sh
// when available, else the catalog fallback.
func (m model) depVersion(d Dep) string {
	if d.EnvVar == "" {
		return d.Version // per-platform
	}
	if v, ok := m.depVers[d.EnvVar]; ok && v != "" {
		return v
	}
	return d.Version
}

// depLines renders the full (unwindowed) dependency listing as styled lines.
func (m model) depLines() []string {
	var lines []string
	nameW, verW := 12, 12
	for _, d := range dependencyCatalog() {
		if l := len(d.Name); l > nameW {
			nameW = l
		}
	}
	lastCat := ""
	purposeW := m.width - nameW - verW - 10 // -2 for the scrollbar gutter (bar + padding)
	if purposeW < 12 {
		purposeW = 12
	}
	for _, d := range dependencyCatalog() {
		if d.Category != lastCat {
			if lastCat != "" {
				lines = append(lines, "")
			}
			lines = append(lines, hdrStyle.Render(d.Category))
			lastCat = d.Category
		}
		ver := m.depVersion(d)
		verCell := lipgloss.NewStyle().Foreground(cAccent).Render(padTrunc(ver, verW))
		name := textStyle.Render(padTrunc(d.Name, nameW))
		lic := faintStyle.Render(padTrunc(d.License, 14))
		purpose := dimStyle.Render(truncate(d.Purpose, purposeW))
		lines = append(lines, fmt.Sprintf("  %s  %s  %s  %s", name, verCell, lic, purpose))
	}
	return lines
}

func (m model) viewDeps() string {
	var b strings.Builder
	hfocus := -1
	if m.onTabs {
		hfocus = m.tabCur
	}
	writeLine(&b, renderHeader(2, hfocus, m.width, false))
	src := "built-in defaults"
	if len(m.depVers) > 0 {
		src = "live from scripts/shared/_versions.sh"
	}
	writeLine(&b, dimStyle.Render("Pinned build dependencies — "+src))
	b.WriteByte('\n')

	lines := m.depLines()
	h := m.depViewHeight()
	start := clampInt(m.depScroll, 0, maxInt(0, len(lines)-h))
	writeLine(&b, scrollView(lines, h, start))

	pos := dimStyle.Render(fmt.Sprintf("%d dependencies", len(dependencyCatalog())))
	var help string
	if m.onTabs {
		help = helpBar(
			[2]string{"←→", "switch section"},
			[2]string{"↓/⏎", "list"},
			[2]string{"esc", "back"},
		)
	} else {
		help = helpBar(
			[2]string{"↑↓", "scroll"},
			[2]string{"↑", "sections"},
			[2]string{"b/s", "build/settings"},
			[2]string{"esc", "back"},
		)
	}
	return m.anchorBottom(b.String(), hrule(m.width)+"\n"+pos+"    "+help)
}
