// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// The Docker tab (third build sub-tab, after Compile / Tools) manages the
// multi-stage build images: it shows each one's on-disk status + size, builds a
// missing one on demand, and deletes them individually or all at once — so you
// only keep the toolchains you actually use. Building reuses the normal build
// dashboard (the image build is a real, logged step); deleting runs in the
// background and refreshes the status when done.

// dockerActionDoneMsg signals a finished background delete so the model can
// clear the busy flag and re-read the image status.
type dockerActionDoneMsg struct{}

// dockerStateMsg carries the result of a background image-status query.
type dockerStateMsg struct {
	up    bool
	state map[string]dockerImageStatus
}

// startDockerRefresh re-reads the daemon state + each image's presence/size in
// the BACKGROUND (docker info + docker images are subprocesses; running them in
// the key handler would stall the UI — the "microlag" on entering the tab), then
// posts a dockerStateMsg. The cursor/list render immediately from cached state;
// sizes fill in when the query returns. Called on entering the tab and after an
// action.
func (m *model) startDockerRefresh() {
	m.dockerChecking = true
	sub := m.sub
	go func() {
		up := dockerDaemonRunning()
		sub <- dockerStateMsg{up: up, state: queryDockerImages(up)}
	}()
}

// dockerRowKind identifies a navigable row in the Docker tab.
type dockerRowKind int

const (
	drToggle    dockerRowKind = iota // "build Android in Docker" toggle (macOS only)
	drImage                          // one build image
	drDeleteAll                      // the "Delete all images" button
)

// dockerRow is one navigable row of the Docker tab.
type dockerRow struct {
	kind  dockerRowKind
	image dockerImage // valid when kind == drImage
}

// dockerRowList is the ordered, navigable rows. The Android build-mode toggle is
// first and only on macOS (where Android can build natively); off macOS Android
// always uses Docker, so the toggle would be a no-op and is hidden.
func dockerRowList() []dockerRow {
	var rows []dockerRow
	if hostOS == "darwin" {
		rows = append(rows, dockerRow{kind: drToggle})
	}
	for _, im := range dockerImages() {
		rows = append(rows, dockerRow{kind: drImage, image: im})
	}
	return append(rows, dockerRow{kind: drDeleteAll})
}

// startDockerDelete removes the given stages in the background, then posts a
// dockerActionDoneMsg so Update refreshes the status.
func (m *model) startDockerDelete(stages []string, busy string) {
	if len(stages) == 0 || m.dockerBusy != "" {
		return
	}
	m.dockerBusy = busy
	sub := m.sub
	go func() {
		for _, s := range stages {
			_ = deleteDockerImage(s)
		}
		sub <- dockerActionDoneMsg{}
	}()
}

// presentStages returns the stages whose image currently exists on disk.
func (m model) presentStages() []string {
	var out []string
	for _, im := range dockerImages() {
		if m.dockerState[im.stage].present {
			out = append(out, im.stage)
		}
	}
	return out
}

func (m model) keyDocker(k string) (tea.Model, tea.Cmd) {
	rows := dockerRowList()
	last := len(rows) - 1
	if m.dockerCursor > last {
		m.dockerCursor = last
	}
	switch k {
	case "q":
		m.killAll()
		return m, tea.Quit
	case "up", "k":
		if m.dockerCursor > 0 {
			m.dockerCursor--
		} else {
			m.onBuildTabs = true // top → back to the Compile/Tools/Docker strip
		}
	case "down", "j":
		if m.dockerCursor < last {
			m.dockerCursor++
		}
	case "esc", "b":
		m.onBuildTabs = true
	case "enter", " ":
		switch rows[m.dockerCursor].kind {
		case drToggle:
			m.settings.ForceAndroidDocker = !m.settings.ForceAndroidDocker
			if m.ctx != nil {
				_ = m.settings.save(m.ctx.scriptsRoot)
			}
		case drDeleteAll:
			m.startDockerDelete(m.presentStages(), "all") // guarded if busy/empty
		case drImage:
			if m.dockerBusy != "" {
				return m, nil
			}
			stage := rows[m.dockerCursor].image.stage
			if m.dockerState[stage].present {
				m.startDockerDelete([]string{stage}, stage)
			} else {
				m.startRun([]string{"docker-image-" + stage}) // build via the dashboard (logged)
			}
		}
	}
	return m, nil
}

