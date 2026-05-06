// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Libs source switch. mpv_audio_kit consumes the prebuilt libmpv per platform
// either from a bundled local copy or by downloading it from this repo's GitHub
// Releases. Four of the five build systems (CMake on Linux/Windows, Gradle on
// Android, CocoaPods on iOS/macOS) already "use local if present, else
// download"; SwiftPM is a hard either/or. To switch them uniformly without
// rewriting that logic, each consumer file wraps its toggleable region in
//
//	<comment> mpvkit:<mode>:begin   …region…   <comment> mpvkit:<mode>:end
//
// markers, and the three Libs actions comment / uncomment those regions:
//
//   - local  → use the bundled binary only, never download (download regions
//     commented; SwiftPM's local `path:` region active). Reuses the Checksums
//     install so the bundled binaries + their SHAs are refreshed first.
//   - remote → download from GitHub when the local copy is absent / stale
//     (download regions active; SwiftPM's `url:+checksum:` region active).
//   - clean  → delete the bundled binaries from every platform slot, so a
//     remote build has nothing stale to fall back to.
//
// The marker lines themselves are always comments and are never toggled.

type libMode int

const (
	libLocal libMode = iota
	libRemote
)

func (m libMode) String() string {
	if m == libRemote {
		return "remote"
	}
	return "local"
}

// libToggleFile is one consumer build file plus its line-comment token.
type libToggleFile struct {
	rel   string
	token string
}

// libToggleFiles lists every mpv_audio_kit file whose mpvkit: regions the Libs
// actions drive. Kept in lockstep with the markers added to the consumer repo.
func libToggleFiles() []libToggleFile {
	return []libToggleFile{
		{"ios/mpv_audio_kit/Package.swift", "//"},
		{"macos/mpv_audio_kit/Package.swift", "//"},
		{"ios/mpv_audio_kit.podspec", "#"},
		{"macos/mpv_audio_kit.podspec", "#"},
		{"android/build.gradle.kts", "//"},
		{"linux/CMakeLists.txt", "#"},
		{"windows/CMakeLists.txt", "#"},
	}
}

// libBinaryPath is one bundled-binary slot in the consumer package, removed by
// the clean action.
type libBinaryPath struct {
	label string
	rel   string
}

func libBinaryPaths() []libBinaryPath {
	return []libBinaryPath{
		{"macos xcframework", "macos/mpv_audio_kit/Frameworks/libmpv.xcframework"},
		{"ios xcframework", "ios/mpv_audio_kit/Frameworks/libmpv.xcframework"},
		{"android arm64-v8a", "android/src/main/jniLibs/arm64-v8a/libmpv.so"},
		{"android armeabi-v7a", "android/src/main/jniLibs/armeabi-v7a/libmpv.so"},
		{"android x86_64", "android/src/main/jniLibs/x86_64/libmpv.so"},
		{"linux x86_64", "linux/libs/x86_64/libmpv.so"},
		{"linux aarch64", "linux/libs/aarch64/libmpv.so"},
		{"windows x86_64", "windows/libs/x86_64/libmpv.dll"},
		{"windows arm64", "windows/libs/arm64/libmpv.dll"},
	}
}

// ── marker-driven comment/uncomment ─────────────────────────────────────────

func leadingWS(s string) string {
	return s[:len(s)-len(strings.TrimLeft(s, " \t"))]
}

// lineCommented reports whether line's first non-whitespace run is the token.
func lineCommented(line, token string) bool {
	return strings.HasPrefix(strings.TrimLeft(line, " \t"), token)
}

// commentLine prefixes the comment token to a line, preserving its indentation.
// Blank and already-commented lines are returned unchanged (idempotent).
func commentLine(line, token string) string {
	if strings.TrimSpace(line) == "" || lineCommented(line, token) {
		return line
	}
	ws := leadingWS(line)
	return ws + token + " " + line[len(ws):]
}

// uncommentLine strips one leading comment token (and at most one following
// space), preserving indentation. Non-commented lines are returned unchanged.
func uncommentLine(line, token string) string {
	if !lineCommented(line, token) {
		return line
	}
	ws := leadingWS(line)
	rest := strings.TrimPrefix(line[len(ws):], token)
	rest = strings.TrimPrefix(rest, " ")
	return ws + rest
}

