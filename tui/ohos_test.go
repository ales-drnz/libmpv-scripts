// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"slices"
	"testing"
)

func TestOhosTargets(t *testing.T) {
	for arch, key := range map[string]string{"arm64-v8a": "ohos-arm64-v8a", "x86_64": "ohos-x86_64"} {
		tg, ok := targetByKey(key)
		if !ok {
			t.Fatalf("no %s target", key)
		}
		if tg.Group != "OHOS" || tg.kind != kDocker || tg.image != "ohos" ||
			tg.script != "scripts/build_libmpv_ohos.sh" || !tg.InMenu ||
			tg.dockerPlatform != "linux/amd64" ||
			!slices.Equal(tg.args, []string{"--arch=" + arch}) {
			t.Errorf("%s: %+v", key, tg)
		}
	}
	all, ok := targetByKey("ohos")
	if !ok || all.kind != kAggregate || !slices.Equal(all.members, []string{"ohos-arm64-v8a", "ohos-x86_64"}) {
		t.Errorf("ohos: %+v", all)
	}
	every, _ := targetByKey("all")
	if !slices.Contains(every.members, "ohos") {
		t.Errorf("all does not build OHOS: %v", every.members)
	}
	if !isOSGroup("OHOS") {
		t.Error(`isOSGroup("OHOS") = false: builds/work/OHOS would never be cleaned`)
	}
}
