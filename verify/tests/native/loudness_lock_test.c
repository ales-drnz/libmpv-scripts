// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// loudness_lock_test: white-box test of audio/mak_loudness.c (F75), which
// run.sh builds from the patched tree with the stubs below. A coordinator
// thread of generation 1 marks the loudness failed exactly while the core
// starts generation 2 and marks it scanning. The test lock holds that
// thread only before it takes the mutex, between its generation check and
// the write, until the core has marked generation 2: on r17 the check is
// outside the lock, so the stale FAILED lands on top of the new
// generation's SCANNING. Fixed, the check is under the lock and the stale
// write is dropped. The two threads hand over through flags, not sleeps;
// each wait has a ceiling scaled as mpv_test.h's rule 1 says.
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#include "osdep/threads.h"

static _Thread_local int an_slow_lock;
static atomic_int an_held, an_go;

// Waits until *flag is set, up to 5 s times MAK_TIME_SCALE; 1 if it was.
static int an_until(atomic_int *flag)
{
    const char *s = getenv("MAK_TIME_SCALE");
    double scale = s && atof(s) > 1 ? atof(s) : 1;
    struct timespec t0, t;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    while (!atomic_load(flag)) {
        clock_gettime(CLOCK_MONOTONIC, &t);
        if (t.tv_sec - t0.tv_sec + (t.tv_nsec - t0.tv_nsec) / 1e9 > 5 * scale)
            return 0;
        usleep(1000);
    }
    return 1;
}

static int an_lock(pthread_mutex_t *m)
{
    if (an_slow_lock) {
        atomic_store(&an_held, 1);
        an_until(&an_go);
    }
    return pthread_mutex_lock(m);
}

#undef mp_mutex_lock
#define mp_mutex_lock(m) an_lock(m)

#include "audio/mak_loudness.c"

// The waveform product's generation, stubbed.
static atomic_int an_gen;
int mak_waveform_current_gen(void) { return atomic_load(&an_gen); }
double mak_waveform_decode_fraction(void) { return 0; }

static void *stale_failed(void *p)
{
    (void)p;
    an_slow_lock = 1;
    mak_loudness_mark_failed(1);   // the coordinator of generation 1 fails
    return NULL;
}

int main(void)
{
    int fails = 0;
    for (int round = 0; round < 3; round++) {
        atomic_store(&an_gen, 1);
        atomic_store(&an_held, 0);
        atomic_store(&an_go, 0);
        mak_loudness_set_enabled(true);
        mak_loudness_mark_scanning(1);
        pthread_t t;
        pthread_create(&t, NULL, stale_failed, NULL);
        int held = an_until(&an_held);  // the old thread is in its lock
        atomic_fetch_add(&an_gen, 1);   // core: begin_generation (2)
        mak_loudness_mark_scanning(2);  // core: mark_scanning (2)
        atomic_store(&an_go, 1);        // the old thread takes the mutex
        pthread_join(t, NULL);
        if (!held) {
            printf("FAIL round %d: the old thread never reached its lock\n", round);
            fails++;
            continue;
        }
        bool scanning = mak_loudness_is_scanning();
        printf("%s round %d: generation 2 %s\n", scanning ? "ok  " : "FAIL",
               round, scanning ? "still scanning" : "lost to the stale failed");
        fails += !scanning;
    }
    printf(fails ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", fails);
    return fails ? 1 : 0;
}
