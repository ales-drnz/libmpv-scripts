// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A SwiftPM-style file has BOTH a local and a remote region; exactly one must be
// active (uncommented) per mode, and round-tripping must be lossless.
func TestLibToggleSwiftBothRegions(t *testing.T) {
	// The commented (inactive) region is written in NORMALIZED style — the
	// comment token sits after each line's natural indentation, exactly as the
	// toggler produces — so local↔remote is byte-for-byte reversible.
	const src = `    targets: [
        // mpvkit:local:begin
        .binaryTarget(
            name: "libmpv",
            path: "Frameworks/libmpv.xcframework"),
        // mpvkit:local:end
        // mpvkit:remote:begin
        // .binaryTarget(
            // name: "libmpv",
            // url: "https://example/libmpv.zip",
            // checksum: "abc"),
        // mpvkit:remote:end
    ]`

	// → remote: local commented, remote uncommented.
	rem, _, regions := libToggleContent(src, "//", libRemote)
	if regions != 2 {
		t.Fatalf("expected 2 regions, saw %d", regions)
	}
	if !strings.Contains(rem, "\n            url: \"https://example/libmpv.zip\",\n") {
		t.Errorf("remote mode should activate the url line:\n%s", rem)
	}
	if !strings.Contains(rem, "\n            // path: \"Frameworks/libmpv.xcframework\"),\n") {
		t.Errorf("remote mode should comment the local path line:\n%s", rem)
	}
	// Marker lines must be untouched.
	if !strings.Contains(rem, "// mpvkit:local:begin") || !strings.Contains(rem, "// mpvkit:remote:end") {
		t.Errorf("marker lines must never be toggled:\n%s", rem)
	}

	// → local: should restore the original byte-for-byte.
	loc, _, _ := libToggleContent(rem, "//", libLocal)
	if loc != src {
		t.Errorf("local↔remote round-trip not lossless:\n--- got ---\n%s\n--- want ---\n%s", loc, src)
	}

	// Idempotent: re-applying the same mode yields no edits.
	if _, edits, _ := libToggleContent(loc, "//", libLocal); len(edits) != 0 {
		t.Errorf("re-applying local should be a no-op, got %d edits", len(edits))
	}
}

// A CMake-style file has ONLY a remote region (local use is unconditional):
// local mode comments the download block, remote mode uncomments it.
func TestLibToggleCMakeRemoteOnly(t *testing.T) {
	const src = `set(_BUNDLED_MPV "x")
# mpvkit:remote:begin
if(DOWNLOAD_NEEDED)
  file(DOWNLOAD "url" "${_BUNDLED_MPV}")
endif()
# mpvkit:remote:end
add_library(x)`

	loc, edits, regions := libToggleContent(src, "#", libLocal)
	if regions != 1 {
		t.Fatalf("expected 1 region, saw %d", regions)
	}
	if len(edits) == 0 {
		t.Fatal("local mode should comment the download block")
	}
	if !strings.Contains(loc, "\n# if(DOWNLOAD_NEEDED)\n") || !strings.Contains(loc, "\n  # file(DOWNLOAD") {
		t.Errorf("local mode should comment every body line (indent-preserving):\n%s", loc)
	}
	// Unrelated lines outside the region are untouched.
	if !strings.Contains(loc, "\nadd_library(x)") || !strings.Contains(loc, "set(_BUNDLED_MPV \"x\")\n") {
		t.Errorf("lines outside the region must not change:\n%s", loc)
	}
	// Back to remote restores the original.
	rem, _, _ := libToggleContent(loc, "#", libRemote)
	if rem != src {
		t.Errorf("remote round-trip not lossless:\n%s", rem)
	}
}

