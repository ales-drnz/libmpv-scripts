// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"slices"
	"testing"
)

// The Tizen builds: one Docker target per arch of build_libmpv_tizen.sh, on
// the tizen image, and "all" for both. Cross from any host, so no host arch.
func TestTizenTargets(t *testing.T) {
	for arch, key := range map[string]string{"armv7l": "tizen-armv7l", "i686": "tizen-i686"} {
		tg, ok := targetByKey(key)
		if !ok {
			t.Fatalf("no %s target", key)
		}
		if tg.Group != "Tizen" || tg.kind != kDocker || tg.image != "tizen" ||
			tg.script != "scripts/build_libmpv_tizen.sh" || !tg.InMenu || tg.hostArch != "" ||
			!slices.Equal(tg.args, []string{"--arch=" + arch}) {
			t.Errorf("%s: %+v", key, tg)
		}
		if !tg.Available() {
			t.Errorf("%s should build on any host with Docker", key)
		}
	}
	all, ok := targetByKey("tizen")
	if !ok || all.kind != kAggregate || !slices.Equal(all.members, []string{"tizen-armv7l", "tizen-i686"}) {
		t.Errorf("tizen: %+v", all)
	}
	every, _ := targetByKey("all")
	if !slices.Contains(every.members, "tizen") {
		t.Errorf("all does not build Tizen: %v", every.members)
	}
	if !isOSGroup("Tizen") {
		t.Error(`isOSGroup("Tizen") = false: builds/work/Tizen would never be cleaned`)
	}
}

// Every group of the menu has a column in the select grid, and no band is
// wider than three columns (an 80-column terminal).
func TestEveryMenuGroupHasAColumn(t *testing.T) {
	m := newTestModel()
	shown := map[string]bool{}
	for _, band := range m.selBands() {
		if len(band) > 3 {
			t.Errorf("a band of %d columns", len(band))
		}
		for _, c := range band {
			shown[c.group] = len(c.items) > 0
		}
	}
	for _, tg := range m.targets {
		if !shown[tg.Group] {
			t.Errorf("group %s of %s has no column", tg.Group, tg.Key)
		}
	}
}

// Every image a target builds on is one of the Docker tab and has its
// docker-image-<stage> step.
func TestEveryTargetImageIsKnown(t *testing.T) {
	stages := map[string]bool{}
	for _, img := range dockerImages() {
		stages[img.stage] = true
	}
	for _, tg := range allTargets() {
		if tg.image == "" || tg.kind == kImage {
			continue
		}
		if !stages[tg.image] {
			t.Errorf("%s builds on image %q, not in dockerImages", tg.Key, tg.image)
		}
		if _, ok := targetByKey("docker-image-" + tg.image); !ok {
			t.Errorf("%s builds on image %q, which has no docker-image-%s step", tg.Key, tg.image, tg.image)
		}
	}
}
