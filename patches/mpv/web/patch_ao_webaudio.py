#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Adds ao_webaudio, mpv's audio output in the browser (web build only).

Problem
=======

mpv has no audio output that works in a browser. The ones that build
under Emscripten do not fit: OpenAL and SDL2 queue their audio on the
page's main thread (an AudioBufferSourceNode, a ScriptProcessorNode), so
every long Flutter frame or garbage collection is a hole in the sound,
and their calls from mpv's audio thread wait on the main thread. The Wasm
Audio Worklets of Emscripten run in a context of their own, where mpv's
locks cannot be taken.

Design
======

A push output, the shape buffer.c drives on every platform:

    mpv "ao" thread (buffer.c)              browser audio thread
      write() ── ring in wasm memory ──►  AudioWorkletProcessor "mak-ring"
      get_state(): queued + latency         process(): 128 frames, mixed
                 SharedArrayBuffer, indices with Atomics

- The rings live in a static table (mak_wa_ring.h) that the worklet reads
  with Atomics: one single producer, single consumer ring per open output.
  Nothing waits on the main thread or on the worklet, which can neither
  call into wasm nor wait.
- The format is fixed, like a device: the AudioContext's rate and the
  channel count of the page, float32. mpv resamples and remixes to it.
- Pause keeps the frames and plays silence; a reset (seek, stop) drops
  them without moving the consumer's index. The worklet fades 64 frames
  at every start and stop, and a gap (an underrun) is silence, counted
  once audio comes back.
- get_state reports the queued frames plus the AudioContext's base and
  output latency (the page publishes them), so time-pos follows what is
  heard. A suspended AudioContext (the autoplay policy before a user
  gesture) reads nothing: the ring stays full and time-pos waits.
- ao-volume and ao-mute are the output's gain, applied in the worklet
  after the PCM tap, on the cubic curve of mpv's volume. They are kept in
  the webaudio-volume and webaudio-mute options, so a reopened output
  keeps them.
- webaudio-output picks the AudioWorkletNode an output plays through
  (0 to 15), one node per player when the page wants to route each one.
- A new AudioContext (another rate) or channel count reopens every output
  through ao_request_reload, from the output's own thread.

The page side (the AudioContext, the worklet module, the nodes) is
scripts/web/mak_webaudio.js, linked into the module's glue, and
scripts/web/mak_webaudio_processor.js.

Files patched
=============

    audio/out/ao_webaudio.c   NEW, the driver
    audio/out/mak_wa_ring.h   NEW, the table and the producer side
    audio/out/ao.c            the driver, first of the native ones
    meson.options             the webaudio feature
    meson.build               ao_webaudio.c on emscripten

Web only: the feature requires host_machine.system() == 'emscripten' and
build_libmpv_web.sh passes -Dwebaudio=enabled. Not a toggle: without it
the web build has no sound.

Usage: patch_ao_webaudio.py <mpv source dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = 'MAK_AO_WEBAUDIO_PATCH_V1'

AO_EXTERN = 'extern const struct ao_driver audio_out_aaudio;'
AO_EXTERN_PATCHED = (
    AO_EXTERN + '\n'
    '/* ' + MARKER + ' */\n'
    'extern const struct ao_driver audio_out_webaudio;'
)

# First of the native outputs: the web build has no other.
AO_LIST = (
    '// native:\n'
    '#if HAVE_AUDIOTRACK\n'
)
AO_LIST_PATCHED = (
    '// native:\n'
    '#if HAVE_WEBAUDIO\n'
    '    &audio_out_webaudio,\n'
    '#endif\n'
    '#if HAVE_AUDIOTRACK\n'
)

OPTION = (
    "option('wasapi', type: 'feature', value: 'auto', "
    "description: 'WASAPI audio output')"
)
OPTION_PATCHED = (
    OPTION + '\n'
    '# ' + MARKER + '\n'
    "option('webaudio', type: 'feature', value: 'auto', "
    "description: 'Web Audio output (Emscripten)')"
)

MESON = (
    "if features['wasapi']\n"
    "    sources += files('audio/out/ao_wasapi.c',\n"
    "                     'audio/out/ao_wasapi_changenotify.c',\n"
    "                     'audio/out/ao_wasapi_utils.c')\n"
    "endif\n"
)
MESON_PATCHED = MESON + (
    '\n'
    '# ' + MARKER + '\n'
    "features += {'webaudio': get_option('webaudio').require(\n"
    "    host_machine.system() == 'emscripten').allowed()}\n"
    "if features['webaudio']\n"
    "    sources += files('audio/out/ao_webaudio.c')\n"
    "endif\n"
)


def apply(p):
    # The C sources live in ao_webaudio/ next to this script: edit them
    # there, this patch copies them into the tree.
    for name in ('ao_webaudio.c', 'mak_wa_ring.h'):
        p.new_file('audio/out/' + name, p.asset('ao_webaudio/' + name))
    p.edits('audio/out/ao.c', [
        ('ao.c driver externs', AO_EXTERN, AO_EXTERN_PATCHED),
        ('ao.c native drivers', AO_LIST, AO_LIST_PATCHED),
    ])
    p.edits('meson.options', [('wasapi option', OPTION, OPTION_PATCHED)])
    p.edits('meson.build', [('wasapi sources', MESON, MESON_PATCHED)])


anchor.main(apply, 'patch_ao_webaudio', marker=MARKER, usage='<mpv_src_dir>')
