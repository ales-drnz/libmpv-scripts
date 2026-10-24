# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Fix the Android AudioTrack output (audio/out/ao_audiotrack.c, and the
paused delay of audio/out/buffer.c that its set_pause brings out).

audiotrack is mpv's default output on Android. Its thread pulls a chunk of
75 to 150 ms from mpv's buffer and writes it to the AudioTrack with a
blocking write, which paces the loop while there is audio.

1. Idle. When mpv's buffer has nothing (an underrun, such as a live PCM
   source between two chunks of input, since it plays with cache-pause=no,
   or a pause with audio-stream-silence), the read returned 0 samples, the
   write of 0 bytes returned at once and the thread spun on a whole core.
   The thread now waits 10 ms and reads again; a resume after an underrun
   waits at most that long. With audio-stream-silence the read pads the
   chunk with silence, as the callback outputs (aaudio, opensles) do, so
   the track is fed silence instead of running dry, and it waits for the
   buffer lock, so a busy lock is not mistaken for a gap.

2. Dead track. When audioserver dies (a crash, a Bluetooth codec change on
   some devices), the write returns ERROR_DEAD_OBJECT and the driver
   recreated the AudioTrack without calling play(): the thread then waited
   on a stopped track for good, with the player playing, the position
   stuck and audio-output-state active. The recreated track also kept the
   written frame count and timestamps of the old one, and a failed
   recreation left no track at all. The thread now stops using the dead
   track and asks mpv to reload the output, as aaudio does on a
   disconnect: mpv closes it and opens a new one from the core, which
   starts it with play() and fresh counters, and audio-output-state goes
   through initializing again.

3. Pause. The driver had no set_pause, so buffer.c paused it with reset,
   which pauses and flushes the track: every pause threw away what the
   track held (75 to 150 ms, sometimes more) and the rest of the chunk in
   writing, since the pause cuts the blocking write short. A resume
   skipped that audio, and the position jumped ahead by as much. set_pause
   now pauses and plays the track without a flush, and the thread keeps
   the rest of a cut chunk and writes it first on the resume. A reset in
   between (a seek or a stop) drops it.

4. Paused delay. For a pull output paused in hardware, buffer.c kept the
   delay of the audio the device held in queued_time_ns, but ao_get_delay
   still read it off the clock (end_time_ns minus now). Paused, the delay
   ran down and the position crept ahead by what the track held (about
   140 ms on audiotrack), then went back as much on the resume; every read
   that woke the core moved it. ao_get_delay now returns the saved delay
   while paused, and the pause and the resume set it under the buffer lock,
   with hw_paused, so a read in between never sees the old one.

Each fix has its own marker and runs once. All anchors are checked before
the file is written, so a mismatch leaves the tree as it was.

Android only: ao_audiotrack.c is compiled only there, so the patch is
applied from build_libmpv_android.sh, gated on the `audiotrack` patch id.
Fix 4 changes shared code, but only the Android build gets it: there the
paused delay is the size of an AudioTrack buffer, on the desktop outputs a
few milliseconds.

Usage: patch_audiotrack.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_lib"))
import anchor  # noqa: E402

AUDIOTRACK = "audio/out/ao_audiotrack.c"
BUFFER = "audio/out/buffer.c"

# Each fix has its own marker, so a tree that has some of them gets the
# others.
IDLE = "MAK_AUDIOTRACK_IDLE_PATCH_V1"
DEAD = "MAK_AUDIOTRACK_DEAD_OBJECT_PATCH_V1"
PAUSE = "MAK_AUDIOTRACK_PAUSE_PATCH_V1"
DELAY = "MAK_AUDIOTRACK_PAUSED_DELAY_PATCH_V1"


