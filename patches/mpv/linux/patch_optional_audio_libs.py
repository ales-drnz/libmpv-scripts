#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
"""
Make PipeWire and PulseAudio optional at run time (Linux only).

libmpv used to carry DT_NEEDED entries for libpipewire-0.3.so.0 and
libpulse.so.0, so a system missing either could not load libmpv at all,
even to play through ALSA. The Linux build now links both AOs against
Implib.so stubs (tools/implib) instead of the real libraries, and this
patch adds the other half:

  audio/out/mak_dl.{h,c}   mak_pipewire_load / mak_pulse_load open the
                           library once (dlopen, never closed) and report
                           whether it is usable. PipeWire must also be at
                           least 0.3.57, the version mpv's AO is written
                           against: Ubuntu 22.04 ships 0.3.48, and a stub
                           calling a symbol the old library lacks aborts.
                           mak_pipewire_dlopen / mak_pulse_dlopen hand the
                           stubs that same handle (--dlopen-callback), so
                           the guard is the only place that decides.

  audio/out/ao_pipewire.c  init, hotplug_init and list_devs return early
  audio/out/ao_pulse.c     when the library is not usable, before the first
                           stubbed call, so mpv falls through to the next AO
                           in its list (pipewire, pulse, alsa, ...).

  meson.build              compiles mak_dl.c with either AO.

Usage: patch_optional_audio_libs.py <mpv_src_dir>
"""

import os
import sys

MARKER = 'MAK_OPTIONAL_AUDIO_LIBS_PATCH_V1'

MAK_DL_H = '''/* ''' + MARKER + ''' */
#pragma once

#include <stdbool.h>

struct mp_log;

/* Whether the client library can be used, opening it on the first call.
 * Call before any of its functions: they are lazily bound stubs that abort
 * the process if the library is missing. */
bool mak_pipewire_load(struct mp_log *log);
bool mak_pulse_load(struct mp_log *log);

/* dlopen callbacks for the Implib.so stubs: the handle opened above. */
void *mak_pipewire_dlopen(const char *name);
void *mak_pulse_dlopen(const char *name);
'''

MAK_DL_C = '''/* ''' + MARKER + '''
 *
 * Run-time loading of the PipeWire and PulseAudio client libraries, which
 * libmpv links through Implib.so stubs instead of DT_NEEDED entries. See
 * patches/mpv/linux/patch_optional_audio_libs.py in libmpv-scripts.
 */

#include <dlfcn.h>
#include <stdio.h>

#include "common/msg.h"
#include "osdep/threads.h"

#include "audio/out/mak_dl.h"

/* The oldest PipeWire mpv's AO supports (its meson floor). */
#define MAK_PIPEWIRE_MIN_MAJOR 0
#define MAK_PIPEWIRE_MIN_MINOR 3
#define MAK_PIPEWIRE_MIN_MICRO 57

static mp_once pipewire_once = MP_STATIC_ONCE_INITIALIZER;
static void *pipewire_handle;
static char pipewire_error[256];

static mp_once pulse_once = MP_STATIC_ONCE_INITIALIZER;
static void *pulse_handle;
static char pulse_error[256];

static void open_pipewire(void)
{
    void *h = dlopen("libpipewire-0.3.so.0", RTLD_LAZY | RTLD_GLOBAL);
    if (!h) {
        snprintf(pipewire_error, sizeof(pipewire_error), "%s", dlerror());
        return;
    }
    const char *(*get_version)(void) =
        (const char *(*)(void))dlsym(h, "pw_get_library_version");
    int major = 0, minor = 0, micro = 0;
    if (!get_version ||
        sscanf(get_version(), "%d.%d.%d", &major, &minor, &micro) != 3)
    {
        snprintf(pipewire_error, sizeof(pipewire_error),
                 "cannot read the library version");
        return;
    }
    if (major != MAK_PIPEWIRE_MIN_MAJOR ? major < MAK_PIPEWIRE_MIN_MAJOR :
        minor != MAK_PIPEWIRE_MIN_MINOR ? minor < MAK_PIPEWIRE_MIN_MINOR :
        micro < MAK_PIPEWIRE_MIN_MICRO)
    {
        snprintf(pipewire_error, sizeof(pipewire_error),
                 "version %d.%d.%d is older than %d.%d.%d", major, minor,
                 micro, MAK_PIPEWIRE_MIN_MAJOR, MAK_PIPEWIRE_MIN_MINOR,
                 MAK_PIPEWIRE_MIN_MICRO);
        return;
    }
    pipewire_handle = h;
}

static void open_pulse(void)
{
    pulse_handle = dlopen("libpulse.so.0", RTLD_LAZY | RTLD_GLOBAL);
    if (!pulse_handle)
        snprintf(pulse_error, sizeof(pulse_error), "%s", dlerror());
}

bool mak_pipewire_load(struct mp_log *log)
{
    mp_exec_once(&pipewire_once, open_pipewire);
    if (!pipewire_handle)
        mp_verbose(log, "PipeWire unavailable: %s\\n", pipewire_error);
    return pipewire_handle;
}

bool mak_pulse_load(struct mp_log *log)
{
    mp_exec_once(&pulse_once, open_pulse);
    if (!pulse_handle)
        mp_verbose(log, "PulseAudio unavailable: %s\\n", pulse_error);
    return pulse_handle;
}

void *mak_pipewire_dlopen(const char *name)
{
    (void)name;
    mp_exec_once(&pipewire_once, open_pipewire);
    return pipewire_handle;
}

void *mak_pulse_dlopen(const char *name)
{
    (void)name;
    mp_exec_once(&pulse_once, open_pulse);
    return pulse_handle;
}
'''


