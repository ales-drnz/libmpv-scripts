# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Destroy the audio device hotplug on the core thread that created it.

Reading `audio-device-list` (or printing `audio-device`) creates the AO
hotplug from a property getter, which runs on mpv's core thread. With
libmpv the core is destroyed by whatever thread destroys the last
mpv_handle: mp_destroy_client() joins the core thread, then calls
mp_destroy() -> command_uninit() -> ao_hotplug_destroy() on the caller's
thread.

On Windows the WASAPI hotplug is COM. hotplug_init() runs CoInitializeEx()
and registers an IMMNotificationClient on the core thread; hotplug_uninit()
then unregisters it, releases the enumerator and calls CoUninitialize() on a
thread that never initialized COM. That unbalanced teardown crashes the
process with an access violation, or corrupts the heap (mpv's ta canary
assertion), as soon as a client that observed `audio-device-list` destroys
the core: every Player dispose in mpv_audio_kit. The mpv CLI is not hit,
since its core runs on the main thread that also destroys it.

This patch destroys the hotplug at the end of core_thread(), after
mp_shutdown_clients() has returned: no client is left to read the device
list and recreate it, and command_uninit() then finds it gone. Init and
uninit run on one thread on every platform; PulseAudio, PipeWire and
CoreAudio hotplugs are only closed a moment earlier.

Usage: patch_hotplug_core_thread.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "MAK_HOTPLUG_CORE_THREAD_PATCH_V1"

root = Path(sys.argv[1])
client = root / "player/client.c"
command = root / "player/command.c"
command_h = root / "player/command.h"

# Every anchor is checked before any file is written, so a mismatch leaves
# the tree as it was instead of half patched.
pending: list[tuple[Path, str]] = []


def patch(path: Path, edits: list[tuple[str, str]]) -> None:
    text = path.read_text()
    if MARKER in text:
        print(f"Already patched: {path.name}")
        return
    for old, new in edits:
        if text.count(old) != 1:
            sys.exit(
                f"patch_hotplug_core_thread: anchor not found once in {path}: "
                f"{old!r}"
            )
        text = text.replace(old, new, 1)
    pending.append((path, text))


patch(command_h, [(
    "void command_uninit(struct MPContext *mpctx);\n",
    "void command_uninit(struct MPContext *mpctx);\n"
    f"// {MARKER}: destroy the AO hotplug on the thread that created it.\n"
    "void command_destroy_hotplug(struct MPContext *mpctx);\n",
)])

patch(command, [(
    "void command_uninit(struct MPContext *mpctx)\n"
    "{\n",
    f"/* {MARKER}: the hotplug is created by a property getter on the core\n"
    " * thread, and on Windows its WASAPI teardown must run there too (COM is\n"
    " * per thread). core_thread() calls this once no client is left. */\n"
    "void command_destroy_hotplug(struct MPContext *mpctx)\n"
    "{\n"
    "    struct command_ctx *ctx = mpctx->command_ctx;\n"
    "    if (!ctx)\n"
    "        return;\n"
    "    ao_hotplug_destroy(ctx->hotplug);\n"
    "    ctx->hotplug = NULL;\n"
    "}\n"
    "\n"
    "void command_uninit(struct MPContext *mpctx)\n"
    "{\n",
)])

patch(client, [(
    "    mp_shutdown_clients(mpctx);\n"
    "\n"
    "    MP_THREAD_RETURN();\n",
    "    mp_shutdown_clients(mpctx);\n"
    "\n"
    f"    // {MARKER}: no client is left to read the device list, so the\n"
    "    // hotplug goes now, on the thread that created it, instead of on the\n"
    "    // thread that destroys the last mpv_handle.\n"
    "    command_destroy_hotplug(mpctx);\n"
    "\n"
    "    MP_THREAD_RETURN();\n",
)])

for path, text in pending:
    path.write_text(text)
    print(f"Patched: {path}")
