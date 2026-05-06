// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

//go:build windows

package main

import (
	"os/exec"
	"strconv"
	"syscall"
)

// setProcGroup creates a new process group so the child (and its children)
// can be killed as a unit.
func setProcGroup(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x00000200} // CREATE_NEW_PROCESS_GROUP
}

// killGroup terminates the child process tree. Windows has no killpg, so we
// shell out to taskkill /T (tree) /F (force).
func killGroup(c *exec.Cmd) {
	if c.Process == nil {
		return
	}
	_ = exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(c.Process.Pid)).Run()
}
