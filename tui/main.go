// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Command libmpv-tui is an interactive terminal dashboard for the libmpv
// build system. It orchestrates the existing `make` targets — selecting
// which OS/arch to build, showing live progress (spinner, running timer,
// final durations), letting you drill into each build's live log, cancel a
// running build, and finally validate the binaries.
//
// It is a thin front-end: every action shells out to `make <target>`; the
// build logic stays in the scripts. Cross-platform (macOS / Linux / Windows)
// — Apple targets are auto-disabled when the host is not macOS.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type status int

const (
	stQueued status = iota
	stBuilding
	stDone
	stFailed
	stCancelled
	stSkipped // auto-skipped after an earlier failure
)

type item struct {
	t         Target
	status    status
	start     time.Time
	end       time.Time
	code      int
	log       []string
	cnt       counters  // live info/warn/error tally from the log
	cmd       *exec.Cmd // the running process, for cancel
	cancelled bool
}

// cancel kills a running build's whole process group.
func cancel(it *item) {
	if it.cmd != nil {
		killGroup(it.cmd)
	}
}

type screen int

const (
	scSelect screen = iota
	scDash
	scLog
	scSettings
	scDeps
	scVerify
	scChecksums
	scUpdateCacert
)

type tickMsg struct{}

type model struct {
	targets []Target
	ctx     *buildCtx
	sub     chan tea.Msg

	screen screen
	width  int
	height int

	// select screen — 2D grid cursor (band → column → row), plus the top tab
	// strip and the Build button as focus zones above and below the grid.
	selBand     int
	selCol      int
	selRow      int
	onBuild     bool
	onFlavor    bool // cursor is on the audio/video flavor toggle (next to Build)
	onTabs      bool // cursor is up in the Build/Settings/Dependencies strip
	onAllBin    bool // cursor is on the top "All binaries" control (Compile tab)
	onSkip      bool // cursor is on the "skip on failure" option (Tools tab)
	onCleanWork bool // cursor is on the "clean work after build" option (Tools tab)
	onBuildTabs bool // cursor is on the Compile/Tools sub-tab strip
	onAbort     bool // cursor is on the dashboard's red Abort button
	buildTab    int  // 0 = Compile, 1 = Tools
	tabCur      int  // focused tab when onTabs
	selected    map[int]bool
	allBinaries bool // "All binaries" selected → everything is covered

	// dashboard
	run     []*item // the chosen build queue, in order
	queue   []int   // indices into run not yet started
	running int     // index into run currently building, or -1
	spinPos int

	// log screen
	logIdx    int
	logScroll int
	logFollow bool
	logReturn screen // screen to go back to when leaving the log (dash or verify)
	logFilter string // when set, the log shows only this binary's verifier section

	// settings screen — all edits are staged here and only committed to the
	// persisted settings on an explicit "Save" in the leave dialog.
	settings   userSettings
	setEnabled map[string]bool // catalog item name → on (staged edit state)
	setTab     int             // index into visibleSections() for the active flavor
	onSetTabs  bool            // cursor is up in the Decoders/Filters/Patches strip
	setRows    []setRow        // flattened (headers + items) for the active tab
	setCur     int             // cursor into setRows
	setScroll  int
	setNotice  string // transient status line ("Reset to defaults", …)

	// unsaved-changes dialog (shown when leaving Settings with edits)
	confirmPending bool
	confirmDest    screen // where to go once the dialog is resolved
	confirmCur     int    // 0 save · 1 discard · 2 keep editing

	// dependencies screen
	depScroll int
	depVers   map[string]string // live versions parsed from _versions.sh

	// verify screen — the live binaries × phases matrix, fed by the verifier's
	// structured events (see verify_view.go).
	vbins                                  []*binVerify
	vbinIdx                                map[string]*binVerify
	vCursor                                int
	vPassed, vFailed, vWarned, vNA, vFound int
	vSummary                               bool
	vXaudit, vXauditMsg                    string

	// checksums screen — install-and-diff result (see checksums_view.go). The
	// same screen renders the Libs actions (local / remote / clean); csTitle is
	// the subtitle and csVerb the summary noun ("installed" / "updated" / …).
	csEntries []csEntry
	csRunning bool
	csErr     error
	csScroll  int
	csTitle   string
	csVerb    string

	// update-cacert screen — runs scripts/update_cacert.sh, streams its output
	// live, then shows the refreshed bundle's provenance (date / cert count /
	// size / path). See update_cacert_view.go.
	ucRunning bool
	ucLog     []string
	ucErr     error
	ucResult  cacertResult
	ucScroll  int

	// libModeState is mpv_audio_kit's current libs source ("local" / "remote" /
	// "mixed" / "unknown"), detected on entering the Tools tab and after a Libs
	// action — the colored segment of the toggle. libPending is the segment the
	// cursor is on ("local"/"remote"): ←/→ move it, ⏎ confirms (applies) it, so a
	// switch never fires on a stray arrow press.
	libModeState string
	libPending   string

	// flavorPending is the segment the cursor is on while the flavor toggle (next
	// to Build) is focused ("audio"/"video"): ←/→ move it, ⏎ applies — exactly
	// like libPending, so the flavor never flips on a stray arrow press.
	flavorPending string

	// Docker tab — multi-stage image management. dockerCursor walks the image
	// rows + the "delete all" row; dockerState is the per-stage on-disk status
	// (refreshed on entering the tab and after an action); dockerBusy names the
	// stage being deleted (or "all"), "" when idle.
	dockerCursor   int
	dockerState    map[string]dockerImageStatus
	dockerBusy     string
	dockerDaemonUp bool // cached on tab-enter so the render path never execs docker
	dockerChecking bool // a daemon/image query is in flight (drives the "checking…" spinner)
	dockerChecked  bool // at least one query has completed (so we never flash a stale state first)

	// clean-work-area dialog (shown when a build starts with cached work).
	cleanPending  bool
	cleanScanning bool
	cleanKeys     []string
	cleanCur      int
	cleanDir      string
	cleanEntries  []workEntry
	cleanTotal    int64

	// previously-skipped banner on the dashboard
	skipNote bool
}

func initialModel(ctx *buildCtx) model {
	us := loadSettings()
	m := model{
		targets:    menuTargets(),
		ctx:        ctx,
		sub:        make(chan tea.Msg, 256),
		screen:     scSelect,
		width:      80,
		height:     24,
		selected:   map[int]bool{},
		running:    -1,
		settings:   us,
		setEnabled: us.enabledSet(),
	}
	m.rebuildSetRows()
	return m
}

func (m model) Init() tea.Cmd {
	return tea.Batch(tickCmd(), listen(m.sub))
}

// listen blocks for the next message produced by a build goroutine.
func listen(sub chan tea.Msg) tea.Cmd {
	return func() tea.Msg { return <-sub }
}

func tickCmd() tea.Cmd {
	return tea.Tick(120*time.Millisecond, func(time.Time) tea.Msg { return tickMsg{} })
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil

	case tickMsg:
		m.spinPos = (m.spinPos + 1) % len(spinnerFrames)
		return m, tickCmd()

	case logLineMsg:
		if it := m.byKey(msg.key); it != nil {
			// Verify's structured events drive the matrix and are kept out of the
			// raw log; everything else is logged as usual.
			if it.t.Key == "verify" && strings.HasPrefix(msg.line, "@@V1@@") {
				m.applyVerifyEvent(msg.line)
				return m, listen(m.sub)
			}
			it.log = append(it.log, msg.line)
			it.cnt.add(classify(msg.line))
			if m.screen == scLog && m.run[m.logIdx] == it && m.logFollow {
				m.logScroll = m.maxScroll(it)
			}
		}
		return m, listen(m.sub)

	case procDoneMsg:
		failed := false
		if it := m.byKey(msg.key); it != nil {
			it.end = time.Now()
			it.code = msg.code
			switch {
			case it.cancelled:
				it.status = stCancelled
			case msg.code == 0:
				it.status = stDone
			default:
				it.status = stFailed
				failed = true
			}
		}
		m.running = -1
		// Auto-skip: on a genuine failure, drop the rest of the queue so we
		// don't burn time on builds that the user will likely re-run after a
		// fix. Cancelled builds don't trigger it.
		if failed && m.settings.SkipOnFailure && len(m.queue) > 0 {
			for _, idx := range m.queue {
				m.run[idx].status = stSkipped
			}
			m.queue = nil
			m.skipNote = true
		}
		// Reclaim space: if enabled, drop an OS's work tree once it's fully built.
		if m.settings.CleanWorkAfterBuild {
			if done := m.byKey(msg.key); done != nil {
				m.maybeCleanOSWork(done)
			}
		}
		m.startNext() // launch the next queued build (mutates m)
		return m, listen(m.sub)

	case checksumsDoneMsg:
		m.csRunning = false
		m.csEntries = msg.entries
		m.csErr = msg.err
		return m, listen(m.sub)

	case ucLineMsg:
		m.ucLog = append(m.ucLog, msg.line)
		// Follow the tail while the script is still running.
		m.ucScroll = maxInt(0, len(m.ucLog)-m.ucViewHeight())
		return m, listen(m.sub)

	case ucDoneMsg:
		m.ucRunning = false
		m.ucErr = msg.err
		m.ucResult = parseCacertResult(m.ucLog)
		return m, listen(m.sub)

	case dockerActionDoneMsg:
		m.dockerBusy = ""
		m.startDockerRefresh()
		return m, listen(m.sub)

	case dockerStateMsg:
		m.dockerDaemonUp = msg.up
		m.dockerState = msg.state
		m.dockerChecking = false
		m.dockerChecked = true
		return m, listen(m.sub)

	case cleanScanMsg:
		m.cleanScanning = false
		m.cleanEntries = msg.entries
		m.cleanTotal = msg.total
		return m, listen(m.sub)

	case tea.KeyMsg:
		return m.handleKey(msg)
	}
	return m, nil
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	k := msg.String()
	if k == "ctrl+c" {
		m.killAll()
		return m, tea.Quit
	}
	// The unsaved-changes dialog captures all keys while it is up.
	if m.confirmPending {
		return m.keyConfirm(k)
	}
	// The clean-work-area dialog likewise captures all keys.
	if m.cleanPending {
		return m.keyCleanConfirm(k)
	}
	// Global section switches — available from the three "idle" top screens
	// (not while a build dashboard / log is up, where these letters are used
	// for navigation and 'b' has no meaning). Leaving Settings with staged
	// edits routes through the confirm dialog instead of switching directly.
	if m.screen == scSelect || m.screen == scSettings || m.screen == scDeps {
		switch k {
		case "s":
			if m.screen != scSettings {
				return m.gotoSettings(), nil
			}
		case "d":
			if m.screen != scDeps {
				return m.requestLeaveSettings(scDeps)
			}
		case "b":
			if m.screen != scSelect {
				return m.requestLeaveSettings(scSelect)
			}
		}
	}
	switch m.screen {
	case scSelect:
		return m.keySelect(k)
	case scDash:
		return m.keyDash(k)
	case scLog:
		return m.keyLog(k)
	case scSettings:
		return m.keySettings(k)
	case scDeps:
		return m.keyDeps(k)
	case scVerify:
		return m.keyVerify(k)
	case scChecksums:
		return m.keyChecksums(k)
	case scUpdateCacert:
		return m.keyUpdateCacert(k)
	}
	return m, nil
}

