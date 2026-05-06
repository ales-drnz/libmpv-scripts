// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import (
	"fmt"
	"strconv"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// The Verify screen reads as a report: a list of the release binaries with their
// overall result and a pass/warn/fail tally, and — for the binary under the
// cursor — its individual checks in plain language (failures and warnings
// first). It is driven by the structured events scripts/verify_binaries.sh emits
// when run with VERIFY_EMIT=1 ("@@V1@@\t…" lines), parsed in applyVerifyEvent;
// the full raw verifier log is one keystroke away (Enter).

// phaseStatus is the aggregate state of one (binary, phase) cell.
type phaseStatus int

const (
	psNone    phaseStatus = iota // no event yet
	psRunning                    // phase entered, no result yet
	psSkip                       // ran but informational-only, or never reached
	psNA                         // intentionally not-applicable here (carries a reason)
	psPass
	psWarn
	psFail
)

// rank orders the terminal states so a phase with several checks reflects its
// worst one (a single ✗ outranks any number of ✓). psNone / psRunning are
// transient and rank below everything.
func rank(s phaseStatus) int {
	switch s {
	case psFail:
		return 5
	case psWarn:
		return 4
	case psPass:
		return 3
	case psNA:
		return 2
	case psSkip:
		return 1
	default:
		return 0
	}
}

// mergeStatus folds a newly-arrived check into a cell's running aggregate.
func mergeStatus(cur, incoming phaseStatus) phaseStatus {
	if rank(incoming) >= rank(cur) {
		return incoming
	}
	return cur
}

// statusFromStr maps an event's status token to a cell state. "info" counts as
// "ran but nothing to assert" → renders the same as an explicit skip.
func statusFromStr(s string) phaseStatus {
	switch s {
	case "pass":
		return psPass
	case "warn":
		return psWarn
	case "fail":
		return psFail
	case "na":
		return psNA
	default: // info, skip
		return psSkip
	}
}

// verifyPhaseOrder is every verification phase in the order the verifier runs
// them, with a readable label. The focused-binary detail groups its checks under
// these phases so the report reads as sections, not a flat dump.
var verifyPhaseOrder = []struct{ id, label string }{
	{"fmt", "Format / arch"},
	{"exports", "Exports"},
	{"patches", "mpv patches"},
	{"ffmpeg", "FFmpeg patches"},
	{"decoders", "Audio decoders"},
	{"filters", "Audio filters"},
	{"audioonly", "Audio-only invariant"},
	{"deps", "Runtime dependencies"},
	{"versions", "Dependency versions"},
	{"apihash", "API surface hash"},
	{"l11", "NEEDED allowlist"},
	{"l12", "UND symbol resolvability"},
	{"l13", "Runtime load test"},
	{"l14", "Stub detection"},
}

// phaseLabel maps a phase id to its readable section title.
func phaseLabel(id string) string {
	for _, p := range verifyPhaseOrder {
		if p.id == id {
			return p.label
		}
	}
	return id
}

// vcheck is one result line, kept for the focused-binary detail.
type vcheck struct{ phase, status, msg string }

// binVerify holds one binary's verification state.
type binVerify struct {
	name     string
	platform string
	phase    map[string]phaseStatus
	checks   []vcheck
	cur      string // id of the phase currently running (last entered)
	done     bool
}

// vAddBin returns the row for name, creating it on first sight.
func (m *model) vAddBin(name, platform string) *binVerify {
	if m.vbinIdx == nil {
		m.vbinIdx = map[string]*binVerify{}
	}
	if b := m.vbinIdx[name]; b != nil {
		if platform != "" && b.platform == "" {
			b.platform = platform
		}
		return b
	}
	b := &binVerify{name: name, platform: platform, phase: map[string]phaseStatus{}}
	m.vbinIdx[name] = b
	m.vbins = append(m.vbins, b)
	return b
}

