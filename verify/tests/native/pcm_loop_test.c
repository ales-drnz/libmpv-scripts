// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// pcm_loop_test <mode> <fixtures> <tmpdir>: a looped live PCM entry
// (mak-pcm://) at its end (F225).
//   file  loop-file=inf before the entry; keep-open parks at the end
//   late  loop-file=inf set while the entry plays
//   ab    ab-loop-a=0.2 ab-loop-b=0.6 (ab-loop-count inf), loop-file=no:
//         the entry plays on past B to its real end (1 s)
//   next  loop-file=inf and a second entry (p_st48.flac) after the PCM one
//   abnext the A-B loop and the second entry
//   off   no loop (control: parks at the end, no warning)
//   afdrop no loop, 3 s of PCM, af=dynaudnorm, then af="" 0.5 s after
//         the source drained, while dynaudnorm holds the EOF (F61): the
//         entry cannot seek, and must still park within 5 s, with no
//         "Cannot seek"
// One second of s16le stereo 48 kHz is written and finished before the
// load, with the options the kit passes (pcmLoadOptions). After the source
// drained, the entry must end: the keep-open park (pause yes) or the next
// entry, with no "Cannot seek" error, the core idle (CPU under 0.5 s in
// 2 s) and the "cannot loop" warning once when a loop was asked for.
#include "playback_test.h"

int64_t mak_pcm_create(int64_t capacity_bytes);
int64_t mak_pcm_write(int64_t id, const uint8_t *data, int64_t len);
int mak_pcm_finish(int64_t id);
int mak_pcm_state(int64_t id);
int mak_pcm_release(int64_t id);

static int flag(mpv_handle *h, const char *name)
{
    int v = -1;
    if (mpv_get_property(h, name, MPV_FORMAT_FLAG, &v) < 0)
        return -1;
    return v;
}

