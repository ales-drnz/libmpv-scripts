// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"archive/zip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const zeroSHA = "0000000000000000000000000000000000000000000000000000000000000000"

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRunChecksumsUpdatesAndCopies(t *testing.T) {
	scriptsRoot := t.TempDir()
	repoRoot := t.TempDir()
	release := filepath.Join(scriptsRoot, "builds", "release")

	// release binaries (only desktop + one android — macOS/iOS absent → skipped)
	writeFile(t, filepath.Join(release, "libmpv_linux-x86_64.so"), "linux-x86 binary")
	writeFile(t, filepath.Join(release, "libmpv_windows-arm64.dll"), "win-arm64 binary")
	writeFile(t, filepath.Join(release, "libmpv_android-arm64-v8a.so"), "android binary")

	// consumer package files with placeholder hashes
	writeFile(t, filepath.Join(repoRoot, "linux/CMakeLists.txt"),
		"set(EXPECTED_SHA256_X86_64  \""+zeroSHA+"\")\nset(EXPECTED_SHA256_AARCH64 \""+zeroSHA+"\")\n")
	writeFile(t, filepath.Join(repoRoot, "windows/CMakeLists.txt"),
		"set(EXPECTED_SHA256_X86_64  \""+zeroSHA+"\")\nset(EXPECTED_SHA256_ARM64   \""+zeroSHA+"\")\n")
	writeFile(t, filepath.Join(repoRoot, "android/build.gradle.kts"),
		"\"file\" to \"libmpv_android-arm64-v8a.so\", \"sha256\" to \""+zeroSHA+"\",\n")

	ctx := &buildCtx{scriptsRoot: scriptsRoot, repoRoot: repoRoot}
	var logs []string
	if err := runChecksums(ctx, func(l string) { logs = append(logs, l) }); err != nil {
		t.Fatalf("runChecksums failed: %v", err)
	}

	// expected hashes
	hLinux, err := sha256File(filepath.Join(release, "libmpv_linux-x86_64.so"))
	if err != nil {
		t.Fatal(err)
	}
	hWin, err := sha256File(filepath.Join(release, "libmpv_windows-arm64.dll"))
	if err != nil {
		t.Fatal(err)
	}
	hAndroid, err := sha256File(filepath.Join(release, "libmpv_android-arm64-v8a.so"))
	if err != nil {
		t.Fatal(err)
	}

	read := func(p string) string {
		b, err := os.ReadFile(filepath.Join(repoRoot, p))
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}

	// The replacement normalises CMake whitespace to two spaces (sed parity),
	// so assert on the hash + var, not exact spacing.
	if got := read("linux/CMakeLists.txt"); !strings.Contains(got, "EXPECTED_SHA256_X86_64  \""+hLinux+"\"") {
		t.Errorf("linux x86_64 hash not written:\n%s", got)
	}
	if got := read("linux/CMakeLists.txt"); !strings.Contains(got, "EXPECTED_SHA256_AARCH64 \""+zeroSHA+"\"") {
		t.Error("linux aarch64 (absent binary) should be left untouched")
	}
	if got := read("windows/CMakeLists.txt"); !strings.Contains(got, "EXPECTED_SHA256_ARM64  \""+hWin+"\"") {
		t.Errorf("windows arm64 hash not written:\n%s", got)
	}
	if got := read("windows/CMakeLists.txt"); !strings.Contains(got, "EXPECTED_SHA256_X86_64  \""+zeroSHA+"\"") {
		t.Error("windows x86_64 (absent binary) should be left untouched")
	}
	if got := read("android/build.gradle.kts"); !strings.Contains(got, "\"sha256\" to \""+hAndroid+"\"") {
		t.Errorf("android hash not written:\n%s", got)
	}

	// binaries copied to their slots
	for _, p := range []string{
		"linux/libs/x86_64/libmpv.so",
		"windows/libs/arm64/libmpv.dll",
		"android/src/main/jniLibs/arm64-v8a/libmpv.so",
	} {
		if !fileExists(filepath.Join(repoRoot, p)) {
			t.Errorf("expected copied binary at %s", p)
		}
	}
}

func TestRunChecksumsEmptyReleaseErrors(t *testing.T) {
	ctx := &buildCtx{scriptsRoot: t.TempDir(), repoRoot: t.TempDir()}
	if err := runChecksums(ctx, func(string) {}); err == nil {
		t.Error("expected an error when builds/release is empty")
	}
}

func TestExtractZipSymlink(t *testing.T) {
	dir := t.TempDir()
	zipPath := filepath.Join(dir, "fw.zip")
	zf, err := os.Create(zipPath)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(zf)
	// a regular file
	fw, err := zw.Create("libmpv.xcframework/Info.plist")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fw.Write([]byte("<plist/>")); err != nil {
		t.Fatal(err)
	}
	// a symlink entry
	sh := &zip.FileHeader{Name: "libmpv.xcframework/Current"}
	sh.SetMode(os.ModeSymlink | 0o777)
	sw, err := zw.CreateHeader(sh)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := sw.Write([]byte("Versions/A")); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := zf.Close(); err != nil {
		t.Fatal(err)
	}

	dest := filepath.Join(dir, "out")
	if err := extractZip(zipPath, dest); err != nil {
		t.Fatalf("extractZip: %v", err)
	}
	if !fileExists(filepath.Join(dest, "libmpv.xcframework/Info.plist")) {
		t.Error("regular file not extracted")
	}
	target, err := os.Readlink(filepath.Join(dest, "libmpv.xcframework/Current"))
	if err != nil {
		t.Fatalf("symlink not created: %v", err)
	}
	if target != "Versions/A" {
		t.Errorf("symlink target = %q, want Versions/A", target)
	}
}