// gotoSettings switches to the Settings screen, seeding the staged edit state
// from the persisted settings.
func (m model) gotoSettings() model {
	m.setEnabled = m.settings.enabledSet()
	m.setNotice = ""
	m.confirmPending = false
	m.onSetTabs = false
	m.screen = scSettings
	if n := m.totalSettingsTabs(); m.setTab >= n {
		m.setTab = 0
	}
	m.rebuildSetRows()
	m.setCur = m.firstSelectableRow()
	m.setScroll = 0
	return m
}

// requestLeaveSettings either opens the unsaved-changes dialog (when there are
// staged edits) or navigates straight to dest. It is only meaningful from the
// Settings screen; from elsewhere it just navigates.
func (m model) requestLeaveSettings(dest screen) (tea.Model, tea.Cmd) {
	if m.screen == scSettings && m.isDirty() {
		m.confirmPending = true
		m.confirmDest = dest
		m.confirmCur = 0
		return m, nil
	}
	return m.navTo(dest), nil
}

// navTo switches to a top screen, running any per-screen entry logic.
func (m model) navTo(dest screen) model {
	switch dest {
	case scSettings:
		return m.gotoSettings()
	case scDeps:
		return m.gotoDeps()
	default:
		m.screen = scSelect
		m.onTabs = false
		return m
	}
}

// gotoDeps switches to the Dependencies screen, parsing live versions once.
func (m model) gotoDeps() model {
	if m.depVers == nil && m.ctx != nil {
		m.depVers = readPinnedVersions(m.ctx.scriptsRoot)
	}
	m.screen = scDeps
	m.onTabs = false
	m.depScroll = 0
	return m
}

// selCol is one column of the select grid: a section header + the target
// indices (into m.targets) under it.
type selColumn struct {
	group string
	items []int
}

// selBands lays the OS sections out as bands of side-by-side columns:
//
//	band 0: macOS · iOS
//	band 1: Windows · Linux · Android
//	band 2: Publish
func (m model) selBands() [][]selColumn {
	col := func(g string) selColumn {
		var idx []int
		for i, t := range m.targets {
			if t.Group == g {
				idx = append(idx, i)
			}
		}
		return selColumn{g, idx}
	}
	return [][]selColumn{
		{col("macOS"), col("iOS")},
		{col("Windows"), col("Linux"), col("Android")},
		{col("Tools")},
	}
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// focusedIdx returns the target index under the cursor (false if on Build).
func (m model) focusedIdx(bands [][]selColumn) (int, bool) {
	if m.onBuild || m.onFlavor || m.selBand >= len(bands) {
		return 0, false
	}
	band := bands[m.selBand]
	if m.selCol >= len(band) {
		return 0, false
	}
	col := band[m.selCol]
	if m.selRow >= len(col.items) {
		return 0, false
	}
	return col.items[m.selRow], true
}

// ── Hierarchical selection (group "all" + the global "All binaries") ─────────
//
// A group's "all" cell (macOS all, Windows all, …) covers that group's per-arch
// cells; "All binaries" covers every cell. A covered cell shows checked but
// dimmed and can't be toggled — selecting the parent already includes it.

// groupAllIndex returns the index of a group's "all" target, or -1.
func (m model) groupAllIndex(group string) int {
	for i, t := range m.targets {
		if t.Group == group && strings.HasPrefix(t.Label, "all") {
			return i
		}
	}
	return -1
}

// cellCovered reports whether a cell is implied by a higher-level selection
// (the global "All binaries", or its group's "all").
func (m model) cellCovered(idx int) bool {
	if m.allBinaries {
		// "All binaries" covers only the binary builds — the Publish steps
		// (Checksums, Verify) stay independently selectable.
		return m.targets[idx].Group != "Tools"
	}
	t := m.targets[idx]
	ga := m.groupAllIndex(t.Group)
	return ga >= 0 && ga != idx && m.selected[ga]
}

// cellChecked reports whether a cell should render as selected.
func (m model) cellChecked(idx int) bool { return m.selected[idx] || m.cellCovered(idx) }

// focusedUnavailReason returns a "Label — why" hint when the grid cursor is on
// an unavailable target, else "".
func (m model) focusedUnavailReason() string {
	if m.onTabs || m.onAllBin || m.onBuild || m.onFlavor || m.onSkip || m.onCleanWork || m.buildTab == 2 {
		return ""
	}
	idx, ok := m.focusedIdx(m.selBands())
	if !ok {
		return ""
	}
	t := m.targets[idx]
	if r := t.unavailReason(); r != "" {
		return t.fullLabel() + " — " + r
	}
	return ""
}

// refreshLibMode re-detects mpv_audio_kit's libs source so the toggle reflects
// reality. Cheap (reads a handful of small files) — called on entering the
// Tools tab and after a Libs action.
func (m *model) refreshLibMode() {
	if m.ctx == nil {
		return
	}
	m.libModeState = libDetectMode(m.ctx.repoRoot)
	// Start the cursor on the current side; default to local for mixed/unknown.
	if m.libModeState == "local" || m.libModeState == "remote" {
		m.libPending = m.libModeState
	} else {
		m.libPending = "local"
	}
}

// libToggleFocused reports whether the grid cursor is on the lib-mode toggle.
func (m model) libToggleFocused(bands [][]selColumn) bool {
	idx, ok := m.focusedIdx(bands)
	return ok && m.targets[idx].Key == "lib-mode"
}

// applyLibPending confirms the toggle: it runs the switch to the pending side,
// but only when that differs from the current source (so pressing ⏎ on the
// already-active side is a harmless no-op). This is the confirmation step —
// ←/→ only move the cursor; nothing changes on disk until ⏎.
func (m *model) applyLibPending() {
	if m.libPending == "" || m.libPending == m.libModeState {
		return
	}
	m.startLibAction("lib-" + m.libPending)
}

// renderLibToggle draws the local⇄remote libs source as a segmented, colored
// control styled like the Build button (rounded border), with the active
// segment filled in and the detected state spelled out to its right. The
// border + filled segment are green when a side is set, cyan when focused, and
// faint when the package is in a mixed / unknown state.
func (m model) renderLibToggle(focused bool) string {
	// Green segment = what's currently set. When focused, a cyan-filled segment
	// is the selection cursor (moved by ←/→); it only takes effect on ⏎.
	seg := func(name string) string {
		switch {
		case focused && m.libPending == name:
			return lipgloss.NewStyle().Background(cAccent).Foreground(cBg).Bold(true).Padding(0, 1).Render(name)
		case m.libModeState == name:
			return lipgloss.NewStyle().Background(cOK).Foreground(cBg).Bold(true).Padding(0, 1).Render(name)
		default:
			return lipgloss.NewStyle().Foreground(cFaint).Padding(0, 1).Render(name)
		}
	}
	inner := seg("local") + dimStyle.Render("│") + seg("remote")

	border := cBorder
	switch {
	case focused:
		border = cAccent
	case m.libModeState == "local" || m.libModeState == "remote":
		border = cOK
	}
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).BorderForeground(border).
		MarginLeft(2).Render(inner)

	var hint string
	switch {
	case focused && m.libPending != m.libModeState:
		hint = lipgloss.NewStyle().Foreground(cAccent).Bold(true).Render("⏎ switch to "+m.libPending) +
			dimStyle.Render("   (currently "+m.libModeState+")")
	case m.libModeState == "local":
		hint = dimStyle.Render("mpv_audio_kit uses the local libmpv — never downloads   ←→ change")
	case m.libModeState == "remote":
		hint = dimStyle.Render("downloads libmpv from GitHub when a local copy is missing   ←→ change")
	case m.libModeState == "mixed":
		hint = warnStyle.Render("⚠ mixed") + dimStyle.Render(" — ←→ pick a side, ⏎ to apply")
	default:
		hint = dimStyle.Render("source unknown — ←→ pick a side, ⏎ to apply")
	}
	return lipgloss.JoinHorizontal(lipgloss.Center, box, "  "+hint)
}

// renderFlavorToggle draws the audio⇄video build-flavor selector as a segmented
// control shown next to the Build button, styled like renderLibToggle. The
// flavor decides whether the build produces an audio-only or a video-capable
// libmpv (into builds/release/ vs builds/release/video/); it persists
// immediately on space/enter, and the Settings ▸ Video Decoders tab tracks it.
// renderFlavorToggle draws the audio⇄video build-flavor selector next to the
// Build button — same shape and behaviour as renderLibToggle: the green segment
// is the active flavor; when focused, ←/→ move a cyan PENDING cursor and the
// hint reads "⏎ switch to X" — nothing changes until ⏎.
func (m model) renderFlavorToggle(focused bool) string {
	cur := flavorOrDefault(m.settings.Flavor)
	seg := func(name string) string {
		switch {
		case focused && m.flavorPending == name:
			return lipgloss.NewStyle().Background(cAccent).Foreground(cBg).Bold(true).Padding(0, 1).Render(name)
		case cur == name:
			return lipgloss.NewStyle().Background(cOK).Foreground(cBg).Bold(true).Padding(0, 1).Render(name)
		default:
			return lipgloss.NewStyle().Foreground(cFaint).Padding(0, 1).Render(name)
		}
	}
	inner := seg(flavorAudio) + dimStyle.Render("│") + seg(flavorVideo)
	border := cOK
	if focused {
		border = cAccent
	}
	box := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).BorderForeground(border).MarginLeft(2).Render(inner)
	if !focused {
		return box
	}
	var hint string
	if m.flavorPending != "" && m.flavorPending != cur {
		hint = lipgloss.NewStyle().Foreground(cAccent).Bold(true).Render("⏎ switch to "+m.flavorPending) +
			dimStyle.Render("   (currently "+cur+")")
	} else if cur == flavorVideo {
		hint = dimStyle.Render("video-capable libmpv   ←→ change")
	} else {
		hint = dimStyle.Render("audio-only libmpv   ←→ change")
	}
	return lipgloss.JoinHorizontal(lipgloss.Center, box, "  "+hint)
}

