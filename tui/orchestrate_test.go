// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import "testing"

// Android builds natively on a macOS host (the NDK is native arm64 there) unless
// forced to Docker; everywhere else it stays Docker. resolveNative is pure (no
// docker calls), so this locks the matrix without touching a daemon.
func TestResolveNativeAndroid(t *testing.T) {
	saved := hostOS
	defer func() { hostOS = saved }()

	and, ok := targetByKey("android-arm64-v8a")
	if !ok {
		t.Fatal("android-arm64-v8a target missing")
	}
	lin, _ := targetByKey("linux-x86_64")

	// macOS, default → native (kNative, no docker image).
	hostOS = "darwin"
	if got := (&buildCtx{}).resolveNative(and); got.kind != kNative || got.image != "" {
		t.Errorf("darwin default: want native+no-image, got kind=%v image=%q", got.kind, got.image)
	}
	// macOS, forced → stays Docker.
	if got := (&buildCtx{androidForceDocker: true}).resolveNative(and); got.kind != kDocker || got.image != "android" {
		t.Errorf("darwin forced: want docker(android), got kind=%v image=%q", got.kind, got.image)
	}
	// Non-Android target on macOS is never touched.
	if got := (&buildCtx{}).resolveNative(lin); got.kind != kDocker {
		t.Errorf("linux on darwin must stay docker, got kind=%v", got.kind)
	}
	// Off macOS, Android always Docker (no native arm64 NDK on Linux/Windows).
	hostOS = "linux"
	if got := (&buildCtx{}).resolveNative(and); got.kind != kDocker {
		t.Errorf("linux host: android must stay docker, got kind=%v", got.kind)
	}
}
