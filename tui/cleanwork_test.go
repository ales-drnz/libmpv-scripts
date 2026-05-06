// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import "testing"

func runItem(group string, st status) *item {
	return &item{t: Target{Group: group}, status: st}
}

// The work tree of an OS may only be removed once EVERY arch of that OS in the
// run has finished successfully — so arches sharing a cached toolchain aren't
// wiped mid-OS, and a failed OS keeps its tree.
func TestOSGroupAllDone(t *testing.T) {
	cases := []struct {
		name string
		run  []*item
		want bool
	}{
		{"all arches done", []*item{
			runItem("Android", stDone), runItem("Android", stDone), runItem("Android", stDone),
		}, true},
		{"one arch still building", []*item{
			runItem("Android", stDone), runItem("Android", stBuilding), runItem("Android", stQueued),
		}, false},
		{"one arch failed", []*item{
			runItem("Android", stDone), runItem("Android", stFailed),
		}, false},
		{"one arch skipped", []*item{
			runItem("Linux", stDone), runItem("Linux", stSkipped),
		}, false},
		{"group not in run", []*item{
			runItem("Linux", stDone),
		}, false}, // asking about Android, which has no items here
		{"other groups ignored", []*item{
			runItem("Linux", stDone), runItem("Android", stDone), runItem("Windows", stBuilding),
		}, true}, // Android is fully done; Windows building is irrelevant
	}
	for _, c := range cases {
		group := "Android"
		if c.name == "one arch skipped" {
			group = "Linux"
		}
		if got := osGroupAllDone(c.run, group); got != c.want {
			t.Errorf("%s: osGroupAllDone(%q) = %v, want %v", c.name, group, got, c.want)
		}
	}
}

func TestIsOSGroup(t *testing.T) {
	for _, g := range []string{"macOS", "iOS", "Linux", "Windows", "Android"} {
		if !isOSGroup(g) {
			t.Errorf("isOSGroup(%q) = false, want true", g)
		}
	}
	for _, g := range []string{"Tools", "Docker", "Aggregate", ""} {
		if isOSGroup(g) {
			t.Errorf("isOSGroup(%q) = true, want false", g)
		}
	}
}
