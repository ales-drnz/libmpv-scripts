// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The JS side of W1: drives the module (libmpv.mjs, no main) through its
// exports from the calling thread, the way the Dart backend of W4 will.
// Events come from the wakeup bridge of scripts/web/mak_web.c: mpv posts one
// task to the main thread, which drains mpv_wait_event(h, 0). Nothing here
// waits on mpv but the calls that take the core lock (initialize, hook_add,
// hook_continue, terminate_destroy), which W4 moves to a service thread.
//
// Shared by run_lib_node.mjs (Node) and harness.html (browser):
//   const result = await runLibHarness(factory, files, log);
// files: [{name, bytes}], the first one also goes through the af chain.

const FMT = { NONE: 0, STRING: 1, FLAG: 3, INT64: 4, DOUBLE: 5, NODE: 6, ARRAY: 7, MAP: 8, BYTES: 9 };
const EV = {
  NONE: 0, SHUTDOWN: 1, LOG: 2, GET_REPLY: 3, SET_REPLY: 4, CMD_REPLY: 5,
  START_FILE: 6, END_FILE: 7, FILE_LOADED: 8, PROPERTY_CHANGE: 22, HOOK: 25,
};
const AF_CHAIN = 'lavfi=[equalizer=f=1000:t=q:w=1:g=3],lavfi=[afftdn],lavfi=[loudnorm]';

// The struct layout W0 derived from client.h for wasm32 (DESIGN.md 6.3), in
// the order of mak_web_layout().
const EXPECTED_LAYOUT = [
  16, 8, // mpv_node: size, format
  12, 4, 8, // mpv_node_list: size, values, keys
  8, 4, // mpv_byte_array: size, size field
  24, 4, 8, 16, // mpv_event: size, error, reply_userdata, data
  12, 4, 8, // mpv_event_property: size, format, data
  16, 8, 12, // mpv_event_log_message: size, text, log_level
  32, 4, 8, 16, 24, // mpv_event_end_file: size, error, entry, insert, num
  16, 8, // mpv_event_hook: size, id
];

