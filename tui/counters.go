// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import "regexp"

// logClass is the severity bucket a single build-output line falls into.
type logClass int

const (
	clNone logClass = iota
	clInfo
	clWarn
	clErr
)

// counters tallies how many info / warning / error lines a build has emitted.
// Shown live next to the spinner so a long build's health is visible at a
// glance without opening the log.
type counters struct {
	info int
	warn int
	errs int
}

func (c *counters) add(cl logClass) {
	switch cl {
	case clInfo:
		c.info++
	case clWarn:
		c.warn++
	case clErr:
		c.errs++
	}
}

// Diagnostic patterns are deliberately anchored so we don't mistake "-Werror",
// "checking for error_at_line... yes", or a filename containing "error" for a
// real diagnostic. We trust:
//   - the build scripts' own markers (▶ log · ✓ ok · ⚠ warn · ✗ err), and
//   - the canonical clang/gcc/ninja/ld diagnostic shapes ("…: error:" etc).
var (
	reErr  = regexp.MustCompile(`(?i)(^|\s)(error|fatal error):|undefined reference|Undefined symbols`)
	reWarn = regexp.MustCompile(`(?i)(^|\s)warning:`)
)

// classify buckets one line of combined build output.
func classify(line string) logClass {
	// Explicit script markers first — they are intentional and unambiguous.
	switch {
	case containsRune(line, '✗'):
		return clErr
	case containsRune(line, '⚠'):
		return clWarn
	case containsRune(line, '▶'), containsRune(line, '✓'):
		return clInfo
	}
	// Then the toolchain's own diagnostic shapes.
	switch {
	case reErr.MatchString(line):
		return clErr
	case reWarn.MatchString(line):
		return clWarn
	}
	return clNone
}

func containsRune(s string, r rune) bool {
	for _, c := range s {
		if c == r {
			return true
		}
	}
	return false
}
