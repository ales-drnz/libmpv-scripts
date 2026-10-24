# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Stop mpv from pinning the system-wide Windows timer resolution to 1 ms.

`osdep/timer-win32.c::mp_raw_time_init` decides a high-resolution-timer
policy at startup (it runs from `mp_create`, i.e. during `mpv_create` /
`mpv_initialize`):

    if (!(v = getenv("MPV_HRT")) || !strcmp(v, "auto"))
        v = IsWindows10OrGreater() ? "perwait" : "always";

- "perwait": raise the 1 ms timer resolution only for the duration of each
  short timed wait (`mp_sleep_ns` and the playloop's `mp_cond_timedwait`)
  and restore it after. No global pin at init — but during PLAYBACK the
  playloop still toggles the global resolution per wait (measured ~2-3x/s
  in this audio-only build; ~0 while idle).
- "always": call `NtSetTimerResolution(1ms, TRUE)` ONCE at init and never
  restore it — the whole process (and system) timer resolution is pinned at
  1 ms for the player's lifetime.
- "never": mpv never calls `NtSetTimerResolution` — the global timer
  resolution is left untouched.

`IsWindows10OrGreater()` (versionhelpers.h) is MANIFEST-shimmed: a host
executable whose manifest does not declare Windows 10 support
(`<supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>`) is reported as
Windows 8, so the check returns false and mpv takes the "always" branch —
even on a real Windows 10/11 machine. Many Flutter apps ship a runner
manifest without that entry, so they hit "always".

A pinned 1 ms timer resolution fights the Desktop Window Manager's frame
synchronisation and shows up as UI micro-stutter / dropped frames in the
host app — instantly at init, even with nothing playing. mpv tolerates this
for a *video* player (it wants the precise timer for A/V sync and owns the
window), but this is a HEADLESS audio library inside a GUI that does its own
rendering: pinning the global timer is never what we want.

Fix: force the auto policy to "never" unconditionally — mpv never calls
`NtSetTimerResolution` at all. "perwait" (the previous fix) removed the init
pin but left the playloop's per-wait raises during playback, and even those
bursty global-resolution transitions still disrupt the host compositor on a
clean high-refresh machine (verified: 67 -> 200 FPS with `MPV_HRT=never`).
"never" is safe for audio: on Windows 10 1803+ mpv's sleeps use
`CreateWaitableTimerExW(CREATE_WAITABLE_TIMER_HIGH_RESOLUTION)`, which is
sub-millisecond accurate INDEPENDENT of the global timer resolution, so
dropping the global raise costs no real precision. An explicit
`MPV_HRT=always|perwait|never` still overrides it.

Windows-only: `osdep/timer-win32.c` is compiled only on Windows, so this
patch lives here and is applied (gated on the toggleable `timer_resolution`
patch id) inline from build_libmpv_windows.sh — never from the shared
apply_mpv_patches_common. Idempotent. Fails loud if the upstream anchor
changes (an mpv version bump that rewrites this line must be re-reviewed);
no-ops with a message if the file is absent (a future source-layout change).

Usage: patch_timer_resolution.py <mpv_source_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

TIMER = "osdep/timer-win32.c"

PATCHED_MARKER = 'v = "never"; // mpv_audio_kit'

ANCHOR = '        v = IsWindows10OrGreater() ? "perwait" : "always";'
REPLACEMENT = (
    '        // mpv_audio_kit: never touch the global Windows timer resolution.\n'
    '        // Even "perwait" leaves per-wait NtSetTimerResolution toggles during\n'
    '        // playback that disrupt the host GUI compositor (DWM) on clean high-\n'
    '        // refresh machines. Force "never"; audio sleep accuracy is preserved\n'
    '        // by the high-resolution waitable timer (Win10 1803+).\n'
    '        ' + PATCHED_MARKER
)


def apply(p):
    if not p.exists(TIMER):
        print(f"Nothing to patch: {TIMER} not present (no-op)")
        return
    # A missing anchor: the upstream mp_raw_time_init policy line changed,
    # re-review osdep/timer-win32.c against this patch before shipping.
    p.edits(TIMER, [("mp_raw_time_init policy line", ANCHOR, REPLACEMENT)])


anchor.main(apply, "patch_timer_resolution", marker=PATCHED_MARKER,
            usage="<mpv_source_dir>")