int main(int argc, char **argv)
{
    if (argc < 4)
        return 2;
    const char *mode = argv[1], *fx = argv[2];
    int m_file = !strcmp(mode, "file"), m_late = !strcmp(mode, "late"),
        m_ab = !strcmp(mode, "ab"), m_next = !strcmp(mode, "next"),
        m_off = !strcmp(mode, "off"), m_drop = !strcmp(mode, "afdrop");
    if (!strcmp(mode, "abnext"))
        m_ab = m_next = 1;
    if (!(m_file || m_late || m_ab || m_next || m_off || m_drop)) {
        printf("unknown mode %s\n", mode);
        return 2;
    }

    mpv_handle *h = pb_create();
    mpv_set_option_string(h, "keep-open", "yes");
    mpv_set_option_string(h, "idle", "yes");
    if (m_file || (m_next && !m_ab))
        mpv_set_option_string(h, "loop-file", "inf");
    if (m_ab) {
        mpv_set_option_string(h, "ab-loop-a", "0.2");
        mpv_set_option_string(h, "ab-loop-b", "0.6");
    }
    if (m_drop)
        mpv_set_option_string(h, "af", "dynaudnorm");
    if (mpv_initialize(h) < 0)
        return 2;
    mpv_request_log_messages(h, "warn");

    int64_t id = mak_pcm_create(0);
    int64_t len = 48000 * 4 * (m_drop ? 3 : 1);
    uint8_t *pcm = calloc(1, len);
    for (int64_t i = 0; i < len / 2; i++)
        ((int16_t *)pcm)[i] = 8192;
    mt_check(id > 0 && mak_pcm_write(id, pcm, len) == len && mak_pcm_finish(id) == 0,
             "%d s of PCM written and finished in id %lld",
             (int)(len / 192000), (long long)id);
    free(pcm);

    char url[64];
    snprintf(url, sizeof url, "mak-pcm://%lld", (long long)id);
    const char *opts = "demuxer=rawaudio,demuxer-rawaudio-format=s16le,"
        "demuxer-rawaudio-rate=48000,demuxer-rawaudio-channels=2,"
        "cache-pause=no,demuxer-termination-timeout=0,"
        "demuxer-seekable-cache=no,gapless-audio=no";
    const char *load[] = {"loadfile", url, "replace", "-1", opts, NULL};
    mt_check(mpv_command(h, load) >= 0, "loadfile %s", url);
    if (m_next) {
        char pb[4096];
        snprintf(pb, sizeof pb, "%s/p_st48.flac", fx);
        mt_cmd(h, "loadfile", pb, "append", NULL);
    }

    struct pb_ev ev = {.needle = {"Cannot seek", "cannot loop", NULL},
                       .end_reason = -1};
    double t0 = mt_now();
    int late_set = 0;
    while (mt_now() - t0 < 10 && mak_pcm_state(id) != 3) {
        pb_pump(h, 20, &ev);
        if (m_late && !late_set && ev.loaded) {
            mpv_set_property_string(h, "loop-file", "inf");
            late_set = 1;
        }
    }
    mt_check(mak_pcm_state(id) == 3, "the source drained (state %d)",
             mak_pcm_state(id));
    if (m_drop) {
        pb_pump(h, 500, &ev);
        double at = -1;
        mt_double(h, "time-pos", &at);
        mt_check(flag(h, "eof-reached") == 0, "still playing at %.3f s", at);
        mt_check(mpv_set_property_string(h, "af", "") >= 0, "af cleared");
        double d0 = mt_now(), took = -1;
        while (mt_now() - d0 < 5.0) {
            pb_pump(h, 50, &ev);
            if (ev.end_files || (flag(h, "pause") == 1 &&
                                 flag(h, "eof-reached") == 1)) {
                took = mt_now() - d0;
                break;
            }
        }
        double pos = -1;
        mt_double(h, "time-pos", &pos);
        printf("     af cleared at %.3f s, end after %.2f s (time-pos %.3f, "
               "end-file %d), Cannot seek %d\n", at, took, pos, ev.end_files,
               ev.hits[0]);
        mt_check(took >= 0, "the entry ended within 5 s of the change (%.2f s)",
                 took);
        mt_check(ev.hits[0] == 0, "no failed refresh seek (%d)", ev.hits[0]);
        mak_pcm_release(id);
        mpv_terminate_destroy(h);
        return mt_result();
    }
    // Settle, then measure two seconds.
    pb_pump(h, 1000, &ev);
    int before = ev.hits[0];
    double c0 = pb_cpu(), w0 = mt_now();
    while (mt_now() - w0 < 2.0)
        pb_pump(h, 50, &ev);
    double cpu = pb_cpu() - c0;
    printf("     cpu %.2f s in 2 s, Cannot seek %d (last 2 s: %d), cannot loop %d, "
           "end-file %d (reason %d), file-loaded %d\n", cpu, ev.hits[0],
           ev.hits[0] - before, ev.hits[1], ev.end_files, ev.end_reason, ev.loaded);
    mt_check(ev.hits[0] == 0, "no failed loop seek (%d)", ev.hits[0]);
    mt_check(cpu < 0.5, "the core is idle (%.2f s of CPU in 2 s)", cpu);
    mt_check(ev.hits[1] == (m_off ? 0 : 1), "the cannot loop warning %s (%d)",
             m_off ? "is not there" : "comes once", ev.hits[1]);
    if (m_next) {
        mt_check(ev.end_files >= 1 && ev.loaded >= 2,
                 "the PCM entry ended and the next one loaded "
                 "(end-file %d, reason %d, file-loaded %d)", ev.end_files,
                 ev.end_reason, ev.loaded);
    } else {
        int p = flag(h, "pause"), eof = flag(h, "eof-reached");
        double pos = -1;
        mt_double(h, "time-pos", &pos);
        mt_check(p == 1 && eof == 1 && pos > 0.95,
                 "parked at the end (pause %d, eof-reached %d, time-pos %.3f)",
                 p, eof, pos);
    }
    mak_pcm_release(id);
    mpv_terminate_destroy(h);
    return mt_result();
}
