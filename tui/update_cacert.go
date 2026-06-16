// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"bufio"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"strings"
)

// The Update-CA-bundle tool runs scripts/update_cacert.sh, which refreshes the
// Mozilla CA root bundle (patches/ffmpeg/embed_cacert/cacert.pem) from curl.se.
// That bundle is what the embed_cacert ffmpeg patch compiles into libmpv, so a
// refresh only takes effect on the next binary rebuild.

// cacertResult is the provenance parsed from the refresh script's output, shown
// in the result card.
type cacertResult struct {
	dest  string // destination file path  (the "→ …" line)
	date  string // "Certificate data from Mozilla as of: …"
	count string // total number of CA roots
	size  string // bundle size in bytes
}

// runUpdateCacert runs scripts/update_cacert.sh and streams each output line to
// logf. Shared by the headless CLI entry point (kSelf "_updatecacert") and the
// TUI's live screen.
func runUpdateCacert(ctx *buildCtx, logf func(string)) error {
	script := filepath.Join(ctx.scriptsRoot, "scripts", "update_cacert.sh")
	if !fileExists(script) {
		return fmt.Errorf("update_cacert.sh not found at %s", script)
	}

	cmd := exec.Command("bash", script)
	cmd.Dir = ctx.scriptsRoot

	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw

	if err := cmd.Start(); err != nil {
		_ = pw.Close()
		return err
	}

	scanned := make(chan struct{})
	go func() {
		sc := bufio.NewScanner(pr)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			logf(sc.Text())
		}
		close(scanned)
	}()

	err := cmd.Wait()
	_ = pw.Close()
	<-scanned
	return err
}

// parseCacertResult extracts the bundle provenance from the script's output so
// the result card can show it without re-reading the file.
func parseCacertResult(lines []string) cacertResult {
	var r cacertResult
	for _, l := range lines {
		t := strings.TrimSpace(l)
		switch {
		case strings.HasPrefix(t, "→ "):
			r.dest = strings.TrimSpace(strings.TrimPrefix(t, "→ "))
		case strings.Contains(t, "Certificate data from Mozilla"):
			if i := strings.Index(t, "as of:"); i >= 0 {
				r.date = strings.TrimSpace(t[i+len("as of:"):])
			} else {
				r.date = t
			}
		case strings.HasPrefix(t, "Total CAs:"):
			r.count = strings.TrimSpace(strings.TrimPrefix(t, "Total CAs:"))
		case strings.HasPrefix(t, "Size:"):
			r.size = strings.TrimSpace(strings.TrimPrefix(t, "Size:"))
		}
	}
	return r
}
