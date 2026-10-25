// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The page side of ao_webaudio, linked into libmpv.mjs with --post-js:
// Module.makWebAudio. Main thread only (the glue also runs in the pthread
// workers, where nothing here is called).
//
// mpv's output (patches/mpv/web/ao_webaudio) writes rings in wasm memory
// and the "mak-ring" AudioWorkletProcessor (mak_webaudio_processor.js, next
// to libmpv.mjs) plays them. This file makes the AudioContext, loads the
// worklet, makes one AudioWorkletNode per output id and publishes in the
// shared table what mpv's output needs: the sample rate, the channels, the
// latency and the context's state. mpv never waits on it.
//
//   const audio = await module.makWebAudio.init({ channels: 2 });
//   audio.output(0)        // the AudioWorkletNode of output 0, connected to
//                          // the destination unless init got connect: false
//   audio.state            // 'suspended' until a user gesture, then 'running'
//
// An output id other than 0 is for a page that routes each player on its
// own (the webaudio-output option of that player's mpv). To give the media
// session an audio element, route a node through a
// MediaStreamAudioDestinationNode into an <audio>.

Module['makWebAudio'] = (() => {
  const ABI = 1;
  // Word indices of patches/mpv/web/ao_webaudio/mak_wa_ring.h, as in
  // mak_webaudio_processor.js.
  const T = { ABI: 0, SLOTS: 1, SLOT_WORDS: 2, RATE: 3, CHANNELS: 4, LATENCY_US: 5,
    DEVICE_GEN: 6, CTX_STATE: 7, HEADER_WORDS: 16 };
  const S = { STATE: 0, GEN: 1, OUTPUT: 2, CAPACITY: 4, CHANNELS: 6, WRITE_POS: 7,
    READ_POS: 8, STARTED: 12, PAUSED: 13, GAIN: 14, CONSUMED: 15, UNDERRUNS: 16,
    STARVED: 17, PEAK: 18, QUANTA: 19 };
  const CTX = { suspended: 1, running: 2, closed: 3, interrupted: 1 };

  let ctx = null;
  let ownContext = false;
  let table = 0;
  let channels = 0;
  let timer = 0;
  let offGesture = null;
  const nodes = new Map();
  const listeners = new Set();
  const bits = new Float32Array(1);
  const bitsU = new Uint32Array(bits.buffer);

  const u32 = () => new Uint32Array(wasmMemory.buffer);
  const word = (i) => (table >>> 2) + i;
  const slotWord = (u, slot, i) =>
    word(T.HEADER_WORDS) + slot * Atomics.load(u, word(T.SLOT_WORDS)) + i;
  const asFloat = (b) => { bitsU[0] = b; return bits[0]; };

  // The latency and the state, every second and at every state change: the
  // output latency moves (a Bluetooth headset) and is 0 until the context
  // runs in some browsers.
  function publish() {
    if (!table) return;
    const u = u32();
    const latency = ctx ? (ctx.baseLatency || 0) + (ctx.outputLatency || 0) : 0;
    Atomics.store(u, word(T.LATENCY_US), Math.round(latency * 1e6));
    Atomics.store(u, word(T.CTX_STATE), ctx ? (CTX[ctx.state] ?? 0) : 0);
  }

  function onState() {
    publish();
    for (const f of listeners) {
      try { f(ctx.state); } catch (e) { console.error(e); }
    }
  }

  // The autoplay policy starts a context suspended until a user gesture:
  // every gesture resumes it while it is not running.
  function resumeOnGesture() {
    const kick = () => {
      if (ctx && ctx.state !== 'running' && ctx.state !== 'closed') ctx.resume().catch(() => {});
    };
    const events = ['pointerdown', 'keydown', 'touchend'];
    for (const e of events) addEventListener(e, kick, { capture: true, passive: true });
    offGesture = () => {
      for (const e of events) removeEventListener(e, kick, { capture: true });
    };
  }

  // Options: context (an AudioContext of the page, kept on close), sampleRate,
  // latencyHint ('playback' by default), channels (2 by default, at most the
  // destination's), processorUrl, connect (false leaves output 0
  // unconnected), resumeOnGesture (false leaves resuming to the page). A
  // second call replaces the context: every open output reopens at the new
  // rate, once it is ready (they wait meanwhile, with no reader).
  async function init(opts = {}) {
    if (ctx) await teardown();
    table = Module['_mak_wa_table_get']();
    const u = u32();
    if (Atomics.load(u, word(T.ABI)) !== ABI) {
      throw new Error(`makWebAudio: table version ${Atomics.load(u, word(T.ABI))}, expected ${ABI}`);
    }
    ownContext = !opts.context;
    ctx = opts.context ?? new AudioContext({
      latencyHint: opts.latencyHint ?? 'playback',
      ...(opts.sampleRate ? { sampleRate: opts.sampleRate } : {}),
    });
    await ctx.audioWorklet.addModule(
      opts.processorUrl ?? new URL('mak_webaudio_processor.js', import.meta.url).href);
    const max = Math.min(ctx.destination.maxChannelCount || 2, 8);
    channels = Math.max(1, Math.min(opts.channels ?? 2, max));
    Atomics.store(u, word(T.RATE), ctx.sampleRate);
    Atomics.store(u, word(T.CHANNELS), channels);
    publish();
    Atomics.add(u, word(T.DEVICE_GEN), 1);
    ctx.addEventListener('statechange', onState);
    timer = setInterval(publish, 1000);
    if (opts.resumeOnGesture !== false) resumeOnGesture();
    if (opts.connect !== false) output(0).connect(ctx.destination);
    return api;
  }

  // The AudioWorkletNode of an output id, made on first use. It plays every
  // open output of mpv with that webaudio-output, mixed.
  function output(id = 0) {
    if (!ctx) throw new Error('makWebAudio: init first');
    let node = nodes.get(id);
    if (!node) {
      node = new AudioWorkletNode(ctx, 'mak-ring', {
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [channels],
        processorOptions: { memory: wasmMemory, table, output: id },
      });
      node.onprocessorerror = (e) => console.error('makWebAudio: the worklet failed', e);
      nodes.set(id, node);
    }
    return node;
  }

  // The slots of the table, open or not, for diagnostics and tests. peak
  // is the largest sample put out since the last read, which resets it.
  function stats() {
    if (!table) return [];
    const u = u32();
    const out = [];
    for (let i = 0; i < Atomics.load(u, word(T.SLOTS)); i++) {
      const r = (k) => Atomics.load(u, slotWord(u, i, S[k]));
      const written = r('WRITE_POS');
      out.push({
        slot: i, open: r('STATE') === 1, gen: r('GEN'), output: r('OUTPUT'),
        capacity: r('CAPACITY'), channels: r('CHANNELS'), written,
        queued: (written - r('READ_POS')) >>> 0, started: r('STARTED') === 1,
        paused: r('PAUSED') === 1, gain: asFloat(r('GAIN')), consumed: r('CONSUMED'),
        underruns: r('UNDERRUNS'), starved: r('STARVED'), quanta: r('QUANTA'),
        peak: asFloat(Atomics.exchange(u, slotWord(u, i, S.PEAK), 0)),
      });
    }
    return out;
  }

  // The nodes and the context go; the table keeps the device, so a new
  // context replaces it with a single reload of the open outputs.
  async function teardown() {
    clearInterval(timer);
    if (offGesture) offGesture();
    offGesture = null;
    for (const node of nodes.values()) {
      node.port.postMessage('close');
      node.disconnect();
    }
    nodes.clear();
    if (ctx) {
      ctx.removeEventListener('statechange', onState);
      if (ownContext && ctx.state !== 'closed') await ctx.close();
    }
    ctx = null;
  }

  async function close() {
    await teardown();
    if (table) {
      // No device: open outputs reopen and fail until the next init.
      const u = u32();
      Atomics.store(u, word(T.RATE), 0);
      Atomics.store(u, word(T.CHANNELS), 0);
      Atomics.store(u, word(T.CTX_STATE), 0);
      Atomics.add(u, word(T.DEVICE_GEN), 1);
    }
  }

  const api = {
    init,
    output,
    stats,
    close,
    resume: () => (ctx ? ctx.resume() : Promise.reject(new Error('makWebAudio: init first'))),
    onStateChange(f) {
      listeners.add(f);
      return () => listeners.delete(f);
    },
    get context() { return ctx; },
    get channels() { return channels; },
    get state() { return ctx ? ctx.state : 'none'; },
    // The latency mpv adds to the queued audio, in seconds.
    get latency() {
      return table ? Atomics.load(u32(), word(T.LATENCY_US)) / 1e6 : 0;
    },
  };
  return api;
})();
