// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import "testing"

func feedVerify(m *model, evs ...string) {
	for _, e := range evs {
		m.applyVerifyEvent(e)
	}
}

// A check failure outranks any number of passes in the same phase; a warn
// outranks a pass; an info-only phase and a never-entered phase both settle to
// "skip" (rendered as n/a) once the binary is done.
func TestVerifyAggregation(t *testing.T) {
	m := &model{}
	feedVerify(m,
		"@@V1@@\tbin\tlibmpv_linux-x86_64.so\tlinux",
		"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tpatches\tpass\tok",
		"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tpatches\tfail\tmissing waveform-data",
		"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\texports\tpass\t54/54",
		"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tfilters\twarn\tone sampled filter missing",
		"@@V1@@\tcheck\tlibmpv_linux-x86_64.so\tl13\tinfo\tskipped on linux",
		"@@V1@@\tbindone\tlibmpv_linux-x86_64.so",
	)

	b := m.vbinIdx["libmpv_linux-x86_64.so"]
	if b == nil {
		t.Fatal("binary row not created")
	}
	if b.platform != "linux" {
		t.Errorf("platform = %q, want linux", b.platform)
	}
	cases := map[string]phaseStatus{
		"patches": psFail, // fail outranks the earlier pass
		"exports": psPass,
		"filters": psWarn,
		"l13":     psSkip, // info → skip
		"fmt":     psSkip, // never entered → skip at bindone
	}
	for ph, want := range cases {
		if got := b.phase[ph]; got != want {
			t.Errorf("phase %q = %v, want %v", ph, got, want)
		}
	}
	if !b.done {
		t.Error("binary should be marked done")
	}
}

// A worse status is never downgraded by a later milder one.
func TestVerifyWarnNotDowngradedByPass(t *testing.T) {
	m := &model{}
	feedVerify(m,
		"@@V1@@\tbin\tlibmpv_android-arm64-v8a.so\tandroid",
		"@@V1@@\tcheck\tlibmpv_android-arm64-v8a.so\tfilters\twarn\tmissing",
		"@@V1@@\tcheck\tlibmpv_android-arm64-v8a.so\tfilters\tpass\tlater pass",
	)
	if got := m.vbinIdx["libmpv_android-arm64-v8a.so"].phase["filters"]; got != psWarn {
		t.Errorf("filters = %v, want psWarn (pass must not downgrade warn)", got)
	}
}

// An "na" check (a category intentionally not-applicable to this platform) maps
// to the distinct psNA state — kept apart from a pass and from an info-only
// skip — and is tallied as N/A, not as a pass, so the per-OS counts stay
// explainable. Its reason text is preserved for the report.
func TestVerifyNotApplicable(t *testing.T) {
	m := &model{}
	feedVerify(m,
		"@@V1@@\tbin\tlibmpv_macos.xcframework.zip\tmacos",
		"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tl11\tpass\tNEEDED ok",
		"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tl12\tna\tnm/ELF-based; resolved by dyld",
		"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tl13\tna\tneeds Apple dyld",
		"@@V1@@\tcheck\tlibmpv_macos.xcframework.zip\tl14\tna\tAndroid-only",
		"@@V1@@\tbindone\tlibmpv_macos.xcframework.zip",
	)
	b := m.vbinIdx["libmpv_macos.xcframework.zip"]
	if b == nil {
		t.Fatal("binary row not created")
	}
	for _, ph := range []string{"l12", "l13", "l14"} {
		if got := b.phase[ph]; got != psNA {
			t.Errorf("phase %q = %v, want psNA", ph, got)
		}
	}
	if b.phase["l11"] != psPass {
		t.Errorf("l11 = %v, want psPass", b.phase["l11"])
	}
	pass, warn, fail, na := b.counts()
	if pass != 1 || warn != 0 || fail != 0 || na != 3 {
		t.Errorf("counts = (pass=%d warn=%d fail=%d na=%d), want (1,0,0,3)", pass, warn, fail, na)
	}
	if got := b.checks[1].msg; got != "nm/ELF-based; resolved by dyld" {
		t.Errorf("na reason not preserved: %q", got)
	}
}

// A phase that has been entered but not yet resolved shows as running.
func TestVerifyRunningState(t *testing.T) {
	m := &model{}
	feedVerify(m,
		"@@V1@@\tbin\tlibmpv_linux-aarch64.so\tlinux",
		"@@V1@@\tphase\tlibmpv_linux-aarch64.so\tl13",
	)
	b := m.vbinIdx["libmpv_linux-aarch64.so"]
	if b.phase["l13"] != psRunning {
		t.Errorf("l13 = %v, want psRunning", b.phase["l13"])
	}
	if b.done {
		t.Error("binary should not be done yet")
	}
}

// Global checks (cross-platform audit) carry no binary name and must not create
// a phantom row; xaudit/summary events populate their own fields.
func TestVerifyGlobalsAndSummary(t *testing.T) {
	m := &model{}
	feedVerify(m,
		"@@V1@@\tcheck\t\txaudit\tpass\tno binary here",
		"@@V1@@\txaudit\tpass\tAPI surface identical across 9 binaries (hash abc123)",
		"@@V1@@\tsummary\t128\t1\t3\t11\t9",
	)
	if len(m.vbins) != 0 {
		t.Errorf("expected no binary rows, got %d", len(m.vbins))
	}
	if m.vXaudit != "pass" {
		t.Errorf("vXaudit = %q, want pass", m.vXaudit)
	}
	if !m.vSummary || m.vPassed != 128 || m.vFailed != 1 || m.vWarned != 3 || m.vNA != 11 || m.vFound != 9 {
		t.Errorf("summary mis-parsed: passed=%d failed=%d warned=%d na=%d found=%d summary=%v",
			m.vPassed, m.vFailed, m.vWarned, m.vNA, m.vFound, m.vSummary)
	}
}

// A check message containing tabs keeps its tail intact: the line is split with
// limit 7 (to leave room for the summary's numeric fields) and the check case
// rejoins f[5]+f[6] so a tab-bearing diagnostic is preserved verbatim.
func TestVerifyMessageWithTabs(t *testing.T) {
	m := &model{}
	feedVerify(m,
		"@@V1@@\tbin\tlibmpv_windows-x86_64.dll\twindows",
		"@@V1@@\tcheck\tlibmpv_windows-x86_64.dll\tl11\tfail\tforbidden dep\textra\tcolumns",
	)
	b := m.vbinIdx["libmpv_windows-x86_64.dll"]
	if b.phase["l11"] != psFail {
		t.Fatalf("l11 = %v, want psFail", b.phase["l11"])
	}
	if got := b.checks[0].msg; got != "forbidden dep\textra\tcolumns" {
		t.Errorf("msg = %q, want the tail preserved verbatim", got)
	}
}
