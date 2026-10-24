# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Close the audio output and destroy the audio device hotplug on the core
thread that created them.

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

The audio output has the same split. The core thread opens it, and with
gapless audio on (mpv's default, weak) a quit does not close it: playback
ends without uninit_audio_out(), and mp_destroy() closes it on the
caller's thread. The WASAPI output unregisters its own
IMMNotificationClient there and calls CoUninitialize() on a thread that
never ran its CoInitializeEx(), the same sequence as the hotplug, at every
dispose of a player that has a file loaded.

This patch closes the output, then destroys the hotplug, at the end of
core_thread(), after mp_shutdown_clients() has returned: no client is left
to read the device list or reopen the output, and mp_destroy() and
command_uninit() then find both gone. The drain rule of
uninit_audio_out() is unchanged, and the quit has already reset the
output, so there is nothing left to drain. Init and uninit run on one
thread on every platform; the other outputs and hotplugs are only closed a
moment earlier.

Usage: patch_hotplug_core_thread.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_lib"))
import anchor  # noqa: E402

MARKER = "MAK_HOTPLUG_CORE_THREAD_PATCH_V2"


def apply(p):
    p.edits("player/command.h", [(
        "void command_uninit(struct MPContext *mpctx);\n",
        "void command_uninit(struct MPContext *mpctx);\n"
        f"// {MARKER}: destroy the AO hotplug on the thread that created it.\n"
        "void command_destroy_hotplug(struct MPContext *mpctx);\n",
    )])

    p.edits("player/command.c", [(
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

    p.edits("player/client.c", [(
        "    mp_shutdown_clients(mpctx);\n"
        "\n"
        "    MP_THREAD_RETURN();\n",
        "    mp_shutdown_clients(mpctx);\n"
        "\n"
        f"    // {MARKER}: no client is left to read the device list or reopen\n"
        "    // the output, so both go now, on the thread that created them,\n"
        "    // instead of on the thread that destroys the last mpv_handle. With\n"
        "    // gapless audio a quit leaves the output open; it goes first.\n"
        "    uninit_audio_out(mpctx);\n"
        "    command_destroy_hotplug(mpctx);\n"
        "\n"
        "    MP_THREAD_RETURN();\n",
    )])


anchor.main(apply, "patch_hotplug_core_thread", marker=MARKER)
