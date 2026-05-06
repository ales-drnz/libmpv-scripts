// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

//go:build !windows

package main

import (
	"os/exec"
	"syscall"
)

// setProcGroup puts the child in its own process group so we can signal the
// whole tree (make → build script → docker) at once.
func setProcGroup(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// killGroup terminates the child's entire process group.
func killGroup(c *exec.Cmd) {
	if c.Process == nil {
		return
	}
	// Negative PID targets the group. SIGKILL is blunt but reliable for a
	// build we want gone now.
	_ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
}