// parseLibMarker returns (mode, edge, true) when line is an `mpvkit:<mode>:<edge>`
// marker for the given comment token.
func parseLibMarker(line, token string) (mode, edge string, ok bool) {
	t := strings.TrimLeft(line, " \t")
	if !strings.HasPrefix(t, token) {
		return "", "", false
	}
	t = strings.TrimSpace(strings.TrimPrefix(t, token))
	if !strings.HasPrefix(t, "mpvkit:") {
		return "", "", false
	}
	parts := strings.Split(t, ":")
	if len(parts) != 3 || (parts[1] != "local" && parts[1] != "remote") ||
		(parts[2] != "begin" && parts[2] != "end") {
		return "", "", false
	}
	return parts[1], parts[2], true
}

// libToggleContent rewrites content so the regions tagged with the target mode
// are uncommented (active) and all other mpvkit regions are commented (inert).
// It returns the new content, the before/after edits, and the number of marker
// regions it saw (0 ⇒ the file has no mpvkit markers).
func libToggleContent(content, token string, mode libMode) (string, []csEdit, int) {
	lines := strings.Split(content, "\n")
	var edits []csEdit
	cur := "" // mode of the region we're inside, "" when outside
	regions := 0
	for i, line := range lines {
		if m, edge, ok := parseLibMarker(line, token); ok {
			if edge == "begin" {
				cur, regions = m, regions+1
			} else {
				cur = ""
			}
			continue // marker lines are never toggled
		}
		if cur == "" {
			continue
		}
		var nl string
		if cur == mode.String() {
			nl = uncommentLine(line, token)
		} else {
			nl = commentLine(line, token)
		}
		if nl != line {
			edits = append(edits, csEdit{Old: strings.TrimSpace(line), New: strings.TrimSpace(nl)})
			lines[i] = nl
		}
	}
	return strings.Join(lines, "\n"), edits, regions
}

// ── current-mode detection ──────────────────────────────────────────────────

// libFileMode reports the mode one consumer file is currently in by checking
// which of its mpvkit regions is active (uncommented):
//   - both local+remote regions (SwiftPM): the active one wins; both/neither
//     active ⇒ "mixed".
//   - only a remote region (CMake / Gradle / podspec): active ⇒ "remote",
//     commented ⇒ "local" (local use is unconditional there).
//
// Returns "unknown" when the file has no mpvkit markers.
func libFileMode(content, token string) string {
	cur := ""
	var hasLocal, hasRemote, localActive, remoteActive bool
	for _, line := range strings.Split(content, "\n") {
		if mode, edge, ok := parseLibMarker(line, token); ok {
			if edge == "begin" {
				cur = mode
				if mode == "local" {
					hasLocal = true
				} else {
					hasRemote = true
				}
			} else {
				cur = ""
			}
			continue
		}
		if cur == "" || strings.TrimSpace(line) == "" {
			continue
		}
		if !lineCommented(line, token) { // an active (uncommented) body line
			if cur == "local" {
				localActive = true
			} else {
				remoteActive = true
			}
		}
	}
	switch {
	case hasLocal && hasRemote:
		switch {
		case localActive && !remoteActive:
			return "local"
		case remoteActive && !localActive:
			return "remote"
		default:
			return "mixed"
		}
	case hasRemote:
		if remoteActive {
			return "remote"
		}
		return "local"
	case hasLocal:
		if localActive {
			return "local"
		}
		return "remote"
	default:
		return "unknown"
	}
}

// libDetectMode inspects every consumer file and returns the package's overall
// libs source: "local", "remote", "mixed" (files disagree — e.g. mid-switch or
// hand-edited), or "unknown" (a file is missing / unmarked).
func libDetectMode(repoRoot string) string {
	seen := ""
	for _, f := range libToggleFiles() {
		data, err := os.ReadFile(filepath.Join(repoRoot, f.rel))
		if err != nil {
			return "unknown"
		}
		m := libFileMode(string(data), f.token)
		if m == "mixed" || m == "unknown" {
			return m
		}
		if seen == "" {
			seen = m
		} else if seen != m {
			return "mixed"
		}
	}
	if seen == "" {
		return "unknown"
	}
	return seen
}

