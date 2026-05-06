// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"bufio"
	"io"
	"os/exec"

	tea "github.com/charmbracelet/bubbletea"
)

// logLineMsg is one line of build output for a target.
type logLineMsg struct {
	key  string
	line string
}

// procDoneMsg is sent once, after every log line, when a build exits.
type procDoneMsg struct {
	key  string
	code int
	err  error
}

// start launches the command for an item. It returns the *exec.Cmd (so the
// model can cancel it) and streams output + completion into sub. Log lines
// are guaranteed to arrive before the procDoneMsg.
func start(it *item, ctx *buildCtx, sub chan tea.Msg) *exec.Cmd {
	cmd := ctx.command(it.t)
	setProcGroup(cmd)

	pr, pw := io.Pipe()
	cmd.Stdout = pw
	cmd.Stderr = pw

	key := it.t.Key

	if err := cmd.Start(); err != nil {
		if closeErr := pw.Close(); closeErr != nil {
			sub <- logLineMsg{key: key, line: closeErr.Error()}
		}
		go func() { sub <- procDoneMsg{key: key, code: -1, err: err} }()
		return cmd
	}

	scanned := make(chan error, 1)
	go func() {
		sc := bufio.NewScanner(pr)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024) // tolerate long lines
		for sc.Scan() {
			sub <- logLineMsg{key: key, line: sc.Text()}
		}
		scanned <- sc.Err()
	}()

	go func() {
		err := cmd.Wait()
		if closeErr := pw.Close(); err == nil {
			err = closeErr
		}
		if scanErr := <-scanned; err == nil {
			err = scanErr
		}
		code := 0
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else if err != nil {
			code = -1
		}
		sub <- procDoneMsg{key: key, code: code, err: err}
	}()

	return cmd
}
