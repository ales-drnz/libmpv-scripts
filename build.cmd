@echo off
rem Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
rem All rights reserved.
rem Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

rem Entry point for the libmpv build orchestrator (Go / Bubble Tea TUI) on Windows.
rem   build                 interactive dashboard
rem   build linux-x86_64 verify   headless
where go >nul 2>nul || (echo Go not found - install from https://go.dev/dl/ & exit /b 1)
cd /d "%~dp0tui"
go run . %*
