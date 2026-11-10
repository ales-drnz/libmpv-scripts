// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The part of Tizen's sound_manager.h (capi-media-sound-manager) that
// ao_tizen.c uses, for ao_tizen_test.c. The names and the argument types
// are Tizen's; the values are the test's own.
#pragma once

typedef struct sound_stream_info_s *sound_stream_info_h;

typedef enum {
    SOUND_STREAM_TYPE_MEDIA,
} sound_stream_type_e;

typedef enum {
    SOUND_MANAGER_ERROR_NONE = 0,
} sound_manager_error_e;

typedef void (*sound_stream_focus_state_changed_cb)(void);

int sound_manager_create_stream_information(sound_stream_type_e stream_type,
                                            sound_stream_focus_state_changed_cb callback,
                                            void *user_data,
                                            sound_stream_info_h *stream_info);
int sound_manager_destroy_stream_information(sound_stream_info_h stream_info);
