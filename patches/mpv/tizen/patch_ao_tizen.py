#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Adds ao_tizen, mpv's audio output on Tizen (Tizen build only).

Problem
=======

mpv has no audio output for Tizen. The system's PulseAudio is not an API
for apps: a Tizen app plays PCM through audio_out of capi-media-audio-io,
and its ALSA devices are not open to it either.

Design
======

A pull output, the shape of ao_audiotrack:

    ao/tizen thread                          Tizen sound server
      ao_read_data ── audio_out_write ──►    the stream, ~50 ms periods
                      (blocks while full)

audio_out_write (capi-media-audio-io 0.5.39, Tizen 6.0) holds the
handle's lock for its whole call and waits while the stream has no room,
failing after 5 s; audio_out_pause and audio_out_flush take the same
lock, so they wait for a write in flight; a write on a paused handle
fails. So:

- the thread only reads and writes, and start, reset and set_pause change
  the handle's state from the core;
- a chunk read when a pause arrives stays pending, written first on the
  resume: a pause loses nothing;
- a reset bumps a generation, so a write in flight across it counts for
  nothing (its frames were flushed);
- a refused write while playing is tried again after 100 ms, logged once.

audio_out reports no position and no latency. The frames heard follow the
clock from the last start or resume, held between 0 and the frames
written: the queue is what was written past them, and out_time follows
it. The sink's own latency is not seen.

The device takes 8 to 192 kHz, mono or stereo (multichannel output is
not supported by audio_out_create_new), S16 or S32; mpv converts the
rest. The stream carries the media type (sound_manager stream
information); the playback focus is the app's to take.

Files patched
=============

    audio/out/ao_tizen.c   NEW, the driver
    audio/out/ao.c         the driver, after audiotrack
    meson.options          the tizen-audio feature
    meson.build            ao_tizen.c with capi-media-audio-io and
                           capi-media-sound-manager

Tizen only: the feature needs both pkg-config packages, which only a
Tizen sysroot has, and build_libmpv_tizen.sh passes
-Dtizen-audio=enabled. Not a toggle: without it the Tizen build has no
sound.

Usage: patch_ao_tizen.py <mpv source dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = 'MAK_AO_TIZEN_PATCH_V1'

AO_EXTERN = 'extern const struct ao_driver audio_out_audiotrack;'
AO_EXTERN_PATCHED = (
    AO_EXTERN + '\n'
    '/* ' + MARKER + ' */\n'
    'extern const struct ao_driver audio_out_tizen;'
)

# After audiotrack, so the anchor of patch_ao_webaudio.py stays as it is.
AO_LIST = (
    '#if HAVE_AUDIOTRACK\n'
    '    &audio_out_audiotrack,\n'
    '#endif\n'
)
AO_LIST_PATCHED = AO_LIST + (
    '#if HAVE_TIZEN_AUDIO\n'
    '    &audio_out_tizen,\n'
    '#endif\n'
)

OPTION = (
    "option('audiotrack', type: 'feature', value: 'auto', "
    "description: 'Android AudioTrack audio output')"
)
OPTION_PATCHED = (
    OPTION + '\n'
    '# ' + MARKER + '\n'
    "option('tizen-audio', type: 'feature', value: 'auto', "
    "description: 'Tizen audio_out output')"
)

MESON = (
    "if features['audiotrack']\n"
    "    sources += files('audio/out/ao_audiotrack.c')\n"
    "endif\n"
)
MESON_PATCHED = MESON + (
    '\n'
    '# ' + MARKER + '\n'
    "tizen_audio_io = dependency('capi-media-audio-io',\n"
    "                            required: get_option('tizen-audio'))\n"
    "tizen_sound_manager = dependency('capi-media-sound-manager',\n"
    "                                 required: get_option('tizen-audio'))\n"
    "features += {'tizen-audio': tizen_audio_io.found() and\n"
    "                            tizen_sound_manager.found()}\n"
    "if features['tizen-audio']\n"
    "    dependencies += [tizen_audio_io, tizen_sound_manager]\n"
    "    sources += files('audio/out/ao_tizen.c')\n"
    "endif\n"
)


def apply(p):
    # The C source lives in ao_tizen/ next to this script: edit it there,
    # this patch copies it into the tree.
    p.new_file('audio/out/ao_tizen.c', p.asset('ao_tizen/ao_tizen.c'))
    p.edits('audio/out/ao.c', [
        ('ao.c driver externs', AO_EXTERN, AO_EXTERN_PATCHED),
        ('ao.c native drivers', AO_LIST, AO_LIST_PATCHED),
    ])
    p.edits('meson.options', [('audiotrack option', OPTION, OPTION_PATCHED)])
    p.edits('meson.build', [('audiotrack sources', MESON, MESON_PATCHED)])


anchor.main(apply, 'patch_ao_tizen', marker=MARKER, usage='<mpv_src_dir>')