// applyFlavorPending confirms the flavor toggle (⏎): switches to the pending
// side and saves, but only when it differs from the active flavor — so ⏎ on the
// already-active side is a harmless no-op. Mirrors applyLibPending.
func (m *model) applyFlavorPending() {
	if m.flavorPending == "" || m.flavorPending == flavorOrDefault(m.settings.Flavor) {
		return
	}
	m.settings.Flavor = m.flavorPending
	if m.ctx != nil {
		_ = m.settings.save(m.ctx.scriptsRoot)
	}
}

// selectedCount counts the checked binary cells, EXCLUDING the per-group "all"
// rows (those are aggregate controls, not binaries — counting them on top of
// their covered arches would double-count).
func (m model) selectedCount() int {
	n := 0
	for i, t := range m.targets {
		if m.isAction(i) { // Checksums / Verify run on their own
			continue
		}
		if m.cellChecked(i) && t.Available() && m.groupAllIndex(t.Group) != i {
			n++
		}
	}
	return n
}

// cellLocked reports whether a cell can't be toggled (because it's covered).
func (m model) cellLocked(idx int) bool { return m.cellCovered(idx) }

// allBinaryKeys resolves "All binaries" to the minimal build set: each OS
// group's "all", filtered by availability. The Publish steps (Checksums,
// Verify) are NOT included — they stay opt-in.
func (m model) allBinaryKeys() []string {
	var keys []string
	seen := map[string]bool{}
	for _, t := range m.targets {
		if !t.Available() || t.Group == "Tools" {
			continue
		}
		if ga := m.groupAllIndex(t.Group); ga >= 0 && !seen[t.Group] {
			seen[t.Group] = true
			keys = append(keys, m.targets[ga].Key)
		}
	}
	return keys
}

// buildTabLabels are the build-page sub-tabs.
var buildTabLabels = []string{"Compile", "Tools", "Docker"}

// tabBandRange returns the [lo, hi) band indices shown by the active build tab:
// Compile = the OS bands; Tools = the actions band.
func (m model) tabBandRange() (int, int) {
	if m.buildTab == 1 {
		return 2, 3 // Tools
	}
	return 0, 2 // Compile
}

func (m *model) firstGridCell() {
	lo, _ := m.tabBandRange()
	m.selBand, m.selCol, m.selRow = lo, 0, 0
}

func (m *model) lastGridCell(bands [][]selColumn) {
	_, hi := m.tabBandRange()
	m.selBand = clampInt(hi-1, 0, len(bands)-1)
	m.selCol = clampInt(m.selCol, 0, len(bands[m.selBand])-1)
	m.selRow = len(bands[m.selBand][m.selCol].items) - 1
}

func (m model) keySelect(k string) (tea.Model, tea.Cmd) {
	if m.onTabs {
		return m.keyHeaderTabs(k)
	}
	if m.onBuildTabs {
		return m.keyBuildTabs(k)
	}
	if m.buildTab == 2 { // Docker management tab — its own list cursor
		return m.keyDocker(k)
	}
	if m.onAllBin {
		return m.keyAllBin(k)
	}
	bands := m.selBands()
	switch k {
	case "q", "esc":
		return m, tea.Quit
	case "a":
		m.toggleAllBinaries()
	case "up", "k":
		m.navUp(bands)
	case "down", "j":
		m.navDown(bands)
	case "left", "h":
		// On the flavor toggle, ←/→ move the PENDING side — nothing switches until
		// ⏎. ← past the leftmost segment (audio) steps back out to the Build button
		// (so you're never stuck inside without applying); ↑ also leaves into the
		// grid. The libs toggle only moves its pending cursor (no horizontal exit).
		switch {
		case m.onFlavor:
			if m.flavorPending == flavorAudio { // at the leftmost → exit to Build
				m.onFlavor = false
				m.onBuild = true
			} else {
				m.flavorPending = flavorAudio
			}
		case m.libToggleFocused(bands):
			m.libPending = "local"
		default:
			m.navLeft(bands)
		}
	case "right", "l":
		switch {
		case m.onBuild: // Build → enter the toggle on its leftmost segment (audio)
			m.onBuild = false
			m.onFlavor = true
			m.flavorPending = flavorAudio
		case m.onFlavor:
			m.flavorPending = flavorVideo
		case m.libToggleFocused(bands):
			m.libPending = "remote"
		default:
			m.navRight(bands)
		}
	case " ", "enter":
		// Activate the focused element: toggle a target, run an action
		// (Checksums / Verify / Libs), flip a build option, or start the build.
		switch {
		case m.onBuild:
			m.begin()
		case m.onFlavor:
			m.applyFlavorPending()
		case m.onSkip:
			m.toggleSkip()
		case m.onCleanWork:
			m.toggleCleanWork()
		default:
			m.activateFocused(bands)
		}
	}
	return m, nil
}

// toggleAllBinaries flips the global "All binaries" selection. Turning it on
// clears the per-target frontier (everything becomes covered anyway).
func (m *model) toggleAllBinaries() {
	m.allBinaries = !m.allBinaries
	if m.allBinaries {
		m.selected = map[int]bool{}
	}
}

// toggleSkip flips the "skip remaining builds on failure" option (in the Tools
// section) and persists it immediately.
func (m *model) toggleSkip() {
	m.settings.SkipOnFailure = !m.settings.SkipOnFailure
	if m.ctx != nil {
		_ = m.settings.save(m.ctx.scriptsRoot)
	}
}

// toggleCleanWork flips the "delete each OS's work tree after it builds" option
// (in the Tools section) and persists it immediately.
func (m *model) toggleCleanWork() {
	m.settings.CleanWorkAfterBuild = !m.settings.CleanWorkAfterBuild
	if m.ctx != nil {
		_ = m.settings.save(m.ctx.scriptsRoot)
	}
}

// isAction reports whether a cell is a one-shot action (Publish steps:
// Checksums / Verify) that runs immediately rather than being toggled.
func (m model) isAction(idx int) bool { return m.targets[idx].Group == "Tools" }

// activateFocused acts on the grid cell under the cursor: run it immediately if
// it's an action (Checksums / Verify), otherwise toggle it (honouring coverage
// locks; turning a group "all" on clears its now-covered per-arch selections).
func (m *model) activateFocused(bands [][]selColumn) {
	idx, ok := m.focusedIdx(bands)
	if !ok || !m.targets[idx].Available() || m.cellLocked(idx) {
		return
	}
	t := m.targets[idx]
	if m.isAction(idx) { // Checksums / Verify → run now, each on its own screen
		switch t.Key {
		case "verify":
			m.startVerify()
		case "checksums":
			m.startChecksums()
		case "update-cacert":
			m.startUpdateCacert()
		case "lib-mode":
			m.applyLibPending()
		case "lib-clean":
			m.startLibAction(t.Key)
		default:
			m.startRun([]string{t.Key})
		}
		return
	}
	now := !m.selected[idx]
	m.selected[idx] = now
	if !now {
		delete(m.selected, idx)
		return
	}
	if m.groupAllIndex(t.Group) == idx { // a group "all" → drop covered arches
		for j, tj := range m.targets {
			if tj.Group == t.Group && j != idx {
				delete(m.selected, j)
			}
		}
	}
}

// keyAllBin handles the cursor while it's on the "All binaries" control
// (Compile tab).
func (m model) keyAllBin(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "q", "esc":
		return m, tea.Quit
	case " ", "a":
		m.toggleAllBinaries()
	case "up", "k":
		m.onAllBin = false
		m.onBuildTabs = true // up → Compile/Tools strip
	case "down", "j":
		m.onAllBin = false
		m.firstGridCell()
	}
	return m, nil
}

// keyBuildTabs handles the cursor on the Compile/Tools sub-tab strip.
func (m model) keyBuildTabs(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "q":
		return m, tea.Quit
	case "left", "h":
		if m.buildTab > 0 {
			m.buildTab--
		}
	case "right", "l":
		if m.buildTab < len(buildTabLabels)-1 {
			m.buildTab++
		}
		if m.buildTab == 1 { // entering Tools → detect the libs source
			m.refreshLibMode()
		}
		if m.buildTab == 2 { // hovering Docker → prefetch image status (async)
			m.startDockerRefresh()
		}
	case "up", "k":
		return m.enterHeaderTabs(), nil
	case "down", "j", "enter", " ", "esc":
		m.onBuildTabs = false
		switch m.buildTab {
		case 0: // Compile → land on All binaries
			m.onAllBin = true
		case 1: // Tools → the build options sit at the top
			m.refreshLibMode()
			m.onSkip = true
		case 2: // Docker → the image-management list
			m.dockerCursor = 0     // cursor visible immediately (no wait)
			m.startDockerRefresh() // status fills in from the background query
		}
	}
	return m, nil
}

// ── Top tab strip (Build/Settings/Dependencies) — a focus zone above every
// section's content. Reached by pressing ↑ at the top of the content on the
// Build, Settings and Dependencies screens; there is a single cursor, so when
// the strip is focused the content shows no selection. ──────────────────────

// sectionIndex maps a screen to its tab index in the strip.
func sectionIndex(s screen) int {
	switch s {
	case scSettings:
		return 1
	case scDeps:
		return 2
	default:
		return 0
	}
}

// enterHeaderTabs moves the single cursor up into the top tab strip, starting
// on the current section's tab.
func (m model) enterHeaderTabs() model {
	m.onTabs = true
	m.onSetTabs = false
	m.onAllBin = false
	m.onBuildTabs = false
	m.tabCur = sectionIndex(m.screen)
	return m
}

// dropIntoContent moves the cursor from the strip back down into the current
// section's content (the level just below the header).
func (m model) dropIntoContent() model {
	m.onTabs = false
	switch m.screen {
	case scSelect:
		m.onBuildTabs = true // land on the Compile/Tools sub-tab strip
	case scSettings:
		m.onSetTabs = true // land on the sub-tab strip, one level down
	}
	return m
}

// switchSection navigates to the adjacent section (←→ on the header strip),
// keeping the cursor on the strip so you can keep moving — the same live-switch
// feel as the Decoders/Filters/Behavior sub-tabs. Leaving Settings with staged
// edits routes through the unsaved-changes dialog first.
func (m model) switchSection(dir int) (tea.Model, tea.Cmd) {
	next := sectionIndex(m.screen) + dir
	if next < 0 || next >= len(topTabs) {
		return m, nil // clamp at the ends
	}
	dest := scSelect
	switch next {
	case 1:
		dest = scSettings
	case 2:
		dest = scDeps
	}
	if m.screen == scSettings && m.isDirty() {
		return m.requestLeaveSettings(dest)
	}
	m = m.navTo(dest).enterHeaderTabs()
	return m, nil
}

