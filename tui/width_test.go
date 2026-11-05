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
