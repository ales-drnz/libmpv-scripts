// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// TestGridsFitEightyColumns locks the width of the target grids: the
// selector and the build dashboard fit an 80-column terminal, as each band
// holds at most three OS columns.
func TestGridsFitEightyColumns(t *testing.T) {
	m := newTestModel()
	m.width, m.height = 80, 60
	cell := func(int, bool) string { return strings.Repeat("x", gridRowW) }
	dash := func(int, bool) string { return strings.Repeat("x", dashRowW) }
	views := map[string]string{
		"selector":  m.renderBandRange(cell, false, 0, len(m.selBands()), true),
		"dashboard": m.renderDashBoxes(dash),
	}
	for name, v := range views {
		for _, line := range strings.Split(v, "\n") {
			if w := lipgloss.Width(line); w > 80 {
				t.Errorf("%s: a line %d columns wide", name, w)
				break
			}
		}
	}
}

// TestTruncateCountsColumns locks truncate on a styled line: it cut at w
// bytes, so the row of a binary with failures in the verify view, 77
// columns of text in 150 bytes of text and color codes, lost its end at
// 120 and showed the head of a cut escape, "1 ✗[".
func TestTruncateCountsColumns(t *testing.T) {
	bold := "\x1b[1;96m"
	reset := "\x1b[0m"
	row := ""
	for i := 0; i < 10; i++ {
		row += bold + "✗ x86" + reset + "  "
	}
	if got := truncate(row, 120); got != row {
		t.Errorf("a row %d columns wide is cut at 120: %q", lipgloss.Width(row), got)
	}
	got := truncate(row, 30)
	if w := lipgloss.Width(got); w != 30 {
		t.Errorf("cut at 30 columns, the row is %d wide: %q", w, got)
	}
	if strings.HasSuffix(got, "\x1b") || strings.HasSuffix(got, "\x1b[") {
		t.Errorf("the cut leaves half an escape: %q", got)
	}
	if got := truncate("plain", 3); got != "pla" {
		t.Errorf("a plain string cut at 3: %q", got)
	}
}
