// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The part of OHAudio's headers (native SDK of OpenHarmony, API 26) that
// ao_ohaudio.c uses, for ao_ohaudio_test.c, which simulates the renderer
// behind it. The names, the values and the argument types are the SDK's.
#pragma once
#include <stdint.h>
#include <time.h>

typedef enum {
    AUDIOSTREAM_SUCCESS = 0,
    AUDIOSTREAM_ERROR_INVALID_PARAM = 1,
    AUDIOSTREAM_ERROR_ILLEGAL_STATE = 2,
    AUDIOSTREAM_ERROR_SYSTEM = 3,
} OH_AudioStream_Result;

typedef enum {
    AUDIOSTREAM_TYPE_RENDERER = 1,
    AUDIOSTREAM_TYPE_CAPTURER = 2,
} OH_AudioStream_Type;

typedef enum {
    AUDIOSTREAM_SAMPLE_U8 = 0,
    AUDIOSTREAM_SAMPLE_S16LE = 1,
    AUDIOSTREAM_SAMPLE_S24LE = 2,
    AUDIOSTREAM_SAMPLE_S32LE = 3,
    AUDIOSTREAM_SAMPLE_F32LE = 4,
} OH_AudioStream_SampleFormat;

typedef enum {
    AUDIOSTREAM_ENCODING_TYPE_RAW = 0,
} OH_AudioStream_EncodingType;

typedef enum {
    AUDIOSTREAM_USAGE_UNKNOWN = 0,
    AUDIOSTREAM_USAGE_MUSIC = 1,
    AUDIOSTREAM_USAGE_MOVIE = 10,
} OH_AudioStream_Usage;

typedef enum {
    AUDIOSTREAM_LATENCY_MODE_NORMAL = 0,
    AUDIOSTREAM_LATENCY_MODE_FAST = 1,
} OH_AudioStream_LatencyMode;

typedef enum {
    AUDIOSTREAM_EVENT_ROUTING_CHANGED = 0,
} OH_AudioStream_Event;

typedef enum {
    AUDIOSTREAM_INTERRUPT_FORCE = 0,
    AUDIOSTREAM_INTERRUPT_SHARE = 1,
} OH_AudioInterrupt_ForceType;

typedef enum {
    AUDIOSTREAM_INTERRUPT_HINT_NONE = 0,
    AUDIOSTREAM_INTERRUPT_HINT_RESUME = 1,
    AUDIOSTREAM_INTERRUPT_HINT_PAUSE = 2,
    AUDIOSTREAM_INTERRUPT_HINT_STOP = 3,
    AUDIOSTREAM_INTERRUPT_HINT_DUCK = 4,
    AUDIOSTREAM_INTERRUPT_HINT_UNDUCK = 5,
} OH_AudioInterrupt_Hint;

typedef enum {
    REASON_UNKNOWN = 0,
    REASON_NEW_DEVICE_AVAILABLE = 1,
    REASON_OLD_DEVICE_UNAVAILABLE = 2,
    REASON_OVERRODE = 3,
} OH_AudioStream_DeviceChangeReason;

typedef enum {
    AUDIO_DATA_CALLBACK_RESULT_INVALID = -1,
    AUDIO_DATA_CALLBACK_RESULT_VALID = 0,
} OH_AudioData_Callback_Result;

typedef struct OH_AudioStreamBuilderStruct OH_AudioStreamBuilder;
typedef struct OH_AudioRendererStruct OH_AudioRenderer;

typedef struct OH_AudioRenderer_Callbacks_Struct {
    int32_t (*OH_AudioRenderer_OnWriteData)(OH_AudioRenderer *renderer, void *userData,
                                            void *buffer, int32_t length);
    int32_t (*OH_AudioRenderer_OnStreamEvent)(OH_AudioRenderer *renderer, void *userData,
                                              OH_AudioStream_Event event);
    int32_t (*OH_AudioRenderer_OnInterruptEvent)(OH_AudioRenderer *renderer, void *userData,
                                                 OH_AudioInterrupt_ForceType type,
                                                 OH_AudioInterrupt_Hint hint);
    int32_t (*OH_AudioRenderer_OnError)(OH_AudioRenderer *renderer, void *userData,
                                        OH_AudioStream_Result error);
} OH_AudioRenderer_Callbacks;

typedef void (*OH_AudioRenderer_OutputDeviceChangeCallback)(OH_AudioRenderer *renderer, void *userData,
                                                           OH_AudioStream_DeviceChangeReason reason);
typedef OH_AudioData_Callback_Result (*OH_AudioRenderer_OnWriteDataCallback)(OH_AudioRenderer *renderer,
                                                                            void *userData,
                                                                            void *audioData,
                                                                            int32_t audioDataSize);
