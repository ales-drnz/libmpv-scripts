// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The part of Tizen's audio_io.h (capi-media-audio-io) that ao_tizen.c
// uses, for ao_tizen_test.c, which simulates the device behind it. The
// names and the argument types are Tizen's; the values are the test's own.
#pragma once
#include <stdbool.h>
#include <stddef.h>

#include "sound_manager.h"

typedef struct audio_io_s *audio_out_h;

typedef enum {
    AUDIO_SAMPLE_TYPE_U8 = 0x70,
    AUDIO_SAMPLE_TYPE_S16_LE,
    AUDIO_SAMPLE_TYPE_S24_LE,
    AUDIO_SAMPLE_TYPE_S24_32_LE,
    AUDIO_SAMPLE_TYPE_S32_LE,
} audio_sample_type_e;

typedef enum {
    AUDIO_CHANNEL_MONO = 0x80,
    AUDIO_CHANNEL_STEREO,
} audio_channel_e;

typedef enum {
    AUDIO_IO_ERROR_NONE = 0,
    AUDIO_IO_ERROR_INVALID_PARAMETER = -22,
    AUDIO_IO_ERROR_INVALID_OPERATION = -38,
    AUDIO_IO_ERROR_INVALID_STATE = -0x01900005,
} audio_io_error_e;

int audio_out_create_new(int sample_rate, audio_channel_e channel,
                         audio_sample_type_e type, audio_out_h *output);
int audio_out_destroy(audio_out_h output);
int audio_out_set_sound_stream_info(audio_out_h output, sound_stream_info_h info);
int audio_out_prepare(audio_out_h output);
int audio_out_unprepare(audio_out_h output);
int audio_out_pause(audio_out_h output);
int audio_out_resume(audio_out_h output);
int audio_out_flush(audio_out_h output);
int audio_out_write(audio_out_h output, void *buffer, unsigned int length);
