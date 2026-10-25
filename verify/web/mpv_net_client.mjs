// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// A small promise client over the web module (libmpv.mjs), driven from the
// calling thread the way the Dart backend will: asynchronous commands and
// properties, events from the wakeup bridge of scripts/web/mak_web.c.
// Used by net_harness.mjs (mpv_client.mjs is the synchronous client of the
// audio and lib harnesses); one module hosts several cores.
//
//   const mod = await openModule(factory, log);
//   const core = mod.core({ ao: 'null', ... });
//   await core.command(['loadfile', url]);
//   const ev = await core.waitEvent((e) => e.id === EV.END_FILE, 5000);
//   core.destroy();

export const FMT = { NONE: 0, STRING: 1, FLAG: 3, INT64: 4, DOUBLE: 5, NODE: 6, ARRAY: 7, MAP: 8, BYTES: 9 };
export const EV = {
  NONE: 0, SHUTDOWN: 1, LOG: 2, GET_REPLY: 3, SET_REPLY: 4, CMD_REPLY: 5,
  START_FILE: 6, END_FILE: 7, FILE_LOADED: 8, IDLE: 11, SEEK: 20, PLAYBACK_RESTART: 21,
  PROPERTY_CHANGE: 22, HOOK: 25,
};
export const END = { EOF: 0, STOP: 2, QUIT: 3, ERROR: 4, REDIRECT: 5 };

export async function openModule(factory, log) {
  const m = await factory({ print: log, printErr: log });
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
      default: return null;
    }
  };
  const value = (fmt, p) => {
    if (!p) return null;
    const d = dv();
    switch (fmt) {
      case FMT.STRING: return str(u32(p));
      case FMT.FLAG: return d.getInt32(p, true) !== 0;
      case FMT.INT64: return Number(d.getBigInt64(p, true));
      case FMT.DOUBLE: return d.getFloat64(p, true);
      case FMT.NODE: return node(p);
      default: return null;
    }
  };

  const cores = new Map();
  m.onMpvWakeup = (h) => {
    const c = cores.get(h);
    if (c) c.drain();
  };

  let nextId = 1000;
  function core(options) {
    const h = m._mpv_create();
    for (const [k, v] of Object.entries(options)) {
      withStrings([k, String(v)], (a, b) => m._mpv_set_option_string(h, a, b));
    }
    const initErr = m._mpv_initialize(h);
    const listeners = new Set();
    const c = {
      h, initErr, logs: [],
      drain() {
        for (;;) {
          const e = m._mpv_wait_event(h, 0);
          const d = dv();
          const id = d.getInt32(e, true);
          if (id === EV.NONE) break;
          const ev = { id, error: d.getInt32(e + 4, true), reply: Number(d.getBigUint64(e + 8, true)), t: performance.now() };
          const data = d.getUint32(e + 16, true);
          switch (id) {
            case EV.GET_REPLY:
            case EV.PROPERTY_CHANGE:
              ev.name = str(u32(data));
              ev.format = d.getInt32(data + 4, true);
              ev.value = ev.error >= 0 ? value(ev.format, d.getUint32(data + 8, true)) : null;
              break;
            case EV.END_FILE:
              ev.reason = d.getInt32(data, true);
              ev.fileError = d.getInt32(data + 4, true);
              break;
            case EV.LOG:
              ev.prefix = str(u32(data));
              ev.level = str(u32(data + 4));
              ev.text = (str(u32(data + 8)) || '').trimEnd();
              c.logs.push(`[${ev.prefix}] ${ev.level}: ${ev.text}`);
              break;
            default: break;
          }
          for (const l of [...listeners]) l(ev);
        }
      },
      on(fn) {
        listeners.add(fn);
        return () => listeners.delete(fn);
      },
      // Resolves with the first event pred accepts, or null after ms.
      waitEvent(pred, ms) {
        return new Promise((resolve) => {
          const off = c.on((ev) => {
            if (!pred(ev)) return;
            off();
            clearTimeout(timer);
            resolve(ev);
          });
          const timer = setTimeout(() => { off(); resolve(null); }, ms);
        });
      },
      async command(list, ms = 10000) {
        const id = nextId++;
        const ptrs = list.map((s) => m.stringToNewUTF8(String(s)));
        const arr = m._malloc(4 * (ptrs.length + 1));
        ptrs.forEach((p, i) => dv().setUint32(arr + 4 * i, p, true));
        dv().setUint32(arr + 4 * ptrs.length, 0, true);
        const wait = c.waitEvent((ev) => ev.id === EV.CMD_REPLY && ev.reply === id, ms);
        const err = m._mpv_command_async(h, BigInt(id), arr);
        ptrs.forEach((p) => m._free(p));
        m._free(arr);
        if (err < 0) return { error: err };
        return (await wait) || { error: -999 };
      },
      async get(name, fmt, ms = 10000) {
        const id = nextId++;
        const wait = c.waitEvent((ev) => ev.id === EV.GET_REPLY && ev.reply === id, ms);
        withStrings([name], (n) => m._mpv_get_property_async(h, BigInt(id), n, fmt));
        return (await wait) || { error: -999, value: null };
      },
      observe(name, fmt) {
        withStrings([name], (n) => m._mpv_observe_property(h, BigInt(nextId++), n, fmt));
      },
      requestLog(level) {
        withStrings([level], (l) => m._mpv_request_log_messages(h, l));
      },
      destroy() {
        m._mak_web_wakeup_detach(c.bridge);
        cores.delete(h);
        m._mpv_terminate_destroy(h);
      },
    };
    cores.set(h, c);
    c.bridge = m._mak_web_wakeup_attach(h);
    return c;
  }

  return {
    m, core,
    memory: () => m.wasmMemory.buffer.byteLength,
    // webio streams not freed yet (-1 on a module without webio).
    liveStreams: () => (m._mak_webio_live_streams ? m._mak_webio_live_streams() : -1),
    writeFile(path, bytes) {
      const dir = path.slice(0, path.lastIndexOf('/'));
      try {
        m.FS.mkdir(dir);
      } catch (e) {}
      m.FS.writeFile(path, bytes);
    },
  };
}
