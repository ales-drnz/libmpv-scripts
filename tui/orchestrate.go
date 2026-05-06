// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// dockerPlatformFor returns the docker --platform for a target: an explicit pin
// (android → linux/amd64, since the NDK is x86_64-only) or, by default, the host
// arch so linux/windows/verify build & run NATIVE (no emulation). Explicit here
// instead of `FROM --platform=$BUILDPLATFORM` in the Dockerfile, which would pin
// every stage to the host arch and break the android amd64 build.
func dockerPlatformFor(t Target) string {
	if t.dockerPlatform != "" {
		return t.dockerPlatform
	}
	return "linux/" + runtime.GOARCH
}

// buildCtx holds the resolved paths the build commands need. It replaces the
// Makefile's REPO_ROOT / DOCKER_RUN / NDK-mount machinery.
type buildCtx struct {
	scriptsRoot string // the libmpv-scripts checkout (holds scripts/, docker/, tui/)
	repoRoot    string // the mpv_audio_kit package (build outputs land here)
	ndkSysroot  string // host NDK sysroot for verify's Android layer, or ""
	// androidForceDocker pins the Android build to Docker even on macOS (default
	// false ⇒ native host build on Apple Silicon). The TUI sets it from
	// settings.ForceAndroidDocker before each build; the CLI reads it from the
	// ANDROID_FORCE_DOCKER env var.
	androidForceDocker bool
}

// resolveNative returns t adjusted for where it should actually run: a
// nativeOnDarwin target (Android) runs on the host (kNative, native NDK, no
// Docker) when on macOS and not forced to Docker; otherwise it's unchanged
// (Docker). Off macOS it's always unchanged.
func (c *buildCtx) resolveNative(t Target) Target {
	if t.nativeOnDarwin && hostOS == "darwin" && !c.androidForceDocker {
		t.kind = kNative
		t.image = ""
	}
	return t
}

func newBuildCtx() (*buildCtx, error) {
	sr, err := findScriptsRoot()
	if err != nil {
		return nil, err
	}
	rr, err := resolveRepoRoot(sr)
	if err != nil {
		return nil, err
	}
	return &buildCtx{
		scriptsRoot:        sr,
		repoRoot:           rr,
		ndkSysroot:         findNDK(),
		androidForceDocker: os.Getenv("ANDROID_FORCE_DOCKER") == "1",
	}, nil
}

// findScriptsRoot walks up from the working directory to the libmpv-scripts
// root, identified by scripts/shared/_helpers.sh + a docker/ dir.
func findScriptsRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if fileExists(filepath.Join(dir, "scripts", "shared", "_helpers.sh")) &&
			dirExists(filepath.Join(dir, "docker")) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("not inside a libmpv-scripts checkout (no scripts/shared/_helpers.sh found)")
		}
		dir = parent
	}
}

