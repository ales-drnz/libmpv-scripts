// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"slices"
	"testing"
)

// The webOS build: one Docker target, armv7l, on the webos image, pinned to
// linux/amd64 like Android (the NDK runs on x86_64 hosts only), in "all"
// and in the clean of builds/work/webOS.
func TestWebosTarget(t *testing.T) {
	tg, ok := targetByKey("webos-armv7l")
	if !ok {
		t.Fatal("no webos-armv7l target")
	}
	if tg.Group != "webOS" || tg.kind != kDocker || tg.image != "webos" ||
		tg.script != "scripts/build_libmpv_webos.sh" || !tg.InMenu ||
		tg.dockerPlatform != "linux/amd64" {
		t.Errorf("webos-armv7l: %+v", tg)
	}
	img, ok := targetByKey("docker-image-webos")
	if !ok || img.dockerPlatform != "linux/amd64" {
		t.Errorf("docker-image-webos: %+v", img)
	}
	every, _ := targetByKey("all")
	if !slices.Contains(every.members, "webos-armv7l") {
		t.Errorf("all does not build webOS: %v", every.members)
	}
	if !isOSGroup("webOS") {
		t.Error(`isOSGroup("webOS") = false: builds/work/webOS would never be cleaned`)
	}
}
