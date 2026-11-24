// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// See native_audiostream_base.h.
#pragma once
#include "native_audiostream_base.h"

OH_AudioStream_Result OH_AudioRenderer_Release(OH_AudioRenderer *renderer);
OH_AudioStream_Result OH_AudioRenderer_Start(OH_AudioRenderer *renderer);
OH_AudioStream_Result OH_AudioRenderer_Pause(OH_AudioRenderer *renderer);
OH_AudioStream_Result OH_AudioRenderer_Stop(OH_AudioRenderer *renderer);
OH_AudioStream_Result OH_AudioRenderer_Flush(OH_AudioRenderer *renderer);
OH_AudioStream_Result OH_AudioRenderer_GetTimestamp(OH_AudioRenderer *renderer, clockid_t clockId,
                                                    int64_t *framePosition, int64_t *timestamp);
OH_AudioStream_Result OH_AudioRenderer_GetUnderflowCount(OH_AudioRenderer *renderer, uint32_t *count);
