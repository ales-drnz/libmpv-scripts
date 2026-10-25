/* MAK_AO_WEBAUDIO_PATCH_V1 ─── the rings of ao_webaudio, shared with the
 * AudioWorklet. See patches/mpv/web/patch_ao_webaudio.py in libmpv-scripts
 * for the rationale.
 *
 * One table in wasm memory, never freed: a header the page's main thread
 * writes (the AudioContext's rate, the output channels, the latency) and
 * MAK_WA_SLOTS slots, one per open output. Each slot is a single producer,
 * single consumer ring of interleaved float32 frames:
 *
 *   producer  ao_webaudio's write(), on mpv's "ao" thread (buffer.c);
 *   consumer  the "mak-ring" AudioWorkletProcessor
 *             (scripts/web/mak_webaudio_processor.js), on the browser's
 *             audio thread, which can neither call into wasm nor wait.
 *
 * Every field is a 32-bit word, so the worklet reads them with Atomics on a
 * Uint32Array at the word indices below (the JS side keeps the same list).
 * Positions count frames since the slot opened and wrap at 2^32; only their
 * differences matter. Who writes each word: P the producer, C the consumer,
 * M the main thread.
 *
 * A reset (seek, stop) never moves read_pos, which only the consumer
 * writes: the producer notes where the new audio starts (flush_pos) and
 * bumps flush_seq; the consumer skips to flush_pos and acknowledges. Until
 * then the producer counts no queued audio before flush_pos. buffer.c wants
 * the whole capacity free right after a reset (it sleeps until woken when
 * there is no room and it is not streaming), so the ring is at least twice
 * the capacity: a full capacity of new audio fits beside the dropped frames
 * the consumer has not skipped yet, and never overwrites them. */
#ifndef MAK_WA_RING_H_
#define MAK_WA_RING_H_

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* Bumped when a word moves or changes meaning; the worklet refuses a table
 * of another version. */
#define MAK_WA_ABI 1

/* Open outputs at once, over every player of the page. */
#define MAK_WA_SLOTS 8

/* Frames of one render quantum of Web Audio. Capacities and free space
 * are multiples of it. */
#define MAK_WA_QUANTUM 128

/* Output ids an output may use (the webaudio-output option). */
#define MAK_WA_MAX_OUTPUT 15

/* Slot states. */
#define MAK_WA_FREE 0
#define MAK_WA_OPEN 1

/* AudioContext states, as the main thread publishes them. */
#define MAK_WA_CTX_NONE 0
#define MAK_WA_CTX_SUSPENDED 1
#define MAK_WA_CTX_RUNNING 2
#define MAK_WA_CTX_CLOSED 3

struct mak_wa_slot {
    _Atomic uint32_t state;      /* P: MAK_WA_FREE or MAK_WA_OPEN, set last */
    _Atomic uint32_t gen;        /* P: bumped at every open */
    _Atomic uint32_t output;     /* P: output id (the AudioWorkletNode) */
    _Atomic uint32_t data;       /* P: byte address of the frames */
    _Atomic uint32_t capacity;   /* P: frames it may hold, whole quanta */
    _Atomic uint32_t frames;     /* P: frames of the ring, a power of two
                                  * at least twice capacity: a position
                                  * maps to pos & (frames - 1) across the
                                  * wrap */
    _Atomic uint32_t channels;   /* P */
    _Atomic uint32_t write_pos;  /* P: frames written */
    _Atomic uint32_t read_pos;   /* C: frames read */
    _Atomic uint32_t flush_seq;  /* P: bumped by every reset */
    _Atomic uint32_t flush_pos;  /* P: write_pos at the last reset */
    _Atomic uint32_t flush_ack;  /* C: the flush_seq it applied */
    _Atomic uint32_t started;    /* P: 1 from start() to reset() */
    _Atomic uint32_t paused;     /* P */
    _Atomic uint32_t gain;       /* P: float bits, volume and mute applied */
    _Atomic uint32_t consumed;   /* C: frames played since the open */
    _Atomic uint32_t underruns;  /* C: gaps in the middle of a stream */
    _Atomic uint32_t starved;    /* C: frames of silence put in a gap */
    _Atomic uint32_t peak;       /* C: float bits, max |sample| put out */
    _Atomic uint32_t quanta;     /* C: render quanta that read the slot */
    uint32_t reserved[12];
};