// keyHeaderTabs handles navigation while the cursor is in the top tab strip,
// on any of the three top screens. ←→ switches section live; ↓/⏎ drops into
// the section's content.
func (m model) keyHeaderTabs(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "left", "h":
		return m.switchSection(-1)
	case "right", "l":
		return m.switchSection(1)
	case "down", "j", "enter", " ", "esc", "q":
		return m.dropIntoContent(), nil
	}
	return m, nil
}

func (m *model) navUp(bands [][]selColumn) {
	lo, _ := m.tabBandRange()
	if m.onBuild || m.onFlavor { // bottom action row (Build / flavor) → grid
		m.onBuild = false
		m.onFlavor = false
		m.lastGridCell(bands)
		return
	}
	// Tools options now sit ABOVE the actions grid: strip → Skip → Clean-work →
	// grid. So Clean-work → Skip → strip going up.
	if m.onCleanWork {
		m.onCleanWork = false
		m.onSkip = true
		return
	}
	if m.onSkip {
		m.onSkip = false
		m.onBuildTabs = true // Skip is the top of Tools → sub-tab strip
		return
	}
	if m.selRow > 0 {
		m.selRow--
		return
	}
	if m.selBand > lo { // top of column → previous band in this tab
		m.selBand--
		m.selCol = clampInt(m.selCol, 0, len(bands[m.selBand])-1)
		m.selRow = len(bands[m.selBand][m.selCol].items) - 1
		return
	}
	// top of the active tab's grid
	if m.buildTab == 0 {
		m.onAllBin = true // Compile → All binaries
	} else {
		m.onCleanWork = true // Tools → the option row just above the grid
	}
}

func (m *model) navDown(bands [][]selColumn) {
	if m.onBuild || m.onFlavor { // bottom action row — nothing below it
		return
	}
	// Tools options sit ABOVE the grid: Skip → Clean-work → grid (top).
	if m.onSkip {
		m.onSkip = false
		m.onCleanWork = true
		return
	}
	if m.onCleanWork {
		m.onCleanWork = false
		m.firstGridCell()
		return
	}
	_, hi := m.tabBandRange()
	col := bands[m.selBand][m.selCol]
	if m.selRow < len(col.items)-1 {
		m.selRow++
		return
	}
	if m.selBand < hi-1 { // bottom → next band in this tab
		m.selBand++
		m.selCol = clampInt(m.selCol, 0, len(bands[m.selBand])-1)
		m.selRow = 0
		return
	}
	// bottom of the grid
	if m.buildTab == 0 {
		m.onBuild = true // Compile → Build button (→ moves onto the flavor toggle)
	}
	// Tools: the grid is the bottom — nothing below it now.
}

func (m *model) navLeft(bands [][]selColumn) {
	if m.onBuild || m.onSkip || m.onCleanWork || m.selCol == 0 {
		return
	}
	m.selCol--
	m.selRow = clampInt(m.selRow, 0, len(bands[m.selBand][m.selCol].items)-1)
}

func (m *model) navRight(bands [][]selColumn) {
	if m.onBuild || m.onSkip || m.onCleanWork || m.selCol >= len(bands[m.selBand])-1 {
		return
	}
	m.selCol++
	m.selRow = clampInt(m.selRow, 0, len(bands[m.selBand][m.selCol].items)-1)
}

// begin builds the run queue from the current selection and starts it. No-op
// when nothing is selected. expand() resolves order, de-dups, and prepends
// the Docker image build when a Docker target needs it.
func (m *model) begin() {
	var keys []string
	if m.allBinaries {
		keys = m.allBinaryKeys()
	} else {
		for i, t := range m.targets {
			if m.selected[i] && t.Available() {
				keys = append(keys, t.Key)
			}
		}
	}
	if len(keys) == 0 {
		return
	}
	// Offer to wipe the cached work tree before a fresh build.
	if m.ctx != nil && hasWorkCache(m.ctx) {
		m.promptCleanThenBuild(keys)
		return
	}
	m.startRun(keys)
}

// startRun expands the given keys into a build queue and switches to the
// dashboard. Shared by the Build button and the one-shot action targets
// (Checksums / Verify).
func (m *model) startRun(keys []string) {
	if len(keys) == 0 {
		return
	}
	m.ctx.androidForceDocker = m.settings.ForceAndroidDocker // honor the Docker-tab toggle
	tg, err := m.ctx.expand(keys)
	if err != nil {
		return
	}
	m.run = nil
	for _, t := range tg {
		m.run = append(m.run, &item{t: t, status: stQueued})
	}
	m.queue = make([]int, len(m.run))
	for i := range m.run {
		m.queue[i] = i
	}
	m.skipNote = false
	m.screen = scDash
	m.onBuild = false
	m.onFlavor = false
	m.onTabs = false
	m.onAllBin = false
	m.onSkip = false
	m.onCleanWork = false
	m.onBuildTabs = false
	m.focusFirstRunCell()
	m.startNext()
}

func (m model) keyDash(k string) (tea.Model, tea.Cmd) {
	bands := m.dashBands()
	m.clampGridCursor(bands) // selBand/selCol may be stale from another tab/screen
	if !m.buildActive() {
		m.onAbort = false // the Abort button only exists while building
	}
	switch k {
	case "q":
		m.killAll()
		return m, tea.Quit
	case "up", "k":
		if m.onAbort {
			m.onAbort = false // back up into the grid
		} else {
			m.gridUp(bands)
		}
	case "down", "j":
		// At the bottom of the grid, drop onto the Abort button (while building).
		col := bands[m.selBand][m.selCol]
		if !m.onAbort && m.buildActive() && m.selBand == len(bands)-1 && m.selRow >= len(col.items)-1 {
			m.onAbort = true
		} else {
			m.gridDown(bands)
		}
	case "left", "h":
		if !m.onAbort {
			m.navLeft(bands)
		}
	case "right", "l":
		if !m.onAbort {
			m.navRight(bands)
		}
	case "enter", " ":
		if m.onAbort {
			m.abortAll()
			return m, nil
		}
		if idx, ok := m.focusedIdx(bands); ok {
			if ri := m.primaryRunIndex(m.cellRunItems(idx)); ri >= 0 {
				m.openLog(ri, "", scDash)
			}
		}
	case "c":
		// Cancel all if the Abort button is focused, else just the focused build.
		if m.onAbort {
			m.abortAll()
			return m, nil
		}
		if idx, ok := m.focusedIdx(bands); ok {
			for _, it := range m.cellRunItems(idx) {
				if it.status == stBuilding {
					it.cancelled = true
					cancel(it)
				}
			}
		}
	case "b", "esc":
		if !m.buildActive() { // builds finished → back to the selector
			m.screen = scSelect
		}
	case "s":
		if !m.buildActive() {
			return m.gotoSettings(), nil
		}
	case "d":
		if !m.buildActive() {
			return m.gotoDeps(), nil
		}
	}
	return m, nil
}

func (m model) keyLog(k string) (tea.Model, tea.Cmd) {
	it := m.run[m.logIdx]
	page := m.logViewHeight()
	switch k {
	case "esc", "left", "h", "q":
		m.screen = m.logReturn
	case "up", "k":
		if m.logScroll > 0 {
			m.logScroll--
		}
		m.logFollow = false
	case "down", "j":
		if m.logScroll < m.maxScroll(it) {
			m.logScroll++
		}
		m.logFollow = m.logScroll >= m.maxScroll(it)
	case "pgup":
		m.logScroll -= page
		if m.logScroll < 0 {
			m.logScroll = 0
		}
		m.logFollow = false
	case "pgdown", " ":
		m.logScroll += page
		if m.logScroll > m.maxScroll(it) {
			m.logScroll = m.maxScroll(it)
		}
		m.logFollow = m.logScroll >= m.maxScroll(it)
	case "home", "g":
		m.logScroll = 0
		m.logFollow = false
	case "end", "G":
		m.logScroll = m.maxScroll(it)
		m.logFollow = true
	}
	return m, nil
}

// startNext launches the next queued build, sequentially. Returns nil when
// the queue is empty.
func (m *model) startNext() tea.Cmd {
	if m.running != -1 || len(m.queue) == 0 {
		return nil
	}
	idx := m.queue[0]
	m.queue = m.queue[1:]
	it := m.run[idx]
	it.status = stBuilding
	it.start = time.Now()
	m.running = idx
	it.cmd = start(it, m.ctx, m.sub)
	return nil
}

func (m *model) byKey(key string) *item {
	for _, it := range m.run {
		if it.t.Key == key {
			return it
		}
	}
	return nil
}

func (m *model) killAll() {
	for _, it := range m.run {
		if it.status == stBuilding {
			it.cancelled = true
			cancel(it)
		}
	}
}

// abortAll stops everything: it kills the running build(s) and drops the queue
// so nothing else starts, marking still-queued items cancelled. Drives the
// dashboard's red Abort button.
func (m *model) abortAll() {
	m.killAll()
	for _, it := range m.run {
		if it.status == stQueued {
			it.cancelled = true
			it.status = stCancelled
		}
	}
	m.queue = nil
}

func main() {
	args := os.Args[1:]

	// help / list don't need a resolved build context.
	if len(args) > 0 {
		switch args[0] {
		case "help", "-h", "--help":
			printUsage()
			return
		case "list":
			printList()
			return
		case "_preview": // hidden: render a screen to stdout (dev aid, no TTY)
			which := "select"
			if len(args) > 1 {
				which = args[1]
			}
			preview(which)
			return
		}
	}

	ctx, err := newBuildCtx()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}

	// Hidden Go steps (kSelf targets re-exec the orchestrator with these).
	if len(args) > 0 && args[0] == "_checksums" {
		if err := runChecksums(ctx, func(l string) { fmt.Println(l) }); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}
	if len(args) > 0 && args[0] == "_updatecacert" {
		if err := runUpdateCacert(ctx, func(l string) { fmt.Println(l) }); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}
	if len(args) > 0 && args[0] == "_dockerstart" {
		if err := ensureDockerRunning(func(l string) { fmt.Println(l) }); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}
	if len(args) > 0 && args[0] == "_libmode" { // toggle to the opposite of the current source
		key := "lib-local"
		if libDetectMode(ctx.repoRoot) == "local" {
			key = "lib-remote"
		}
		if err := runLibAction(ctx, key, func(l string) { fmt.Println(l) }); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}
	if len(args) > 0 {
		if key, ok := map[string]string{
			"_liblocal":  "lib-local",
			"_libremote": "lib-remote",
			"_libclean":  "lib-clean",
		}[args[0]]; ok {
			if err := runLibAction(ctx, key, func(l string) { fmt.Println(l) }); err != nil {
				fmt.Fprintln(os.Stderr, "error:", err)
				os.Exit(1)
			}
			return
		}
	}

	// No args (or `menu`) → interactive dashboard. Otherwise headless CLI.
	if len(args) == 0 || args[0] == "menu" {
		p := tea.NewProgram(initialModel(ctx), tea.WithAltScreen())
		if _, err := p.Run(); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		return
	}
	os.Exit(runCLI(args, ctx))
}

