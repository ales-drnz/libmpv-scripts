// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// mak_webio.js: the JS side of the webio protocols of FFmpeg
// (patches/ffmpeg/webio/webio.c), an Emscripten JS library linked with
// --js-library by build_libmpv_web.sh.
//
// Everything here runs on the net thread, a pthread that never blocks and
// lives in its event loop. webio.c sends it tasks (start, space, close);
// fetch answers and body chunks come back as promises on the same loop, and
// go to the C side through mak_webio_response, _reserve, _commit, _icy and
// _end, each with the generation of the request they serve.
//
// The browser rules, applied here:
// - Range: bytes=N- is a safelisted header, so a plain request never needs a
//   CORS preflight. A 206 answer says the file is seekable; Content-Range
//   gives the size when the server exposes it, else Content-Length of the
//   answer to bytes=0- is the size. A 200 answer is a stream: no seek.
// - fetch follows redirects; later requests go to the final URL.
// - Headers fetch forbids (Cookie, Referer, Host...) are dropped and named in
//   a warning. User-Agent goes to the page's own origin, and to another one
//   only when the app set its own (mpv's default "libmpv" would cost a
//   preflight everywhere). Other headers on another origin need a preflight:
//   when the request fails with them, it is tried once without them.
// - ICY: Icy-MetaData goes to the page's origin, and to another one only with
//   icy_cross_origin. There the answer must expose icy-metaint: without it
//   the metadata blocks could not be told from the audio, so the request is
//   made again without ICY.
// - fetch tells a CORS refusal from a network error in no way: the message
//   names both, and mixed content when the page is https and the URL http.
//
// Nothing here uses the Emscripten preprocessor, so verify/web/
// webio_logic_test.mjs can load the pure helpers in plain Node.

