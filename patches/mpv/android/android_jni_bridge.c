/*
 * Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
 */

/* android_jni_bridge.c — Compiled into libmpv.so for Android only.
 *
 * mpv's audiotrack AO and several ffmpeg helpers (mediacodec hwaccel,
 * Android content:// URIs, …) reach the JVM via ffmpeg's
 * `av_jni_set_java_vm()` global. Android invokes JNI_OnLoad whenever a
 * shared library is brought in via System.loadLibrary(...), so the
 * canonical place to forward the VM pointer to ffmpeg is right here:
 * the plugin's Kotlin side calls System.loadLibrary("mpv") on engine
 * attach, Android's loader fires this JNI_OnLoad with a valid JavaVM*,
 * and ffmpeg's globals are wired up before any AO init runs.
 *
 * Without this hook, audiotrack reports
 *   `[ao/audiotrack] error: No Java virtual machine has been registered`
 * and mpv gets dragged through every other AO before giving up — i.e.
 * silent playback on a perfectly-functional device.
 *
 * Reference: mpv-android does the same in its JNI bridge
 * (https://github.com/mpv-android/mpv-android).
 */

/* Guarded so the intent is self-documenting and the TU is a strict no-op
 * if the link snippet is ever copy-pasted into another platform's build.
 * The NDK clang always defines __ANDROID__. */
#ifdef __ANDROID__

#include <jni.h>
#ifndef NDEBUG
#include <android/log.h>
#endif

/* Provided by libavcodec, statically linked into libmpv.so. Forward-
 * declared here to avoid pulling in any ffmpeg headers — keeps this
 * translation unit minimal and side-effect-free.
 */
int av_jni_set_java_vm(void *vm, void *log_ctx);

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void) reserved;
    /* Capture the return code: a non-zero rc (conflicting VM already set,
     * or libavcodec built without CONFIG_JNI) is the root cause of the
     * downstream "[ao/audiotrack] No Java virtual machine" error, so make
     * it diagnosable at the source in debug builds. */
    int rc = av_jni_set_java_vm((void *) vm, 0);
    (void) rc;
#ifndef NDEBUG
    if (rc != 0) {
        __android_log_print(ANDROID_LOG_ERROR, "mpv_audio_kit",
                            "av_jni_set_java_vm failed (rc=%d) — audiotrack "
                            "AO will have no JVM", rc);
    }
#endif
    return JNI_VERSION_1_6;
}

#endif /* __ANDROID__ */
