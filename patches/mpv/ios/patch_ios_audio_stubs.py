# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patch mpv audio sources for iOS compatibility.

iOS lacks the CoreAudio Hardware Abstraction Layer (HAL) that macOS provides.
This patch applies four changes:

1. ao_avfoundation.m: Comments out macOS-only setAudioOutputDeviceUniqueID
2. ao_audiounit.m: Removes MixWithOthers (prevents Now Playing on iOS)
3. ao.h: Adds iOS stub types for CoreAudio HAL types
4. ao_coreaudio_utils.c: Guards macOS code, adds iOS stub implementations

Usage: python3 patch_ios_audio_stubs.py <mpv_source_dir>
"""
import sys
import re

mpv_dir = sys.argv[1]

# ── 1. ao_avfoundation.m: comment out macOS-only device property ────────────

avf_path = f"{mpv_dir}/audio/out/ao_avfoundation.m"
with open(avf_path) as f:
    content = f.read()

if '//[p->renderer setAudioOutputDeviceUniqueID:' not in content:
    content = content.replace(
        '[p->renderer setAudioOutputDeviceUniqueID:',
        '//[p->renderer setAudioOutputDeviceUniqueID:',
    )
    with open(avf_path, 'w') as f:
        f.write(content)
    print("Patched ao_avfoundation.m: commented out macOS-only device property")

# ── 2. ao_audiounit.m: remove MixWithOthers ─────────────────────────────────
# mpv 0.38+ adds MixWithOthers by default when not in exclusive mode, which
# prevents iOS from assigning the Now Playing slot to this app (lock screen /
# Control Center widget never appears). On iOS there is no true exclusive
# hardware access anyway, so this option has no meaningful effect.

au_path = f"{mpv_dir}/audio/out/ao_audiounit.m"
with open(au_path) as f:
    content = f.read()

if 'AVAudioSessionCategoryOptionMixWithOthers' in content:
    # Remove the if block: if (!(ao->init_flags & AO_INIT_EXCLUSIVE)) { ...MixWithOthers... }
    content = re.sub(
        r'\s*if \(!\(ao->init_flags & AO_INIT_EXCLUSIVE\)\)\s*\{[^}]*AVAudioSessionCategoryOptionMixWithOthers[^}]*\}',
        '',
        content,
    )
    with open(au_path, 'w') as f:
        f.write(content)
    print("Patched ao_audiounit.m: removed MixWithOthers")

# ── 3. ao.h: iOS stub types for CoreAudio HAL ──────────────────────────────

aoh_path = f"{mpv_dir}/audio/out/ao.h"
with open(aoh_path) as f:
    content = f.read()

if 'TARGET_OS_IPHONE' not in content:
    ios_stubs = """
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <stdint.h>
typedef uint32_t AudioObjectID;
typedef uint32_t AudioDeviceID;
typedef uint32_t AudioStreamID;
typedef uint32_t AudioObjectPropertyScope;
typedef uint32_t AudioObjectPropertySelector;
typedef struct { AudioObjectPropertySelector mSelector; AudioObjectPropertyScope mScope; uint32_t mElement; } AudioObjectPropertyAddress;
#define kAudioObjectPropertyElementMain 0
#define kAudioObjectPropertyElementWildcard 0xFFFFFFFFu
#define kAudioObjectPropertyScopeGlobal 0x676c6f62
#define kAudioDevicePropertyScopeOutput 0x6f757470
#define kAudioDevicePropertyScopeInput 0x696e7074
#define kAudioObjectSystemObject 1
#define kAudioHardwarePropertyDefaultOutputDevice 0x646f7574
#define kAudioDevicePropertyStreamConfiguration 0x736c6179
#define kAudioDevicePropertyPreferredChannelLayout 0x706c6179
#define kAudioDevicePropertyPreferredChannelsForStereo 0x64636832
#define kAudioDevicePropertyLatency 0x6c746e63
#define kAudioDevicePropertySafetyOffset 0x7366746f
#define kAudioDevicePropertyBufferFrameSize 0x6673697a
#define kAudioDevicePropertyNominalSampleRate 0x6e737274
#define kAudioDevicePropertyStreamFormat 0x73666d74
#define kAudioStreamPropertyPhysicalFormat 0x70666f72
static inline int AudioObjectGetPropertyData(uint32_t a, const void *b, uint32_t c, const void *d, uint32_t *e, void *f) { return -1; }
static inline int AudioObjectGetPropertyDataSize(uint32_t a, const void *b, uint32_t c, const void *d, uint32_t *e) { return -1; }
static inline int AudioObjectSetPropertyData(uint32_t a, const void *b, uint32_t c, const void *d, uint32_t e, const void *f) { return -1; }
static inline int AudioObjectIsPropertySettable(uint32_t a, const void *b, void *c) { return 0; }
static inline int AudioObjectAddPropertyListener(uint32_t a, const void *b, void *c, void *d) { return -1; }
static inline int AudioObjectRemovePropertyListener(uint32_t a, const void *b, void *c, void *d) { return -1; }
#endif
"""
    content = content.replace(
        '#define MPLAYER_AUDIO_OUT_H',
        '#define MPLAYER_AUDIO_OUT_H\n' + ios_stubs,
        1,
    )
    with open(aoh_path, 'w') as f:
        f.write(content)
    print("Patched ao.h: added iOS stub types")

# ── 4. ao_coreaudio_utils.c: guard macOS code + iOS stubs ───────────────────

utils_path = f"{mpv_dir}/audio/out/ao_coreaudio_utils.c"
with open(utils_path) as f:
    src = f.read()

if 'TARGET_OS_IPHONE_COREAUDIO_UTILS_V2_PATCHED' in src:
    print("ao_coreaudio_utils.c: already patched, skipping")
    sys.exit(0)

# Find end of license block
license_end = src.find('*/\n')
if license_end == -1:
    license_end = 0
else:
    license_end += 3

# Walk forward to first non-blank line
code_start = license_end
while code_start < len(src) and src[code_start] == '\n':
    code_start += 1

ios_stubs = r'''
/* ============================================================
 * iOS stubs for ao_coreaudio_utils.c
 * All CoreAudio HAL APIs are macOS-only; we provide minimal
 * no-op or mach_time-based implementations for iOS.
 * But we keep all format helpers intact so mpv actually plays sound!
 * ============================================================ */
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE

#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include "audio/out/ao_coreaudio_utils.h"
#include "common/common.h"  // mp_tag_str (otherwise only reached transitively)
#include "common/msg.h"
#include "osdep/endian.h"
#include "audio/format.h"

bool check_ca_st(struct ao *ao, int level, OSStatus code, const char *message) {
    if (code == noErr) return true;
    if (ao) mp_msg(ao->log, level, "%s (%s/%d)\n", message, mp_tag_str(code), (int)code);
    return false;
}

void ca_get_device_list(struct ao *ao, struct ao_device_list *list) {}

static void ca_fill_asbd_raw(AudioStreamBasicDescription *asbd, int mp_format, int samplerate, int num_channels) {
    asbd->mSampleRate       = samplerate;
    asbd->mFormatID         = af_fmt_is_spdif(mp_format) ? kAudioFormat60958AC3 : kAudioFormatLinearPCM;
    asbd->mChannelsPerFrame = num_channels;
    asbd->mBitsPerChannel   = af_fmt_to_bytes(mp_format) * 8;
    asbd->mFormatFlags      = kAudioFormatFlagIsPacked;
    int channels_per_buffer = num_channels;
    if (af_fmt_is_planar(mp_format)) { asbd->mFormatFlags |= kAudioFormatFlagIsNonInterleaved; channels_per_buffer = 1; }
    if (af_fmt_is_float(mp_format)) { asbd->mFormatFlags |= kAudioFormatFlagIsFloat; }
    else if (!af_fmt_is_unsigned(mp_format)) { asbd->mFormatFlags |= kAudioFormatFlagIsSignedInteger; }
    if (BYTE_ORDER == BIG_ENDIAN) asbd->mFormatFlags |= kAudioFormatFlagIsBigEndian;
    asbd->mFramesPerPacket = 1;
    asbd->mBytesPerPacket = asbd->mBytesPerFrame = asbd->mFramesPerPacket * channels_per_buffer * (asbd->mBitsPerChannel / 8);
}

void ca_fill_asbd(struct ao *ao, AudioStreamBasicDescription *asbd) {
    ca_fill_asbd_raw(asbd, ao->format, ao->samplerate, ao->channels.num);
}

bool ca_formatid_is_compressed(uint32_t formatid) {
    switch (formatid) {
    case 'IAC3': case 'iac3': case kAudioFormat60958AC3: case kAudioFormatAC3: return true;
    }
    return false;
}

static uint32_t ca_normalize_formatid(uint32_t formatID) { return ca_formatid_is_compressed(formatID) ? kAudioFormat60958AC3 : formatID; }

bool ca_asbd_equals(const AudioStreamBasicDescription *a, const AudioStreamBasicDescription *b) {
    int flags = kAudioFormatFlagIsPacked | kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian;
    bool spdif = ca_formatid_is_compressed(a->mFormatID) && ca_formatid_is_compressed(b->mFormatID);
    return (a->mFormatFlags & flags) == (b->mFormatFlags & flags) && a->mBitsPerChannel == b->mBitsPerChannel &&
           ca_normalize_formatid(a->mFormatID) == ca_normalize_formatid(b->mFormatID) &&
           (spdif || a->mBytesPerPacket == b->mBytesPerPacket) && (spdif || a->mChannelsPerFrame == b->mChannelsPerFrame) && a->mSampleRate == b->mSampleRate;
}

int ca_asbd_to_mp_format(const AudioStreamBasicDescription *asbd) {
    for (int fmt = 1; fmt < AF_FORMAT_COUNT; fmt++) {
        AudioStreamBasicDescription mp_asbd = {0};
        ca_fill_asbd_raw(&mp_asbd, fmt, asbd->mSampleRate, asbd->mChannelsPerFrame);
        if (ca_asbd_equals(&mp_asbd, asbd)) return af_fmt_is_spdif(fmt) ? AF_FORMAT_S_AC3 : fmt;
    }
    return 0;
}

void ca_print_asbd(struct ao *ao, const char *description, const AudioStreamBasicDescription *asbd) {}

static bool value_is_better(double req, double old, double new) {
    if (new >= req) { return old < req || new <= old; } else { return old < req && new >= old; }
}

bool ca_asbd_is_better(AudioStreamBasicDescription *req, AudioStreamBasicDescription *old, AudioStreamBasicDescription *new) {
    if (new->mChannelsPerFrame > MP_NUM_CHANNELS) return false;
    if (old->mChannelsPerFrame > MP_NUM_CHANNELS) return true;
    if (req->mFormatID != new->mFormatID) return false;
    if (req->mFormatID != old->mFormatID) return true;
    if (!value_is_better(req->mBitsPerChannel, old->mBitsPerChannel, new->mBitsPerChannel)) return false;
    if (!value_is_better(req->mSampleRate, old->mSampleRate, new->mSampleRate)) return false;
    if (!value_is_better(req->mChannelsPerFrame, old->mChannelsPerFrame, new->mChannelsPerFrame)) return false;
    return true;
}

int64_t ca_frames_to_ns(struct ao *ao, uint32_t frames) {
    return MP_TIME_S_TO_NS(frames / (double)ao->samplerate);
}

int64_t ca_get_latency(const AudioTimeStamp *ts) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    uint64_t out = ts->mHostTime;
    uint64_t now = mach_absolute_time();
    if (now > out) return 0;
    return (out - now) * timebase.numer / timebase.denom;
}

#endif /* TARGET_OS_IPHONE */
'''

new_src = (
    src[:code_start]
    + '#if !TARGET_OS_IPHONE\n'
    + src[code_start:]
    + '\n#endif /* !TARGET_OS_IPHONE */\n'
    + ios_stubs
    + '\n#define TARGET_OS_IPHONE_COREAUDIO_UTILS_V2_PATCHED 1\n'
)

with open(utils_path, 'w') as f:
    f.write(new_src)
print("Patched ao_coreaudio_utils.c for iOS (full file guard + stubs)")
