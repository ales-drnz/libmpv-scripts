/* Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
 *
 * The producer side of ao_webaudio's ring (mak_wa_ring.h, the header the
 * driver uses) in a small wasm module, for ring_test.mjs, which drives it
 * against the worklet's consumer (RingReader of mak_webaudio_processor.js)
 * on the same memory. Built by ring_test.sh. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <emscripten/emscripten.h>

#include "mak_wa_ring.h"

static struct mak_wa_table table = {
    .abi = MAK_WA_ABI,
    .slots = MAK_WA_SLOTS,
    .slot_words = MAK_WA_S_WORDS,
};

EMSCRIPTEN_KEEPALIVE struct mak_wa_table *rt_table(void) { return &table; }

EMSCRIPTEN_KEEPALIVE void rt_open(int i, uint32_t output, float *data,
                                  uint32_t capacity, uint32_t frames,
                                  uint32_t channels, float gain)
{
    uint32_t bits;
    memcpy(&bits, &gain, sizeof(bits));
    mak_wa_open(&table.slot[i], output, data, capacity, frames, channels, bits);
}

EMSCRIPTEN_KEEPALIVE void rt_close(int i) { mak_wa_close(&table.slot[i]); }

EMSCRIPTEN_KEEPALIVE uint32_t rt_write(int i, const float *src, uint32_t frames)
{
    return mak_wa_write(&table.slot[i], src, frames);
}

EMSCRIPTEN_KEEPALIVE uint32_t rt_free(int i) { return mak_wa_free(&table.slot[i]); }
EMSCRIPTEN_KEEPALIVE uint32_t rt_queued(int i) { return mak_wa_queued(&table.slot[i]); }
EMSCRIPTEN_KEEPALIVE void rt_flush(int i) { mak_wa_flush(&table.slot[i]); }

EMSCRIPTEN_KEEPALIVE void rt_set(int i, int word, uint32_t value)
{
    atomic_store((_Atomic uint32_t *)&table.slot[i] + word, value);
}

EMSCRIPTEN_KEEPALIVE void rt_gain(int i, float gain)
{
    uint32_t bits;
    memcpy(&bits, &gain, sizeof(bits));
    atomic_store(&table.slot[i].gain, bits);
}

/* The word indices of the header, for the JS side to compare. */
EMSCRIPTEN_KEEPALIVE const int *rt_layout(void)
{
    static const int t[] = {
        MAK_WA_T_ABI, MAK_WA_T_SLOTS, MAK_WA_T_SLOT_WORDS, MAK_WA_T_RATE,
        MAK_WA_T_CHANNELS, MAK_WA_T_LATENCY_US, MAK_WA_T_DEVICE_GEN,
        MAK_WA_T_CTX_STATE, MAK_WA_T_HEADER_WORDS,
        MAK_WA_S_STATE, MAK_WA_S_GEN, MAK_WA_S_OUTPUT, MAK_WA_S_DATA,
        MAK_WA_S_CAPACITY, MAK_WA_S_FRAMES, MAK_WA_S_CHANNELS,
        MAK_WA_S_WRITE_POS, MAK_WA_S_READ_POS, MAK_WA_S_FLUSH_SEQ,
        MAK_WA_S_FLUSH_POS, MAK_WA_S_FLUSH_ACK, MAK_WA_S_STARTED,
        MAK_WA_S_PAUSED, MAK_WA_S_GAIN, MAK_WA_S_CONSUMED, MAK_WA_S_UNDERRUNS,
        MAK_WA_S_STARVED, MAK_WA_S_PEAK, MAK_WA_S_QUANTA, MAK_WA_S_WORDS,
        MAK_WA_ABI, MAK_WA_SLOTS, MAK_WA_QUANTUM, MAK_WA_OPEN, -1,
    };
    return t;
}
