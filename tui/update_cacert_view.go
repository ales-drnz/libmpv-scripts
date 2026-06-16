// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// The Update-CA-bundle screen runs scripts/update_cacert.sh, streaming its
// output live (so the download is visibly happening), then renders a card with
// the refreshed bundle's provenance — Mozilla date, root count, size, path —
// plus a reminder that the bytes only ship after a binary rebuild.

// ucLineMsg is one line streamed from the refresh script.
type ucLineMsg struct{ line string }

// ucDoneMsg is sent once, after the last line, when the script exits.
type ucDoneMsg struct{ err error }

// startUpdateCacert switches to the screen and runs the refresh in a goroutine,
// streaming ucLineMsg per line and a final ucDoneMsg (picked up by the model's
// standing listen() on m.sub).
func (m *model) startUpdateCacert() {
	m.screen = scUpdateCacert
	m.ucRunning = true
	m.ucLog = nil
	m.ucErr = nil
	m.ucResult = cacertResult{}
	m.ucScroll = 0
	sub := m.sub
	ctx := m.ctx
	go func() {
		err := runUpdateCacert(ctx, func(l string) { sub <- ucLineMsg{line: l} })
		sub <- ucDoneMsg{err: err}
	}()
}

func (m model) ucViewHeight() int {
	h := m.height - 14 // title + result card (~9 rows) + 2 rules + help + margins
	if h < 3 {
		h = 3
	}
	return h
}

func (m model) keyUpdateCacert(k string) (tea.Model, tea.Cmd) {
	page := m.ucViewHeight()
	maxScroll := maxInt(0, len(m.ucLog)-page)
	switch k {
	case "q":
		return m, tea.Quit
	case "esc", "b":
		if !m.ucRunning {
			m.screen = scSelect
		}
	case "up", "k":
		if m.ucScroll > 0 {
			m.ucScroll--
		}
	case "down", "j":
		if m.ucScroll < maxScroll {
			m.ucScroll++
		}
	case "pgup":
		m.ucScroll = maxInt(0, m.ucScroll-page)
	case "pgdown", " ":
		m.ucScroll = clampInt(m.ucScroll+page, 0, maxScroll)
	case "home", "g":
		m.ucScroll = 0
	case "end", "G":
		m.ucScroll = maxScroll
	}
	return m, nil
}

func (m model) ucHelp() string {
	return helpBar(
		[2]string{"↑↓", "scroll"},
		[2]string{"esc", "back"},
		[2]string{"q", "quit"},
	)
}

// ucCard renders the bordered provenance panel shown once the refresh succeeds.
func (m model) ucCard() string {
	r := m.ucResult
	val := func(s string) string {
		if s == "" {
			return "—"
		}
		return s
	}
	certs := "—"
	if r.count != "" {
		certs = r.count + " roots"
	}
	row := func(label, v string) string {
		return faintStyle.Render(padTrunc(label, 14)) + textStyle.Render(v)
	}
	// The dest is an absolute path — bound it to the viewport so a long
	// checkout path can't widen the card past the terminal and wrap (which
	// shatters the rounded border). It's also shown in full in the log above.
	destW := maxInt(12, m.width-24)
	inner := strings.Join([]string{
		okStyle.Render("✓ ") + textStyle.Render("Mozilla CA bundle updated"),
		"",
		row("Source", "curl.se → Mozilla"),
		row("Published", val(r.date)),
		row("Certificates", certs),
		row("Size", val(r.size)),
		row("File", truncate(val(r.dest), destW)),
	}, "\n")
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(cBorder).
		Padding(0, 2).
		Render(inner)
}

// ucLogView renders the (windowed) raw script output.
func (m model) ucLogView() string {
	if len(m.ucLog) == 0 {
		return faintStyle.Render("  (no output yet)")
	}
	lines := make([]string, len(m.ucLog))
	for i, l := range m.ucLog {
		lines[i] = faintStyle.Render("  " + truncate(l, maxInt(1, m.width-2)))
	}
	h := m.ucViewHeight()
	start := clampInt(m.ucScroll, 0, maxInt(0, len(lines)-h))
	return scrollView(lines, h, start)
}

func (m model) viewUpdateCacert() string {
	var b strings.Builder
	writeLine(&b, titleStyle.Render("◆ libmpv"), dimStyle.Render("  Update CA bundle"))

	if m.ucRunning {
		writeLine(&b, spinnerFrames[m.spinPos], " ",
			dimStyle.Render("downloading the latest Mozilla CA bundle from curl.se…"))
		writeLine(&b, hrule(m.width))
		writeLine(&b, m.ucLogView())
		return m.anchorBottom(b.String(), hrule(m.width)+"\n"+m.ucHelp())
	}

	if m.ucErr != nil {
		writeLine(&b, failStyle.Render("✗ update failed"))
		writeLine(&b, warnStyle.Render("  "+m.ucErr.Error()))
	} else {
		writeLine(&b, m.ucCard())
		writeLine(&b, "")
		writeLine(&b, dimStyle.Render(
			"  Rebuild the binaries to embed the new roots — the embed_cacert patch compiles this file in."))
	}
	writeLine(&b, hrule(m.width))
	writeLine(&b, m.ucLogView())
	return m.anchorBottom(b.String(), hrule(m.width)+"\n"+m.ucHelp())
}