struct mak_wa_table {
    _Atomic uint32_t abi;        /* MAK_WA_ABI */
    _Atomic uint32_t slots;      /* MAK_WA_SLOTS */
    _Atomic uint32_t slot_words; /* sizeof(struct mak_wa_slot) / 4 */
    _Atomic uint32_t rate;       /* M: AudioContext.sampleRate, 0 before */
    _Atomic uint32_t channels;   /* M: channels of every output */
    _Atomic uint32_t latency_us; /* M: baseLatency + outputLatency */
    _Atomic uint32_t device_gen; /* M: bumped when rate or channels change */
    _Atomic uint32_t ctx_state;  /* M: MAK_WA_CTX_* */
    uint32_t reserved[8];
    struct mak_wa_slot slot[MAK_WA_SLOTS];
};

/* Word indices, the ones the worklet uses. */
enum {
    MAK_WA_T_ABI = 0, MAK_WA_T_SLOTS, MAK_WA_T_SLOT_WORDS, MAK_WA_T_RATE,
    MAK_WA_T_CHANNELS, MAK_WA_T_LATENCY_US, MAK_WA_T_DEVICE_GEN,
    MAK_WA_T_CTX_STATE, MAK_WA_T_HEADER_WORDS = 16,
};
enum {
    MAK_WA_S_STATE = 0, MAK_WA_S_GEN, MAK_WA_S_OUTPUT, MAK_WA_S_DATA,
    MAK_WA_S_CAPACITY, MAK_WA_S_FRAMES, MAK_WA_S_CHANNELS, MAK_WA_S_WRITE_POS,
    MAK_WA_S_READ_POS, MAK_WA_S_FLUSH_SEQ, MAK_WA_S_FLUSH_POS,
    MAK_WA_S_FLUSH_ACK, MAK_WA_S_STARTED, MAK_WA_S_PAUSED, MAK_WA_S_GAIN,
    MAK_WA_S_CONSUMED, MAK_WA_S_UNDERRUNS, MAK_WA_S_STARVED, MAK_WA_S_PEAK,
    MAK_WA_S_QUANTA, MAK_WA_S_WORDS = 32,
};

