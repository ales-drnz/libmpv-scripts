// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// Checksums step, reimplemented in Go so it runs on every host (Windows
// included) with no bash. It mirrors scripts/generate_checksums.sh:
//   - SHA-256 each binary present in builds/release/,
//   - write that hash into the consumer package's build files,
//   - copy / extract each artifact into its per-platform slot.
// Binaries that weren't built are skipped (not an error); it only fails when
// builds/release/ is empty.

// csEdit is one before/after line pair produced by a checksum rewrite — the
// unit the Checksums diff view renders.
type csEdit struct {
	File string // package-relative path of the edited file
	Old  string // line before the rewrite
	New  string // line after the rewrite
}

// csEntry is the per-artifact result: its hash, where the binary was installed,
// the files it touched (with diffs), and a status.
type csEntry struct {
	Label   string
	Status  string // "ok" | "skipped" | "error"
	Hash    string
	Dest    string // package-relative install destination
	Edits   []csEdit
	Message string // skip reason / error text
}

// csArtifact maps one release binary to its install + checksum-rewrite step.
type csArtifact struct {
	label   string
	relFile string // filename under builds/release/
	// install copies/extracts the binary and rewrites every checksum that
	// references it, returning the package-relative destination and the diffs.
	install func(src, hash string) (dest string, edits []csEdit, err error)
}

// csArtifacts is the SINGLE source of truth for what the checksums step does —
// shared by the headless runChecksums (CLI) and the TUI's collecting runner, so
// the install destinations and edited files can never drift between the two.
func csArtifacts(root string) []csArtifact {
	p := func(rel string) string { return filepath.Join(root, rel) }

	return []csArtifact{
		// ── macOS xcframework ──
		{label: "macos xcframework", relFile: "libmpv_macos.xcframework.zip",
			install: func(src, h string) (string, []csEdit, error) {
				ed, err := rewriteAll(
					rw(p("macos/mpv_audio_kit.podspec"), "macos/mpv_audio_kit.podspec", rePodspecSHA, `EXPECTED_SHA256="`+h+`"`),
					rw(p("macos/mpv_audio_kit/Package.swift"), "macos/mpv_audio_kit/Package.swift", reSwiftChecksum, `${1}`+h),
				)
				if err != nil {
					return "", nil, err
				}
				dest := "macos/mpv_audio_kit/Frameworks"
				return dest, ed, extractXCFramework(src, p(dest))
			}},

		// ── iOS xcframework ──
		{label: "ios xcframework", relFile: "libmpv_ios.xcframework.zip",
			install: func(src, h string) (string, []csEdit, error) {
				ed, err := rewriteAll(
					rw(p("ios/mpv_audio_kit.podspec"), "ios/mpv_audio_kit.podspec", rePodspecSHA, `EXPECTED_SHA256="`+h+`"`),
					rw(p("ios/mpv_audio_kit/Package.swift"), "ios/mpv_audio_kit/Package.swift", reSwiftChecksum, `${1}`+h),
				)
				if err != nil {
					return "", nil, err
				}
				dest := "ios/mpv_audio_kit/Frameworks"
				return dest, ed, extractXCFramework(src, p(dest))
			}},

		// ── Android ABIs ──
		androidArtifact(p, "arm64-v8a"),
		androidArtifact(p, "armeabi-v7a"),
		androidArtifact(p, "x86_64"),

		// ── Linux ──
		linuxArtifact(p, "x86_64", "EXPECTED_SHA256_X86_64"),
		linuxArtifact(p, "aarch64", "EXPECTED_SHA256_AARCH64"),

		// ── Windows ──
		windowsArtifact(p, "x86_64", "EXPECTED_SHA256_X86_64"),
		windowsArtifact(p, "arm64", "EXPECTED_SHA256_ARM64"),
	}
}

func androidArtifact(p func(string) string, abi string) csArtifact {
	gradleRel := "android/build.gradle.kts"
	destRel := "android/src/main/jniLibs/" + abi + "/libmpv.so"
	return csArtifact{
		label:   "android " + abi,
		relFile: "libmpv_android-" + abi + ".so",
		install: func(src, h string) (string, []csEdit, error) {
			if err := copyFile(src, p(destRel)); err != nil {
				return "", nil, err
			}
			ed, err := rewriteAll(rw(p(gradleRel), gradleRel, reAndroidSHA(abi), `${1}`+h))
			return destRel, ed, err
		},
	}
}

