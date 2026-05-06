// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"context"
	"fmt"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// dockerProgressLine turns a captured `docker build` output line into a compact
// status. BuildKit plain progress prefixes each line with a step id and an
// elapsed timestamp ("#8 12.34 Setting up …"); strip both so the bare step text
// is what shows on the dashboard. Non-BuildKit / other lines pass through.
func dockerProgressLine(s string) string {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, "#") {
		return s
	}
	f := strings.Fields(s)
	rest := f[1:] // drop the "#<n>" step id
	if len(rest) > 0 {
		if _, err := strconv.ParseFloat(rest[0], 64); err == nil {
			rest = rest[1:] // drop the elapsed-seconds timestamp
		}
	}
	return strings.Join(rest, " ")
}

// dockerImage describes one buildable multi-stage image. The kit builds, tracks
// and deletes these individually (Docker tab) so you only keep the toolchains
// you actually use on disk.
type dockerImage struct {
	stage string // Dockerfile --target stage; the image is mpv-build-<stage>
	label string
	desc  string
}

// dockerImages is the source of truth for the multi-stage image set, in display
// order. Kept in sync with docker/Dockerfile's stages and targets.go's `image`.
func dockerImages() []dockerImage {
	return []dockerImage{
		{"linux", "Linux", "GCC cross (x86_64 + aarch64) + audio/X11 dev libs"},
		{"windows", "Windows", "GNU MinGW-w64 (x86_64) + llvm-mingw (arm64)"},
		{"android", "Android", "base toolchain; the NDK is fetched per build"},
		{"verify", "Verify", "all cross-compilers + qemu + Wine for the load tests"},
	}
}

// dockerImageName maps a stage to its tagged image name.
func dockerImageName(stage string) string { return "mpv-build-" + stage }

// dockerImageStatus is one image's on-disk state for the Docker tab.
type dockerImageStatus struct {
	present bool
	size    string // human-readable ("1.2GB"); "" when absent / daemon down
}

// queryDockerImages reports, per stage, whether mpv-build-<stage> exists and its
// size. `up` is the (already-determined) daemon state — passed in so callers
// query the daemon once, not once per call. Returns all-absent when down. Each
// `docker images` call is bounded by a short timeout. NOT for the render path —
// it execs subprocesses; call it on tab-enter / after an action and cache.
func queryDockerImages(up bool) map[string]dockerImageStatus {
	out := map[string]dockerImageStatus{}
	for _, im := range dockerImages() {
		if !up {
			out[im.stage] = dockerImageStatus{}
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		b, err := exec.CommandContext(ctx, "docker", "images", dockerImageName(im.stage), "--format", "{{.Size}}").Output()
		cancel()
		size := strings.TrimSpace(string(b))
		if i := strings.IndexByte(size, '\n'); i >= 0 { // multiple tags → first line
			size = size[:i]
		}
		out[im.stage] = dockerImageStatus{present: err == nil && size != "", size: size}
	}
	return out
}

// deleteDockerImage removes mpv-build-<stage> (force: drop it even if tagged /
// referenced). Shared layers stay until the last image referencing them is gone.
func deleteDockerImage(stage string) error {
	return exec.Command("docker", "rmi", "-f", dockerImageName(stage)).Run()
}

// dockerStepMsg is the human description of a prepended Docker prep step, shown
// in the dashboard / verify prep banners.
func dockerStepMsg(key string) string {
	switch {
	case key == "docker-start":
		return "starting the Docker daemon"
	case strings.HasPrefix(key, "docker-image-"):
		stage := strings.TrimPrefix(key, "docker-image-")
		return "building the " + stage + " Docker image (first run)"
	default:
		return "preparing build environment"
	}
}

// dockerDaemonRunning reports whether the Docker daemon is reachable. The query
// is bounded by a short timeout so a half-started daemon can't hang the caller.
func dockerDaemonRunning() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "docker", "info", "--format", "{{.ServerVersion}}").Run() == nil
}

// ensureDockerRunning makes sure the Docker daemon is up: if it isn't, it
// launches Docker for the current OS and waits (streaming progress to logf)
// until the daemon answers or a timeout elapses. Safe to call when Docker is
// already running — it returns immediately.
func ensureDockerRunning(logf func(string)) error {
	if dockerDaemonRunning() {
		logf("Docker daemon already running.")
		return nil
	}
	logf("Docker daemon is not running — launching Docker…")
	if err := startDockerDaemon(); err != nil {
		return fmt.Errorf("could not start Docker automatically (%v); start Docker manually and retry", err)
	}

	const timeout = 150 * time.Second
	logf("Waiting for the Docker daemon to become ready (first launch can take a minute)…")
	start := time.Now()
	nextTick := 8
	for time.Since(start) < timeout {
		if dockerDaemonRunning() {
			logf(fmt.Sprintf("Docker daemon ready after %ds.", int(time.Since(start).Seconds())))
			return nil
		}
		time.Sleep(2 * time.Second)
		if s := int(time.Since(start).Seconds()); s >= nextTick {
			logf(fmt.Sprintf("  …still starting (%ds)", s))
			nextTick = s + 8
		}
	}
	return fmt.Errorf("timed out after %s waiting for the Docker daemon to start", timeout)
}

// startDockerDaemon launches the platform's Docker service / desktop app. It
// returns once the launch was *initiated* — readiness is polled separately.
func startDockerDaemon() error {
	switch runtime.GOOS {
	case "darwin":
		// Docker Desktop registers as the "Docker" app.
		return exec.Command("open", "-a", "Docker").Run()
	case "windows":
		for _, p := range []string{
			`C:\Program Files\Docker\Docker\Docker Desktop.exe`,
			`C:\Program Files\Docker\Docker\frontend\Docker Desktop.exe`,
		} {
			if fileExists(p) {
				return exec.Command(p).Start()
			}
		}
		return fmt.Errorf("Docker Desktop.exe not found in the default location")
	case "linux":
		// Rootful systemd service is the common case; fall back to Docker
		// Desktop's per-user service. (A rootful start may need privileges — if
		// it fails, the caller surfaces a "start it manually" message.)
		if exec.Command("systemctl", "start", "docker").Run() == nil {
			return nil
		}
		if exec.Command("systemctl", "--user", "start", "docker-desktop").Run() == nil {
			return nil
		}
		return fmt.Errorf("could not start the docker service — try: sudo systemctl start docker")
	default:
		return fmt.Errorf("automatic start is unsupported on %s", runtime.GOOS)
	}
}