// preview renders a single screen once to stdout — a non-interactive dev aid
// to eyeball layout without a TTY. `which` ∈ {select, dash, settings, deps}.
func preview(which string) {
	m := model{
		targets:    menuTargets(),
		width:      120,
		height:     40,
		selected:   map[int]bool{},
		running:    -1,
		settings:   defaultSettings(),
		setEnabled: defaultSettings().enabledSet(),
	}
	if ctx, err := newBuildCtx(); err == nil {
		m.ctx = ctx
		m.depVers = readPinnedVersions(ctx.scriptsRoot)
	}
	m.rebuildSetRows()
	m.setCur = m.firstSelectableRow()

	switch which {
	case "dash":
		for _, t := range expandPreview([]string{"macos", "linux-x86_64", "windows-x86_64", "android-arm64-v8a"}) {
			m.run = append(m.run, &item{t: t})
		}
		for i, t := range m.targets { // mark the matching grid cells selected
			if t.Key == "macos" || t.Key == "linux-x86_64" || t.Key == "windows-x86_64" || t.Key == "android-arm64-v8a" {
				m.selected[i] = true
			}
		}
		if len(m.run) >= 4 {
			m.run[0].status, m.run[0].start, m.run[0].end = stDone, time.Now().Add(-90*time.Second), time.Now().Add(-5*time.Second)
			m.run[0].cnt = counters{info: 42, warn: 3}
			m.run[1].status, m.run[1].start = stBuilding, time.Now().Add(-30*time.Second)
			m.run[1].cnt = counters{info: 18, warn: 1, errs: 0}
			m.running = 1
			m.run[2].status = stQueued
			m.run[3].status = stQueued
		}
		m.screen = scDash
		m.focusFirstRunCell()
		fmt.Println(m.viewDash())
	case "settings":
		m.screen = scSettings
		fmt.Println(m.viewSettings())
	case "settings-filters":
		m.screen = scSettings
		m.setTab = 1
		m.rebuildSetRows()
		m.setCur = m.firstSelectableRow()
		fmt.Println(m.viewSettings())
	case "settings-patches":
		m.screen = scSettings
		m.setTab = 2
		m.rebuildSetRows()
		m.setCur = m.firstSelectableRow()
		fmt.Println(m.viewSettings())
	case "settings-strip":
		m.screen = scSettings
		m.onSetTabs = true
		m.rebuildSetRows()
		fmt.Println(m.viewSettings())
	case "settings-video":
		m.screen = scSettings
		m.settings.Flavor = flavorVideo
		m.setTab = 2 // the Video Decoders tab (video flavor only)
		m.rebuildSetRows()
		m.setCur = m.firstSelectableRow()
		fmt.Println(m.viewSettings())
	case "settings-header":
		m.screen = scSettings
		m = m.enterHeaderTabs()
		m.rebuildSetRows()
		fmt.Println(m.viewSettings())
	case "confirm":
		m.screen = scSettings
		m.confirmPending = true
		m.confirmCur = 0
		m.rebuildSetRows()
		fmt.Println(m.viewConfirm())
	case "clean":
		m.cleanPending = true
		m.cleanCur = 0
		if m.ctx != nil {
			m.cleanDir = workCacheDir(m.ctx)
		} else {
			m.cleanDir = "builds/work"
		}
		m.cleanEntries = []workEntry{
			{name: "macOS", size: 2_400_000_000},
			{name: "Linux", size: 1_800_000_000},
			{name: "Android", size: 1_200_000_000},
			{name: "Windows", size: 900_000_000},
		}
		m.cleanTotal = 6_300_000_000
		fmt.Println(m.viewCleanConfirm())
	case "deps":
		m.screen = scDeps
		fmt.Println(m.viewDeps())
	case "verify":
		m.screen = scVerify
		m.spinPos = 2
		// Drive the real event parser with a representative sequence so the
		// preview exercises the same path as a live run.
		evs := []string{
			"@@V1@@\tbin\tlibmpv_linux-x86_64.so\tlinux",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tfmt\tpass\tformat/arch matches",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\texports\tpass\tmpv_* exports: 54/54",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tpatches\tpass\tpatched props present (10)",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tffmpeg\tpass\tffmpeg patches present (2)",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tdecoders\tpass\taudio decoders present",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tfilters\tpass\taudio filters present",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tversions\tpass\tdep version manifest: 9/9 match",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tl11\tpass\tL11 NEEDED allowlist: 12/12",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tl12\tpass\tL12 UND resolvability ok",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tl13\tpass\tL13 dlopen loads + props respond",
			"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tl14\tna\tstub detection is Android-only",
			"@@V1@@\tbindone\tlibmpv_linux-x86_64.so",
			"@@V1@@\tbin\tlibmpv_linux-aarch64.so\tlinux",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\tfmt\tpass\tformat/arch matches",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\texports\tpass\tmpv_* exports: 54/54",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\tpatches\tpass\tpatched props present (10)",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\tffmpeg\tpass\tffmpeg patches present (2)",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\tdecoders\tpass\taudio decoders present",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\tfilters\tpass\taudio filters present",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\tversions\tpass\tdep version manifest: 9/9 match",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\tl11\tpass\tL11 NEEDED allowlist: 12/12",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\tl12\tpass\tL12 UND resolvability ok",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\tl13\tpass\tL13 dlopen loads + props respond",
			"@@V1@@\tcheck\tlibmpv_linux-aarch64.so\tl14\tna\tstub detection is Android-only",
			"@@V1@@\tbindone\tlibmpv_linux-aarch64.so",
			"@@V1@@\tbin\tlibmpv_windows-x86_64.dll\twindows",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tfmt\tpass\tformat/arch matches",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\texports\tpass\tmpv_* exports: 54/54",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tpatches\tfail\tmpv patch MISSING: waveform-data",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tffmpeg\tpass\tffmpeg patches present (2)",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tdecoders\tpass\taudio decoders present",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tfilters\twarn\t1 sampled filter missing",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tversions\tpass\tdep version manifest: 9/9 match",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tl11\tpass\tL11 NEEDED allowlist: 40/40",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tl12\tna\tnm/ELF-based; PE imports bound by the loader (see L13)",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tl13\tpass\tL13 LoadLibrary loads + props respond",
			"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tl14\tna\tstub detection is Android-only",
			"@@V1@@\tbindone\tlibmpv_windows-x86_64.dll",
			"@@V1@@\tbin\tlibmpv_macos.xcframework.zip\tmacos",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tfmt\tpass\tformat/arch matches",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\texports\tpass\tmpv_* exports: 54/54",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tpatches\tpass\tpatched props present (10)",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tffmpeg\tpass\tffmpeg patches present (2)",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tdecoders\tpass\taudio decoders present",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tfilters\tpass\taudio filters present",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tversions\tpass\tdep version manifest: 9/9 match",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tl11\tpass\tL11 NEEDED allowlist: 14/14",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tl12\tna\tnm/ELF-based; Mach-O binds resolved by dyld",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tl13\tna\tneeds Apple dyld/Xcode; exercised by local flutter test",
			"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tl14\tna\tstub detection is Android-only",
			"@@V1@@\tbindone\tlibmpv_macos.xcframework.zip",
			"@@V1@@\txaudit\tpass\tAPI surface identical across 9 binaries (hash a1b2c3d4e5f6)",
			"@@V1@@\tsummary\t41\t1\t2\t6\t4",
		}
		for _, e := range evs {
			m.applyVerifyEvent(e)
		}
		m.vCursor = 2
		fmt.Println(m.viewVerify())
	case "checksums":
		m.screen = scChecksums
		m.csEntries = []csEntry{
			{Label: "macos xcframework", Status: "ok", Hash: "a1b2c3d4e5f60718", Dest: "macos/mpv_audio_kit/Frameworks", Edits: []csEdit{
				{File: "macos/mpv_audio_kit.podspec", Old: `EXPECTED_SHA256="00000000000000000000000000000000000000000000000000000000deadbeef"`, New: `EXPECTED_SHA256="a1b2c3d4e5f60718000000000000000000000000000000000000000000000000"`},
				{File: "macos/mpv_audio_kit/Package.swift", Old: `checksum: "0000000000000000000000000000000000000000000000000000000000000000"`, New: `checksum: "a1b2c3d4e5f60718000000000000000000000000000000000000000000000000"`},
			}},
			{Label: "android arm64-v8a", Status: "ok", Hash: "3f2a1b0c9d8e7f60", Dest: "android/src/main/jniLibs/arm64-v8a/libmpv.so", Edits: []csEdit{
				{File: "android/build.gradle.kts", Old: `"sha256" to "deadbeef00000000000000000000000000000000000000000000000000000000"`, New: `"sha256" to "3f2a1b0c9d8e7f60000000000000000000000000000000000000000000000000"`},
			}},
			{Label: "linux x86_64", Status: "ok", Hash: "9c8d7e6f5a4b3c20", Dest: "linux/libs/x86_64/libmpv.so", Edits: []csEdit{
				{File: "linux/CMakeLists.txt", Old: `set(EXPECTED_SHA256_X86_64  "00000000000000000000000000000000000000000000000000000000feedface")`, New: `set(EXPECTED_SHA256_X86_64  "9c8d7e6f5a4b3c20000000000000000000000000000000000000000000000000")`},
			}},
			{Label: "ios xcframework", Status: "skipped", Message: "not built"},
		}
		fmt.Println(m.viewChecksums())
	case "select-docker":
		m.buildTab = 2
		m.dockerDaemonUp = true
		m.dockerState = map[string]dockerImageStatus{
			"linux":   {present: true, size: "1.21GB"},
			"windows": {present: false},
			"android": {present: true, size: "612MB"},
			"verify":  {present: false},
		}
		m.dockerCursor = 1 // focus Windows (missing → build)
		fmt.Println(m.viewSelect())
	case "select-tabs":
		m.onTabs, m.tabCur = true, 1 // Settings tab focused
		for i, t := range m.targets {
			if t.Key == "macos" || t.Key == "linux-x86_64" || t.Key == "verify" {
				m.selected[i] = true
			}
		}
		fmt.Println(m.viewSelect())
	case "select-groupall":
		for i, t := range m.targets {
			if t.Key == "windows" || t.Key == "linux-x86_64" {
				m.selected[i] = true
			}
		}
		m.selBand, m.selCol, m.selRow = 1, 1, 0 // cursor on Linux x86_64
		fmt.Println(m.viewSelect())
	case "select-allbin":
		m.allBinaries = true
		m.selBand, m.selCol, m.selRow = 1, 0, 0
		fmt.Println(m.viewSelect())
	case "select-tools":
		m.buildTab = 1
		m.libModeState, m.libPending = "local", "remote" // cursor moved to remote, not yet applied
		m.selBand, m.selCol, m.selRow = 2, 0, 3          // focus the libs toggle
		fmt.Println(m.viewSelect())
	case "select-build":
		m.onBuild = true // cursor on the Build button
		for i, t := range m.targets {
			if t.Key == "macos" || t.Key == "linux-x86_64" {
				m.selected[i] = true
			}
		}
		fmt.Println(m.viewSelect())
	case "select-windows":
		hostOS = "windows"                      // simulate a Windows host
		m.selBand, m.selCol, m.selRow = 0, 0, 0 // cursor on macOS arm64 (disabled)
		fmt.Println(m.viewSelect())
	default:
		m.selBand, m.selCol, m.selRow = 0, 1, 1 // iOS / simulator focused
		for i, t := range m.targets {
			if t.Key == "macos" || t.Key == "linux-x86_64" || t.Key == "verify" {
				m.selected[i] = true
			}
		}
		fmt.Println(m.viewSelect())
	}
}

