// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"fmt"
	"os"
)

// runCLI runs targets headlessly (no TUI), streaming output straight to the
// terminal. Stops at the first failure, like `make`. This is the scriptable
// path that replaces `make <target>`.
//
//	libmpv-tui macos linux-x86_64
//	libmpv-tui build all
//	libmpv-tui verify
func runCLI(args []string, ctx *buildCtx) int {
	keys := args
	if keys[0] == "build" {
		keys = keys[1:]
	}
	if len(keys) == 0 {
		printUsage()
		return 1
	}
	targets, err := ctx.expand(keys)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		return 1
	}
	for _, t := range targets {
		fmt.Printf("\n\x1b[1;36m▶ %s\x1b[0m\n", t.Label)
		cmd := ctx.command(t)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		cmd.Stdin = os.Stdin
		if err := cmd.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "\x1b[1;31m✗ %s failed: %v\x1b[0m\n", t.Key, err)
			return 1
		}
		fmt.Printf("\x1b[1;32m✓ %s\x1b[0m\n", t.Key)
	}
	return 0
}

func printUsage() {
	fmt.Print(`libmpv build orchestrator

USAGE
  ./build                  interactive dashboard (default)
  ./build <target...>      build the given targets, headless
  ./build list             list all targets
  ./build help             this help

EXAMPLES
  ./build                          # open the dashboard
  ./build macos verify             # build macOS, then verify
  ./build all                      # everything + checksums

THROTTLE (env, forwarded into Docker builds)
  JOBS=N  ENABLE_LTO_DEPS=0  FORCE_DOWNLOAD=1  KEEP_BUILD=1  WIPE_ALL=1

The mpv_audio_kit package is found as a sibling checkout, or via
MPV_AUDIO_KIT_ROOT. Apple targets require macOS; the rest build in Docker.
`)
}

func printList() {
	group := ""
	for _, t := range allTargets() {
		if t.Group != group {
			fmt.Printf("\n%s\n", t.Group)
			group = t.Group
		}
		avail := ""
		if !t.Available() {
			avail = "  (" + t.Note + ")"
		}
		fmt.Printf("  %-16s %s%s\n", t.Key, t.Label, avail)
	}
}
