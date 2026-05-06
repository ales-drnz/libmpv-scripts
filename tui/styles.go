// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

// ── Palette ──────────────────────────────────────────────────────────────────
// A cohesive, calm "midnight" palette (Tokyo-Night-ish). Colors are truecolor
// hex; lipgloss degrades them to the nearest 256-color on terminals that lack
// truecolor, so they stay readable everywhere.
var (
	cAccent  = lipgloss.Color("#7DCFFF") // primary — cyan
	cAccent2 = lipgloss.Color("#BB9AF7") // secondary — violet
	cText    = lipgloss.Color("#C0CAF5") // body text
	cDim     = lipgloss.Color("#7A82A8") // muted grey-blue
	cFaint   = lipgloss.Color("#565F89") // even fainter (disabled)
	cOK      = lipgloss.Color("#9ECE6A") // green
	cWarn    = lipgloss.Color("#E0AF68") // amber
	cInfo    = lipgloss.Color("#7DCFFF") // cyan (info)
	cFail    = lipgloss.Color("#F7768E") // red
	cRun     = lipgloss.Color("#7AA2F7") // running — blue
	cCancel  = lipgloss.Color("#FF9E64") // orange
	cBorder  = lipgloss.Color("#3B4261") // panel borders
	cSel     = lipgloss.Color("#283457") // selection background
	cSelText = lipgloss.Color("#FFFFFF") // near-white on selection
	cBg      = lipgloss.Color("#1A1B26") // app background (dark text on a filled pill)
)

// ── Core text styles (names referenced across the app) ───────────────────────
var (
	titleStyle = lipgloss.NewStyle().Bold(true).Foreground(cAccent)
	dimStyle   = lipgloss.NewStyle().Foreground(cDim)
	faintStyle = lipgloss.NewStyle().Foreground(cFaint)
	helpStyle  = lipgloss.NewStyle().Foreground(cDim)
	textStyle  = lipgloss.NewStyle().Foreground(cText)

	rowStyle    = lipgloss.NewStyle().Padding(0, 1)
	rowSelStyle = lipgloss.NewStyle().Padding(0, 1).
			Background(cSel).Foreground(cSelText).Bold(true)

	// hiStyle highlights the focused cell/row in the selectors.
	hiStyle = lipgloss.NewStyle().Background(cSel).Foreground(cSelText).Bold(true)

	// hdrStyle styles a section header inside a column.
	hdrStyle = lipgloss.NewStyle().Bold(true).Foreground(cAccent2)

	panelStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(cBorder).
			Padding(0, 1)

	logStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#A9B1D6"))

	okStyle   = lipgloss.NewStyle().Foreground(cOK)
	warnStyle = lipgloss.NewStyle().Foreground(cWarn)
	failStyle = lipgloss.NewStyle().Foreground(cFail)
)

// ── Build button (green box) ─────────────────────────────────────────────────
// A green-bordered box. When the selector cursor lands on it, the interior
// fills with the button's OWN color (green), dark text for contrast, so the
// highlight is green rather than the generic selection blue. (A full
// edge-to-edge fill isn't possible while keeping rounded corners: giving the
// border cells a background squares off the ╭╮╰╯ glyphs, so the rounded
// outline keeps a thin dark halo around the green fill — that's the cost of
// curved corners in a cell grid.) Faint when nothing is selected.
var (
	buildBtnStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).BorderForeground(cOK).
			Foreground(cOK).Bold(true).Padding(0, 2)
	buildBtnFocusStyle = lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).BorderForeground(cOK).
				Background(cOK).Foreground(cBg).Bold(true).Padding(0, 2)
	buildBtnDisabledStyle = lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).BorderForeground(cFaint).
				Foreground(cFaint).Padding(0, 2)

	// The dashboard's Abort button — the red counterpart of the green Build
	// button: red outline normally, filled red (dark text) when focused.
	abortBtnStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).BorderForeground(cFail).
			Foreground(cFail).Bold(true).Padding(0, 2)
	abortBtnFocusStyle = lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).BorderForeground(cFail).
				Background(cFail).Foreground(cBg).Bold(true).Padding(0, 2)
)

// spinnerFrames is a smooth Braille spinner.
var spinnerFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// Checkbox glyphs — little squares (a tiny "frame", echoing the Build box)
// instead of bracketed letters like [ ] / [x].
const (
	boxOff     = "□" // unchecked
	boxOn      = "■" // checked (and, rendered faint, a locked-on item)
	boxPartial = "▣" // some-but-not-all (the "All" master toggle)
	boxNA      = "·" // an unavailable target (not toggleable)
)

// ── Tab bar ──────────────────────────────────────────────────────────────────
var (
	tabActiveStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#1A1B26")).
			Background(cAccent).
			Padding(0, 2)
	// subTabActiveStyle marks the active Settings sub-tab (Decoders/Filters/…)
	// — red, at the same intensity as the cyan accent.
	subTabActiveStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("#1A1B26")).
				Background(lipgloss.Color("#FF7D7D")).
				Padding(0, 2)
	tabInactiveStyle = lipgloss.NewStyle().
				Foreground(cDim).
				Padding(0, 2)
	// tabFocusStyle marks the tab the selector cursor is on (distinct from the
	// active section, which keeps the filled accent).
	tabFocusStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(cSelText).
			Background(cSel).
			Padding(0, 2)
	keyCapStyle = lipgloss.NewStyle().Foreground(cAccent).Bold(true)
)

// hrule renders a full-width dim horizontal rule.
func hrule(width int) string {
	return lipgloss.NewStyle().Foreground(cBorder).Render(strings.Repeat("─", maxInt(width, 1)))
}

