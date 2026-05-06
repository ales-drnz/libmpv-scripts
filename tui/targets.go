// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import "runtime"

type tkind int

const (
	kNative    tkind = iota // bash script on the host
	kDocker                 // bash script inside the mpv-build-env container
	kImage                  // docker build of the build-env image
	kAggregate              // expands to other targets
	kSelf                   // a Go step run by re-execing the orchestrator
)

// Target is one buildable / publishable step. It carries everything needed
// to construct its command at run time — no Makefile in the loop.
//
// `Group` is the OS section ("macOS", "Windows", …). `Label` is the short
// per-arch text shown under that section ("arm64", "all", …). `env` carries
// the per-arch / per-slice selectors (ARCHS, ABIS, SKIP_SIMULATOR, …) for
// native builds — this is how macOS / iOS / Android get the same
// per-architecture granularity as Linux / Windows.
type Target struct {
	Key       string
	Label     string
	Group     string
	Note      string
	Desc      string // one-line "what it does", shown under the focused Tools action
	AppleOnly bool   // needs the Apple toolchain → host must be macOS
	InMenu    bool   // shown in the interactive selector

	kind    tkind
	script  string
	args    []string
	env     []string // extra "K=V" pairs for native runs
	ndk     bool     // mount the host NDK sysroot (verify only)
	members []string // for kAggregate
	selfArg string   // hidden subcommand for kSelf (e.g. "_checksums")
	// image is the multi-stage Dockerfile stage / image suffix this target uses.
	// kDocker targets run in mpv-build-<image>; kImage targets build that stage.
	image string
	// dockerPlatform pins the build/run platform (e.g. "linux/amd64"). Android
	// uses it: the NDK only ships an x86_64-linux host toolchain, so on Apple
	// Silicon we run amd64 under Rosetta 2 (fast) instead of letting the x86_64
	// clang run under qemu-user in an arm64 container (≈5-6× slower). "" = native.
	dockerPlatform string
	// nativeOnDarwin: on a macOS host, run this target on the host (kNative)
	// instead of in Docker — the macOS NDK is native arm64, so Android builds at
	// full native speed with no emulation. Overridable (settings.ForceAndroidDocker
	// / ANDROID_FORCE_DOCKER) and a no-op off macOS (stays Docker). See expand().
	nativeOnDarwin bool
}

// hostOS is the OS the orchestrator runs on. A package var so tests can
// simulate other hosts.
var hostOS = runtime.GOOS

// Available reports whether this target can run on the current host:
//
//   - Apple targets (macOS / iOS) need macOS + Xcode — there is no legal,
//     supported way to build them off a Mac, so they're disabled elsewhere.
//   - The other NATIVE build scripts (Android, checksums, version bump) are
//     bash + Unix tools run on the host, so they don't work on native Windows
//     (they're fine on macOS / Linux, and under WSL — which reports "linux").
//   - Docker targets (Windows / Linux builds, verify) run bash INSIDE the
//     container, so the host only needs Docker. They work on every host OS,
//     and on any host CPU arch: the build image is multi-arch (built native to
//     the host) and cross-compiles every target architecture, so an arm64 or
//     x86 Windows/Linux box builds all desktop arches at native speed.
func (t Target) Available() bool {
	switch {
	case t.AppleOnly:
		return hostOS == "darwin"
	case t.kind == kNative:
		return hostOS != "windows"
	default:
		return true
	}
}

// unavailReason explains, for the UI, why a target can't run here ("" when it
// can).
func (t Target) unavailReason() string {
	if t.Available() {
		return ""
	}
	if t.AppleOnly {
		return "needs macOS + Xcode"
	}
	if t.kind == kNative {
		return "needs a macOS/Linux host (Unix build script)"
	}
	return "unavailable on this host"
}

func (t Target) needsDocker() bool { return t.kind == kDocker }

