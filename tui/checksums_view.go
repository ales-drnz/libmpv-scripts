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

// The Checksums screen runs the install-and-checksum step in-process and shows,
// per release binary, where it was installed plus a GitHub-style before/after
// diff of every checksum line it rewrote (podspec, Package.swift, CMakeLists,
// build.gradle.kts). Driven by checksumsDoneMsg (see runChecksumsCollect).

// checksumsDoneMsg carries the result of the background checksums run.
type checksumsDoneMsg struct {
	entries []csEntry
	err     error
}

// startChecksums switches to the Checksums screen and runs the step in a
// goroutine, posting a checksumsDoneMsg when finished (picked up by the model's
// standing listen() on m.sub, same as the build runner).
func (m *model) startChecksums() {
	m.startCsScreen("checksums — install into mpv_audio_kit", "installed", func() ([]csEntry, error) {
		return runChecksumsCollect(m.ctx)
	})
}

// startLibAction runs one of the Libs source-switch actions (local / remote /
// clean) on the same result screen as Checksums — they all produce a per-file
// list of edits, so the diff view is shared.
func (m *model) startLibAction(key string) {
	subtitle := map[string]string{
		"lib-local":  "libs — lock mpv_audio_kit to the local libmpv",
		"lib-remote": "libs — download libmpv from GitHub when absent",
		"lib-clean":  "libs — remove bundled libmpv from mpv_audio_kit",
	}[key]
	verb := map[string]string{"lib-local": "updated", "lib-remote": "updated", "lib-clean": "removed"}[key]
	m.startCsScreen(subtitle, verb, func() ([]csEntry, error) {
		return runLibActionCollect(m.ctx, key)
	})
}

// startCsScreen switches to the shared result screen and runs work in a
// goroutine, posting a checksumsDoneMsg when finished (picked up by the model's
// standing listen() on m.sub, same as the build runner).
func (m *model) startCsScreen(title, verb string, work func() ([]csEntry, error)) {
	m.screen = scChecksums
	m.csRunning = true
	m.csEntries = nil
	m.csErr = nil
	m.csScroll = 0
	m.csTitle = title
	m.csVerb = verb
	sub := m.sub
	go func() {
		entries, err := work()
		sub <- checksumsDoneMsg{entries: entries, err: err}
	}()
}

func (m model) csViewHeight() int {
	h := m.height - 7 // title + summary + 2 rules + help + margins
	if h < 4 {
		h = 4
	}
	return h
}

func (m model) keyChecksums(k string) (tea.Model, tea.Cmd) {
	page := m.csViewHeight()
	maxScroll := maxInt(0, len(m.csLines())-page)
	switch k {
	case "q":
		return m, tea.Quit
	case "esc", "b":
		if !m.csRunning {
			m.screen = scSelect
			m.refreshLibMode() // a Libs action may have changed the source
		}
	case "up", "k":
		if m.csScroll > 0 {
			m.csScroll--
		}
	case "down", "j":
		if m.csScroll < maxScroll {
			m.csScroll++
		}
	case "pgup":
		m.csScroll = maxInt(0, m.csScroll-page)
	case "pgdown", " ":
		m.csScroll = clampInt(m.csScroll+page, 0, maxScroll)
	case "home", "g":
		m.csScroll = 0
	case "end", "G":
		m.csScroll = maxScroll
	}
	return m, nil
}

// shortHash abbreviates a SHA-256 for the entry header.
func shortHash(h string) string {
	if len(h) <= 12 {
		return h
	}
	return h[:12] + "…"
}

// csLines renders the full (unwindowed) result as styled lines.
func (m model) csLines() []string {
	var out []string
	accent := lipgloss.NewStyle().Foreground(cAccent)
	for _, e := range m.csEntries {
		switch e.Status {
		case "skipped":
			msg := e.Message
			if msg == "" {
				msg = "skipped (not built)"
			}
			out = append(out, faintStyle.Render("· "+padTrunc(e.Label, 20)+"  "+msg))
			continue
		case "error":
			out = append(out, failStyle.Render("✗ "+padTrunc(e.Label, 20))+"  "+dimStyle.Render(e.Message))
			continue
		}
		// "ok" header: hash + destination when present (Checksums); the Libs
		// actions carry no hash, so just the touched/removed path.
		head := okStyle.Render("✓ ") + textStyle.Render(padTrunc(e.Label, 20))
		if e.Hash != "" {
			head += "  " + accent.Render(shortHash(e.Hash))
		}
		if e.Dest != "" {
			head += dimStyle.Render("  → " + e.Dest)
		}
		out = append(out, head)
		lastFile := ""
		for _, ed := range e.Edits {
			if ed.File != "" && ed.File != lastFile {
				out = append(out, dimStyle.Render("    "+ed.File))
				lastFile = ed.File
			}
			out = append(out, failStyle.Render("    - "+truncate(ed.Old, maxInt(1, m.width-6))))
			out = append(out, okStyle.Render("    + "+truncate(ed.New, maxInt(1, m.width-6))))
		}
		if len(e.Edits) == 0 {
			note := e.Message
			if note == "" {
				note = "installed; checksums already current"
			}
			out = append(out, dimStyle.Render("    ("+note+")"))
		}
		out = append(out, "")
	}
	return out
}

func (m model) csHelp() string {
	return helpBar(
		[2]string{"↑↓", "scroll"},
		[2]string{"esc", "back"},
		[2]string{"q", "quit"},
	)
}

func (m model) viewChecksums() string {
	var b strings.Builder
	title := m.csTitle
	if title == "" {
		title = "checksums — install into mpv_audio_kit"
	}
	writeLine(&b, titleStyle.Render("◆ libmpv"), dimStyle.Render("  "+title))

	if m.csRunning {
		writeLine(&b, spinnerFrames[m.spinPos], " ", dimStyle.Render("updating mpv_audio_kit…"))
		return m.anchorBottom(b.String(), hrule(m.width)+"\n"+m.csHelp())
	}

	// summary line
	var ok, skip, errc int
	for _, e := range m.csEntries {
		switch e.Status {
		case "ok":
			ok++
		case "skipped":
			skip++
		case "error":
			errc++
		}
	}
	verb := m.csVerb
	if verb == "" {
		verb = "installed"
	}
	summary := okStyle.Render(fmt.Sprintf("✓ %d %s", ok, verb)) +
		dimStyle.Render("    ") + faintStyle.Render(fmt.Sprintf("· %d skipped", skip))
	if errc > 0 {
		summary += dimStyle.Render("    ") + failStyle.Render(fmt.Sprintf("✗ %d error", errc))
	}
	writeLine(&b, summary)
	if m.csErr != nil {
		writeLine(&b, warnStyle.Render("⚠ "+m.csErr.Error()))
	}
	writeLine(&b, hrule(m.width))

	// windowed diff list
	lines := m.csLines()
	h := m.csViewHeight()
	start := clampInt(m.csScroll, 0, maxInt(0, len(lines)-h))
	writeLine(&b, scrollView(lines, h, start))

	return m.anchorBottom(b.String(), hrule(m.width)+"\n"+m.csHelp())
}
