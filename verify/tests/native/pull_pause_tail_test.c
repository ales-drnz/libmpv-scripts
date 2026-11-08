// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// pull_pause_tail_test <mode>: white-box test of audio/out/buffer.c
// (patch_gapless_tail.py), which run.sh builds from the patched tree, with
// a fake clock and a fake pull output. The output's callback has read the
// last sample, and its device still holds 50 ms (end_time_ns ahead): the
// final latency of a pull output, about a quantum on PipeWire.
//   hold   an output with set_pause (PipeWire, WASAPI, AAudio): a pause
//          there keeps the 50 ms, 1 s later the delay is still 50 ms, and
//          the resume starts the device again and waits 50 ms for it
//          (r22: the delay counted down while paused, the resume never
//          called set_pause and the output took itself for played out:
//          the rest stayed in the device, and time-pos crept to the end)
//   mid    the same pause and resume while the callback still reads:
//          the delay holds too (r22: it counted down while paused), the
//          resume starts the device (control, green on r22)
//   reset  an output without set_pause (SDL, CoreAudio, AudioUnit,
//          AudioTrack): the pause resets the device, the rest goes with
//          it, and the resume finds it played out (control)
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "audio/out/buffer.c"

static int64_t fake_now = 1000000000;   // 1 s
int64_t mp_time_ns(void) { return fake_now; }

// What buffer.c needs from the rest of mpv. The pull path of this test
// never reads samples: the queue stays empty.
static char dummy[64];
void mp_msg(struct mp_log *log, int lev, const char *format, ...) {}
void af_fill_silence(void *dst, size_t bytes, int format) { memset(dst, 0, bytes); }
bool af_fmt_is_planar(int format) { return false; }
int af_fmt_to_bytes(int format) { return 4; }
void ao_convert_inplace(struct ao_convert_fmt *fmt, void **data, int n) {}
bool ao_need_conversion(struct ao_convert_fmt *fmt) { return false; }
void ao_post_process_data(struct ao *ao, void **data, int n) {}
bool mp_aframe_alloc_data(struct mp_aframe *f, int samples) { return false; }
struct mp_aframe *mp_aframe_create(void) { return NULL; }
uint8_t **mp_aframe_get_data_ro(struct mp_aframe *f) { return NULL; }
uint8_t **mp_aframe_get_data_rw(struct mp_aframe *f) { return NULL; }
int mp_aframe_get_size(struct mp_aframe *f) { return 0; }
bool mp_aframe_set_chmap(struct mp_aframe *f, struct mp_chmap *in) { return true; }
bool mp_aframe_set_format(struct mp_aframe *f, int format) { return true; }
bool mp_aframe_set_rate(struct mp_aframe *f, int rate) { return true; }
bool mp_aframe_set_silence(struct mp_aframe *f, int offset, int samples) { return true; }
void mp_aframe_skip_samples(struct mp_aframe *f, int samples) {}
struct mp_async_queue *mp_async_queue_create(void) { return (void *)dummy; }
struct mp_filter *mp_async_queue_create_filter(struct mp_filter *parent,
                                               enum mp_pin_dir dir,
                                               struct mp_async_queue *queue)
{
    return (void *)dummy;
}
int64_t mp_async_queue_get_samples(struct mp_async_queue *queue) { return 0; }
void mp_async_queue_reset(struct mp_async_queue *queue) {}
void mp_async_queue_resume_reading(struct mp_async_queue *queue) {}
void mp_async_queue_set_config(struct mp_async_queue *queue,
                               struct mp_async_queue_config cfg) {}
struct mp_filter *mp_filter_create_root(struct mpv_global *global) { return (void *)dummy; }
void mp_filter_graph_set_wakeup_cb(struct mp_filter *root,
                                   void (*wakeup_cb)(void *ctx), void *ctx) {}
void mp_filter_reset(struct mp_filter *filter) {}
void mp_frame_unref(struct mp_frame *frame) {}
struct mp_frame mp_pin_out_read(struct mp_pin *p) { return (struct mp_frame){0}; }

// The fake pull output: counts its calls.
static int starts, resets, pauses, resumes;
static void drv_start(struct ao *ao) { starts++; }
static void drv_reset(struct ao *ao) { resets++; }
static bool drv_set_pause(struct ao *ao, bool paused)
{
    if (paused)
        pauses++;
    else
        resumes++;
    return true;
}
static const struct ao_driver hw_pause_driver = {
    .name = "fakepull", .start = drv_start, .reset = drv_reset,
    .set_pause = drv_set_pause,
};
static const struct ao_driver reset_driver = {
    .name = "fakepullreset", .start = drv_start, .reset = drv_reset,
};

static void wakeup(void *ctx) {}

static int failures;

static void check(int ok, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    printf("%s ", ok ? "ok  " : "FAIL");
    vprintf(fmt, ap);
    printf("\n");
    va_end(ap);
    failures += !ok;
}

static int near(double a, double b) { return a > b - 0.0005 && a < b + 0.0005; }

int main(int argc, char **argv)
{
    if (argc < 2)
        return 2;
    const char *mode = argv[1];
    int m_hold = !strcmp(mode, "hold"), m_mid = !strcmp(mode, "mid"),
        m_reset = !strcmp(mode, "reset");
    if (!(m_hold || m_mid || m_reset)) {
        printf("unknown mode %s\n", mode);
        return 2;
    }

    struct ao *ao = talloc_zero(NULL, struct ao);
    ao->driver = m_reset ? &reset_driver : &hw_pause_driver;
    ao->samplerate = 48000;
    ao->wakeup_cb = wakeup;
    init_buffer_pre(ao);
    check(init_buffer_post(ao), "the buffer is up");
    struct buffer_state *p = ao->buffer_state;

    ao_start(ao);
    check(starts == 1, "the device started (%d)", starts);
    // The callback read the last sample (m_mid: it still reads), the
    // device plays it 50 ms from now.
    mp_mutex_lock(&p->lock);
    p->end_time_ns = fake_now + MP_TIME_S_TO_NS(0.05);
    if (!m_mid)
        p->playing = false;
    mp_mutex_unlock(&p->lock);
    double d = ao_get_delay(ao);
    check(near(d, 0.05), "the device holds 50 ms (%.4f)", d);

    ao_set_paused(ao, true, false);
    fake_now += MP_TIME_S_TO_NS(1);
    d = ao_get_delay(ao);
    if (m_reset) {
        check(resets == 1 && pauses == 0, "the pause reset the device (%d)",
              resets);
    } else {
        check(pauses == 1, "the pause paused the device (%d)", pauses);
        check(near(d, 0.05), "1 s later the delay is still 50 ms (%.4f)", d);
    }

    ao_set_paused(ao, false, false);
    double wait = -1;
    bool done = ao_played_out(ao, &wait);
    if (m_reset) {
        check(done, "the rest went with the reset: played out");
    } else {
        check(resumes == 1, "the resume started the device (%d)", resumes);
        d = ao_get_delay(ao);
        check(near(d, 0.05), "the delay is 50 ms again (%.4f)", d);
        if (!m_mid) {
            check(!done && near(wait, 0.05),
                  "the output waits 50 ms for its device (%d, %.4f)", done,
                  wait);
            fake_now += MP_TIME_S_TO_NS(0.051);
            check(ao_played_out(ao, NULL), "then it played out");
        }
    }

    // The stand-ins of the queue and the filter are no talloc blocks.
    p->queue = NULL;
    p->filter_root = NULL;
    ao_uninit(ao);
    printf("RESULT %s\n", failures ? "FAIL" : "PASS");
    return failures != 0;
}
