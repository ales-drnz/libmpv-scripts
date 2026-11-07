# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Fix the Android AudioTrack output (audio/out/ao_audiotrack.c).

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

The paused delay of a pull output in buffer.c, fix 4 until libmpv-r23,
is in patch_gapless_tail.py since, for every pull output.

Each fix has its own marker and runs once. All anchors are checked before
the file is written, so a mismatch leaves the tree as it was.

Android only: ao_audiotrack.c is compiled only there, so the patch is
applied from build_libmpv_android.sh, gated on the `audiotrack` patch id.

Usage: patch_audiotrack.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "_lib"))
import anchor  # noqa: E402

AUDIOTRACK = "audio/out/ao_audiotrack.c"

# Each fix has its own marker, so a tree that has some of them gets the
# others.
IDLE = "MAK_AUDIOTRACK_IDLE_PATCH_V1"
DEAD = "MAK_AUDIOTRACK_DEAD_OBJECT_PATCH_V1"
PAUSE = "MAK_AUDIOTRACK_PAUSE_PATCH_V1"


def apply(p):
    # Two whole functions the fixes add, in C files next to this script.
    read_chunk = p.asset("audiotrack_read_insert.c")
    set_pause = p.asset("audiotrack_pause_insert.c")

    # ── 1. Idle: wait instead of spinning when there is nothing to write ────
    p.edits(AUDIOTRACK, [
        (
            "static MP_THREAD_VOID ao_thread(void *arg)\n"
            "{\n",
            read_chunk + "\n"
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
            set_pause + "\n"
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


anchor.main(apply, "patch_audiotrack")