addToLibrary({
  $MakWebio__deps: ['$UTF8ToString', '$stringToNewUTF8', 'malloc', 'free',
    'mak_webio_reserve', 'mak_webio_commit', 'mak_webio_response',
    'mak_webio_icy', 'mak_webio_end'],
  $MakWebio: {
    streams: null, // stream pointer -> entry
    scratch: 0,
    refused: null, // origins that refused the extra headers

    // ── pure helpers (webio_logic_test.mjs) ────────────────────────────

    // Request headers whose names fetch forbids (Fetch standard), plus the
    // Proxy- and Sec- prefixes.
    FORBIDDEN: ['accept-charset', 'accept-encoding', 'access-control-request-headers',
      'access-control-request-method', 'connection', 'content-length', 'cookie',
      'cookie2', 'date', 'dnt', 'expect', 'host', 'keep-alive', 'origin', 'referer',
      'set-cookie', 'te', 'trailer', 'transfer-encoding', 'upgrade', 'via'],

    // "Name: value" lines to [name, value] pairs.
    parseHeaders(text) {
      const out = [];
      for (const line of (text || '').split(/\r?\n/)) {
        const i = line.indexOf(':');
        if (i <= 0) continue;
        const name = line.slice(0, i).trim();
        if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(name)) continue;
        out.push([name, line.slice(i + 1).trim()]);
      }
      return out;
    },

    forbidden(name) {
      const n = name.toLowerCase();
      return MakWebio.FORBIDDEN.includes(n) || n.startsWith('proxy-') || n.startsWith('sec-');
    },

    // CORS-safelisted request headers we may send without a preflight.
    safelisted(name, value) {
      const n = name.toLowerCase();
      if (n === 'range') return /^bytes=\d+-\d*$/.test(value);
      if (n === 'accept' || n === 'accept-language' || n === 'content-language') {
        return value.length <= 128 && !/["():<>?@[\\\]{}\x7f]/.test(value);
      }
      return false;
    },

    // The headers of one request. same: the URL is on the page's origin.
    // dropExtra: send only what needs no preflight. Returns {headers,
    // extra (a header that needs a preflight), dropped (names fetch
    // forbids), referrer}.
    buildHeaders(text, same, opts) {
      const headers = [];
      const dropped = [];
      let extra = false;
      let referrer = null;
      for (const [name, value] of MakWebio.parseHeaders(text)) {
        const n = name.toLowerCase();
        if (n === 'referer') {
          referrer = value;
          continue;
        }
        if (n === 'range') continue;
        if (n === 'user-agent') {
          // Same origin: no preflight. Elsewhere only a UA the app chose.
          if (!same && /^libmpv\b/.test(value)) continue;
        } else if (MakWebio.forbidden(n)) {
          dropped.push(name);
          continue;
        }
        if (!same && !MakWebio.safelisted(n, value)) {
          if (opts.dropExtra) continue;
          extra = true;
        }
        headers.push([name, value]);
      }
      const end = opts.end >= 0 ? String(opts.end - 1) : '';
      headers.push(['Range', `bytes=${opts.off}-${end}`]);
      if (opts.icy && (same || (opts.icyCors && !opts.dropExtra))) {
        headers.push(['Icy-MetaData', '1']);
        if (!same) extra = true;
      }
      return { headers, extra, dropped, referrer };
    },

    // Content-Range: bytes a-b/total, or null. total is -1 for "*".
    contentRange(value) {
      const m = /^bytes\s+(\d+)-(\d+)\/(\d+|\*)$/i.exec((value || '').trim());
      if (!m) return null;
      return { start: Number(m[1]), end: Number(m[2]), total: m[3] === '*' ? -1 : Number(m[3]) };
    },

    int(value) {
      return value != null && /^\s*\d+\s*$/.test(value) ? Number(value) : -1;
    },

    // What an answer means for the request [off, end): {kind, size,
    // seekable}. kind 'ok', 'eof' (416 past the end), 'noseek' (the server
    // ignored Range on a later request), 'badrange' or 'http'.
    classify(status, off, end, contentRange, contentLength) {
      if (status === 416 && off > 0) return { kind: 'eof', size: -1, seekable: false };
      if (status >= 400 || status < 200 || status === 204) return { kind: 'http', size: -1, seekable: false };
      const len = MakWebio.int(contentLength);
      if (status === 206) {
        const cr = MakWebio.contentRange(contentRange);
        if (cr) {
          if (cr.start !== off) return { kind: 'badrange', size: -1, seekable: false };
          return { kind: 'ok', size: cr.total, seekable: true };
        }
        // Content-Range not exposed: the length of bytes=off- runs to the end.
        return { kind: 'ok', size: end < 0 && len >= 0 ? off + len : -1, seekable: true };
      }
      if (off > 0) return { kind: 'noseek', size: -1, seekable: false };
      return { kind: 'ok', size: len, seekable: false };
    },

    // Splits an ICY stream: every metaint bytes of audio, a length byte L and
    // L * 16 bytes of metadata (NUL padded). push() returns the audio as
    // Uint8Array views and the metadata as {meta: Uint8Array}, in order.
    icyParser(metaint) {
      let state = 0; // 0 audio, 1 length byte, 2 metadata
      let left = metaint;
      let buf = null;
      let got = 0;
      return {
        push(c) {
          const out = [];
          let i = 0;
          while (i < c.length) {
            if (state === 0) {
              const k = Math.min(left, c.length - i);
              out.push(c.subarray(i, i + k));
              i += k;
              left -= k;
              if (!left) state = 1;
            } else if (state === 1) {
              const len = c[i++] * 16;
              if (len) {
                buf = new Uint8Array(len);
                got = 0;
                state = 2;
              } else {
                left = metaint;
                state = 0;
              }
            } else {
              const k = Math.min(buf.length - got, c.length - i);
              buf.set(c.subarray(i, i + k), got);
              got += k;
              i += k;
              if (got === buf.length) {
                let n = buf.indexOf(0);
                if (n < 0) n = buf.length;
                out.push({ meta: buf.subarray(0, n) });
                left = metaint;
                state = 0;
              }
            }
          }
          return out;
        },
      };
    },

    sameOrigin(url) {
      const here = globalThis.location;
      if (!here) return true; // Node: no origin, no CORS
      try {
        return new URL(url).origin === here.origin;
      } catch (e) {
        return false;
      }
    },

    fetchError(url, err, same) {
      const here = globalThis.location;
      let why;
      if (here && here.protocol === 'https:' && /^http:/i.test(url)) {
        why = 'mixed content: an https page cannot fetch an http URL';
      } else if (same) {
        why = 'network error';
      } else {
        why = 'network error, or the server does not allow this origin (CORS: Access-Control-Allow-Origin)';
      }
      return `webio: ${url}: the browser refused the request (${why}): ${err && err.message || err}`;
    },

    // ── net thread ──────────────────────────────────────────────────────

    init() {
      MakWebio.streams = new Map();
      MakWebio.scratch = _malloc(8);
      MakWebio.refused = new Set();
    },

    cstr(s) {
      return s ? stringToNewUTF8(s) : 0;
    },

    bytes(u8) {
      const p = _malloc(u8.length + 1);
      HEAPU8.set(u8, p);
      HEAPU8[p + u8.length] = 0;
      return p;
    },

    start(s, gen, url, headerText, off, end, flags) {
      let e = MakWebio.streams.get(s);
      if (!e) {
        e = { s, url, finalUrl: null, gen, ctrl: null, waiter: null,
          dropExtra: false, icyOff: false, notes: [] };
        MakWebio.streams.set(s, e);
      }
      MakWebio.stop(e);
      e.gen = gen;
      MakWebio.run(e, gen, headerText, off, end, flags);
    },

    // Aborts the request in flight and wakes a body loop waiting for room,
    // which then sees its request stale and ends.
    stop(e) {
      if (e.ctrl) {
        e.ctrl.abort();
        e.ctrl = null;
      }
      if (e.waiter) {
        const w = e.waiter;
        e.waiter = null;
        w();
      }
    },

    space(s) {
      const e = MakWebio.streams.get(s);
      if (e && e.waiter) {
        const w = e.waiter;
        e.waiter = null;
        w();
      }
    },

    close(s) {
      const e = MakWebio.streams.get(s);
      if (!e) return;
      MakWebio.streams.delete(s);
      MakWebio.stop(e);
    },

    live(e, gen) {
      return MakWebio.streams.get(e.s) === e && e.gen === gen;
    },

    fail(e, gen, kind, status, msg) {
      _mak_webio_end(e.s, gen, kind, status, MakWebio.cstr(msg));
    },

    async run(e, gen, headerText, off, end, flags) {
      const blob = (flags & 4) !== 0;
      const url = e.finalUrl || e.url;
      const same = blob || MakWebio.sameOrigin(url);
      let origin = null;
      try {
        origin = new URL(url).origin;
      } catch (err) {}
      if (!same && MakWebio.refused.has(origin)) e.dropExtra = true;
      for (let attempt = 0; attempt < 3; attempt++) {
        const req = MakWebio.buildHeaders(headerText, same, {
          off, end, icy: (flags & 1) !== 0 && !e.icyOff, icyCors: (flags & 2) !== 0,
          dropExtra: e.dropExtra,
        });
        if (req.dropped.length && !e.droppedNoted) {
          e.droppedNoted = true;
          e.notes.push(`webio: the browser does not send ${req.dropped.join(', ')}`);
        }
        const ctrl = new AbortController();
        e.ctrl = ctrl;
        const init = { headers: req.headers, signal: ctrl.signal, redirect: 'follow',
          credentials: 'same-origin' };
        if (req.referrer && same) init.referrer = req.referrer;
        const t0 = performance.now();
        let resp;
        try {
          resp = await fetch(url, init);
        } catch (err) {
          if (!MakWebio.live(e, gen)) return;
          if (req.extra && !e.dropExtra) {
            // Most likely the preflight: try once with the plain request.
            e.dropExtra = true;
            if (origin) MakWebio.refused.add(origin);
            e.notes.push(`webio: ${url}: the request failed with headers that need a CORS preflight, sent again without them`);
            continue;
          }
          MakWebio.fail(e, gen, 1, 0, MakWebio.fetchError(url, err, same));
          return;
        }
        if (!MakWebio.live(e, gen)) {
          MakWebio.discard(resp);
          return;
        }
        const ms = performance.now() - t0;
        const h = resp.headers;
        const icyAsked = req.headers.some(([n]) => n === 'Icy-MetaData');
        const metaint = MakWebio.int(h.get('icy-metaint'));
        if (icyAsked && metaint <= 0 && resp.type === 'cors') {
          // The server may send metadata blocks we could not find.
          MakWebio.discard(resp);
          e.icyOff = true;
          e.notes.push(`webio: ${url}: the server does not expose icy-metaint (Access-Control-Expose-Headers), read without ICY metadata`);
          continue;
        }
        if (blob && resp.status === 200) {
          // A browser without Range on blob: URLs: slice the blob.
          MakWebio.discard(resp);
          return MakWebio.runBlob(e, gen, url, off, end, ms);
        }
        const c = MakWebio.classify(resp.status, off, end, h.get('content-range'), h.get('content-length'));
        if (c.kind !== 'ok') {
          MakWebio.discard(resp);
          if (c.kind === 'eof') return _mak_webio_end(e.s, gen, 5, resp.status, 0);
          if (c.kind === 'http') {
            return MakWebio.fail(e, gen, 2, resp.status,
              `webio: ${url}: HTTP ${resp.status}${resp.statusText ? ' ' + resp.statusText : ''}`);
          }
          if (c.kind === 'noseek') {
            return MakWebio.fail(e, gen, 6, resp.status, `webio: ${url}: the server ignored Range, no seek`);
          }
          return MakWebio.fail(e, gen, 4, resp.status,
            `webio: ${url}: the answer does not start at byte ${off} (Content-Range ${h.get('content-range')})`);
        }
        e.finalUrl = resp.url || url;
        let icyHeaders = '';
        h.forEach((v, k) => {
          if (k.startsWith('icy-') && k !== 'icy-metaint') icyHeaders += `${k}: ${v}\n`;
        });
        const note = e.notes.length ? e.notes.join('; ') : null;
        e.notes = [];
        _mak_webio_response(e.s, gen, resp.status, c.size, c.seekable ? 1 : 0,
          MakWebio.cstr(h.get('content-type')), MakWebio.cstr(resp.redirected ? resp.url : null),
          MakWebio.cstr(icyHeaders), MakWebio.cstr(note), ms);
        if (!resp.body) return _mak_webio_end(e.s, gen, 0, 0, 0);
        return MakWebio.pump(e, gen, resp.body.getReader(), metaint > 0 && icyAsked ? MakWebio.icyParser(metaint) : null);
      }
      MakWebio.fail(e, gen, 1, 0, `webio: ${url}: no request worked`);
    },

    async runBlob(e, gen, url, off, end, ms) {
      try {
        if (!e.blob) e.blob = await (await fetch(url)).blob();
        if (!MakWebio.live(e, gen)) return;
        const size = e.blob.size;
        if (off >= size) return _mak_webio_end(e.s, gen, 5, 416, 0);
        _mak_webio_response(e.s, gen, 206, size, 1, MakWebio.cstr(e.blob.type), 0, 0, 0, ms);
        const part = e.blob.slice(off, end >= 0 ? end : size);
        return MakWebio.pump(e, gen, part.stream().getReader(), null);
      } catch (err) {
        if (MakWebio.live(e, gen)) MakWebio.fail(e, gen, 1, 0, `webio: ${url}: the blob cannot be read: ${err && err.message || err}`);
      }
    },

    discard(resp) {
      if (resp.body) resp.body.cancel().catch(() => {});
    },

    // Copies the body into the ring, waiting for room when it is full.
    async pump(e, gen, reader, icy) {
      let rel = 0; // data bytes of this request so far
      const end = () => reader.cancel().catch(() => {});
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (!MakWebio.live(e, gen)) return end();
          if (done) return _mak_webio_end(e.s, gen, 0, 0, 0);
          const parts = icy ? icy.push(value) : [value];
          for (const part of parts) {
            if (part.meta) {
              _mak_webio_icy(e.s, gen, rel, MakWebio.bytes(part.meta));
              continue;
            }
            let o = 0;
            while (o < part.length) {
              const n = _mak_webio_reserve(e.s, gen, MakWebio.scratch);
              if (n < 0) return end();
              if (n === 0) {
                await new Promise((resolve) => { e.waiter = resolve; });
                if (!MakWebio.live(e, gen)) return end();
                continue;
              }
              const k = Math.min(n, part.length - o);
              HEAPU8.set(part.subarray(o, o + k), HEAPU32[MakWebio.scratch >> 2]);
              _mak_webio_commit(e.s, gen, k);
              o += k;
              rel += k;
            }
          }
        }
      } catch (err) {
        if (MakWebio.live(e, gen)) {
          MakWebio.fail(e, gen, 3, 0, `webio: ${e.finalUrl || e.url}: the connection broke: ${err && err.message || err}`);
        }
      }
    },
  },

  mak_webio_js_init__deps: ['$MakWebio'],
  mak_webio_js_init: () => MakWebio.init(),
  mak_webio_js_start__deps: ['$MakWebio', '$UTF8ToString'],
  mak_webio_js_start: (s, gen, url, headers, off, end, flags) =>
    MakWebio.start(s, gen, UTF8ToString(url), UTF8ToString(headers), off, end, flags),
  mak_webio_js_space__deps: ['$MakWebio'],
  mak_webio_js_space: (s) => MakWebio.space(s),
  mak_webio_js_close__deps: ['$MakWebio'],
  mak_webio_js_close: (s) => MakWebio.close(s),
});