// expandPreview is a best-effort expand for the preview dashboard that never
// touches Docker (so it works without a daemon).
func expandPreview(keys []string) []Target {
	var out []Target
	for _, k := range keys {
		if t, ok := targetByKey(k); ok {
			out = append(out, t)
		}
	}
	return out
}

func fileExists(p string) bool { fi, err := os.Stat(p); return err == nil && !fi.IsDir() }
func dirExists(p string) bool  { fi, err := os.Stat(p); return err == nil && fi.IsDir() }

func formatDur(d time.Duration) string {
	d = d.Round(time.Second)
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	m := int(d.Minutes())
	s := int(d.Seconds()) - m*60
	if m < 60 {
		return fmt.Sprintf("%dm %02ds", m, s)
	}
	h := m / 60
	m = m % 60
	return fmt.Sprintf("%dh %02dm %02ds", h, m, s)
}

// ── View ────────────────────────────────────────────────────────────────────

func (m model) View() string {
	if m.cleanPending {
		return m.viewCleanConfirm()
	}
	switch m.screen {
	case scSelect:
		return m.viewSelect()
	case scDash:
		return m.viewDash()
	case scLog:
		return m.viewLog()
	case scSettings:
		if m.confirmPending {
			return m.viewConfirm()
		}
		return m.viewSettings()
	case scDeps:
		return m.viewDeps()
	case scVerify:
		return m.viewVerify()
	case scChecksums:
		return m.viewChecksums()
	case scUpdateCacert:
		return m.viewUpdateCacert()
	}
	return ""
}

func (m model) viewSelect() string {
	var b strings.Builder
	focus := -1
	if m.onTabs {
		focus = m.tabCur
	}
	writeLine(&b, renderHeader(0, focus, m.width, false))

	sel := m.selectedCount()

	// build sub-tab strip (Compile | Tools) — red active tab, like Settings.
	bfocus := -1
	if m.onBuildTabs {
		bfocus = m.buildTab
	}
	writeLine(&b, m.renderBuildTabStrip(bfocus))
	b.WriteByte('\n')

	cursorInGrid := !m.onBuild && !m.onFlavor && !m.onTabs && !m.onAllBin && !m.onSkip && !m.onCleanWork && !m.onBuildTabs

	okRow := lipgloss.NewStyle().Foreground(cOK)
	row := func(idx int, focused bool) string {
		t := m.targets[idx]
		avail := t.Available()

		// Action cells (run buttons, not checkboxes): the label on the left, a
		// dim one-line description on the right — like the "All binaries" row and
		// the Settings rows. A blank line precedes the first Libs action so the
		// local/remote/clean trio reads as its own group, apart from Checksums /
		// Verify.
		if m.isAction(idx) {
			// The libs source is a segmented toggle, not a plain run button.
			if t.Key == "lib-mode" {
				return "\n" + m.renderLibToggle(focused) // blank line separates it from Checksums/Verify
			}
			const actLabelW = 11
			if focused {
				line := "▷ " + padTrunc(t.Label, actLabelW) + t.Desc
				return hiStyle.Render(padTrunc(line, maxInt(1, m.width-2)))
			}
			label, descW := "  "+padTrunc(t.Label, actLabelW), maxInt(1, m.width-actLabelW-4)
			if !avail {
				return dimStyle.Render(label + truncate(t.Desc, descW))
			}
			return lipgloss.NewStyle().Foreground(cAccent2).Render(label) +
				dimStyle.Render(truncate(t.Desc, descW))
		}

		checked := m.cellChecked(idx)
		covered := m.cellCovered(idx)
		check := boxOff
		switch {
		case !avail:
			check = boxNA
		case checked:
			check = boxOn
		}
		var line string
		if focused {
			line = padTrunc("▷ "+check+" "+t.Label, gridRowW)
		} else {
			line = "  " + padTrunc(check+" "+t.Label, gridCellW)
		}
		switch {
		case focused:
			return hiStyle.Render(line)
		case !avail:
			return dimStyle.Render(line)
		case covered:
			return faintStyle.Render(line) // selected but covered → opaque, locked
		case checked:
			return okRow.Render(line)
		default:
			return line
		}
	}
	if m.buildTab == 0 {
		// ── Compile: All binaries + the OS grid + Build button ──
		abCheck := boxOff
		if m.allBinaries {
			abCheck = boxOn
		}
		switch {
		case m.onAllBin:
			writeLine(&b, hiStyle.Render(padTrunc("▷ "+abCheck+" All binaries  — every available target", maxInt(1, m.width-2))))
			b.WriteByte('\n')
		case m.allBinaries:
			writeLine(&b, okStyle.Bold(true).Render("  "+abCheck+" All binaries"), dimStyle.Render("  — every available target"))
			b.WriteByte('\n')
		default:
			writeLine(&b, "  ", abCheck, " All binaries", dimStyle.Render("  — every available target"))
			b.WriteByte('\n')
		}
		b.WriteString(m.renderBandRange(row, cursorInGrid, 0, 2, true))

		label := fmt.Sprintf("Build (%d selected)", sel)
		var buildBtn string
		switch {
		case m.onBuild:
			buildBtn = buildBtnFocusStyle.Render(label)
		case sel == 0:
			buildBtn = buildBtnDisabledStyle.Render(label)
		default:
			buildBtn = buildBtnStyle.Render(label)
		}
		// Build button + the audio/video flavor toggle to its right (← → moves
		// between them; space switches the flavor).
		writeLine(&b, lipgloss.JoinHorizontal(lipgloss.Center, buildBtn, "   ", m.renderFlavorToggle(m.onFlavor)))
	} else if m.buildTab == 1 {
		// ── Tools: the two build options on top, then the one-shot actions ──
		optRow := func(focused, on bool, text string) string {
			box := boxOff
			if on {
				box = boxOn
			}
			label := box + " " + text
			switch {
			case focused:
				return hiStyle.Render(padTrunc("▷ "+label, maxInt(1, m.width-2))) + "\n"
			case on:
				return "  " + okStyle.Render(label) + "\n"
			default:
				return "  " + dimStyle.Render(label) + "\n"
			}
		}
		b.WriteString(optRow(m.onSkip, m.settings.SkipOnFailure, "Skip remaining builds on failure"))
		b.WriteString(optRow(m.onCleanWork, m.settings.CleanWorkAfterBuild, "Clean each OS's work folder after it builds"))
		b.WriteString("\n")
		b.WriteString(m.renderBandRange(row, cursorInGrid, 2, 3, false))
	} else {
		// ── Docker: multi-stage build-image management ──
		b.WriteString(m.renderDockerTab())
	}

	b.WriteString("\n")
	if r := m.focusedUnavailReason(); r != "" {
		writeLine(&b, warnStyle.Render("⚠ "+r))
	}
	var help string
	switch {
	case m.onTabs:
		help = helpBar(
			[2]string{"←→", "switch section"},
			[2]string{"↓", "down"},
			[2]string{"esc", "back"},
		)
	case m.onBuildTabs:
		help = helpBar(
			[2]string{"←→", "Compile/Tools/Docker"},
			[2]string{"↓", "into tab"},
			[2]string{"↑", "sections"},
			[2]string{"q", "quit"},
		)
	case m.buildTab == 2:
		act := "build"
		if m.dockerCursor < len(dockerImages()) && m.dockerState[dockerImages()[m.dockerCursor].stage].present {
			act = "delete"
		} else if m.dockerCursor >= len(dockerImages()) {
			act = "delete all"
		}
		help = helpBar(
			[2]string{"↑↓", "move"},
			[2]string{"⏎", act},
			[2]string{"esc", "tabs"},
			[2]string{"q", "quit"},
		)
	case m.onAllBin:
		help = helpBar(
			[2]string{"space", "toggle all"},
			[2]string{"↓", "targets"},
			[2]string{"↑", "tabs"},
			[2]string{"q", "quit"},
		)
	case m.onSkip:
		help = helpBar(
			[2]string{"space", "toggle skip-on-failure"},
			[2]string{"↑↓", "move"},
			[2]string{"q", "quit"},
		)
	case m.onCleanWork:
		help = helpBar(
			[2]string{"space", "toggle clean-work"},
			[2]string{"↑↓", "move"},
			[2]string{"q", "quit"},
		)
	default:
		space := "toggle / build"
		if idx, ok := m.focusedIdx(m.selBands()); ok && m.isAction(idx) {
			space = "run"
		}
		help = helpBar(
			[2]string{"↑↓←→", "move"},
			[2]string{"space", space},
			[2]string{"a", "all"},
			[2]string{"s/d", "settings/deps"},
			[2]string{"q", "quit"},
		)
	}
	return m.anchorBottom(b.String(), hrule(m.width)+"\n"+help)
}

// dashBands is the grid shown on the build dashboard: only the compile OS
// sections. The Tools actions (Checksums / Verify) run on their own screens and
// are never part of a compile run, so they aren't shown here.
func (m model) dashBands() [][]selColumn {
	b := m.selBands()
	hi := 2 // band 2 is Tools — excluded from the dashboard
	if hi > len(b) {
		hi = len(b)
	}
	return b[:hi]
}