// fullLabel is the unambiguous name for flat views (dashboard / logs / CLI),
// where there is no section header to provide the OS context.
func (t Target) fullLabel() string {
	if t.Group == "Tools" {
		return t.Label
	}
	return t.Group + " " + t.Label
}

func allTargets() []Target {
	const (
		sMac     = "scripts/build_libmpv_macos.sh"
		sIOS     = "scripts/build_libmpv_ios.sh"
		sAndroid = "scripts/build_libmpv_android.sh"
		sLinux   = "scripts/build_libmpv_linux.sh"
		sWin     = "scripts/build_libmpv_windows.sh"
	)
	const apple = "needs macOS + Xcode"
	return []Target{
		// ── macOS ──
		{Key: "macos-arm64", Label: "arm64", Group: "macOS", AppleOnly: true, InMenu: true, Note: apple, kind: kNative, script: sMac, env: []string{"ARCHS=arm64"}},
		{Key: "macos-x86_64", Label: "x86_64", Group: "macOS", AppleOnly: true, InMenu: true, Note: apple, kind: kNative, script: sMac, env: []string{"ARCHS=x86_64"}},
		{Key: "macos", Label: "all (universal)", Group: "macOS", AppleOnly: true, InMenu: true, Note: apple, kind: kNative, script: sMac},

		// ── iOS (by arch, like macOS). On iOS, arm64 covers device +
		//    simulator; x86_64 exists only in the simulator. ──
		{Key: "ios-arm64", Label: "arm64", Group: "iOS", AppleOnly: true, InMenu: true, Note: apple, kind: kNative, script: sIOS, env: []string{"SIM_ARCHS=arm64"}},
		{Key: "ios-x86_64", Label: "x86_64", Group: "iOS", AppleOnly: true, InMenu: true, Note: apple, kind: kNative, script: sIOS, env: []string{"ONLY_SIMULATOR=1", "SIM_ARCHS=x86_64"}},
		{Key: "ios", Label: "all (universal)", Group: "iOS", AppleOnly: true, InMenu: true, Note: apple, kind: kNative, script: sIOS},

		// ── Windows (Docker — any host) ──
		{Key: "windows-x86_64", Label: "x86_64", Group: "Windows", InMenu: true, kind: kDocker, script: sWin, image: "windows", args: []string{"--arch=x86_64"}},
		{Key: "windows-arm64", Label: "arm64", Group: "Windows", InMenu: true, kind: kDocker, script: sWin, image: "windows", args: []string{"--arch=aarch64"}},
		{Key: "windows", Label: "all", Group: "Windows", InMenu: true, kind: kAggregate, members: []string{"windows-x86_64", "windows-arm64"}},

		// ── Linux (Docker — any host) ──
		{Key: "linux-x86_64", Label: "x86_64", Group: "Linux", InMenu: true, kind: kDocker, script: sLinux, image: "linux", args: []string{"--arch=x86_64"}},
		{Key: "linux-aarch64", Label: "aarch64", Group: "Linux", InMenu: true, kind: kDocker, script: sLinux, image: "linux", args: []string{"--arch=aarch64"}},
		{Key: "linux", Label: "all", Group: "Linux", InMenu: true, kind: kAggregate, members: []string{"linux-x86_64", "linux-aarch64"}},

		// ── Android (Docker — NDK fetched at runtime; runs on the base image) ──
		{Key: "android-arm64-v8a", Label: "arm64-v8a", Group: "Android", InMenu: true, kind: kDocker, script: sAndroid, image: "android", dockerPlatform: "linux/amd64", nativeOnDarwin: true, env: []string{"ABIS=arm64-v8a"}},
		{Key: "android-armeabi-v7a", Label: "armeabi-v7a", Group: "Android", InMenu: true, kind: kDocker, script: sAndroid, image: "android", dockerPlatform: "linux/amd64", nativeOnDarwin: true, env: []string{"ABIS=armeabi-v7a"}},
		{Key: "android-x86_64", Label: "x86_64", Group: "Android", InMenu: true, kind: kDocker, script: sAndroid, image: "android", dockerPlatform: "linux/amd64", nativeOnDarwin: true, env: []string{"ABIS=x86_64"}},
		// "all" is an AGGREGATE of the per-ABI targets (like Linux/Windows), so
		// each ABI builds as its own dashboard row with its own log + green tick
		// as it finishes — not one combined run. (macOS/iOS "all" stay single
		// because they lipo into one universal xcframework.)
		{Key: "android", Label: "all", Group: "Android", InMenu: true, kind: kAggregate, members: []string{"android-arm64-v8a", "android-armeabi-v7a", "android-x86_64"}},

		// ── Publish / validate ──
		{Key: "checksums", Label: "Checksums", Group: "Tools", InMenu: true, kind: kSelf, selfArg: "_checksums",
			Desc: "install built libs into mpv_audio_kit + refresh its SHA-256s"},
		{Key: "verify", Label: "Verify", Group: "Tools", InMenu: true, kind: kDocker, script: "scripts/verify_binaries.sh", image: "verify", ndk: true,
			Desc: "deep static + runtime audit of every release binary"},
		{Key: "lib-clean", Label: "Clean", Group: "Tools", InMenu: true, kind: kSelf, selfArg: "_libclean",
			Desc: "remove the bundled libs from every platform slot"},

		// ── Libs source switch for mpv_audio_kit ──
		// lib-mode is the in-menu local⇄remote toggle (rendered as a segmented
		// button); lib-local / lib-remote are the explicit force-setters it (and
		// the CLI) drive. lib-clean (above, grouped with Checksums/Verify) wipes
		// the bundled binaries.
		{Key: "lib-mode", Label: "libs", Group: "Tools", InMenu: true, kind: kSelf, selfArg: "_libmode",
			Desc: "libmpv source for mpv_audio_kit (local ⇄ remote)"},
		{Key: "lib-local", Label: "local", Group: "Tools", InMenu: false, kind: kSelf, selfArg: "_liblocal",
			Desc: "use bundled libs only — never download from GitHub"},
		{Key: "lib-remote", Label: "remote", Group: "Tools", InMenu: false, kind: kSelf, selfArg: "_libremote",
			Desc: "download from GitHub Releases when a local lib is missing"},

		// ── Non-menu (CLI / internal) ──
		// One image-build step per multi-stage target; expand() prepends only the
		// one(s) a requested build actually needs, and only when missing.
		{Key: "docker-image-linux", Label: "Build the Linux build image", Group: "Docker", InMenu: false, kind: kImage, image: "linux"},
		{Key: "docker-image-windows", Label: "Build the Windows build image", Group: "Docker", InMenu: false, kind: kImage, image: "windows"},
		{Key: "docker-image-android", Label: "Build the Android build image", Group: "Docker", InMenu: false, kind: kImage, image: "android", dockerPlatform: "linux/amd64"},
		{Key: "docker-image-verify", Label: "Build the Verify image", Group: "Docker", InMenu: false, kind: kImage, image: "verify"},
		{Key: "docker-start", Label: "Start the Docker daemon", Group: "Docker", InMenu: false, kind: kSelf, selfArg: "_dockerstart"},

		// ── Aggregates (CLI convenience) ──
		{Key: "desktop-all", Label: "All desktop targets", Group: "Aggregate", InMenu: false, kind: kAggregate, members: []string{"linux", "windows"}},
		{Key: "all", Label: "Everything + checksums", Group: "Aggregate", InMenu: false, kind: kAggregate, members: []string{"macos", "ios", "android", "desktop-all", "checksums"}},
	}
}

func targetByKey(key string) (Target, bool) {
	for _, t := range allTargets() {
		if t.Key == key {
			return t, true
		}
	}
	return Target{}, false
}

// menuTargets returns the targets shown in the interactive selector.
func menuTargets() []Target {
	var out []Target
	for _, t := range allTargets() {
		if t.InMenu {
			out = append(out, t)
		}
	}
	return out
}