// applyVerifyEvent ingests one "@@V1@@\t…" line into the matrix state.
func (m *model) applyVerifyEvent(line string) {
	// Limit 7 leaves room for the summary's 5 numeric fields. A check message
	// may itself contain tabs (e.g. a multi-column diagnostic), so it spills into
	// f[5] and f[6]; the check case rejoins them to keep the tail verbatim.
	f := strings.SplitN(line, "\t", 7)
	if len(f) < 2 || f[0] != "@@V1@@" {
		return
	}
	switch f[1] {
	case "bin":
		if len(f) >= 4 {
			m.vAddBin(f[2], f[3])
		}
	case "phase":
		if len(f) >= 4 {
			if b := m.vbinIdx[f[2]]; b != nil {
				b.cur = f[3]
				if b.phase[f[3]] == psNone {
					b.phase[f[3]] = psRunning
				}
			}
		}
	case "check":
		if len(f) < 6 || f[2] == "" {
			return // audit/global checks carry no binary — ignored here
		}
		b := m.vbinIdx[f[2]]
		if b == nil {
			b = m.vAddBin(f[2], "")
		}
		msg := f[5]
		if len(f) > 6 { // a tab-bearing message tail (see SplitN comment above)
			msg += "\t" + f[6]
		}
		b.checks = append(b.checks, vcheck{phase: f[3], status: f[4], msg: msg})
		b.phase[f[3]] = mergeStatus(b.phase[f[3]], statusFromStr(f[4]))
	case "bindone":
		if len(f) >= 3 {
			if b := m.vbinIdx[f[2]]; b != nil {
				b.done = true
				b.cur = ""
				// Any phase never entered (or still spinning) is n/a here.
				for _, p := range verifyPhaseOrder {
					if s := b.phase[p.id]; s == psNone || s == psRunning {
						b.phase[p.id] = psSkip
					}
				}
			}
		}
	case "xaudit":
		if len(f) >= 4 {
			m.vXaudit, m.vXauditMsg = f[2], f[3]
		}
	case "summary":
		if len(f) >= 7 {
			m.vPassed = atoiSafe(f[2])
			m.vFailed = atoiSafe(f[3])
			m.vWarned = atoiSafe(f[4])
			m.vNA = atoiSafe(f[5])
			m.vFound = atoiSafe(f[6])
			m.vSummary = true
		}
	}
}

func atoiSafe(s string) int { n, _ := strconv.Atoi(s); return n }

// vShortName strips the libmpv_ prefix and the artifact extension for a compact
// row label ("libmpv_linux-x86_64.so" → "linux-x86_64").
func vShortName(name string) string {
	s := strings.TrimPrefix(name, "libmpv_")
	for _, ext := range []string{".xcframework.zip", ".so", ".dll", ".dylib"} {
		s = strings.TrimSuffix(s, ext)
	}
	return s
}

// vGlyph maps a cell state to its glyph + style (mirrors glyphFor's vocabulary).
func (m model) vGlyph(s phaseStatus) (string, lipgloss.Style) {
	switch s {
	case psPass:
		return "✓", okStyle
	case psWarn:
		return "⚠", warnStyle
	case psFail:
		return "✗", failStyle
	case psRunning:
		return spinnerFrames[m.spinPos], lipgloss.NewStyle().Foreground(cRun)
	case psNA:
		return "∅", faintStyle
	case psSkip:
		return "–", faintStyle
	default:
		return "◌", dimStyle
	}
}

// counts tallies a binary's check results. na = categories that intentionally
// don't apply to this platform (reported with a reason), kept separate from
// pass/warn/fail so the per-OS "passed" number is always paired with an
// explainable "N/A" count rather than silently differing between platforms.
func (b *binVerify) counts() (pass, warn, fail, na int) {
	for _, c := range b.checks {
		switch c.status {
		case "pass":
			pass++
		case "warn":
			warn++
		case "fail":
			fail++
		case "na":
			na++
		}
	}
	return
}

// overall is the binary's headline status glyph. A failure outranks everything;
// otherwise it's a spinner while the verifier is still running it, an
// "interrupted" mark if the verifier exited before finishing it, then warn, then
// all-clear.
func (m model) overall(b *binVerify, alive bool) (string, lipgloss.Style) {
	_, w, f, _ := b.counts()
	switch {
	case f > 0:
		return "✗", failStyle
	case !b.done && alive:
		return spinnerFrames[m.spinPos], lipgloss.NewStyle().Foreground(cRun)
	case !b.done:
		return "⊘", lipgloss.NewStyle().Foreground(cCancel) // verifier stopped early
	case w > 0:
		return "⚠", warnStyle
	default:
		return "✓", okStyle
	}
}

// startVerify launches the Verify action into its own matrix screen. It mirrors
// startRun but routes to scVerify and turns on the structured event stream
// (VERIFY_EMIT) for the verify item only — the catalog Target is untouched
// because expand returns Target values that we copy before mutating.
func (m *model) startVerify() {
	tg, err := m.ctx.expand([]string{"verify"})
	if err != nil {
		return
	}
	m.run = nil
	for _, t := range tg {
		if t.Key == "verify" {
			t.env = append(append([]string{}, t.env...), "VERIFY_EMIT=1")
		}
		m.run = append(m.run, &item{t: t, status: stQueued})
	}
	m.queue = make([]int, len(m.run))
	for i := range m.run {
		m.queue[i] = i
	}
	// Fresh matrix state.
	m.vbins = nil
	m.vbinIdx = map[string]*binVerify{}
	m.vCursor = 0
	m.vPassed, m.vFailed, m.vWarned, m.vNA, m.vFound = 0, 0, 0, 0, 0
	m.vSummary = false
	m.vXaudit, m.vXauditMsg = "", ""

	m.skipNote = false
	m.screen = scVerify
	m.onBuild, m.onTabs, m.onAllBin, m.onSkip, m.onCleanWork, m.onBuildTabs = false, false, false, false, false, false
	m.startNext()
}