// viewDash is the build screen: the SAME target grid as the selector, but in
// "running" mode — selected targets show their live status glyph, unselected
// ones stay opaque, and the Settings/Dependencies sections are darkened (you
// can't change settings mid-build). A readout line under the grid shows the
// focused build's notifications; Enter opens its log.
func (m model) viewDash() string {
	var b strings.Builder
	locked := m.buildActive()
	writeLine(&b, renderHeader(0, -1, m.width, locked))

	// progress summary: bar + done count + total ℹ/⚠/✗ across all builds
	done, total := m.progress()
	var ti, tw, te int
	for _, it := range m.run {
		ti += it.cnt.info
		tw += it.cnt.warn
		te += it.cnt.errs
	}
	bar := progressBar(done, total, clampInt(m.width/3, 8, 40))
	writeLine(&b,
		bar,
		"  ",
		dimStyle.Render(fmt.Sprintf("%d/%d done", done, total)),
		dimStyle.Render("   "),
		counterBar(ti, tw, te),
	)

	// aux run items that have no grid cell (e.g. the docker daemon-start / image
	// build steps prepended by expand()) — set off from the progress bar by a
	// blank line so they don't read as glued to it.
	if aux := m.auxItems(); len(aux) > 0 {
		b.WriteString("\n")
		for _, it := range aux {
			glyph, gstyle := m.glyph(it)
			label := it.t.fullLabel()
			if strings.HasPrefix(it.t.Key, "docker-") {
				label = dockerStepMsg(it.t.Key)
			}
			// While an image is building, surface the live build step (the last
			// captured output line) on this same row — replaced each frame — so
			// it's real progress, not a static "first run" message.
			if it.status == stBuilding && strings.HasPrefix(it.t.Key, "docker-image-") {
				if cur := dockerProgressLine(lastLogLine(it)); cur != "" {
					stage := strings.TrimPrefix(it.t.Key, "docker-image-")
					label = stage + " image  ·  " + cur
				}
			}
			text := label + "  " + m.timeCell(it)
			writeLine(&b, gstyle.Render(glyph), " ", dimStyle.Render(truncate(text, maxInt(8, m.width-2))))
		}
	}

	// Build-outcome notice sits BELOW the prep/docker steps (not glued to the
	// progress bar), separated by a blank line.
	if m.skipNote {
		b.WriteByte('\n')
		writeLine(&b,
			warnStyle.Render("⚠ a build failed — remaining builds were auto-skipped"),
			dimStyle.Render("  (toggle in Tools)"),
		)
	}
	b.WriteString("\n")

	// the grid, run-mode cells
	cell := func(idx int, focused bool) string {
		t := m.targets[idx]
		items := m.cellRunItems(idx)
		inRun := len(items) > 0
		glyph, gstyle := "·", faintStyle
		if inRun {
			glyph, gstyle = m.glyphFor(combinedStatus(items))
		}
		if focused {
			return hiStyle.Render(padTrunc("▷ "+glyph+" "+t.Label, dashRowW))
		}
		ls := faintStyle
		if inRun {
			ls = textStyle
		}
		return "  " + gstyle.Render(glyph) + " " + ls.Render(padTrunc(t.Label, dashRowW-4))
	}
	b.WriteString(m.renderDashBoxes(cell))

	// focused-build readout — the notifications "on the side", for the cell
	// under the cursor.
	bands := m.dashBands()
	readout := dimStyle.Render("move the cursor over a build to see its status")
	if idx, ok := m.focusedIdx(bands); ok {
		if items := m.cellRunItems(idx); len(items) > 0 {
			st := combinedStatus(items)
			glyph, gstyle := m.glyphFor(st)
			var ci, cw, ce int
			for _, it := range items {
				ci += it.cnt.info
				cw += it.cnt.warn
				ce += it.cnt.errs
			}
			readout = gstyle.Render(glyph+" "+m.targets[idx].fullLabel()) +
				dimStyle.Render("    "+statusWord(st)) +
				dimStyle.Render("    "+m.combinedTimeCell(items)) +
				dimStyle.Render("    ") + counterBar(ci, cw, ce)
		}
	}
	writeLine(&b, truncate(readout, m.width))

	// Red Abort button (counterpart of the green Build button): cancels every
	// running + queued build. Shown only while a build is in flight.
	if m.buildActive() {
		label := "✕ Abort all builds"
		if m.onAbort {
			b.WriteByte('\n')
			writeLine(&b, abortBtnFocusStyle.Render(label))
		} else {
			b.WriteByte('\n')
			writeLine(&b, abortBtnStyle.Render(label))
		}
	}

	enterHint := [2]string{"⏎", "view log"}
	if m.onAbort {
		enterHint = [2]string{"⏎", "abort all"}
	}
	return m.anchorBottom(b.String(), hrule(m.width)+"\n"+helpBar(
		[2]string{"↑↓←→", "move"},
		enterHint,
		[2]string{"c", "cancel"},
		[2]string{"q", "quit"},
	))
}

// gridCellW / gridRowW are the fixed cell geometry shared by the selector and
// the build grid so the two layouts line up exactly.
const (
	gridCellW = 22            // label area inside a cell
	gridRowW  = 2 + gridCellW // leading marker + cell

	// dashRowW is the cell width inside the dashboard's per-OS boxes — narrower
	// than the selector cells so three boxed columns (Windows/Linux/Android) fit
	// an 80-column terminal with their rounded borders + padding, while still
	// holding the longest label ("▷ ✓ all (universal)").
	dashRowW = 20
)

// lastLogLine returns the most recent non-empty line of an item's captured
// output (used to surface a docker build's current step live).
func lastLogLine(it *item) string {
	for i := len(it.log) - 1; i >= 0; i-- {
		if s := strings.TrimSpace(it.log[i]); s != "" {
			return s
		}
	}
	return ""
}

// dashGroupStatus folds the run state of every build cell in an OS column into
// one status (false when none of the column's cells are part of this run).
func (m model) dashGroupStatus(c selColumn) (status, bool) {
	var items []*item
	for _, idx := range c.items {
		items = append(items, m.cellRunItems(idx)...)
	}
	if len(items) == 0 {
		return 0, false
	}
	return combinedStatus(items), true
}

// renderDashBoxes lays out the dashboard grid with each OS group wrapped in a
// rounded box — the same look as the Build button — with the OS name as the box
// title and its per-arch build rows inside. The border (and title) are tinted by
// the group's combined status: running (blue), done (green), failed (red), so
// progress reads per-OS at a glance and each arch flips to a green ✓ on its own.
// Groups not part of the current run get a faint idle border.
func (m model) renderDashBoxes(cell func(idx int, focused bool) string) string {
	bands := m.selBands()
	var b strings.Builder
	for bi := 0; bi < 2 && bi < len(bands); bi++ {
		band := bands[bi]
		blocks := make([]string, 0, len(band))
		for ci, c := range band {
			var inner strings.Builder
			for ri, idx := range c.items {
				focused := bi == m.selBand && ci == m.selCol && ri == m.selRow
				inner.WriteString(cell(idx, focused))
				if ri < len(c.items)-1 {
					inner.WriteString("\n")
				}
			}
			var border lipgloss.TerminalColor = cBorder
			title := faintStyle.Render(c.group)
			if st, ok := m.dashGroupStatus(c); ok {
				_, gs := m.glyphFor(st)
				border = gs.GetForeground()
				title = lipgloss.NewStyle().Bold(true).Foreground(border).Render(c.group)
			}
			box := lipgloss.NewStyle().
				Border(lipgloss.RoundedBorder()).BorderForeground(border).
				Padding(0, 1).Render(title + "\n" + inner.String())
			if ci < len(band)-1 {
				box = lipgloss.NewStyle().MarginRight(1).Render(box)
			}
			blocks = append(blocks, box)
		}
		writeLine(&b, lipgloss.JoinHorizontal(lipgloss.Top, blocks...))
	}
	return b.String()
}

// renderBuildTabStrip renders the Compile/Tools sub-tab strip (red active tab,
// same styling as the Settings sub-tabs). focus is the tab under the cursor
// (-1 when the cursor isn't on the strip).
func (m model) renderBuildTabStrip(focus int) string {
	cells := make([]string, len(buildTabLabels))
	for i, name := range buildTabLabels {
		switch {
		case i == focus:
			cells[i] = tabFocusStyle.Render(name)
		case i == m.buildTab:
			cells[i] = subTabActiveStyle.Render(name)
		default:
			cells[i] = tabInactiveStyle.Render(name)
		}
	}
	return lipgloss.JoinHorizontal(lipgloss.Left, cells...)
}

// renderBandRange lays out bands [lo, hi) of the grid — used to split the
// selector into the red "Compile" and "Tools" sections. showHeaders draws the
// per-column group header (suppressed for the single-column Tools band, where
// the red section header already names it).
func (m model) renderBandRange(cell func(idx int, focused bool) string, cursorInGrid bool, lo, hi int, showHeaders bool) string {
	bands := m.selBands()
	var b strings.Builder
	for bi := lo; bi < hi && bi < len(bands); bi++ {
		band := bands[bi]
		blocks := make([]string, 0, len(band))
		for ci, c := range band {
			var cb strings.Builder
			if showHeaders {
				writeLine(&cb, hdrStyle.Render(padTrunc(c.group, gridRowW)))
			}
			for ri, idx := range c.items {
				focused := cursorInGrid && bi == m.selBand && ci == m.selCol && ri == m.selRow
				writeLine(&cb, cell(idx, focused))
			}
			block := strings.TrimRight(cb.String(), "\n")
			if ci < len(band)-1 {
				block = lipgloss.NewStyle().MarginRight(3).Render(block)
			}
			blocks = append(blocks, block)
		}
		writeLine(&b, lipgloss.JoinHorizontal(lipgloss.Top, blocks...))
		b.WriteByte('\n')
	}
	return b.String()
}

// buildActive reports whether a build is in progress (something building or
// still queued). While true the top sections are locked.
func (m model) buildActive() bool {
	if m.running != -1 || len(m.queue) > 0 {
		return true
	}
	for _, it := range m.run {
		if it.status == stBuilding || it.status == stQueued {
			return true
		}
	}
	return false
}

// aggregateLeaves resolves a (possibly aggregate) target to its concrete leaf
// keys.
func aggregateLeaves(t Target) []string {
	if t.kind != kAggregate {
		return []string{t.Key}
	}
	var out []string
	for _, mk := range t.members {
		if mt, ok := targetByKey(mk); ok {
			out = append(out, aggregateLeaves(mt)...)
		}
	}
	return out
}

// cellRunItems returns the run items a grid cell represents, but only for cells
// that are part of this build — directly chosen or covered by a selected
// "all" / "All binaries". Cells outside the selection stay opaque.
func (m model) cellRunItems(idx int) []*item {
	items := m.runItemsForTarget(m.targets[idx])
	if len(items) == 0 {
		return nil
	}
	// Action cells (Checksums / Verify) show whenever they're in the run;
	// build cells show when selected or covered.
	if m.isAction(idx) || m.cellChecked(idx) {
		return items
	}
	return nil
}

// runItemsForTarget returns the run-queue items a grid cell maps to (itself or
// its aggregate members). Empty when the target isn't part of the run.
func (m model) runItemsForTarget(t Target) []*item {
	leaves := aggregateLeaves(t)
	var out []*item
	for _, it := range m.run {
		for _, k := range leaves {
			if it.t.Key == k {
				out = append(out, it)
				break
			}
		}
	}
	return out
}

