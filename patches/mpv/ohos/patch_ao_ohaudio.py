#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Adds ao_ohaudio, mpv's audio output on OpenHarmony and HarmonyOS (OHOS
build only).

Problem
=======

mpv has no audio output for OHOS. An app there plays PCM through OHAudio
(libohaudio.so of the native SDK); OpenSL ES is deprecated and ALSA is not
open to apps.

Origin
======

ao_ohaudio/ao_ohaudio.c is the driver Bao Han wrote for
github.com/ErBWs/mpv (branch feat-ohos-0.41.0, 6edeee00, LGPL-2.1+), the
one the NaivG/bilimusic app ships, reworked here: its copyright notice
and mpv's license stay in the file.

Design
======

A pull output, like the original: OHAudio's write callback reads with
ao_read_data. What the rework adds, from the OpenHarmony 7.0 sources of
the client (multimedia_audio_framework, renderer_in_client*.cpp):

    callback thread          ao_ohaudio                 core (buffer.c)
      OnWriteData ───────►   ao_read_data               reset, start,
      (buffer queued                                    set_pause
       after it returns) ◄── VALID or INVALID   ◄────   generation++,
                                                        wait, Pause, Flush

- Flush drops the queued buffers but does not wait for a callback in
  flight: each reset bumps a generation and waits for it first, and a
  callback that crossed a reset answers INVALID (its buffer is dropped).
- The clock: frames heard follow the time from the last start, between 0
  and the frames handed out, set every 200 ms from GetTimestamp (CLOCK
  MONOTONIC, the clock of mp_time_ns). Flush resets the position, so after
  a reset it counts the epoch's frames; one that goes back is set against
  the clock again, and one from before the last start is stale.
- Interruptions: a forced pause or stop freezes the clock; the resume hint
  starts the stream again from a control thread, never from the callback
  (Start waits for the server). The same thread asks for a reload after a
  second with no callback while playing: a dead device, a Start that
  failed. An error callback asks for one too.
- A shared interruption and the old device gone are the app's to act on:
  logged only.
- Formats: S16 or S32 interleaved, mono or stereo, 8 to 192 kHz: mpv
  converts the rest (F32 needs API 17, multichannel needs layouts).
- Only API 12 or older (HarmonyOS 5.0): libmpv binds at load (-z now), so
  a newer symbol would keep it from loading on an older system;
  scripts/verify/ohos.sh holds the list.

Files patched
=============

    audio/out/ao_ohaudio.c   NEW, the driver
    audio/out/ao.c           the driver, after audiotrack
    meson.options            the ohaudio feature
    meson.build              ao_ohaudio.c with libohaudio

OHOS only: the feature needs libohaudio, which only the native SDK's
sysroot has, and build_libmpv_ohos.sh passes -Dohaudio=enabled. Not a
toggle: without it the OHOS build has no sound.

Usage: patch_ao_ohaudio.py <mpv source dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = 'MAK_AO_OHAUDIO_PATCH_V1'

AO_EXTERN = 'extern const struct ao_driver audio_out_audiotrack;'
AO_EXTERN_PATCHED = (
    AO_EXTERN + '\n'
    '/* ' + MARKER + ' */\n'
    'extern const struct ao_driver audio_out_ohaudio;'
)

AO_LIST = (
    '#if HAVE_AUDIOTRACK\n'
    '    &audio_out_audiotrack,\n'
    '#endif\n'
)
AO_LIST_PATCHED = AO_LIST + (
    '#if HAVE_OHAUDIO\n'
    '    &audio_out_ohaudio,\n'
    '#endif\n'
)

OPTION = (
    "option('audiotrack', type: 'feature', value: 'auto', "
    "description: 'Android AudioTrack audio output')"
)
OPTION_PATCHED = (
    OPTION + '\n'
    '# ' + MARKER + '\n'
    "option('ohaudio', type: 'feature', value: 'auto', "
    "description: 'OpenHarmony OHAudio output')"
)

MESON = (
    "if features['audiotrack']\n"
    "    sources += files('audio/out/ao_audiotrack.c')\n"
    "endif\n"
)
MESON_PATCHED = MESON + (
    '\n'
    '# ' + MARKER + '\n'
    "ohaudio = cc.find_library('ohaudio', required: get_option('ohaudio'))\n"
    "features += {'ohaudio': ohaudio.found() and\n"
    "                        cc.has_header('ohaudio/native_audiorenderer.h')}\n"
    "if features['ohaudio']\n"
    "    dependencies += ohaudio\n"
    "    sources += files('audio/out/ao_ohaudio.c')\n"
    "endif\n"
)


def apply(p):
    # The C source lives in ao_ohaudio/ next to this script: edit it there,
    # this patch copies it into the tree.
    p.new_file('audio/out/ao_ohaudio.c', p.asset('ao_ohaudio/ao_ohaudio.c'))
    p.edits('audio/out/ao.c', [
        ('ao.c driver externs', AO_EXTERN, AO_EXTERN_PATCHED),
        ('ao.c native drivers', AO_LIST, AO_LIST_PATCHED),
    ])
    p.edits('meson.options', [('audiotrack option', OPTION, OPTION_PATCHED)])
    p.edits('meson.build', [('audiotrack sources', MESON, MESON_PATCHED)])


anchor.main(apply, 'patch_ao_ohaudio', marker=MARKER, usage='<mpv_src_dir>')
