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
  short `mp_sleep_ns` (and restore it after). In this audio-only build the
  only `mp_sleep_ns` callers are rare audio-output *retry* paths, so the
  global timer resolution effectively never changes.
- "always": call `NtSetTimerResolution(1ms, TRUE)` ONCE at init and never
  restore it — the whole process (and system) timer resolution is pinned at
  1 ms for the player's lifetime.

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

Fix: force the auto policy to "perwait" unconditionally. `perwait` is mpv's
own Windows-10 default and works on every Windows version
(`NtSetTimerResolution` has existed since XP; the per-wait raise is restored
immediately and the sleep callers are rare retry paths). An explicit
`MPV_HRT=always|never|perwait` still overrides it.

Windows-only: `osdep/timer-win32.c` is compiled only on Windows, so this
patch lives here and is applied (gated on the toggleable `timer_resolution`
patch id) inline from build_libmpv_windows.sh — never from the shared
apply_mpv_patches_common. Idempotent. Fails loud if the upstream anchor
changes (an mpv version bump that rewrites this line must be re-reviewed);
no-ops with a message if the file is absent (a future source-layout change).

Usage: patch_timer_resolution.py <mpv_source_dir>
"""
import os
import sys

if len(sys.argv) != 2:
    sys.exit("usage: patch_timer_resolution.py <mpv_source_dir>")

fn = os.path.join(sys.argv[1], "osdep", "timer-win32.c")
if not os.path.exists(fn):
    print(f"Nothing to patch: {fn} not present (no-op)")
    sys.exit(0)

with open(fn, encoding="utf-8") as f:
    content = f.read()

PATCHED_MARKER = 'v = "perwait"; // mpv_audio_kit'
if PATCHED_MARKER in content:
    print(f"Nothing to patch in {fn} (already patched)")
    sys.exit(0)

ANCHOR = '        v = IsWindows10OrGreater() ? "perwait" : "always";'
REPLACEMENT = (
    '        // mpv_audio_kit: never pin the global Windows timer resolution\n'
    '        // (DWM frame-sync interference in the host GUI). Force "perwait"\n'
    '        // so the 1 ms resolution is only raised around the rare audio-\n'
    '        // output retry sleeps, never globally at init.\n'
    '        v = "perwait"; // mpv_audio_kit'
)

if ANCHOR not in content:
    print(
        f"ERROR: timer-resolution anchor not found in {fn}.\n"
        "The upstream mp_raw_time_init policy line changed — re-review "
        "osdep/timer-win32.c against this patch before shipping.",
        file=sys.stderr,
    )
    sys.exit(1)

content = content.replace(ANCHOR, REPLACEMENT, 1)
with open(fn, "w", encoding="utf-8") as f:
    f.write(content)
print(f"Patched {fn}: forced high-res-timer policy to perwait")