#define MAK_WA_AT(type, field, word) \
    _Static_assert(offsetof(struct type, field) == 4 * (word), #field)
MAK_WA_AT(mak_wa_table, ctx_state, MAK_WA_T_CTX_STATE);
MAK_WA_AT(mak_wa_table, slot, MAK_WA_T_HEADER_WORDS);
MAK_WA_AT(mak_wa_slot, frames, MAK_WA_S_FRAMES);
MAK_WA_AT(mak_wa_slot, read_pos, MAK_WA_S_READ_POS);
MAK_WA_AT(mak_wa_slot, flush_ack, MAK_WA_S_FLUSH_ACK);
MAK_WA_AT(mak_wa_slot, quanta, MAK_WA_S_QUANTA);
_Static_assert(sizeof(struct mak_wa_slot) == 4 * MAK_WA_S_WORDS, "slot");
#undef MAK_WA_AT

/* ── producer side ───────────────────────────────────────────────────── */

/* Opens a claimed slot that no consumer reads (it is free for them): a
 * ring of frames frames (a power of two, at least twice capacity) at data,
 * holding at most capacity,
 * gain as float bits. gen moves before state, so a consumer that sees the
 * slot open sees a new stream. */
static inline void mak_wa_open(struct mak_wa_slot *s, uint32_t output,
                               float *data, uint32_t capacity,
                               uint32_t frames, uint32_t channels,
                               uint32_t gain)
{
    atomic_store(&s->output, output);
    atomic_store(&s->data, (uint32_t)(uintptr_t)data);
    atomic_store(&s->capacity, capacity);
    atomic_store(&s->frames, frames);
    atomic_store(&s->channels, channels);
    atomic_store(&s->write_pos, 0);
    atomic_store(&s->read_pos, 0);
    atomic_store(&s->flush_seq, 0);
    atomic_store(&s->flush_pos, 0);
    atomic_store(&s->flush_ack, 0);
    atomic_store(&s->started, 0);
    atomic_store(&s->paused, 0);
    atomic_store(&s->gain, gain);
    atomic_store(&s->consumed, 0);
    atomic_store(&s->underruns, 0);
    atomic_store(&s->starved, 0);
    atomic_store(&s->peak, 0);
    atomic_store(&s->quanta, 0);
    atomic_fetch_add(&s->gen, 1);
    atomic_store(&s->state, MAK_WA_OPEN);
}

/* The consumer stops reading it; the frames stay until it opens again. */
static inline void mak_wa_close(struct mak_wa_slot *s)
{
    atomic_store(&s->started, 0);
    atomic_store(&s->state, MAK_WA_FREE);
}

/* Frames the consumer has not played since the last reset: before it
 * applies a reset, the audio before flush_pos does not count. */
static inline uint32_t mak_wa_queued(struct mak_wa_slot *s)
{
    uint32_t w = atomic_load(&s->write_pos);
    uint32_t used = w - atomic_load(&s->read_pos);
    uint32_t seq = atomic_load(&s->flush_seq);
    if (atomic_load(&s->flush_ack) != seq) {
        uint32_t fresh = w - atomic_load(&s->flush_pos);
        if (fresh < used)
            used = fresh;
    }
    return used;
}

/* Frames the producer may write now: the capacity less what is queued,
 * within the slots of the ring the consumer is done with. */
static inline uint32_t mak_wa_room(struct mak_wa_slot *s)
{
    uint32_t cap = atomic_load(&s->capacity);
    uint32_t size = atomic_load(&s->frames);
    uint32_t used = atomic_load(&s->write_pos) - atomic_load(&s->read_pos);
    uint32_t queued = mak_wa_queued(s);
    uint32_t room = queued < cap ? cap - queued : 0;
    uint32_t left = used < size ? size - used : 0;
    return room < left ? room : left;
}

/* The room in whole quanta, what get_state reports as free. */
static inline uint32_t mak_wa_free(struct mak_wa_slot *s)
{
    return mak_wa_room(s) / MAK_WA_QUANTUM * MAK_WA_QUANTUM;
}

/* Copies up to frames interleaved frames into the ring, wrapping at the
 * end, and publishes them. Returns the frames written. */
static inline uint32_t mak_wa_write(struct mak_wa_slot *s, const float *src,
                                    uint32_t frames)
{
    uint32_t room = mak_wa_room(s);
    uint32_t size = atomic_load(&s->frames);
    uint32_t ch = atomic_load(&s->channels);
    float *data = (float *)(uintptr_t)atomic_load(&s->data);
    if (frames > room)
        frames = room;
    uint32_t w = atomic_load(&s->write_pos);
    uint32_t at = w & (size - 1);
    uint32_t first = frames < size - at ? frames : size - at;
    memcpy(data + (size_t)at * ch, src, (size_t)first * ch * sizeof(float));
    memcpy(data, src + (size_t)first * ch,
           (size_t)(frames - first) * ch * sizeof(float));
    atomic_store(&s->write_pos, w + frames);
    return frames;
}

/* A reset: the audio written so far is dropped, the next starts at the
 * write position. flush_pos is stored before flush_seq, so a consumer
 * that sees the new sequence sees its position. */
static inline void mak_wa_flush(struct mak_wa_slot *s)
{
    atomic_store(&s->flush_pos, atomic_load(&s->write_pos));
    atomic_fetch_add(&s->flush_seq, 1);
}

#endif