func (m model) keyVerify(k string) (tea.Model, tea.Cmd) {
	switch k {
	case "q":
		m.killAll()
		return m, tea.Quit
	case "up", "k":
		if m.vCursor > 0 {
			m.vCursor--
		}
	case "down", "j":
		if m.vCursor < len(m.vbins)-1 {
			m.vCursor++
		}
	case "enter":
		// If an environment-prep step (docker daemon/image) is running, show its
		// full log. Otherwise open the verifier's log scoped to the focused
		// binary's section — so you read just that platform, not the whole run.
		var prep *item
		for _, it := range m.auxItems() {
			if it.status == stBuilding {
				prep = it
				break
			}
		}
		if prep != nil {
			m.openLog(m.indexOf(prep), "", scVerify)
		} else if it := m.byKey("verify"); it != nil {
			filter := ""
			if m.vCursor >= 0 && m.vCursor < len(m.vbins) {
				filter = m.vbins[m.vCursor].name
			}
			m.openLog(m.indexOf(it), filter, scVerify)
		}
	case "c":
		if it := m.byKey("verify"); it != nil && it.status == stBuilding {
			it.cancelled = true
			cancel(it)
		}
	case "b", "esc":
		if !m.buildActive() {
			m.screen = scSelect
		}
	}
	return m, nil
}

// ── View ──────────────────────────────────────────────────────────────────────

