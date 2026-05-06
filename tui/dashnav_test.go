// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import "testing"

// Regression: leaving the verify log dropped the cursor onto the build
// dashboard with selBand still pointing at the Tools band (index 2), which the
// dashboard's 2-band grid doesn't have → gridDown did bands[2] and panicked.
// The grid nav must clamp a stale cursor instead of indexing out of range.
func TestGridNavClampsStaleCursor(t *testing.T) {
	m := &model{targets: menuTargets()}
	bands := m.dashBands() // dashboard shows only the compile bands
	if len(bands) >= 3 {
		t.Fatalf("dashBands should drop the Tools band, got %d bands", len(bands))
	}
	// A cursor left far out of range from another tab/screen.
	m.selBand, m.selCol, m.selRow = 99, 99, 99

	// None of these may panic.
	m.gridDown(bands)
	m.gridUp(bands)
	m.navLeft(bands)
	m.navRight(bands)

	if m.selBand < 0 || m.selBand >= len(bands) {
		t.Errorf("selBand=%d not clamped into [0,%d)", m.selBand, len(bands))
	}
	if m.selCol < 0 || m.selCol >= len(bands[m.selBand]) {
		t.Errorf("selCol=%d not clamped into [0,%d)", m.selCol, len(bands[m.selBand]))
	}
}

// keyDash itself (the real entry point) must also survive a stale cursor.
func TestKeyDashStaleCursorNoPanic(t *testing.T) {
	for _, k := range []string{"j", "k", "h", "l", "c"} {
		m := newTestModel()
		m.screen = scDash
		m.selBand, m.selCol, m.selRow = 2, 4, 8 // stale from the Tools tab
		_ = press(m, k)                         // must not panic
	}
}