// libSetMode toggles every consumer file to the given mode and returns a
// per-file result (with diffs) plus an aggregate error if any file failed.
func libSetMode(repoRoot string, mode libMode) ([]csEntry, error) {
	var entries []csEntry
	var failed int
	for _, f := range libToggleFiles() {
		e := csEntry{Label: f.rel, Dest: f.rel}
		path := filepath.Join(repoRoot, f.rel)
		data, err := os.ReadFile(path)
		if err != nil {
			e.Status, e.Message = "error", "not found: "+f.rel
			failed++
			entries = append(entries, e)
			continue
		}
		out, edits, regions := libToggleContent(string(data), f.token, mode)
		if regions == 0 {
			e.Status, e.Message = "error", "no mpvkit: markers"
			failed++
			entries = append(entries, e)
			continue
		}
		if out != string(data) {
			if err := os.WriteFile(path, []byte(out), 0o644); err != nil {
				e.Status, e.Message = "error", err.Error()
				failed++
				entries = append(entries, e)
				continue
			}
		}
		e.Status, e.Edits = "ok", edits
		if len(edits) == 0 {
			e.Message = "already " + mode.String()
		}
		entries = append(entries, e)
	}
	if failed > 0 {
		return entries, fmt.Errorf("%d consumer file(s) could not be switched to %s — is mpv_audio_kit at %s up to date?", failed, mode, repoRoot)
	}
	return entries, nil
}

// libClean removes the bundled libmpv from every platform slot in the consumer
// package, returning a per-slot result.
func libClean(repoRoot string) ([]csEntry, error) {
	var entries []csEntry
	for _, b := range libBinaryPaths() {
		e := csEntry{Label: b.label, Dest: b.rel}
		path := filepath.Join(repoRoot, b.rel)
		if !pathExists(path) {
			e.Status, e.Message = "skipped", "already absent"
			entries = append(entries, e)
			continue
		}
		if err := os.RemoveAll(path); err != nil {
			e.Status, e.Message = "error", err.Error()
			entries = append(entries, e)
			continue
		}
		e.Status, e.Message = "ok", "removed"
		entries = append(entries, e)
	}
	return entries, nil
}

func pathExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// ── action entry points (TUI goroutine + CLI both call these) ───────────────

// libRunLocal installs the freshly-built binaries (Checksums step — best effort:
// missing builds are reported, not fatal) and then locks every platform to the
// local copy. The mode switch is the essential part; install just refreshes the
// bundled binaries + their SHAs when a build is present.
func libRunLocal(ctx *buildCtx) ([]csEntry, error) {
	entries, _ := runChecksumsCollect(ctx) // per-entry status carries skips
	toggled, err := libSetMode(ctx.repoRoot, libLocal)
	return append(entries, toggled...), err
}

// libRunRemote switches every platform to download-from-GitHub-when-absent.
func libRunRemote(ctx *buildCtx) ([]csEntry, error) {
	return libSetMode(ctx.repoRoot, libRemote)
}

// libRunClean removes the bundled binaries from the consumer package.
func libRunClean(ctx *buildCtx) ([]csEntry, error) {
	return libClean(ctx.repoRoot)
}

// runLibActionCollect dispatches one Libs action by key and returns its
// per-file result — the single source of truth shared by the TUI screen and the
// headless CLI runner.
func runLibActionCollect(ctx *buildCtx, key string) ([]csEntry, error) {
	switch key {
	case "lib-local":
		return libRunLocal(ctx)
	case "lib-remote":
		return libRunRemote(ctx)
	case "lib-clean":
		return libRunClean(ctx)
	default:
		return nil, fmt.Errorf("unknown libs action: %s", key)
	}
}

// runLibAction is the headless (CLI / kSelf) entry point for the three Libs
// actions; it streams a plain-text summary to logf.
func runLibAction(ctx *buildCtx, key string, logf func(string)) error {
	verb := map[string]string{
		"lib-local":  "use local libmpv (no GitHub download)",
		"lib-remote": "use remote libmpv (download from GitHub when absent)",
		"lib-clean":  "clean bundled libmpv from mpv_audio_kit",
	}[key]
	entries, err := runLibActionCollect(ctx, key)
	logf("=== mpv_audio_kit: " + verb + " ===")
	for _, e := range entries {
		switch e.Status {
		case "ok":
			var detail string
			switch {
			case e.Hash != "": // a Checksums install entry (lib-local)
				detail = "installed → " + e.Dest
			case e.Message != "":
				detail = e.Message
			default:
				detail = fmt.Sprintf("%d change(s)", len(e.Edits))
			}
			logf(fmt.Sprintf("  ✓ %s: %s", e.Label, detail))
		case "skipped":
			logf(fmt.Sprintf("  · %s: %s", e.Label, e.Message))
		case "error":
			logf(fmt.Sprintf("  ✗ %s: %s", e.Label, e.Message))
		}
	}
	return err
}