// ── Scrollbar ────────────────────────────────────────────────────────────────
var (
	scrollThumbStyle = lipgloss.NewStyle().Foreground(cAccent)
	scrollTrackStyle = lipgloss.NewStyle().Foreground(cBorder)
)

// scrollbar builds a vertical scrollbar as `height` single-cell rows for a list
// of `total` items showing `height` of them starting at `offset`. The thumb's
// size and position reflect how much of the list is visible and where. Returns
// nil when everything fits — there's nothing to scroll.
func scrollbar(total, height, offset int) []string {
	if height <= 0 || total <= height {
		return nil
	}
	thumb := height * height / total
	if thumb < 1 {
		thumb = 1
	}
	maxPos := height - thumb
	pos := 0
	if maxOff := total - height; maxOff > 0 {
		pos = clampInt(offset*maxPos/maxOff, 0, maxPos)
	}
	col := make([]string, height)
	for i := range col {
		if i >= pos && i < pos+thumb {
			col[i] = scrollThumbStyle.Render("█")
		} else {
			col[i] = scrollTrackStyle.Render("│")
		}
	}
	return col
}

// scrollView renders `lines` windowed to exactly `height` rows starting at
// `offset`, each prefixed by a two-column gutter: the scrollbar (track + thumb)
// in column 0 plus a column of padding, so the content/cursor never sits flush
// against the bar. When the content fits, the gutter is blank (the layout never
// shifts as the scrollbar appears/disappears). Content lines keep their own
// indentation. `offset` should already be clamped to a valid range.
func scrollView(lines []string, height, offset int) string {
	bar := scrollbar(len(lines), height, offset)
	rows := make([]string, height)
	for i := 0; i < height; i++ {
		cell := " "
		if bar != nil {
			cell = bar[i]
		}
		line := ""
		if idx := offset + i; idx >= 0 && idx < len(lines) {
			line = lines[idx]
		}
		rows[i] = cell + " " + line // scrollbar + padding column
	}
	return strings.Join(rows, "\n")
}

// tabDef is one top-level section in the header strip.
type tabDef struct {
	label string
	key   string
}

var topTabs = []tabDef{
	{"Build", "b"},
	{"Settings", "s"},
	{"Dependencies", "d"},
}

// renderHeader draws the brand + the tab strip and a full-width rule beneath.
// `active` is the current section; `focus` is the tab the selector cursor is
// on (-1 when the cursor isn't in the tab strip). When `locked` is true the
// non-active sections are darkened to signal they can't be opened right now
// (e.g. while a build is running) and no focus ring is drawn.
func renderHeader(active, focus, width int, locked bool) string {
	brand := lipgloss.NewStyle().Bold(true).Foreground(cAccent).Render("◆ libmpv-scripts") +
		lipgloss.NewStyle().Foreground(cFaint).Render(" "+version)

	lockedStyle := lipgloss.NewStyle().Foreground(cFaint).Padding(0, 2)

	cells := make([]string, len(topTabs))
	for i, t := range topTabs {
		label := fmt.Sprintf("[%s] %s", strings.ToUpper(t.key), t.label)
		switch {
		case locked && i != active:
			cells[i] = lockedStyle.Render(label)
		case locked && i == active:
			cells[i] = tabActiveStyle.Render(label)
		case i == focus:
			cells[i] = tabFocusStyle.Render(label)
		case i == active:
			cells[i] = tabActiveStyle.Render(label)
		default:
			cells[i] = tabInactiveStyle.Render(label)
		}
	}
	tabs := lipgloss.JoinHorizontal(lipgloss.Center, cells...)

	bar := brand + "   " + tabs
	return bar + "\n" + hrule(width)
}

// ── Counter badges (warnings / infos / errors during a build) ────────────────
// Rendered as small pills; zero-valued counters render faint so the eye only
// catches the ones that lit up.
func badge(glyph string, n int, on lipgloss.Color) string {
	st := faintStyle
	if n > 0 {
		st = lipgloss.NewStyle().Foreground(on).Bold(true)
	}
	return st.Render(fmt.Sprintf("%s %d", glyph, n))
}

// counterBar renders the info/warn/error triple used on the dashboard.
func counterBar(info, warn, errs int) string {
	return strings.Join([]string{
		badge("ℹ", info, cInfo),
		badge("⚠", warn, cWarn),
		badge("✗", errs, cFail),
	}, "  ")
}

// ── small helpers ────────────────────────────────────────────────────────────

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// keyHint renders a "[key] action" pair for the bottom help line — the key in
// square brackets, no separator dots.
func keyHint(key, action string) string {
	return keyCapStyle.Render("["+key+"]") + " " + dimStyle.Render(action)
}

// helpBar joins key hints with plain spacing (no separator dots).
func helpBar(pairs ...[2]string) string {
	parts := make([]string, len(pairs))
	for i, p := range pairs {
		parts[i] = keyHint(p[0], p[1])
	}
	return strings.Join(parts, "   ")
}

// progressBar renders a compact [████░░░░] done/total bar of the given width.
func progressBar(done, total, width int) string {
	if total <= 0 || width <= 0 {
		return ""
	}
	filled := int(float64(done) / float64(total) * float64(width))
	filled = clampInt(filled, 0, width)
	bar := lipgloss.NewStyle().Foreground(cOK).Render(strings.Repeat("█", filled)) +
		lipgloss.NewStyle().Foreground(cBorder).Render(strings.Repeat("░", width-filled))
	return bar
}