export async function runLibHarness(factory, files, log) {
  const res = { checks: [], measures: {} };
  const check = (ok, name, detail) => {
    res.checks.push({ ok, name, detail });
    log(`${ok ? 'ok' : 'FAIL'} ${name} ${detail}`);
  };
  const measure = (k, v) => {
    res.measures[k] = v;
    log(`measure ${k} ${typeof v === 'number' ? v.toFixed(3) : v}`);
  };

  let t = performance.now();
  const m = await factory({ print: log, printErr: log });
  measure('instantiate_ms', performance.now() - t);

  const dv = () => new DataView(m.wasmMemory.buffer);
  const u32 = (p) => dv().getUint32(p, true);
  const i32 = (p) => dv().getInt32(p, true);
  const str = (p) => (p ? m.UTF8ToString(p) : null);
  const withStrings = (list, fn) => {
    const ptrs = list.map((s) => m.stringToNewUTF8(s));
    try {
      return fn(...ptrs);
    } finally {
      ptrs.forEach((p) => m._free(p));
    }
  };
  const argv = (list, fn) => {
    const ptrs = list.map((s) => m.stringToNewUTF8(s));
    const arr = m._malloc(4 * (ptrs.length + 1));
    ptrs.forEach((p, i) => dv().setUint32(arr + 4 * i, p, true));
    dv().setUint32(arr + 4 * ptrs.length, 0, true);
    try {
      return fn(arr);
    } finally {
      ptrs.forEach((p) => m._free(p));
      m._free(arr);
    }
  };
  // mpv_node to a JS value (offsets checked against mak_web_layout below).
  const node = (p) => {
    const d = dv();
    switch (d.getInt32(p + 8, true)) {
      case FMT.STRING: return str(d.getUint32(p, true));
      case FMT.FLAG: return d.getInt32(p, true) !== 0;
      case FMT.INT64: return Number(d.getBigInt64(p, true));
      case FMT.DOUBLE: return d.getFloat64(p, true);
      case FMT.ARRAY:
      case FMT.MAP: {
        const l = d.getUint32(p, true);
        const num = d.getInt32(l, true), values = d.getUint32(l + 4, true), keys = d.getUint32(l + 8, true);
        const isMap = d.getInt32(p + 8, true) === FMT.MAP;
        const out = isMap ? {} : [];
        for (let i = 0; i < num; i++) {
          const v = node(values + 16 * i);
          if (isMap) out[str(u32(keys + 4 * i))] = v; else out.push(v);
        }
        return out;
      }
      case FMT.BYTES: {
        const ba = d.getUint32(p, true);
        return { bytes: d.getUint32(ba + 4, true) };
      }
      default: return null;
    }
  };

  // Layout check.
  const lp = m._mak_web_layout();
  const layout = [];
  for (let i = 0; i32(lp + 4 * i) !== -1; i++) layout.push(i32(lp + 4 * i));
  check(JSON.stringify(layout) === JSON.stringify(EXPECTED_LAYOUT), 'layout', JSON.stringify(layout));

  m.FS.mkdir('/in');
  for (const f of files) m.FS.writeFile(`/in/${f.name}`, f.bytes);

  // Create and initialize. Both take the core lock: timed, since on the
  // browser main thread they spin.
  t = performance.now();
  const h = m._mpv_create();
  for (const [k, v] of [['ao', 'null'], ['ao-null-untimed', 'yes'], ['vid', 'no'],
    ['idle', 'yes'], ['config', 'no'], ['audio-display', 'no']]) {
    withStrings([k, v], (a, b) => m._mpv_set_option_string(h, a, b));
  }
  const initErr = m._mpv_initialize(h);
  measure('mpv_create_initialize_ms', performance.now() - t);
  check(initErr === 0, 'initialize', `error ${initErr}`);

  // Event pump.
  const state = { replies: new Map(), hooks: 0, hookFile: null, loaded: false, ended: null, logs: 0, durationSeen: 0, wakeups: 0 };
  let waiter = null;
  const drain = () => {
    state.wakeups++;
    for (;;) {
      const e = m._mpv_wait_event(h, 0);
      const d = dv();
      const id = d.getInt32(e, true);
      if (id === EV.NONE) break;
      const err = d.getInt32(e + 4, true);
      const reply = Number(d.getBigUint64(e + 8, true));
      const data = d.getUint32(e + 16, true);
      switch (id) {
        case EV.GET_REPLY: {
          const fmt = d.getInt32(data + 4, true), vp = d.getUint32(data + 8, true);
          let v = null;
          if (err >= 0) {
            if (fmt === FMT.STRING) v = str(u32(vp));
            else if (fmt === FMT.DOUBLE) v = d.getFloat64(vp, true);
            else if (fmt === FMT.NODE) v = node(vp);
          }
          state.replies.set(reply, { err, v });
          break;
        }
        case EV.CMD_REPLY:
        case EV.SET_REPLY:
          state.replies.set(reply, { err });
          break;
        case EV.HOOK: {
          const name = str(u32(data)), hid = d.getBigUint64(data + 8, true);
          if (name === 'on_load') {
            state.hooks++;
            const p = withStrings(['stream-open-filename'], (n) => m._mpv_get_property_string(h, n));
            state.hookFile = str(p);
            m._mpv_free(p);
          }
          m._mpv_hook_continue(h, hid);
          break;
        }
        case EV.FILE_LOADED: state.loaded = true; break;
        case EV.END_FILE: state.ended = { reason: d.getInt32(data, true), error: d.getInt32(data + 4, true) }; break;
        case EV.LOG: {
          if (++state.logs <= 20) log(`log [${str(u32(data + 4))}] ${str(u32(data))}: ${str(u32(data + 8))}`.trimEnd());
          break;
        }
        case EV.PROPERTY_CHANGE: {
          const name = str(u32(data)), fmt = d.getInt32(data + 4, true);
          if (name === 'duration' && fmt === FMT.DOUBLE) state.durationSeen = d.getFloat64(u32(data + 8), true);
          if (name === 'audio-params' && fmt === FMT.NODE && !state.ap) {
            const v = node(u32(data + 8));
            if (v && v.samplerate > 0) state.ap = v;
          }
          break;
        }
        default: break;
      }
    }
    if (waiter && waiter.pred()) {
      const w = waiter;
      waiter = null;
      w.resolve(true);
    }
  };
  const until = (pred, ms) => new Promise((resolve) => {
    if (pred()) return resolve(true);
    const timer = setTimeout(() => { waiter = null; resolve(false); }, ms);
    waiter = { pred, resolve: (v) => { clearTimeout(timer); resolve(v); } };
  });
  m.onMpvWakeup = drain;
  const bridge = m._mak_web_wakeup_attach(h);

  let nextId = 100;
  const getAsync = async (name, fmt) => {
    const id = nextId++;
    withStrings([name], (n) => m._mpv_get_property_async(h, BigInt(id), n, fmt));
    await until(() => state.replies.has(id), 5000);
    const r = state.replies.get(id);
    state.replies.delete(id);
    return r ?? { err: -999 };
  };
  const commandAsync = async (list) => {
    const id = nextId++;
    const err = argv(list, (a) => m._mpv_command_async(h, BigInt(id), a));
    if (err < 0) return { err };
    await until(() => state.replies.has(id), 5000);
    const r = state.replies.get(id);
    state.replies.delete(id);
    return r ?? { err: -999 };
  };

  withStrings(['warn'], (l) => m._mpv_request_log_messages(h, l));
  withStrings(['duration'], (n) => m._mpv_observe_property(h, 1n, n, FMT.DOUBLE));
  // audio-params come with the decoder output, after FILE_LOADED: observed.
  withStrings(['audio-params'], (n) => m._mpv_observe_property(h, 3n, n, FMT.NODE));
  t = performance.now();
  withStrings(['on_load'], (n) => m._mpv_hook_add(h, 2n, n, 0));
  measure('hook_add_ms', performance.now() - t);

  const ver = await getAsync('mpv-version', FMT.STRING);
  check(ver.err >= 0 && /^mpv v0\.41\.0/.test(ver.v ?? ''), 'mpv-version', String(ver.v));

  const decode = async (f, tag) => {
    state.loaded = false;
    state.ended = null;
    state.ap = null;
    const hooks0 = state.hooks;
    const path = `/in/${f.name}`;
    const t0 = performance.now();
    const c = await commandAsync(['loadfile', path]);
    if (c.err < 0) { check(false, tag, `loadfile ${c.err}`); return -1; }
    await until(() => state.loaded || state.ended, 20000);
    let dur = { err: -1 };
    if (state.loaded && tag === 'decode') dur = await getAsync('duration', FMT.DOUBLE);
    const ended = await until(() => state.ended, 120000);
    const ms = performance.now() - t0;
    if (tag === 'decode') {
      const ok = dur.err >= 0 && dur.v > 0 && state.ap && state.ap.samplerate > 0;
      check(ok, `${tag}.props`, `${f.name} duration=${dur.v} audio-params=${JSON.stringify(state.ap)}`);
    }
    check(ended && state.ended.reason === 0, `${tag}.eof`, `${f.name} ${JSON.stringify(state.ended)} in ${ms.toFixed(1)} ms`);
    check(state.hooks === hooks0 + 1 && state.hookFile === path, `${tag}.hook`, `on_load ${state.hooks - hooks0} time(s), ${state.hookFile}`);
    return ms;
  };

  for (const f of files) {
    const ms = await decode(f, 'decode');
    measure(`decode_ms.${f.name}`, ms);
  }
  if (files.length) {
    const s = await commandAsync(['set', 'af', AF_CHAIN]);
    check(s.err >= 0, 'af.set', `error ${s.err}`);
    const ms = await decode(files[0], 'af');
    measure(`decode_af_ms.${files[0].name}`, ms);
    const af = await getAsync('af', FMT.STRING);
    check(af.err >= 0 && /afftdn/.test(af.v ?? ''), 'af-chain', String(af.v));
  }
  check(state.durationSeen > 0, 'observe', `last duration ${state.durationSeen}`);
  measure('wakeups', state.wakeups);

  m._mak_web_wakeup_detach(bridge);
  t = performance.now();
  m._mpv_terminate_destroy(h);
  measure('terminate_destroy_ms', performance.now() - t);
  measure('memory_bytes', m.wasmMemory.buffer.byteLength);

  res.pass = res.checks.filter((c) => c.ok).length;
  res.fail = res.checks.length - res.pass;
  log(`RESULT pass=${res.pass} fail=${res.fail}`);
  return res;
}