def apply(p):
    # ── 1. Idle: wait instead of spinning when there is nothing to write ────
    p.edits(AUDIOTRACK, [
        (
            "static MP_THREAD_VOID ao_thread(void *arg)\n"
            "{\n",
            f"/* {IDLE}:\n"
            " * reads the next chunk into p->chunk and returns its size in bytes, 0\n"
            " * when mpv's buffer has nothing. With audio-stream-silence the chunk is\n"
            " * padded with silence, and the read waits for the buffer lock, so the\n"
            " * track is fed silence rather than running dry, and a busy lock is not\n"
            " * taken for a gap. */\n"
            "static int mak_read_chunk(struct ao *ao)\n"
            "{\n"
            "    struct priv *p = ao->priv;\n"
            "    int read_samples = p->chunksize / ao->sstride;\n"
            "    int64_t ts = mp_time_ns();\n"
            "    ts += MP_TIME_S_TO_NS(read_samples / (double)(ao->samplerate));\n"
            "    ts += MP_TIME_S_TO_NS(AudioTrack_getLatency(ao));\n"
            "    bool silence = ao->stream_silence;\n"
            "    int samples = ao_read_data(ao, &p->chunk, read_samples, ts, NULL,\n"
            "                               silence, silence);\n"
            "    return (silence ? read_samples : samples) * ao->sstride;\n"
            "}\n"
            "\n"
            "static MP_THREAD_VOID ao_thread(void *arg)\n"
            "{\n",
        ),
        (
            "            int read_samples = p->chunksize / ao->sstride;\n"
            "            int64_t ts = mp_time_ns();\n"
            "            ts += MP_TIME_S_TO_NS(read_samples / (double)(ao->samplerate));\n"
            "            ts += MP_TIME_S_TO_NS(AudioTrack_getLatency(ao));\n"
            "            int samples = ao_read_data(ao, &p->chunk, read_samples, ts, NULL, false, false);\n"
            "            int ret = AudioTrack_write(ao, samples * ao->sstride);\n",
            "            int len = mak_read_chunk(ao);\n"
            "            if (!len) {\n"
            f"                // {IDLE}:\n"
            "                // nothing to play (an underrun, such as a live PCM\n"
            "                // source waiting for input, or the buffer lock busy). A\n"
            "                // write of 0 bytes returns at once, so poll instead of\n"
            "                // spinning; the track still holds its buffer.\n"
            "                mp_cond_timedwait(&p->wakeup, &p->lock, MP_TIME_MS_TO_NS(10));\n"
            "                continue;\n"
            "            }\n"
            "            int ret = AudioTrack_write(ao, len);\n",
        ),
    ], marker=IDLE)

    # ── 2. Dead track: reload the output instead of a silent recreation ─────
    p.edits(AUDIOTRACK, [
        (
            "    bool reset_pending;\n",
            "    bool reset_pending;\n"
            f"    // {DEAD}: the thread no longer uses the track\n"
            "    bool mak_dead_object;\n",
        ),
        (
            "static int AudioTrack_Recreate(struct ao *ao)\n"
            "{\n"
            "    struct priv *p = ao->priv;\n"
            "    JNIEnv *env = MP_JNI_GET_ENV(ao);\n"
            "\n"
            "    MP_JNI_CALL_VOID(p->audiotrack, AudioTrack.release);\n"
            "    MP_JNI_EXCEPTION_LOG(ao);\n"
            "    MP_JNI_GLOBAL_FREEP(&p->audiotrack);\n"
            "    return AudioTrack_New(ao);\n"
            "}\n"
            "\n",
            "",
        ),
        (
            "        if (p->audiotrack) {\n"
            "            state = MP_JNI_CALL_INT(p->audiotrack, AudioTrack.getPlayState);\n",
            "        if (p->audiotrack && !p->mak_dead_object) {\n"
            "            state = MP_JNI_CALL_INT(p->audiotrack, AudioTrack.getPlayState);\n",
        ),
        (
            "                MP_WARN(ao, \"AudioTrack.write failed with ERROR_DEAD_OBJECT. Recreating AudioTrack...\\n\");\n"
            "                if (AudioTrack_Recreate(ao) < 0) {\n"
            "                    MP_ERR(ao, \"AudioTrack_Recreate failed\\n\");\n"
            "                }\n",
            f"                // {DEAD}:\n"
            "                // the track died with audioserver. A track recreated\n"
            "                // here never started and kept the counters of the old\n"
            "                // one. mpv reopens the output from the core instead, as\n"
            "                // for an aaudio disconnect; until then the thread\n"
            "                // leaves the dead track alone.\n"
            "                MP_WARN(ao, \"AudioTrack.write failed with ERROR_DEAD_OBJECT. Reloading the audio output...\\n\");\n"
            "                p->mak_dead_object = true;\n"
            "                ao_request_reload(ao);\n",
        ),
    ], marker=DEAD)

    # ── 3. Pause: set_pause without a flush, the cut chunk kept ─────────────
    p.edits(AUDIOTRACK, [
        (
            "    void *chunk;\n"
            "    int chunksize;\n",
            "    void *chunk;\n"
            "    int chunksize;\n"
            f"    // {PAUSE}: bytes at the start of chunk that a\n"
            "    // pause cut short, and the reset count they belong to\n"
            "    int mak_pending;\n"
            "    int mak_pending_gen;\n"
            "    atomic_int mak_reset_gen;\n",
        ),
        (
            "            int len = mak_read_chunk(ao);\n"
            "            if (!len) {\n",
            f"            // {PAUSE}:\n"
            "            // the rest of a chunk that a pause cut short goes first,\n"
            "            // unless a reset (a seek or a stop) came since.\n"
            "            int len = p->mak_pending;\n"
            "            p->mak_pending = 0;\n"
            "            if (len && p->mak_pending_gen != atomic_load(&p->mak_reset_gen))\n"
            "                len = 0;\n"
            "            if (!len) {\n"
            "                p->mak_pending_gen = atomic_load(&p->mak_reset_gen);\n"
            "                len = mak_read_chunk(ao);\n"
            "            }\n"
            "            if (!len) {\n",
        ),
        (
            "                p->written_frames += ret / ao->sstride;\n",
            "                p->written_frames += ret / ao->sstride;\n"
            f"                // {PAUSE}: a pause cuts the\n"
            "                // blocking write short; the rest waits for the resume.\n"
            "                if (ret < len) {\n"
            "                    memmove(p->chunk, (char *)p->chunk + ret, len - ret);\n"
            "                    p->mak_pending = len - ret;\n"
            "                }\n",
        ),
        (
            "    p->timestamp_fetched = 0;\n"
            "    p->timestamp_set = false;\n"
            "}\n"
            "\n"
            "static void start(struct ao *ao)\n",
            "    p->timestamp_fetched = 0;\n"
            "    p->timestamp_set = false;\n"
            f"    // {PAUSE}: drop the rest of a cut chunk\n"
            "    atomic_fetch_add(&p->mak_reset_gen, 1);\n"
            "}\n"
            "\n"
            "static void start(struct ao *ao)\n",
        ),
        (
            "#define OPT_BASE_STRUCT struct priv\n",
            f"/* {PAUSE}:\n"
            " * pause and resume without a flush. Without set_pause, buffer.c paused\n"
            " * this pull output with reset (stop), which flushed what the track held.\n"
            " * No p->lock: the thread holds it while it writes. */\n"
            "static bool set_pause(struct ao *ao, bool paused)\n"
            "{\n"
            "    struct priv *p = ao->priv;\n"
            "    if (!p->audiotrack)\n"
            "        return false;\n"
            "\n"
            "    JNIEnv *env = MP_JNI_GET_ENV(ao);\n"
            "    if (paused) {\n"
            "        MP_JNI_CALL_VOID(p->audiotrack, AudioTrack.pause);\n"
            "        MP_JNI_EXCEPTION_LOG(ao);\n"
            "        return true;\n"
            "    }\n"
            "    // A timestamp from before the pause would put the head past it.\n"
            "    p->timestamp_fetched = 0;\n"
            "    p->timestamp_set = false;\n"
            "    MP_JNI_CALL_VOID(p->audiotrack, AudioTrack.play);\n"
            "    MP_JNI_EXCEPTION_LOG(ao);\n"
            "    mp_cond_signal(&p->wakeup);\n"
            "    return true;\n"
            "}\n"
            "\n"
            "#define OPT_BASE_STRUCT struct priv\n",
        ),
        (
            "    .reset     = stop,\n"
            "    .start     = start,\n",
            "    .reset     = stop,\n"
            "    .start     = start,\n"
            "    .set_pause = set_pause,\n",
        ),
    ], marker=PAUSE)

    # ── 4. Paused delay: the delay saved at the pause, read under the lock ──
    p.edits(BUFFER, [
        (
            "    } else {\n"
            "        int64_t end = p->end_time_ns;\n",
            f"    }} else if (p->hw_paused) {{\n"
            f"        // {DELAY}: paused in\n"
            "        // hardware, the device plays nothing: the delay is the one\n"
            "        // saved at the pause, not one that runs down on the clock.\n"
            "        driver_delay = MPMAX(0, MP_TIME_NS_TO_S(p->queued_time_ns));\n"
            "    } else {\n"
            "        int64_t end = p->end_time_ns;\n",
        ),
        (
            "                is_hw_paused = p->hw_paused = !!ao->driver->set_pause;\n",
            "                is_hw_paused = p->hw_paused = !!ao->driver->set_pause;\n"
            f"                // {DELAY}: saved\n"
            "                // with hw_paused, under the lock ao_get_delay takes.\n"
            "                if (is_hw_paused)\n"
            "                    p->queued_time_ns = p->end_time_ns - mp_time_ns();\n",
        ),
        (
            "            is_hw_paused = p->hw_paused;\n"
            "            p->hw_paused = false;\n",
            "            is_hw_paused = p->hw_paused;\n"
            "            p->hw_paused = false;\n"
            f"            // {DELAY}\n"
            "            if (is_hw_paused)\n"
            "                p->end_time_ns = p->queued_time_ns + mp_time_ns();\n",
        ),
        (
            "                ao->driver->set_pause(ao, true);\n"
            "                p->queued_time_ns = p->end_time_ns - mp_time_ns();\n"
            "            } else {\n"
            "                p->end_time_ns = p->queued_time_ns + mp_time_ns();\n"
            "                ao->driver->set_pause(ao, false);\n",
            "                ao->driver->set_pause(ao, true);\n"
            "            } else {\n"
            "                ao->driver->set_pause(ao, false);\n",
        ),
    ], marker=DELAY)


anchor.main(apply, "patch_audiotrack")