func linuxArtifact(p func(string) string, arch, varName string) csArtifact {
	cmakeRel := "linux/CMakeLists.txt"
	destRel := "linux/libs/" + arch + "/libmpv.so"
	return csArtifact{
		label:   "linux " + arch,
		relFile: "libmpv_linux-" + arch + ".so",
		install: func(src, h string) (string, []csEdit, error) {
			if err := copyFile(src, p(destRel)); err != nil {
				return "", nil, err
			}
			ed, err := rewriteAll(rw(p(cmakeRel), cmakeRel, reCMakeSHA(varName), `set(`+varName+`  "`+h+`")`))
			return destRel, ed, err
		},
	}
}

func windowsArtifact(p func(string) string, arch, varName string) csArtifact {
	cmakeRel := "windows/CMakeLists.txt"
	destRel := "windows/libs/" + arch + "/libmpv.dll"
	return csArtifact{
		label:   "windows " + arch,
		relFile: "libmpv_windows-" + arch + ".dll",
		install: func(src, h string) (string, []csEdit, error) {
			if err := copyFile(src, p(destRel)); err != nil {
				return "", nil, err
			}
			ed, err := rewriteAll(rw(p(cmakeRel), cmakeRel, reCMakeSHA(varName), `set(`+varName+`  "`+h+`")`))
			return destRel, ed, err
		},
	}
}

// runChecksumsCollect performs the install-and-checksum step and returns a
// structured per-artifact result (with file diffs) for the TUI. It also IS the
// implementation — the file edits happen here.
func runChecksumsCollect(ctx *buildCtx) ([]csEntry, error) {
	release := filepath.Join(ctx.scriptsRoot, "builds", "release")
	var entries []csEntry
	found := 0

	for _, a := range csArtifacts(ctx.repoRoot) {
		e := csEntry{Label: a.label}
		src := filepath.Join(release, a.relFile)
		if !fileExists(src) {
			e.Status, e.Message = "skipped", "not built"
			entries = append(entries, e)
			continue
		}
		h, err := sha256File(src)
		if err != nil {
			e.Status, e.Message = "error", err.Error()
			entries = append(entries, e)
			continue
		}
		e.Hash = h
		dest, edits, err := a.install(src, h)
		if err != nil {
			e.Status, e.Message = "error", err.Error()
			entries = append(entries, e)
			continue
		}
		e.Status, e.Dest, e.Edits = "ok", dest, edits
		found++
		entries = append(entries, e)
	}

	if found == 0 {
		return entries, fmt.Errorf("no release binaries found in %s — build something first", release)
	}
	return entries, nil
}

// runChecksums is the headless (CLI / kSelf) entry point: it runs the collecting
// implementation and streams a plain-text summary to logf.
func runChecksums(ctx *buildCtx, logf func(string)) error {
	logf("=== mpv_audio_kit: updating checksums + copying libraries ===")
	entries, err := runChecksumsCollect(ctx)
	found, missing := 0, 0
	for _, e := range entries {
		switch e.Status {
		case "ok":
			found++
			logf(fmt.Sprintf("  ✓ %s: %s", e.Label, e.Hash))
		case "skipped":
			missing++
			logf(fmt.Sprintf("  %s: skipped (not built)", e.Label))
		case "error":
			missing++
			logf(fmt.Sprintf("  ✗ %s: %s", e.Label, e.Message))
		}
	}
	if err != nil {
		return err
	}
	if missing > 0 {
		logf(fmt.Sprintf("Updated %d binary(s); skipped %d not present in release.", found, missing))
	} else {
		logf(fmt.Sprintf("All %d release binary(s) checksummed and copied.", found))
	}
	return nil
}

// ── checksum rewrite + diff capture ─────────────────────────────────────────

// rewriteSpec describes one in-place regex rewrite of a checksum in a file.
type rewriteSpec struct {
	path    string
	display string
	re      *regexp.Regexp
	repl    string
}

