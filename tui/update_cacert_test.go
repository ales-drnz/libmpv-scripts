// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestRunUpdateCacertStreamsScriptOutput(t *testing.T) {
	scriptsRoot := t.TempDir()
	// A stand-in for update_cacert.sh that emits the same shape of output
	// (no network) so the runner + streaming are exercised hermetically.
	writeFile(t, filepath.Join(scriptsRoot, "scripts", "update_cacert.sh"),
		"#!/usr/bin/env bash\n"+
			"echo 'Fetching https://curl.se/ca/cacert.pem...'\n"+
			"echo '→ /tmp/embed_cacert/cacert.pem'\n"+
			"echo '  ## Certificate data from Mozilla as of: Thu May 14 03:12:02 2026 GMT'\n"+
			"echo '  Total CAs: 121'\n"+
			"echo '  Size:      189462 bytes'\n")

	ctx := &buildCtx{scriptsRoot: scriptsRoot, repoRoot: t.TempDir()}
	var logs []string
	if err := runUpdateCacert(ctx, func(l string) { logs = append(logs, l) }); err != nil {
		t.Fatalf("runUpdateCacert failed: %v", err)
	}
	if len(logs) == 0 {
		t.Fatal("expected streamed output lines")
	}
	if !strings.Contains(logs[0], "Fetching") {
		t.Errorf("first line = %q, want it to contain 'Fetching'", logs[0])
	}

	r := parseCacertResult(logs)
	if r.dest != "/tmp/embed_cacert/cacert.pem" {
		t.Errorf("dest = %q", r.dest)
	}
	if r.count != "121" {
		t.Errorf("count = %q, want 121", r.count)
	}
	if r.size != "189462 bytes" {
		t.Errorf("size = %q, want '189462 bytes'", r.size)
	}
	if !strings.HasPrefix(r.date, "Thu May 14") {
		t.Errorf("date = %q, want it to start 'Thu May 14'", r.date)
	}
}

func TestRunUpdateCacertMissingScriptErrors(t *testing.T) {
	ctx := &buildCtx{scriptsRoot: t.TempDir(), repoRoot: t.TempDir()}
	if err := runUpdateCacert(ctx, func(string) {}); err == nil {
		t.Error("expected an error when update_cacert.sh is absent")
	}
}

func TestRunUpdateCacertPropagatesScriptFailure(t *testing.T) {
	scriptsRoot := t.TempDir()
	writeFile(t, filepath.Join(scriptsRoot, "scripts", "update_cacert.sh"),
		"#!/usr/bin/env bash\necho 'boom' >&2\nexit 1\n")
	ctx := &buildCtx{scriptsRoot: scriptsRoot, repoRoot: t.TempDir()}
	if err := runUpdateCacert(ctx, func(string) {}); err == nil {
		t.Error("expected a non-zero exit to surface as an error")
	}
}

func TestUpdateCacertModelWiring(t *testing.T) {
	m := model{screen: scUpdateCacert, ucRunning: true, height: 30}
	for _, l := range []string{
		"Fetching https://curl.se/ca/cacert.pem...",
		"→ /x/embed_cacert/cacert.pem",
		"  ## Certificate data from Mozilla as of: Thu May 14 03:12:02 2026 GMT",
		"  Total CAs: 121",
		"  Size:      189462 bytes",
	} {
		nm, _ := m.Update(ucLineMsg{line: l})
		m = nm.(model)
	}
	if len(m.ucLog) != 5 {
		t.Fatalf("ucLog = %d, want 5 streamed lines", len(m.ucLog))
	}

	// esc must NOT navigate away while the download is still running.
	nm, _ := m.keyUpdateCacert("esc")
	m = nm.(model)
	if m.screen != scUpdateCacert {
		t.Errorf("esc navigated away mid-run: screen=%v", m.screen)
	}

	// completion stops the spinner and parses the provenance.
	nm, _ = m.Update(ucDoneMsg{err: nil})
	m = nm.(model)
	if m.ucRunning {
		t.Error("ucRunning still true after ucDoneMsg")
	}
	if m.ucResult.count != "121" || m.ucResult.dest != "/x/embed_cacert/cacert.pem" {
		t.Errorf("ucResult not parsed from streamed log: %+v", m.ucResult)
	}

	// once done, esc returns to the menu.
	nm, _ = m.keyUpdateCacert("esc")
	m = nm.(model)
	if m.screen != scSelect {
		t.Errorf("esc after done: screen=%v, want scSelect", m.screen)
	}
}

func TestParseCacertResultIgnoresNoise(t *testing.T) {
	r := parseCacertResult([]string{
		"Fetching ...",
		"unrelated chatter",
		"→ /x/cacert.pem",
		"  Total CAs: 7",
	})
	if r.dest != "/x/cacert.pem" || r.count != "7" {
		t.Errorf("parsed = %+v", r)
	}
	if r.date != "" || r.size != "" {
		t.Errorf("expected empty date/size, got %+v", r)
	}
}