def guard(name):
    return (
        f'    /* {MARKER} */\n'
        f'    if (!mak_{name}_load(ao->log))\n'
        f'        return{{ret}};\n'
    )


PIPEWIRE_EDITS = [
    ('include',
     '#include "internal.h"\n',
     '#include "internal.h"\n'
     f'/* {MARKER} */\n'
     '#include "audio/out/mak_dl.h"\n'),
    # Before the declarations below it: pw_properties_new runs in one.
    ('init',
     'static int init(struct ao *ao)\n'
     '{\n'
     '    struct priv *p = ao->priv;\n',
     'static int init(struct ao *ao)\n'
     '{\n'
     '    struct priv *p = ao->priv;\n'
     + guard('pipewire').format(ret=' -1')),
    ('hotplug_init',
     'static int hotplug_init(struct ao *ao)\n'
     '{\n'
     '    struct priv *priv = ao->priv;\n'
     '\n'
     '    int res = pipewire_init_boilerplate(ao);\n',
     'static int hotplug_init(struct ao *ao)\n'
     '{\n'
     '    struct priv *priv = ao->priv;\n'
     + guard('pipewire').format(ret=' -1') +
     '\n'
     '    int res = pipewire_init_boilerplate(ao);\n'),
    ('list_devs',
     '    ao_device_list_add(list, ao, &(struct ao_device_desc){0});\n',
     '    ao_device_list_add(list, ao, &(struct ao_device_desc){0});\n'
     + guard('pipewire').format(ret='')),
]

PULSE_EDITS = [
    ('include',
     '#include "internal.h"\n',
     '#include "internal.h"\n'
     f'/* {MARKER} */\n'
     '#include "audio/out/mak_dl.h"\n'),
    ('init',
     '    char *sink = ao->device;\n'
     '\n'
     '    if (pa_init_boilerplate(ao) < 0)\n',
     '    char *sink = ao->device;\n'
     '\n'
     + guard('pulse').format(ret=' -1') +
     '    if (pa_init_boilerplate(ao) < 0)\n'),
    ('hotplug_init',
     'static int hotplug_init(struct ao *ao)\n'
     '{\n'
     '    struct priv *priv = ao->priv;\n'
     '    if (pa_init_boilerplate(ao) < 0)\n',
     'static int hotplug_init(struct ao *ao)\n'
     '{\n'
     '    struct priv *priv = ao->priv;\n'
     + guard('pulse').format(ret=' -1') +
     '    if (pa_init_boilerplate(ao) < 0)\n'),
    ('list_devs',
     '    struct sink_cb_ctx ctx = {ao, list};\n',
     '    struct sink_cb_ctx ctx = {ao, list};\n'
     + guard('pulse').format(ret='')),
]

MESON_EDITS = [
    ('mak_dl.c source',
     "    sources += files('audio/out/ao_pulse.c')\n"
     'endif\n',
     "    sources += files('audio/out/ao_pulse.c')\n"
     'endif\n'
     f'# {MARKER}\n'
     "if features['pipewire'] or features['pulse']\n"
     "    sources += files('audio/out/mak_dl.c')\n"
     'endif\n'),
]


def apply_edits(path, edits):
    with open(path) as f:
        text = f.read()
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    for name, pristine, patched in edits:
        count = text.count(pristine)
        if count != 1:
            raise RuntimeError(
                f'Pristine anchor ({name}) found {count} times in {path}, '
                f'expected 1.'
            )
        text = text.replace(pristine, patched, 1)
    with open(path, 'w') as f:
        f.write(text)
    print(f'Patched: {path}')


def write_new_file(path, content):
    with open(path, 'w') as f:
        f.write(content)
    print(f'Wrote:    {path}')


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <mpv_src_dir>')
        sys.exit(1)
    src = sys.argv[1]
    out = os.path.join(src, 'audio', 'out')
    write_new_file(os.path.join(out, 'mak_dl.h'), MAK_DL_H)
    write_new_file(os.path.join(out, 'mak_dl.c'), MAK_DL_C)
    apply_edits(os.path.join(out, 'ao_pipewire.c'), PIPEWIRE_EDITS)
    apply_edits(os.path.join(out, 'ao_pulse.c'), PULSE_EDITS)
    apply_edits(os.path.join(src, 'meson.build'), MESON_EDITS)


if __name__ == '__main__':
    main()