func (m model) viewVerify() string {
	var b strings.Builder
	writeLine(&b, titleStyle.Render("◆ libmpv"), dimStyle.Render("  binary verification"))

	// ── Summary bar ──
	doneBins := 0
	var p, w, f, na int
	for _, bv := range m.vbins {
		if bv.done {
			doneBins++
		}
		cp, cw, cf, cna := bv.counts()
		p, w, f, na = p+cp, w+cw, f+cf, na+cna
	}
	if m.vSummary { // final tallies from the verifier are authoritative
		p, w, f, na = m.vPassed, m.vWarned, m.vFailed, m.vNA
	}
	total := len(m.vbins)
	bar := progressBar(doneBins, maxInt(total, 1), clampInt(m.width/4, 8, 26))
	tally := okStyle.Render(fmt.Sprintf("✓ %d passed", p)) + "   " +
		warnStyle.Render(fmt.Sprintf("⚠ %d warned", w)) + "   " +
		failStyle.Render(fmt.Sprintf("✗ %d failed", f))
	if na > 0 {
		tally += "   " + faintStyle.Render(fmt.Sprintf("∅ %d n/a", na))
	}
	writeLine(&b, bar, "  ", dimStyle.Render(fmt.Sprintf("%d/%d binaries", doneBins, total)), "   ", tally)
	if m.vXaudit != "" {
		gl, gs := "✓", okStyle
		if m.vXaudit == "fail" {
			gl, gs = "✗", failStyle
		}
		writeLine(&b, truncate(gs.Render(gl+" cross-platform API: ")+dimStyle.Render(m.vXauditMsg), m.width))
	}
	writeLine(&b, hrule(m.width))

	// ── Environment-prep banner (docker daemon / image steps) ──
	for _, it := range m.auxItems() {
		msg := dockerStepMsg(it.t.Key)
		switch it.status {
		case stBuilding:
			writeLine(&b,
				lipgloss.NewStyle().Foreground(cRun).Render(spinnerFrames[m.spinPos]+" "+msg),
				dimStyle.Render("  "+m.timeCell(it)),
			)
			writeLine(&b, dimStyle.Render("  press Enter to watch"))
		case stQueued:
			writeLine(&b, dimStyle.Render("◌ "+msg+" (queued)"))
		case stFailed:
			writeLine(&b, failStyle.Render("✗ "+msg+" failed — press Enter for the log"))
		}
	}

	if len(m.vbins) == 0 {
		b.WriteByte('\n')
		writeLine(&b, dimStyle.Render("waiting for the verifier to start…"))
		return m.verifyFrame(b.String())
	}

	// Is the verifier still running? Tells "in progress" from "interrupted".
	verifyAlive := false
	if it := m.byKey("verify"); it != nil && it.status == stBuilding {
		verifyAlive = true
	}

	// ── Binary list: status · name · platform · tally ──
	nameW := 12
	for _, bv := range m.vbins {
		if l := len(vShortName(bv.name)); l > nameW {
			nameW = l
		}
	}
	nameW = clampInt(nameW, 12, 26)
	interrupted := false
	for i, bv := range m.vbins {
		gl, gs := m.overall(bv, verifyAlive)
		if !bv.done && !verifyAlive {
			interrupted = true
		}
		cp, cw, cf, cna := bv.counts()
		t := okStyle.Render(fmt.Sprintf("%2d ✓", cp))
		if cw > 0 {
			t += "  " + warnStyle.Render(fmt.Sprintf("%d ⚠", cw))
		}
		if cf > 0 {
			t += "  " + failStyle.Render(fmt.Sprintf("%d ✗", cf))
		}
		if cna > 0 {
			t += "  " + faintStyle.Render(fmt.Sprintf("%d ∅", cna))
		}
		marker, name := "  ", textStyle.Render(padTrunc(vShortName(bv.name), nameW))
		if i == m.vCursor {
			acc := lipgloss.NewStyle().Foreground(cAccent).Bold(true)
			marker, name = acc.Render("▸ "), acc.Render(padTrunc(vShortName(bv.name), nameW))
		}
		row := marker + gs.Render(gl) + " " + name + "  " + dimStyle.Render(padTrunc(bv.platform, 9)) + "  " + t
		writeLine(&b, truncate(row, m.width))
	}
	if interrupted {
		writeLine(&b,
			lipgloss.NewStyle().Foreground(cCancel).Render("⊘ the verifier stopped before finishing"),
			dimStyle.Render(" — press Enter for the log"),
		)
	}

	// ── Detail for the focused binary, grouped by phase ──
	// Each phase is a section header with its tally; failing/warning checks are
	// spelled out underneath while all-green phases stay collapsed, and the phase
	// currently running shows a spinner (so a slow phase never looks frozen).
	bv := m.vbins[clampInt(m.vCursor, 0, len(m.vbins)-1)]
	b.WriteByte('\n')
	writeLine(&b, hdrStyle.Render("Checks — "+vShortName(bv.name)), dimStyle.Render("   (Enter for the full log)"))

	byPhase := map[string][]vcheck{}
	for _, c := range bv.checks {
		byPhase[c.phase] = append(byPhase[c.phase], c)
	}
	var lines []string
	for _, ph := range verifyPhaseOrder {
		st := bv.phase[ph.id]
		checks := byPhase[ph.id]
		if st == psNone && len(checks) == 0 {
			continue // phase not reached on this binary
		}
		var pp, pw, pf int
		for _, c := range checks {
			switch c.status {
			case "pass":
				pp++
			case "warn":
				pw++
			case "fail":
				pf++
			}
		}
		hg, hs := m.vGlyph(st)
		if bv.cur == ph.id && verifyAlive {
			hg, hs = spinnerFrames[m.spinPos], lipgloss.NewStyle().Foreground(cRun)
		}
		cnt := ""
		if pp > 0 {
			cnt += okStyle.Render(fmt.Sprintf("%d ✓", pp))
		}
		if pw > 0 {
			cnt += "  " + warnStyle.Render(fmt.Sprintf("%d ⚠", pw))
		}
		if pf > 0 {
			cnt += "  " + failStyle.Render(fmt.Sprintf("%d ✗", pf))
		}
		lines = append(lines, hs.Render(hg)+" "+textStyle.Render(padTrunc(ph.label, 24))+"  "+cnt)
		for _, c := range checks { // expand problems, and N/A so its reason shows
			if c.status == "fail" || c.status == "warn" || c.status == "na" {
				gl, gs := m.vGlyph(statusFromStr(c.status))
				lines = append(lines, "     "+gs.Render(gl)+" "+truncate(c.msg, maxInt(1, m.width-7)))
			}
		}
		if len(checks) == 0 && bv.cur == ph.id && verifyAlive {
			lines = append(lines, "     "+dimStyle.Render("running…"))
		}
	}
	if len(lines) == 0 {
		lines = append(lines, dimStyle.Render("waiting…"))
	}

	limit := m.height - lipgloss.Height(b.String()) - 3 // leave room for rule + help
	if limit < 1 {
		limit = 1
	}
	for idx, ln := range lines {
		if idx >= limit {
			writeLine(&b, dimStyle.Render(fmt.Sprintf("  +%d more (Enter for the full log)", len(lines)-idx)))
			break
		}
		writeLine(&b, ln)
	}

	return m.verifyFrame(b.String())
}

// verifyFrame appends the rule + help bar shared by every state of the screen.
func (m model) verifyFrame(body string) string {
	help := helpBar(
		[2]string{"↑↓", "binary"},
		[2]string{"⏎", "raw log"},
		[2]string{"c", "cancel"},
		[2]string{"esc", "back"},
		[2]string{"q", "quit"},
	)
	return m.anchorBottom(body, hrule(m.width)+"\n"+help)
}