// libSetMode writes every consumer file and reports per-file results; a file
// missing its markers is a hard error, not a silent pass.
func TestLibSetModeOnDisk(t *testing.T) {
	root := t.TempDir()
	write := func(rel, content string) {
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Lay down every toggle file with a minimal remote region (+ a local region
	// for the Swift manifests).
	for _, f := range libToggleFiles() {
		c := f.token + " mpvkit:remote:begin\nDOWNLOAD()\n" + f.token + " mpvkit:remote:end\n"
		if strings.HasSuffix(f.rel, "Package.swift") {
			c = f.token + " mpvkit:local:begin\nLOCAL()\n" + f.token + " mpvkit:local:end\n" + c
		}
		write(f.rel, c)
	}

	entries, err := libSetMode(root, libLocal)
	if err != nil {
		t.Fatalf("libSetMode(local) error: %v", err)
	}
	if len(entries) != len(libToggleFiles()) {
		t.Fatalf("expected %d entries, got %d", len(libToggleFiles()), len(entries))
	}
	for _, e := range entries {
		if e.Status != "ok" {
			t.Errorf("%s: status %q (%s)", e.Label, e.Status, e.Message)
		}
	}
	// In local mode the download line must be commented everywhere.
	for _, f := range libToggleFiles() {
		data, err := os.ReadFile(filepath.Join(root, f.rel))
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(data), f.token+" DOWNLOAD()") {
			t.Errorf("%s: DOWNLOAD() not commented in local mode:\n%s", f.rel, data)
		}
	}

	// A file with no markers is a hard error.
	write("linux/CMakeLists.txt", "no markers here\n")
	if _, err := libSetMode(root, libLocal); err == nil {
		t.Error("expected an error when a consumer file lacks mpvkit markers")
	}
}

// libFileMode reads the active region of a single file; libDetectMode folds the
// per-file modes into one verdict (mixed when they disagree).
func TestLibDetectMode(t *testing.T) {
	swiftLocal := "// mpvkit:local:begin\n.binaryTarget(path: \"x\"),\n// mpvkit:local:end\n" +
		"// mpvkit:remote:begin\n// .binaryTarget(url: \"y\"),\n// mpvkit:remote:end\n"
	swiftRemote := "// mpvkit:local:begin\n// .binaryTarget(path: \"x\"),\n// mpvkit:local:end\n" +
		"// mpvkit:remote:begin\n.binaryTarget(url: \"y\"),\n// mpvkit:remote:end\n"
	cmakeRemote := "# mpvkit:remote:begin\nfile(DOWNLOAD)\n# mpvkit:remote:end\n"
	cmakeLocal := "# mpvkit:remote:begin\n# file(DOWNLOAD)\n# mpvkit:remote:end\n"

	if got := libFileMode(swiftLocal, "//"); got != "local" {
		t.Errorf("swiftLocal = %q, want local", got)
	}
	if got := libFileMode(swiftRemote, "//"); got != "remote" {
		t.Errorf("swiftRemote = %q, want remote", got)
	}
	if got := libFileMode(cmakeRemote, "#"); got != "remote" {
		t.Errorf("cmakeRemote = %q, want remote", got)
	}
	if got := libFileMode(cmakeLocal, "#"); got != "local" {
		t.Errorf("cmakeLocal = %q, want local", got)
	}

	// Whole package: write every toggle file, then confirm detect agrees.
	root := t.TempDir()
	writeAll := func(mode libMode) {
		for _, f := range libToggleFiles() {
			// Token-correct markers per file: a remote region everywhere, plus a
			// local region for the SwiftPM manifests.
			base := f.token + " mpvkit:remote:begin\nDOWNLOAD()\n" + f.token + " mpvkit:remote:end\n"
			if strings.HasSuffix(f.rel, "Package.swift") {
				base = f.token + " mpvkit:local:begin\nLOCAL()\n" + f.token + " mpvkit:local:end\n" + base
			}
			p := filepath.Join(root, f.rel)
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte(base), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := libSetMode(root, mode); err != nil {
			t.Fatalf("setMode: %v", err)
		}
	}
	writeAll(libLocal)
	if got := libDetectMode(root); got != "local" {
		t.Errorf("detect after setMode(local) = %q, want local", got)
	}
	writeAll(libRemote)
	if got := libDetectMode(root); got != "remote" {
		t.Errorf("detect after setMode(remote) = %q, want remote", got)
	}
	// Force a disagreement: flip one file back to local.
	one := filepath.Join(root, "linux/CMakeLists.txt")
	data, err := os.ReadFile(one)
	if err != nil {
		t.Fatal(err)
	}
	out, _, _ := libToggleContent(string(data), "#", libLocal)
	if err := os.WriteFile(one, []byte(out), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := libDetectMode(root); got != "mixed" {
		t.Errorf("detect with one file flipped = %q, want mixed", got)
	}
}

// libClean removes present binaries and reports absent ones as skipped.
func TestLibClean(t *testing.T) {
	root := t.TempDir()
	// Create two of the slots (one file, one xcframework directory).
	soPath := filepath.Join(root, "linux/libs/x86_64/libmpv.so")
	if err := os.MkdirAll(filepath.Dir(soPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(soPath, []byte("elf"), 0o644); err != nil {
		t.Fatal(err)
	}
	xcf := filepath.Join(root, "macos/mpv_audio_kit/Frameworks/libmpv.xcframework")
	if err := os.MkdirAll(xcf, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(xcf, "Info.plist"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	entries, err := libClean(root)
	if err != nil {
		t.Fatalf("libClean error: %v", err)
	}
	var removed, skipped int
	for _, e := range entries {
		switch e.Status {
		case "ok":
			removed++
		case "skipped":
			skipped++
		}
	}
	if removed != 2 {
		t.Errorf("expected 2 removed, got %d", removed)
	}
	if skipped != len(libBinaryPaths())-2 {
		t.Errorf("expected %d skipped, got %d", len(libBinaryPaths())-2, skipped)
	}
	if pathExists(soPath) || pathExists(xcf) {
		t.Error("clean must remove both the .so file and the xcframework directory")
	}
}
