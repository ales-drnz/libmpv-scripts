// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// When a build starts and the builds/work/ tree still holds cached intermediates
// from previous runs, we offer to wipe it first (a clean build) — modelled on the
// Settings unsaved-changes dialog. The dialog shows the work dir and, in red, the
// per-platform trees that would be deleted with their sizes.

// workEntry is one top-level entry under builds/work/ with its on-disk size.
type workEntry struct {
	name string
	size int64
}

// cleanScanMsg carries the (async) size scan of the work tree.
type cleanScanMsg struct {
	entries []workEntry
	total   int64
}

var cleanButtons = []string{"Clean & build", "Build (keep cache)", "Cancel"}

// workCacheDir is the build scratch tree (builds/work/), all regenerable.
func workCacheDir(ctx *buildCtx) string {
	return filepath.Join(ctx.scriptsRoot, "builds", "work")
}

// isOSGroup reports whether a target Group owns a builds/work/<Group>/ tree.
// (The Group names match the per-OS work subdir names exactly.)
func isOSGroup(g string) bool {
	switch g {
	case "macOS", "iOS", "Linux", "Windows", "Android":
		return true
	}
	return false
}

// maybeCleanOSWork is the "clean work after build" toggle's brain. Called when a
// build finishes: it deletes builds/work/<OS>/ ONLY when every build of that OS
// in the run has succeeded — so arches of one OS that share a cached toolchain /
// dependency tree (e.g. Android's NDK + per-ABI prefixes) aren't wiped while
// later arches of the same OS still need them, and a failed OS keeps its tree
// for retry/inspection.
func (m model) maybeCleanOSWork(done *item) {
	g := done.t.Group
	if m.ctx == nil || !isOSGroup(g) || !osGroupAllDone(m.run, g) {
		return
	}
	dir := filepath.Join(workCacheDir(m.ctx), g)
	go func() { _ = os.RemoveAll(dir) }()
}

// osGroupAllDone reports whether every run item in group g finished
// SUCCESSFULLY — so its shared work tree is safe to remove. False if any item of
// g is still pending (queued/building) or ended non-OK (failed/cancelled/
// skipped), and false if the group has no items in the run at all.
func osGroupAllDone(run []*item, g string) bool {
	any := false
	for _, it := range run {
		if it.t.Group != g {
			continue
		}
		any = true
		if it.status != stDone {
			return false
		}
	}
	return any
}

// hasWorkCache reports whether builds/work/ exists and holds anything.
func hasWorkCache(ctx *buildCtx) bool {
	es, err := os.ReadDir(workCacheDir(ctx))
	return err == nil && len(es) > 0
}

// scanWorkCache measures each top-level entry under dir, largest first.
func scanWorkCache(dir string) ([]workEntry, int64) {
	es, err := os.ReadDir(dir)
	if err != nil {
		return nil, 0
	}
	var out []workEntry
	var total int64
	for _, e := range es {
		sz := dirSize(filepath.Join(dir, e.Name()))
		out = append(out, workEntry{name: e.Name(), size: sz})
		total += sz
	}
	sort.Slice(out, func(i, j int) bool { return out[i].size > out[j].size })
	return out, total
}

func dirSize(root string) int64 {
	var total int64
	_ = filepath.Walk(root, func(_ string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total
}

func humanSize(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}

// promptCleanThenBuild opens the clean-work-area dialog for the given build keys
// and kicks off the async size scan. The dialog resolves into either a clean
// build, an as-is build, or a cancel (keyCleanConfirm).
func (m *model) promptCleanThenBuild(keys []string) {
	m.cleanPending = true
	m.cleanScanning = true
	m.cleanKeys = keys
	m.cleanCur = 0
	m.cleanDir = workCacheDir(m.ctx)
	m.cleanEntries = nil
	m.cleanTotal = 0
	dir, sub := m.cleanDir, m.sub
	go func() {
		entries, total := scanWorkCache(dir)
		sub <- cleanScanMsg{entries: entries, total: total}
	}()
}

func (m model) keyCleanConfirm(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "left", "h":
		m.cleanCur = (m.cleanCur - 1 + len(cleanButtons)) % len(cleanButtons)
	case "right", "l", "tab":
		m.cleanCur = (m.cleanCur + 1) % len(cleanButtons)
	case "esc":
		m.cleanPending = false // esc = cancel, stay on the selector
	case "enter", " ":
		switch m.cleanCur {
		case 0: // Clean & build — wipe the work tree, then build fresh
			_ = os.RemoveAll(m.cleanDir)
			m.cleanPending = false
			m.startRun(m.cleanKeys)
		case 1: // Build, reusing the cache
			m.cleanPending = false
			m.startRun(m.cleanKeys)
		case 2: // Cancel
			m.cleanPending = false
		}
	}
	return m, nil
}

func (m model) viewCleanConfirm() string {
	title := lipgloss.NewStyle().Bold(true).Foreground(cWarn).Render("Clean the work area?")

	// Show the dir relative to the scripts root when possible.
	disp := m.cleanDir
	if m.ctx != nil {
		if rel, err := filepath.Rel(m.ctx.scriptsRoot, m.cleanDir); err == nil {
			disp = rel
		}
	}

	var body string
	body = textStyle.Render("Cached build files from previous runs are still here:") + "\n" +
		lipgloss.NewStyle().Foreground(cAccent).Render(disp+string(os.PathSeparator)) + "\n"
	if m.cleanScanning {
		body += "\n" + dimStyle.Render(spinnerFrames[m.spinPos]+" measuring…")
	} else if len(m.cleanEntries) == 0 {
		body += "\n" + dimStyle.Render("(empty)")
	} else {
		for _, e := range m.cleanEntries {
			body += "\n" + failStyle.Render("− "+padTrunc(e.name, 14)) + dimStyle.Render(humanSize(e.size))
		}
		body += "\n\n" + failStyle.Render("Deletes "+humanSize(m.cleanTotal)) +
			dimStyle.Render(" — a fresh build re-downloads and recompiles everything.")
	}

	btns := make([]string, len(cleanButtons))
	for i, label := range cleanButtons {
		st := lipgloss.NewStyle().Foreground(cDim).Padding(0, 2).
			Border(lipgloss.RoundedBorder()).BorderForeground(cBorder)
		if i == m.cleanCur {
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
		[2]string{"esc", "cancel"},
	)
	content := lipgloss.JoinVertical(lipgloss.Left, title, "", body, "", row, "", help)

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