// resolveRepoRoot mirrors scripts/shared/_helpers.sh::resolve_repo_root in
// pure Go (so it works on Windows too): MPV_AUDIO_KIT_ROOT, then a sibling
// mpv_audio_kit/ checkout, then a legacy nested layout.
func resolveRepoRoot(scriptsRoot string) (string, error) {
	if env := os.Getenv("MPV_AUDIO_KIT_ROOT"); env != "" {
		if isMpvAudioKit(env) {
			abs, _ := filepath.Abs(env)
			return abs, nil
		}
		return "", fmt.Errorf("MPV_AUDIO_KIT_ROOT=%q is not an mpv_audio_kit checkout", env)
	}
	// Sibling mpv_audio_kit/ at any ancestor (production layout).
	for dir := scriptsRoot; ; {
		if cand := filepath.Join(filepath.Dir(dir), "mpv_audio_kit"); isMpvAudioKit(cand) {
			abs, _ := filepath.Abs(cand)
			return abs, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	// Legacy: an ancestor that IS the mpv_audio_kit checkout.
	for dir := scriptsRoot; ; {
		if isMpvAudioKit(dir) {
			abs, _ := filepath.Abs(dir)
			return abs, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("could not locate the mpv_audio_kit repo — " +
		"clone it next to libmpv-scripts, or set MPV_AUDIO_KIT_ROOT=/path/to/mpv_audio_kit")
}

func isMpvAudioKit(dir string) bool {
	p := filepath.Join(dir, "pubspec.yaml")
	data, err := os.ReadFile(p)
	if err != nil {
		return false
	}
	for _, ln := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(strings.TrimSpace(ln), "name: mpv_audio_kit") {
			return true
		}
	}
	return false
}

// findNDK locates a host NDK sysroot (for verify's Android symbol layer).
// Returns "" when none is found — verify then skips Android with a warning.
func findNDK() string {
	home, _ := os.UserHomeDir()
	patterns := []string{
		filepath.Join(home, "Library/Android/sdk/ndk/*/toolchains/llvm/prebuilt/*/sysroot/usr/lib"),
		filepath.Join(home, "Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/sysroot/usr/lib"),
		"/usr/local/lib/android/sdk/ndk/*/toolchains/llvm/prebuilt/*/sysroot/usr/lib",
	}
	for _, pat := range patterns {
		if hits, _ := filepath.Glob(pat); len(hits) > 0 {
			return hits[0]
		}
	}
	return ""
}

// dockerEnvArgs forwards the optional throttle env vars into the container,
// matching the Makefile's DOCKER_ENV.
func dockerEnvArgs() []string {
	args := []string{"-e", "MPV_AUDIO_KIT_ROOT=/repo"}
	for _, k := range []string{"JOBS", "ENABLE_LTO_DEPS", "FORCE_DOWNLOAD", "KEEP_BUILD", "WIPE_ALL"} {
		if v := os.Getenv(k); v != "" {
			args = append(args, "-e", k+"="+v)
		}
	}
	return args
}

// selfExe returns the path to the running orchestrator binary, so kSelf targets
// can re-exec it with a hidden subcommand.
func selfExe() string {
	if exe, err := os.Executable(); err == nil {
		return exe
	}
	return os.Args[0]
}

// command builds the argv + extra env for a target. The returned cmd has its
// Dir set to the scripts root.
func (c *buildCtx) command(t Target) *exec.Cmd {
	var argv []string
	switch t.kind {
	case kNative:
		argv = append([]string{"bash", filepath.Join(c.scriptsRoot, t.script)}, t.args...)
	case kImage:
		// Build just this stage of the multi-stage Dockerfile, tagged
		// mpv-build-<stage>. The shared `base` layers are reused across stages.
		// --progress=plain makes BuildKit emit one line per step/log (no TTY
		// cursor tricks), so the dashboard can surface the current step live.
		argv = []string{"docker", "build", "--progress=plain", "--platform", dockerPlatformFor(t),
			"--target", t.image, "-t", dockerImageName(t.image), "./docker/"}
	case kDocker:
		// Pin the platform: host-native for linux/windows/verify, linux/amd64 for
		// android (its NDK is x86_64-only — native there, Rosetta-accelerated on
		// Apple Silicon).
		argv = []string{"docker", "run", "--rm", "--platform", dockerPlatformFor(t)}
		argv = append(argv, dockerEnvArgs()...)
		// Forward the target's own env (e.g. ABIS for the Android build, which
		// now runs in the container) into the container.
		for _, kv := range t.env {
			argv = append(argv, "-e", kv)
		}
		argv = append(argv,
			"-v", c.repoRoot+":/repo",
			"-v", c.scriptsRoot+":/scripts",
			"-w", "/scripts")
		if t.ndk && c.ndkSysroot != "" {
			argv = append(argv, "-v", c.ndkSysroot+":/ndk-sysroot:ro")
		}
		argv = append(argv, dockerImageName(t.image), "bash", t.script)
		argv = append(argv, t.args...)
	case kSelf:
		// Run the orchestrator itself with a hidden subcommand (cross-platform
		// Go steps like checksums) — works on any host, no bash/Docker.
		argv = []string{selfExe(), t.selfArg}
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = c.scriptsRoot
	cmd.Env = append(os.Environ(), t.env...)
	return cmd
}

func dockerImageExists(image string) bool {
	return exec.Command("docker", "image", "inspect", image).Run() == nil
}

// expand resolves aggregates to concrete targets, preserving order and
// de-duplicating, and prepends the docker-image build when a Docker target is
// requested but the image is missing. Each leaf is run through resolveNative, so
// an Android target that will build on the host (macOS) is already kNative here
// and won't pull in a docker-image prep step.
func (c *buildCtx) expand(keys []string) ([]Target, error) {
	var out []Target
	seen := map[string]bool{}
	var add func(key string) error
	add = func(key string) error {
		t, ok := targetByKey(key)
		if !ok {
			return fmt.Errorf("unknown target %q", key)
		}
		if t.kind == kAggregate {
			for _, m := range t.members {
				if err := add(m); err != nil {
					return err
				}
			}
			return nil
		}
		if !seen[t.Key] {
			seen[t.Key] = true
			out = append(out, c.resolveNative(t))
		}
		return nil
	}
	for _, k := range keys {
		if err := add(k); err != nil {
			return nil, err
		}
	}
	// Dependencies for Docker work, prepended in order: make sure the daemon is
	// up (auto-launch it if not), then build each distinct multi-stage image a
	// requested build needs — and only the missing ones, so adding a second
	// platform later builds just that platform's stage.
	var neededImages []string
	imgSeen := map[string]bool{}
	for _, t := range out {
		if t.needsDocker() && t.image != "" && !imgSeen[t.image] {
			imgSeen[t.image] = true
			neededImages = append(neededImages, t.image)
		}
	}
	if len(neededImages) > 0 {
		var prefix []Target
		daemonUp := dockerDaemonRunning()
		if !daemonUp {
			if ds, ok := targetByKey("docker-start"); ok {
				prefix = append(prefix, ds)
			}
		}
		// When the daemon is down we can't query images, so assume they may need
		// building (a fully-cached `docker build` is fast). When it's up, only
		// build the images that are actually missing.
		for _, stage := range neededImages {
			if daemonUp && dockerImageExists(dockerImageName(stage)) {
				continue
			}
			if img, ok := targetByKey("docker-image-" + stage); ok {
				prefix = append(prefix, img)
			}
		}
		out = append(prefix, out...)
	}
	return out, nil
}