// renderDockerTab renders the image-management list (called from viewSelect when
// the Docker sub-tab is active).
func (m model) renderDockerTab() string {
	var out string
	daemon := m.dockerDaemonUp // cached on tab-enter; never exec docker in render
	// Only show the cursor when it's actually IN the list — not while the focus
	// is still up on the sub-tab strip (or header), matching Compile/Tools where
	// nothing in the content is highlighted until you descend.
	inList := !m.onBuildTabs && !m.onTabs

	// A status line only when there's something to say — otherwise the image
	// list starts right after the sub-tab strip, exactly like Compile/Tools (no
	// extra blank row that would read as a phantom step when entering the tab).
	//
	// The daemon probe is async (docker info is a subprocess), so on first entry
	// we show a "checking…" spinner until the query returns — never the orange
	// "not running" line, which used to flash and then vanish when the real
	// state arrived. Once checked, we keep the last known state and refresh
	// silently in the background.
	switch {
	case m.dockerChecking && !m.dockerChecked:
		out += lipgloss.NewStyle().Foreground(cRun).Render(spinnerFrames[m.spinPos]+" checking Docker…") + "\n\n"
	case !daemon:
		out += warnStyle.Render("⚠ Docker daemon not running") + dimStyle.Render(" — start it to manage images") + "\n\n"
	case m.dockerBusy == "all":
		out += lipgloss.NewStyle().Foreground(cRun).Render(spinnerFrames[m.spinPos]+" deleting all images…") + "\n\n"
	}

	for i, row := range dockerRowList() {
		focused := inList && i == m.dockerCursor
		switch row.kind {

		case drToggle: // macOS only: native ⇄ Docker for Android
			box := boxOff
			if m.settings.ForceAndroidDocker {
				box = boxOn
			}
			label := box + " Force Android build through Docker  (default: native macOS NDK, faster)"
			switch {
			case focused:
				out += hiStyle.Render(padTrunc("▷ "+label, maxInt(1, m.width-2))) + "\n\n"
			case m.settings.ForceAndroidDocker:
				out += "  " + okStyle.Render(label) + "\n\n"
			default:
				out += "  " + dimStyle.Render(label) + "\n\n"
			}

		case drImage:
			im := row.image
			st := m.dockerState[im.stage]
			glyph, gstyle, sizeTxt := "◌", faintStyle, "—"
			if st.present {
				glyph, gstyle, sizeTxt = "✓", okStyle, st.size
			}
			if m.dockerBusy == im.stage {
				glyph, gstyle, sizeTxt = spinnerFrames[m.spinPos], lipgloss.NewStyle().Foreground(cRun), "deleting…"
			}
			label := padTrunc(im.label, 9)
			sizeCell := padTrunc(sizeTxt, 10)
			desc := truncate(im.desc, maxInt(8, m.width-28))
			if focused {
				// Same selection look as everywhere else: ▷ marker + full-width bar.
				plain := "▷ " + glyph + " " + label + "  " + sizeCell + "  " + desc
				out += hiStyle.Render(padTrunc(plain, maxInt(1, m.width-2))) + "\n"
			} else {
				out += "  " + gstyle.Render(glyph) + " " + textStyle.Render(label) + "  " +
					gstyle.Render(sizeCell) + "  " + dimStyle.Render(desc) + "\n"
			}

		case drDeleteAll: // red button (boxed like Abort); faint when nothing to delete
			present := len(m.presentStages())
			allLabel := fmt.Sprintf("Delete all images  (%d present)", present)
			out += "\n"
			switch {
			case present == 0:
				out += buildBtnDisabledStyle.Render(allLabel) + "\n"
			case focused:
				out += abortBtnFocusStyle.Render(allLabel) + "\n"
			default:
				out += abortBtnStyle.Render(allLabel) + "\n"
			}
		}
	}
	return out
}
