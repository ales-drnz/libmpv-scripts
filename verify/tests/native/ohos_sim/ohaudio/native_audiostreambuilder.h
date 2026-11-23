// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// See native_audiostream_base.h.
#pragma once
#include "native_audiostream_base.h"

OH_AudioStream_Result OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder **builder, OH_AudioStream_Type type);
OH_AudioStream_Result OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder *builder);
OH_AudioStream_Result OH_AudioStreamBuilder_SetSamplingRate(OH_AudioStreamBuilder *builder, int32_t rate);
OH_AudioStream_Result OH_AudioStreamBuilder_SetChannelCount(OH_AudioStreamBuilder *builder, int32_t channelCount);
OH_AudioStream_Result OH_AudioStreamBuilder_SetSampleFormat(OH_AudioStreamBuilder *builder,
                                                            OH_AudioStream_SampleFormat format);
OH_AudioStream_Result OH_AudioStreamBuilder_SetEncodingType(OH_AudioStreamBuilder *builder,
                                                            OH_AudioStream_EncodingType encodingType);
OH_AudioStream_Result OH_AudioStreamBuilder_SetLatencyMode(OH_AudioStreamBuilder *builder,
                                                           OH_AudioStream_LatencyMode latencyMode);
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererInfo(OH_AudioStreamBuilder *builder,
                                                            OH_AudioStream_Usage usage);
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererCallback(OH_AudioStreamBuilder *builder,
                                                                OH_AudioRenderer_Callbacks callbacks,
                                                                void *userData);
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererOutputDeviceChangeCallback(
    OH_AudioStreamBuilder *builder, OH_AudioRenderer_OutputDeviceChangeCallback callback, void *userData);
OH_AudioStream_Result OH_AudioStreamBuilder_SetRendererWriteDataCallback(
    OH_AudioStreamBuilder *builder, OH_AudioRenderer_OnWriteDataCallback callback, void *userData);
OH_AudioStream_Result OH_AudioStreamBuilder_GenerateRenderer(OH_AudioStreamBuilder *builder,
                                                             OH_AudioRenderer **audioRenderer);
