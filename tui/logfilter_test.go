// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"strings"
	"testing"
)

// logLines must scope the verifier output to a single binary's section — from
// its "════ <name>" header up to the next section header — so opening the log
// for one platform doesn't show the whole run.
func TestLogLinesScopesToBinary(t *testing.T) {
	it := &item{log: []string{
		"═════ libmpv binary verification ═════",
		"════ libmpv_android-arm64-v8a.so [android]",
		"  ✓ android check 1",
		"  ✓ android check 2",
		"════ libmpv_ios.xcframework.zip [ios]",
		"  ✓ ios check 1",
		"  ✓ ios check 2",
		"  ✗ ios check 3",
		"════ libmpv_linux-x86_64.so [linux]",
		"  ✓ linux check 1",
		"═════ Summary ═════",
		"  Passed: 99",
	}}

	// No filter → whole log.
	if got := len((model{}).logLines(it)); got != len(it.log) {
		t.Errorf("unfiltered logLines = %d lines, want %d", got, len(it.log))
	}

	// Scoped to iOS → only its section (header + its 3 checks), not the others.
	m := model{logFilter: "libmpv_ios.xcframework.zip"}
	got := m.logLines(it)
	if len(got) != 4 {
		t.Fatalf("ios section = %d lines, want 4:\n%s", len(got), strings.Join(got, "\n"))
	}
	if !strings.Contains(got[0], "libmpv_ios") {
		t.Errorf("first line should be the ios header, got %q", got[0])
	}
	for _, ln := range got {
		if strings.Contains(ln, "android") || strings.Contains(ln, "linux") || strings.Contains(ln, "Summary") {
			t.Errorf("ios section leaked another binary's line: %q", ln)
		}
	}

	// Unknown filter → falls back to the whole log (don't hide everything).
	m2 := model{logFilter: "libmpv_nope.so"}
	if got := len(m2.logLines(it)); got != len(it.log) {
		t.Errorf("unknown filter = %d lines, want full %d", got, len(it.log))
	}
}