// auxItems are run-queue items not represented by any grid cell (e.g. the
// docker build-environment image).
func (m model) auxItems() []*item {
	covered := map[string]bool{}
	for _, t := range m.targets {
		for _, k := range aggregateLeaves(t) {
			covered[k] = true
		}
	}
	var out []*item
	for _, it := range m.run {
		if !covered[it.t.Key] {
			out = append(out, it)
		}
	}
	return out
}

func (m model) indexOf(target *item) int {
	for i, it := range m.run {
		if it == target {
			return i
		}
	}
	return -1
}

// primaryRunIndex picks the run item to open a log for from a cell's members:
// the building one, else the last.
func (m model) primaryRunIndex(items []*item) int {
	best := -1
	for _, it := range items {
		if it.status == stBuilding {
			return m.indexOf(it)
		}
		best = m.indexOf(it)
	}
	return best
}

// combinedStatus folds several builds' statuses into one for an aggregate cell.
func combinedStatus(items []*item) status {
	has := map[status]bool{}
	for _, it := range items {
		has[it.status] = true
	}
	switch {
	case has[stBuilding]:
		return stBuilding
	case has[stQueued]:
		return stQueued
	case has[stFailed]:
		return stFailed
	case has[stCancelled]:
		return stCancelled
	case has[stSkipped]:
		return stSkipped
	default:
		return stDone
	}
}

// combinedTimeCell summarises elapsed time across a cell's builds.
func (m model) combinedTimeCell(items []*item) string {
	for _, it := range items {
		if it.status == stBuilding {
			return formatDur(time.Since(it.start)) + " …"
		}
	}
	allQueued := true
	var total time.Duration
	any := false
	for _, it := range items {
		if it.status == stQueued {
			continue
		}
		allQueued = false
		if !it.start.IsZero() && !it.end.IsZero() {
			total += it.end.Sub(it.start)
			any = true
		}
	}
	switch {
	case allQueued:
		return "queued"
	case any:
		return formatDur(total)
	default:
		return ""
	}
}

func statusWord(st status) string {
	switch st {
	case stBuilding:
		return "building"
	case stDone:
		return "done"
	case stFailed:
		return "failed"
	case stCancelled:
		return "cancelled"
	case stSkipped:
		return "skipped"
	default:
		return "queued"
	}
}

// gridUp / gridDown move the cursor within the grid only (no header / Build
// button transitions) — used by the build screen.
// clampGridCursor keeps (selBand, selCol, selRow) inside the given bands. The
// dashboard shows fewer bands than the selector, so a cursor left on a band that
// doesn't exist here (e.g. Tools, after launching Verify) would index out of
// range; clamping makes the grid nav panic-proof.
func (m *model) clampGridCursor(bands [][]selColumn) {
	if len(bands) == 0 {
		return
	}
	m.selBand = clampInt(m.selBand, 0, len(bands)-1)
	m.selCol = clampInt(m.selCol, 0, len(bands[m.selBand])-1)
	m.selRow = clampInt(m.selRow, 0, maxInt(0, len(bands[m.selBand][m.selCol].items)-1))
}

func (m *model) gridUp(bands [][]selColumn) {
	m.clampGridCursor(bands)
	if m.selRow > 0 {
		m.selRow--
		return
	}
	if m.selBand > 0 {
		m.selBand--
		m.selCol = clampInt(m.selCol, 0, len(bands[m.selBand])-1)
		m.selRow = len(bands[m.selBand][m.selCol].items) - 1
	}
}

func (m *model) gridDown(bands [][]selColumn) {
	m.clampGridCursor(bands)
	col := bands[m.selBand][m.selCol]
	if m.selRow < len(col.items)-1 {
		m.selRow++
		return
	}
	if m.selBand < len(bands)-1 {
		m.selBand++
		m.selCol = clampInt(m.selCol, 0, len(bands[m.selBand])-1)
		m.selRow = 0
	}
}

// focusFirstRunCell parks the cursor on the first grid cell that's part of the
// run, so the build screen opens with a meaningful selection.
func (m *model) focusFirstRunCell() {
	bands := m.selBands()
	for bi, band := range bands {
		for ci, c := range band {
			for ri, idx := range c.items {
				if len(m.cellRunItems(idx)) > 0 {
					m.selBand, m.selCol, m.selRow = bi, ci, ri
					return
				}
			}
		}
	}
}

func (m model) viewLog() string {
	it := m.run[m.logIdx]
	lines := m.logLines(it)
	var title string
	if m.logFilter != "" {
		title = titleStyle.Render(vShortName(m.logFilter)) + dimStyle.Render("   verify log — this binary only")
	} else {
		glyph, gstyle := m.glyph(it)
		title = titleStyle.Render(it.t.fullLabel()) + "  " + gstyle.Render(glyph) +
			"  " + dimStyle.Render(m.timeCell(it))
	}

	h := m.logViewHeight()
	start := clampInt(m.logScroll, 0, maxInt(0, len(lines)-h))
	end := start + h
	if end > len(lines) {
		end = len(lines)
	}
	// Each row gets a one-column scrollbar gutter on the left (track + thumb when
	// the log overflows the panel), so the length of the session is visible at a
	// glance. Lines are truncated to the panel width minus that gutter.
	bar := scrollbar(len(lines), h, start)
	var body strings.Builder
	for i := 0; i < h; i++ {
		cell := " "
		if bar != nil {
			cell = bar[i]
		}
		line := ""
		if idx := start + i; idx < len(lines) {
			line = logStyle.Render(truncate(lines[idx], m.width-6))
		}
		writeParts(&body, cell, " ", line) // scrollbar + padding column
		if i < h-1 {
			body.WriteString("\n")
		}
	}

	panel := panelStyle.Width(m.width - 2).Render(body.String())
	pos := fmt.Sprintf("lines %d-%d/%d", start+1, end, len(lines))
	if m.logFollow {
		pos += "  following"
	}
	help := helpBar(
		[2]string{"↑↓/PgUp/PgDn", "scroll"},
		[2]string{"End", "follow"},
		[2]string{"Esc", "back"},
	)
	return m.anchorBottom(title+"\n"+panel, dimStyle.Render(pos)+"   "+help)
}

// ── view helpers ─────────────────────────────────────────────────────────────

func (m model) glyph(it *item) (string, lipgloss.Style) { return m.glyphFor(it.status) }

func (m model) glyphFor(st status) (string, lipgloss.Style) {
	switch st {
	case stBuilding:
		return spinnerFrames[m.spinPos], lipgloss.NewStyle().Foreground(cRun)
	case stDone:
		return "✓", lipgloss.NewStyle().Foreground(cOK)
	case stFailed:
		return "✗", lipgloss.NewStyle().Foreground(cFail)
	case stCancelled:
		return "⊘", lipgloss.NewStyle().Foreground(cCancel)
	case stSkipped:
		return "↷", faintStyle
	default:
		return "◌", dimStyle
	}
}

func (m model) timeCell(it *item) string {
	switch it.status {
	case stBuilding:
		return formatDur(time.Since(it.start)) + " …"
	case stQueued:
		return "queued"
	case stSkipped:
		return "skipped"
	default:
		return formatDur(it.end.Sub(it.start))
	}
}

func (m model) progress() (done, total int) {
	// Count only real build/action items. The docker daemon-start / image-build
	// steps that expand() prepends are env prep, shown separately in the aux
	// banner — counting them would inflate the "N/M done" total.
	aux := map[*item]bool{}
	for _, it := range m.auxItems() {
		aux[it] = true
	}
	for _, it := range m.run {
		if aux[it] {
			continue
		}
		total++
		switch it.status {
		case stDone, stFailed, stCancelled, stSkipped:
			done++
		}
	}
	return
}

func (m model) logViewHeight() int {
	h := m.height - 4 // title + position line + borders
	if h < 3 {
		h = 3
	}
	return h
}

func (m model) maxScroll(it *item) int {
	max := len(m.logLines(it)) - m.logViewHeight()
	if max < 0 {
		return 0
	}
	return max
}

// logLines returns the lines of it.log to show. When logFilter is set (the
// verify report scoped Enter to one binary), only that binary's section of the
// verifier output is returned — from its "════ <name>" header up to the next
// section header — so you read just that platform, not the whole run.
func (m model) logLines(it *item) []string {
	if m.logFilter == "" {
		return it.log
	}
	start := -1
	for i, ln := range it.log {
		if strings.Contains(ln, "════") && strings.Contains(ln, m.logFilter) {
			start = i
			break
		}
	}
	if start < 0 {
		return it.log // section not emitted yet → show the whole log
	}
	end := len(it.log)
	for i := start + 1; i < len(it.log); i++ {
		if strings.Contains(it.log[i], "════") {
			end = i
			break
		}
	}
	return it.log[start:end]
}

// openLog switches to the log screen for run item ri, optionally scoped to one
// binary's section (filter), and remembers ret to return to on exit.
func (m *model) openLog(ri int, filter string, ret screen) {
	if ri < 0 || ri >= len(m.run) {
		return
	}
	m.screen = scLog
	m.logReturn = ret
	m.logFilter = filter
	m.logIdx = ri
	m.logFollow = true
	m.logScroll = m.maxScroll(m.run[ri])
}

func truncate(s string, w int) string {
	if w < 1 {
		return ""
	}
	if len(s) <= w {
		return s
	}
	return s[:w]
}

// anchorBottom pins `footer` to the bottom rows of the terminal by padding the
// gap between it and `body` with blank lines, so the help bar keeps its position
// no matter how tall the content above it is. Used by the variable-height
// screens (select / dashboard / verify); the scroll-window screens already fill
// the height themselves.
func (m model) anchorBottom(body, footer string) string {
	body = strings.TrimRight(body, "\n")
	// bottomMargin keeps the help bar off the very last terminal row, mirroring
	// the breathing room it has above (the rule + gap), so it doesn't read as
	// glued to the bottom edge.
	const bottomMargin = 1
	pad := m.height - lipgloss.Height(body) - lipgloss.Height(footer) - bottomMargin + 1
	if pad < 1 {
		pad = 1
	}
	return body + strings.Repeat("\n", pad) + footer + strings.Repeat("\n", bottomMargin)
}

// padTrunc truncates or right-pads a plain string to exactly w display cells
// (rune-counted; our labels are all single-width). Used to keep grid cells a
// fixed width so nothing wraps and a row highlight spans exactly one cell.
func padTrunc(s string, w int) string {
	r := []rune(s)
	if len(r) > w {
		return string(r[:w])
	}
	return s + strings.Repeat(" ", w-len(r))
}