func rw(path, display string, re *regexp.Regexp, repl string) rewriteSpec {
	return rewriteSpec{path: path, display: display, re: re, repl: repl}
}

func rewriteAll(specs ...rewriteSpec) ([]csEdit, error) {
	var out []csEdit
	for _, s := range specs {
		e, err := rewriteSHA(s)
		if err != nil {
			return nil, err
		}
		out = append(out, e...)
	}
	return out, nil
}

// rewriteSHA applies one rewrite in place and returns the changed line(s) as
// before/after pairs. The checksum edits are always in-line (the line count is
// preserved), so a line-by-line diff cleanly isolates exactly what changed.
func rewriteSHA(s rewriteSpec) ([]csEdit, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return nil, err
	}
	out := s.re.ReplaceAll(data, []byte(s.repl))
	if string(out) == string(data) {
		return nil, nil // nothing matched — leave as-is (sed parity)
	}
	if err := os.WriteFile(s.path, out, 0o644); err != nil {
		return nil, err
	}
	oldLines := strings.Split(string(data), "\n")
	newLines := strings.Split(string(out), "\n")
	n := len(oldLines)
	if len(newLines) < n {
		n = len(newLines)
	}
	var edits []csEdit
	for i := 0; i < n; i++ {
		if oldLines[i] != newLines[i] {
			edits = append(edits, csEdit{
				File: s.display,
				Old:  strings.TrimSpace(oldLines[i]),
				New:  strings.TrimSpace(newLines[i]),
			})
		}
	}
	return edits, nil
}

// ── regex patterns (match the sed/perl in generate_checksums.sh) ────────────
var (
	rePodspecSHA    = regexp.MustCompile(`EXPECTED_SHA256="[a-f0-9]{64}"`)
	reSwiftChecksum = regexp.MustCompile(`(checksum:\s*")[a-f0-9]{64}`)
)

func reAndroidSHA(abi string) *regexp.Regexp {
	return regexp.MustCompile(`("file" to "` + regexp.QuoteMeta("libmpv_android-"+abi+".so") + `",\s*"sha256" to ")[a-f0-9]{64}`)
}

func reCMakeSHA(varName string) *regexp.Regexp {
	return regexp.MustCompile(`set\(` + regexp.QuoteMeta(varName) + `\s+"[a-f0-9]{64}"\)`)
}

// ── helpers ─────────────────────────────────────────────────────────────────

func sha256File(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func copyFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

// extractXCFramework removes any existing libmpv.xcframework under destDir and
// extracts the zip there, preserving the versioned-bundle symlinks.
func extractXCFramework(zipPath, destDir string) error {
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return err
	}
	_ = os.RemoveAll(filepath.Join(destDir, "libmpv.xcframework"))
	return extractZip(zipPath, destDir)
}

func extractZip(zipPath, destDir string) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer r.Close()
	cleanDest := filepath.Clean(destDir)
	for _, f := range r.File {
		p := filepath.Join(destDir, f.Name)
		// zip-slip guard
		if p != cleanDest && !pathInside(cleanDest, p) {
			continue
		}
		info := f.FileInfo()
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			rc, err := f.Open()
			if err != nil {
				return err
			}
			target, err := io.ReadAll(rc)
			rc.Close()
			if err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				return err
			}
			_ = os.Remove(p)
			if err := os.Symlink(string(target), p); err != nil {
				return err
			}
		case info.IsDir():
			if err := os.MkdirAll(p, 0o755); err != nil {
				return err
			}
		default:
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				return err
			}
			rc, err := f.Open()
			if err != nil {
				return err
			}
			out, err := os.OpenFile(p, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
			if err != nil {
				rc.Close()
				return err
			}
			_, cpErr := io.Copy(out, rc)
			out.Close()
			rc.Close()
			if cpErr != nil {
				return cpErr
			}
		}
	}
	return nil
}

func pathInside(parent, p string) bool {
	rel, err := filepath.Rel(parent, p)
	if err != nil {
		return false
	}
	return rel != ".." && !hasDotDotPrefix(rel)
}

func hasDotDotPrefix(rel string) bool {
	return len(rel) >= 3 && rel[0] == '.' && rel[1] == '.' && (rel[2] == '/' || rel[2] == '\\')
}
