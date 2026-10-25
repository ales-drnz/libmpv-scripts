// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// A small mpv client in JS over the module's exports, for the harnesses
// (lib_harness.mjs, audio_harness.mjs): strings and argv in wasm memory,
// mpv_node decoding with the wasm32 offsets, and an event pump fed by the
// wakeup bridge of scripts/web/mak_web.c, from the calling thread. Only the
// calls that take the core lock wait on mpv.

export const FMT = { NONE: 0, STRING: 1, FLAG: 3, INT64: 4, DOUBLE: 5, NODE: 6, ARRAY: 7, MAP: 8, BYTES: 9 };
export const EV = {
  NONE: 0, SHUTDOWN: 1, LOG: 2, GET_REPLY: 3, SET_REPLY: 4, CMD_REPLY: 5,
  START_FILE: 6, END_FILE: 7, FILE_LOADED: 8, IDLE: 11, PLAYBACK_RESTART: 21,
  PROPERTY_CHANGE: 22, HOOK: 25,
};

export function wasmHelpers(m) {
  const dv = () => new DataView(m.wasmMemory.buffer);
  const u32 = (p) => dv().getUint32(p, true);
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
  // mpv_node to a JS value (offsets checked against mak_web_layout).
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
  return { dv, u32, str, withStrings, argv, node };
}

// A core made with options, initialized, its events pumped on wakeups.
// onEvent(id, err, reply, data) sees every event before the replies are
// matched.
export function createCore(m, options, onEvent = () => {}) {
  const w = wasmHelpers(m);
  const h = m._mpv_create();
  for (const [k, v] of options) w.withStrings([k, v], (a, b) => m._mpv_set_option_string(h, a, b));
  const initErr = m._mpv_initialize(h);
  const replies = new Map();
  const waiters = new Set();
  let wakeups = 0;
  const drain = () => {
    wakeups++;
    for (;;) {
      const e = m._mpv_wait_event(h, 0);
      const d = w.dv();
      const id = d.getInt32(e, true);
      if (id === EV.NONE) break;
      const err = d.getInt32(e + 4, true);
      const reply = Number(d.getBigUint64(e + 8, true));
      const data = d.getUint32(e + 16, true);
      if (id === EV.GET_REPLY) {
        const fmt = d.getInt32(data + 4, true), vp = d.getUint32(data + 8, true);
        let v = null;
        if (err >= 0) {
          if (fmt === FMT.STRING) v = w.str(w.u32(vp));
          else if (fmt === FMT.DOUBLE) v = d.getFloat64(vp, true);
          else if (fmt === FMT.FLAG) v = d.getInt32(vp, true) !== 0;
          else if (fmt === FMT.NODE) v = w.node(vp);
        }
        replies.set(reply, { err, v });
      } else if (id === EV.CMD_REPLY || id === EV.SET_REPLY) {
        replies.set(reply, { err });
      }
      onEvent(id, err, reply, data);
    }
    for (const x of [...waiters]) {
      if (x.pred()) {
        waiters.delete(x);
        x.resolve(true);
      }
    }
  };
  const until = (pred, ms) => new Promise((resolve) => {
    if (pred()) return resolve(true);
    const x = { pred, resolve: (v) => { clearTimeout(timer); resolve(v); } };
    const timer = setTimeout(() => { waiters.delete(x); resolve(false); }, ms);
    waiters.add(x);
  });
  m.onMpvWakeup = drain;
  const bridge = m._mak_web_wakeup_attach(h);

  let nextId = 1000;
  const reply = async (id, ms) => {
    await until(() => replies.has(id), ms);
    const r = replies.get(id);
    replies.delete(id);
    return r ?? { err: -999 };
  };
  const core = {
    h, initErr, w,
    get wakeups() { return wakeups; },
    until,
    // Wakes the pump with no event: lets a waiter see state set elsewhere.
    poke: () => drain(),
    get: (name, fmt = FMT.STRING, ms = 5000) => {
      const id = nextId++;
      w.withStrings([name], (n) => m._mpv_get_property_async(h, BigInt(id), n, fmt));
      return reply(id, ms);
    },
    set: (name, value, ms = 5000) => core.command(['set', name, String(value)], ms),
    command: (list, ms = 5000) => {
      const id = nextId++;
      const err = w.argv(list, (a) => m._mpv_command_async(h, BigInt(id), a));
      if (err < 0) return Promise.resolve({ err });
      return reply(id, ms);
    },
    observe: (id, name, fmt) => w.withStrings([name], (n) => m._mpv_observe_property(h, BigInt(id), n, fmt)),
    logs: (level) => w.withStrings([level], (l) => m._mpv_request_log_messages(h, l)),
    destroy: () => {
      m._mak_web_wakeup_detach(bridge);
      m._mpv_terminate_destroy(h);
    },
  };
  return core;
}
