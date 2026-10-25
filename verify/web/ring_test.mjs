// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Unit test of ao_webaudio's ring: the C producer (mak_wa_ring.h through
// ring_test.c) against the worklet's consumer (RingReader of
// mak_webaudio_processor.js) on one shared wasm memory, one step at a time:
// layout, empty, partial, full, wrap at 2^32, underrun, pause, reset,
// gain, close and reopen, two slots on one output, memory growth.
//
//   node ring_test.mjs <ring_mod.mjs> <mak_webaudio_processor.js>
// (ring_test.sh builds the module and runs it)

import { pathToFileURL } from 'node:url';

const [modPath, procPath] = process.argv.slice(2);
const { default: factory } = await import(pathToFileURL(modPath).href);
const { RingReader, T, S, ABI, QUANTUM, FADE, OPEN } = await import(pathToFileURL(procPath).href);
const m = await factory();

let fails = 0, passes = 0;
const check = (ok, name, detail = '') => {
  if (ok) passes++; else fails++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? ` ${detail}` : ''}`);
};
const near = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps;

const table = m._rt_table();
const f32 = () => new Float32Array(m.wasmMemory.buffer);
const u32 = () => new Uint32Array(m.wasmMemory.buffer);
const slotWord = (i, w) => (table >>> 2) + T.HEADER_WORDS + i * S_WORDS + w;
let S_WORDS = 32;

// Layout: the C enums against the JS lists.
{
  const p = m._rt_layout();
  const got = [];
  for (let i = 0; ; i++) {
    const v = new Int32Array(m.wasmMemory.buffer)[(p >>> 2) + i];
    if (v === -1) break;
    got.push(v);
  }
  const want = [T.ABI, T.SLOTS, T.SLOT_WORDS, T.RATE, T.CHANNELS, T.LATENCY_US, T.DEVICE_GEN,
    T.CTX_STATE, T.HEADER_WORDS, S.STATE, S.GEN, S.OUTPUT, S.DATA, S.CAPACITY, S.FRAMES,
    S.CHANNELS, S.WRITE_POS, S.READ_POS, S.FLUSH_SEQ, S.FLUSH_POS, S.FLUSH_ACK, S.STARTED,
    S.PAUSED, S.GAIN, S.CONSUMED, S.UNDERRUNS, S.STARVED, S.PEAK, S.QUANTA, 32, ABI, 8, QUANTUM, OPEN];
  check(JSON.stringify(got) === JSON.stringify(want), 'layout', JSON.stringify(got));
  S_WORDS = got[29];
}

const word = (i, w) => u32()[slotWord(i, w)];
// A ring buffer of frames frames with ch channels, from malloc.
const ring = (frames, ch) => m._malloc(frames * ch * 4);
// Writes n frames whose channel c holds value(k, c) for frame k (k from k0).
const write = (i, k0, n, ch, value = (k, c) => (c ? -(k + 1) : k + 1) / 1e5) => {
  const p = m._malloc(n * ch * 4);
  const f = f32();
  for (let k = 0; k < n; k++) for (let c = 0; c < ch; c++) f[(p >>> 2) + k * ch + c] = value(k0 + k, c);
  const wrote = m._rt_write(i, p, n);
  m._free(p);
  return wrote;
};
const outs = (ch, n = QUANTUM) => Array.from({ length: ch }, () => new Float32Array(n));
const value = (k) => (k + 1) / 1e5;
const stats = (i) => ({
  read: word(i, S.READ_POS), write: word(i, S.WRITE_POS), consumed: word(i, S.CONSUMED),
  underruns: word(i, S.UNDERRUNS), starved: word(i, S.STARVED), ack: word(i, S.FLUSH_ACK),
});

// ── empty, partial, underrun ──────────────────────────────────────────────
{
  const r = new RingReader(m.wasmMemory, table, 0);
  const data = ring(1024, 2);
  m._rt_open(0, 0, data, 1024, 1024, 2, 1);
  m._rt_set(0, S.STARTED, 1);
  let o = outs(2);
  r.render(o);
  check(o[0].every((v) => v === 0) && stats(0).starved === QUANTUM && stats(0).underruns === 0,
    'empty: silence, counted as silent frames, no underrun', JSON.stringify(stats(0)));
  check(m._rt_queued(0) === 0 && m._rt_free(0) === 1024, 'empty: queued 0, free 1024');

  check(write(0, 0, 300, 2) === 300, 'partial: 300 frames written');
  check(m._rt_queued(0) === 300 && m._rt_free(0) === 640, 'partial: queued 300, free 640 (whole quanta)',
    `${m._rt_queued(0)} ${m._rt_free(0)}`);
  o = outs(2);
  r.render(o);
  // Audio back after the empty quantum: one underrun, a fade in.
  const fadedIn = near(o[0][0], value(0) / (FADE + 1)) && near(o[0][FADE], value(FADE)) &&
    near(o[1][100], -value(100)) && near(o[0][127], value(127));
  check(fadedIn && stats(0).underruns === 1 && stats(0).consumed === 128,
    'partial: first quantum faded in, an underrun counted when audio came back', JSON.stringify(stats(0)));
  o = outs(2);
  r.render(o);
  check(near(o[0][0], value(128)) && near(o[0][127], value(255)), 'partial: second quantum plain');
  o = outs(2);
  r.render(o);
  // 44 frames left: they fade out, the rest of the quantum is silence.
  const tail = near(o[0][0], value(256) * (43 / 44)) && near(o[0][43], 0) && o[0].slice(44).every((v) => v === 0);
  check(tail && stats(0).consumed === 300 && stats(0).starved === QUANTUM + 84,
    'partial: the last 44 frames fade out, then silence', JSON.stringify(stats(0)));
  r.render(outs(2));
  check(stats(0).underruns === 1, 'partial: running dry is no underrun yet');
  m._rt_set(0, S.STARTED, 0); // a reset at the end of a stream (with a flush)
  m._rt_flush(0);
  r.render(outs(2));
  m._rt_set(0, S.STARTED, 1);
  write(0, 300, 128, 2);
  r.render(outs(2));
  check(stats(0).underruns === 1, 'partial: a gap closed by a reset is no underrun', JSON.stringify(stats(0)));
  m._rt_close(0);
  r.render(outs(2));
}

// ── full, wrap at 2^32 with a capacity that is not a power of two ────────
{
  const r = new RingReader(m.wasmMemory, table, 0);
  const cap = 1152, size = 2048; // 9 quanta in a ring of 2048
  const data = ring(size, 1);
  m._rt_open(1, 0, data, cap, size, 1, 1);
  check(write(1, 0, 5000, 1, (k) => value(k)) === cap && m._rt_free(1) === 0 && write(1, 0, 10, 1) === 0,
    'full: writes stop at the capacity, free 0', `free ${m._rt_free(1)}`);
  m._rt_close(1);
  // Positions near 2^32: the next 1000 frames wrap.
  const base = 2 ** 32 - 500;
  m._rt_open(1, 0, data, cap, size, 1, 1);
  for (const w of [S.WRITE_POS, S.READ_POS, S.FLUSH_POS]) m._rt_set(1, w, base);
  m._rt_set(1, S.STARTED, 1);
  let got = [], k = 0, ok = true;
  for (let step = 0; step < 20; step++) {
    k += write(1, k, m._rt_free(1), 1, (j) => value(j));
    const o = outs(1);
    r.render(o);
    got.push(...o[0]);
  }
  // After the fade in, frame j of the output is value(j) across the wrap.
  for (let j = FADE; j < got.length; j++) if (!near(got[j], value(j))) { ok = false; break; }
  check(ok && got.length === 20 * QUANTUM && stats(1).read === (base + 20 * QUANTUM) % 2 ** 32,
    'wrap: frames continuous across 2^32 with a ring of 2048 holding 1152',
    `read ${stats(1).read}, queued ${m._rt_queued(1)}`);
  check(m._rt_queued(1) === (k - 20 * QUANTUM) && m._rt_queued(1) <= cap, 'wrap: queued counts across the wrap');
  m._rt_close(1);
  r.render(outs(1));
}

// ── pause, reset, gain ────────────────────────────────────────────────────
{
  const r = new RingReader(m.wasmMemory, table, 0);
  const data = ring(2048, 1); // twice the capacity, as ao_webaudio opens it
  m._rt_open(2, 0, data, 1024, 2048, 1, 1);
  write(2, 0, 1024, 1, (j) => value(j));
  m._rt_set(2, S.STARTED, 1);
  r.render(outs(1));
  m._rt_set(2, S.PAUSED, 1);
  let o = outs(1);
  r.render(o);
  const faded = near(o[0][0], value(128) * (63 / 64)) && o[0][FADE - 1] === 0 && o[0].slice(FADE).every((v) => v === 0);
  check(faded && stats(2).read === 128 + FADE, 'pause: fades out over 64 frames, then silence', JSON.stringify(stats(2)));
  o = outs(1);
  r.render(o);
  check(o[0].every((v) => v === 0) && stats(2).read === 128 + FADE && stats(2).starved === 0,
    'pause: the frames stay, nothing counted as a gap');
  m._rt_set(2, S.PAUSED, 0);
  o = outs(1);
  r.render(o);
  check(near(o[0][FADE], value(128 + FADE + FADE)) && stats(2).underruns === 0, 'pause: resume goes on from the next frame, faded in');

  // Reset: queued drops at once and the whole capacity is free at once
  // (buffer.c sleeps when a reset leaves no room), beside the dropped
  // frames the consumer has not skipped yet.
  m._rt_set(2, S.STARTED, 0);
  m._rt_set(2, S.PAUSED, 0);
  m._rt_flush(2);
  const readBefore = stats(2).read;
  check(m._rt_queued(2) === 0 && m._rt_free(2) === 1024,
    'reset: queued 0 and the whole capacity free before the consumer applies it', `free ${m._rt_free(2)}`);
  check(write(2, 5000, 1024, 1, (j) => value(j)) === 1024 && m._rt_free(2) === 0,
    'reset: a whole capacity of new audio written beside the dropped frames');
  o = outs(1);
  r.render(o);
  check(near(o[0][0], value(readBefore) * (63 / 64)) && o[0][FADE - 1] === 0 && o[0].slice(FADE).every((v) => v === 0) &&
    stats(2).read === 1024 && stats(2).ack === 1,
    'reset: the consumer fades out 64 dropped frames, intact, skips to the reset, acknowledges', JSON.stringify(stats(2)));
  m._rt_set(2, S.STARTED, 1);
  o = outs(1);
  r.render(o);
  check(near(o[0][FADE], value(5000 + FADE)) && stats(2).underruns === 0, 'reset: the new audio starts at the reset, faded in');
  check(m._rt_free(2) === 128, 'reset: room again as the new audio plays', `free ${m._rt_free(2)}`);

  // Gain: ramped over one quantum, then exact.
  m._rt_gain(2, 0.5);
  o = outs(1);
  r.render(o);
  check(near(o[0][127], value(5000 + 255) * 0.5) && near(o[0][63], value(5000 + 128 + 63) * (1 - 0.5 * 64 / 128)),
    'gain: ramped from 1 to 0.5 across the quantum');
  m._rt_close(2);
  r.render(outs(1));
}

// ── close and reopen, two slots on one output, another output ignored ────
{
  const r = new RingReader(m.wasmMemory, table, 3);
  const a = ring(1024, 1), b = ring(1024, 1), c = ring(1024, 1);
  m._rt_open(3, 3, a, 1024, 1024, 1, 1);
  m._rt_open(4, 3, b, 1024, 1024, 1, 1);
  m._rt_open(5, 4, c, 1024, 1024, 1, 1); // output 4: not this reader's
  for (const s of [3, 4, 5]) {
    write(s, 0, 1024, 1, () => 0.25);
    m._rt_set(s, S.STARTED, 1);
  }
  let o = outs(1);
  r.render(o);
  r.render(o = outs(1));
  check(near(o[0][10], 0.5) && stats(5).read === 0, 'mix: two slots of output 3 summed, output 4 left alone',
    `${o[0][10]} ${stats(5).read}`);
  m._rt_close(3);
  r.render(o = outs(1));
  check(near(o[0][0], 0.25 + 0.25 * 63 / 64) && near(o[0][100], 0.25), 'close: a closed slot fades out, the other goes on');
  const gen = word(3, S.GEN);
  m._rt_open(3, 3, a, 1024, 1024, 1, 1);
  write(3, 0, 512, 1, () => 0.125);
  m._rt_set(3, S.STARTED, 1);
  r.render(o = outs(1));
  check(word(3, S.GEN) === gen + 1 && near(o[0][100], 0.25 + 0.125) && stats(3).consumed === 128,
    'reopen: a new stream from position 0, mixed again');
  for (const s of [3, 4, 5]) m._rt_close(s);
  r.render(outs(1));
}

// ── memory growth: a ring past the reader's view ─────────────────────────
{
  const r = new RingReader(m.wasmMemory, table, 0);
  const before = r.f32.byteLength;
  // A ring of 32 MB cannot fit in the 16 MB the reader saw: the memory grows.
  const data = ring(1 << 23, 1);
  m._rt_open(6, 0, data, 1024, 1 << 23, 1, 1);
  write(6, 0, 512, 1, (j) => value(j));
  m._rt_set(6, S.STARTED, 1);
  const o = outs(1);
  r.render(o);
  check(m.wasmMemory.buffer.byteLength > before && r.f32.byteLength > before && near(o[0][100], value(100)),
    'growth: the reader takes the grown buffer and reads the ring', `${before} -> ${r.f32.byteLength}`);
  m._rt_close(6);
  m._free(data);
}

console.log(`RESULT pass=${passes} fail=${fails}`);
process.exit(fails ? 1 : 0);
