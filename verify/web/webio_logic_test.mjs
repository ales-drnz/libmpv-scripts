// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The pure helpers of scripts/web/mak_webio.js in plain Node, without the
// module: header rules of the browser, the answer of a Range request, the
// ICY splitter at every chunk boundary, the messages of a refused fetch,
// the second try of a blob fetch left without an answer.
//
//   node verify/web/webio_logic_test.mjs
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '../../scripts/web/mak_webio.js'), 'utf8');
let lib = null;
new Function('addToLibrary', src)((o) => { lib = o; });
const W = lib.$MakWebio;
globalThis.MakWebio = W;

let pass = 0;
const test = (name, fn) => {
  try {
    fn();
    pass++;
    console.log(`ok ${name}`);
  } catch (e) {
    console.log(`FAIL ${name}\n${e.stack}`);
    process.exitCode = 1;
  }
};
const names = (r) => r.headers.map(([n]) => n);
const header = (r, n) => (r.headers.find(([k]) => k.toLowerCase() === n.toLowerCase()) || [])[1];

test('parseHeaders', () => {
  assert.deepEqual(W.parseHeaders('A: 1\r\nB:2\nbad line\n: x\nC d: 3\r\n'), [['A', '1'], ['B', '2']]);
  assert.deepEqual(W.parseHeaders(''), []);
});

test('Range on every request, bytes=off- or bytes=off-(end-1)', () => {
  assert.equal(header(W.buildHeaders('', true, { off: 0, end: -1 }), 'Range'), 'bytes=0-');
  assert.equal(header(W.buildHeaders('', true, { off: 500, end: 1000 }), 'Range'), 'bytes=500-999');
  // A Range of the app does not replace the one of the request.
  const r = W.buildHeaders('Range: bytes=7-', true, { off: 3, end: -1 });
  assert.deepEqual(r.headers, [['Range', 'bytes=3-']]);
});

test('Range alone needs no preflight on another origin', () => {
  const r = W.buildHeaders('', false, { off: 123, end: -1 });
  assert.equal(r.extra, false);
  assert.ok(W.safelisted('range', 'bytes=123-'));
  assert.ok(!W.safelisted('range', 'bytes=1-2,4-5'));
});

test('forbidden headers dropped and named, Referer becomes the referrer', () => {
  const r = W.buildHeaders('Cookie: a=b\r\nReferer: http://x/\r\nHost: h\r\nSec-Foo: 1\r\nProxy-X: 2\r\nX-Ok: 1', true, { off: 0, end: -1 });
  assert.deepEqual(r.dropped, ['Cookie', 'Host', 'Sec-Foo', 'Proxy-X']);
  assert.equal(r.referrer, 'http://x/');
  assert.deepEqual(names(r), ['X-Ok', 'Range']);
});

test('User-Agent: same origin always, another origin only when the app chose it', () => {
  assert.equal(header(W.buildHeaders('User-Agent: libmpv', true, { off: 0, end: -1 }), 'User-Agent'), 'libmpv');
  const def = W.buildHeaders('User-Agent: libmpv', false, { off: 0, end: -1 });
  assert.equal(header(def, 'User-Agent'), undefined);
  assert.equal(def.extra, false);
  const own = W.buildHeaders('User-Agent: MyApp/2', false, { off: 0, end: -1 });
  assert.equal(header(own, 'User-Agent'), 'MyApp/2');
  assert.equal(own.extra, true);
});

test('custom headers on another origin: extra, and left out with dropExtra', () => {
  const r = W.buildHeaders('X-Token: t\r\nAccept: audio/*', false, { off: 0, end: -1 });
  assert.equal(r.extra, true);
  const d = W.buildHeaders('X-Token: t\r\nAccept: audio/*', false, { off: 0, end: -1, dropExtra: true });
  assert.equal(d.extra, false);
  assert.deepEqual(names(d), ['Accept', 'Range']);
  // Same origin: no preflight, nothing is extra.
  assert.equal(W.buildHeaders('X-Token: t', true, { off: 0, end: -1 }).extra, false);
});

test('Icy-MetaData: same origin, another origin only with icyCors', () => {
  assert.equal(header(W.buildHeaders('', true, { off: 0, end: -1, icy: true }), 'Icy-MetaData'), '1');
  assert.equal(header(W.buildHeaders('', false, { off: 0, end: -1, icy: true }), 'Icy-MetaData'), undefined);
  const c = W.buildHeaders('', false, { off: 0, end: -1, icy: true, icyCors: true });
  assert.equal(header(c, 'Icy-MetaData'), '1');
  assert.equal(c.extra, true);
  assert.equal(header(W.buildHeaders('', false, { off: 0, end: -1, icy: true, icyCors: true, dropExtra: true }), 'Icy-MetaData'), undefined);
  assert.equal(header(W.buildHeaders('', true, { off: 0, end: -1, icy: false }), 'Icy-MetaData'), undefined);
});

test('contentRange', () => {
  assert.deepEqual(W.contentRange('bytes 0-99/1000'), { start: 0, end: 99, total: 1000 });
  assert.deepEqual(W.contentRange('bytes 5-9/*'), { start: 5, end: 9, total: -1 });
  assert.equal(W.contentRange(null), null);
  assert.equal(W.contentRange('bytes */1000'), null);
});

test('classify: 206 with and without Content-Range, 200, errors', () => {
  assert.deepEqual(W.classify(206, 0, -1, 'bytes 0-9/10', '10'), { kind: 'ok', size: 10, seekable: true });
  // Content-Range not exposed (another origin): Content-Length of bytes=0-.
  assert.deepEqual(W.classify(206, 0, -1, null, '3975923'), { kind: 'ok', size: 3975923, seekable: true });
  assert.deepEqual(W.classify(206, 100, -1, null, '900'), { kind: 'ok', size: 1000, seekable: true });
  // A byte range of HLS: the length is the segment's, not the file's.
  assert.deepEqual(W.classify(206, 100, 200, null, '100'), { kind: 'ok', size: -1, seekable: true });
  assert.equal(W.classify(206, 100, -1, 'bytes 0-999/1000', '1000').kind, 'badrange');
  assert.deepEqual(W.classify(200, 0, -1, null, '1000'), { kind: 'ok', size: 1000, seekable: false });
  assert.deepEqual(W.classify(200, 0, -1, null, null), { kind: 'ok', size: -1, seekable: false });
  assert.equal(W.classify(200, 50, -1, null, '1000').kind, 'noseek');
  assert.equal(W.classify(416, 50, -1, 'bytes */10', null).kind, 'eof');
  assert.equal(W.classify(404, 0, -1, null, null).kind, 'http');
  assert.equal(W.classify(204, 0, -1, null, null).kind, 'http');
});

// An ICY stream of metaint 4 with metadata blocks, split at every boundary.
test('icyParser at every chunk split', () => {
  const meta = (s) => {
    const b = new TextEncoder().encode(s);
    const n = Math.ceil(b.length / 16);
    const out = new Uint8Array(1 + n * 16);
    out[0] = n;
    out.set(b, 1);
    return out;
  };
  const audio = (from) => Uint8Array.from([from, from + 1, from + 2, from + 3]);
  const parts = [audio(0), meta("StreamTitle='A';"), audio(10), Uint8Array.of(0), audio(20), meta("StreamTitle='Bé';"), audio(30)];
  const stream = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    stream.set(p, o);
    o += p.length;
  }
  const want = { audio: [0, 1, 2, 3, 10, 11, 12, 13, 20, 21, 22, 23, 30, 31, 32, 33], meta: ["StreamTitle='A';", "StreamTitle='Bé';"], metaAt: [4, 12] };
  for (let a = 0; a <= stream.length; a++) {
    for (let b = a; b <= stream.length; b++) {
      const p = W.icyParser(4);
      const got = { audio: [], meta: [], metaAt: [] };
      for (const c of [stream.subarray(0, a), stream.subarray(a, b), stream.subarray(b)]) {
        for (const x of p.push(c)) {
          if (x.meta) {
            got.meta.push(new TextDecoder().decode(x.meta));
            got.metaAt.push(got.audio.length);
          } else {
            got.audio.push(...x);
          }
        }
      }
      assert.deepEqual(got, want, `split at ${a}, ${b}`);
    }
  }
});

test('sameOrigin: Node has no origin, a page compares origins', () => {
  assert.equal(W.sameOrigin('http://a/x'), true);
  globalThis.location = new URL('http://127.0.0.1:8130/net.html');
  try {
    assert.equal(W.sameOrigin('http://127.0.0.1:8130/media/x'), true);
    assert.equal(W.sameOrigin('http://127.0.0.1:8131/media/x'), false);
    assert.equal(W.sameOrigin('not a url'), false);
  } finally {
    delete globalThis.location;
  }
});

test('fetchError names CORS, network and mixed content', () => {
  globalThis.location = new URL('https://app.example/');
  try {
    assert.match(W.fetchError('http://radio/x', new TypeError('Failed to fetch'), false), /mixed content/);
    assert.match(W.fetchError('https://radio/x', new TypeError('Failed to fetch'), false), /CORS.*Failed to fetch/);
    assert.match(W.fetchError('https://app.example/x', new TypeError('NetworkError'), true), /network error\): NetworkError/);
  } finally {
    delete globalThis.location;
  }
});

// fetchBlob against a fetch that answers from the given try on (0: never),
// and rejects when its request is aborted, as the browser's does.
const blobFetch = async (answerFrom, { stale = false } = {}) => {
  const calls = [];
  const saved = [globalThis.fetch, W.BLOB_ANSWER_MS, W.streams];
  globalThis.fetch = (url, init) => {
    calls.push(init.signal);
    if (answerFrom && calls.length >= answerFrom) return Promise.resolve({ status: 206, try: calls.length });
    return new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new Error('aborted'))));
  };
  W.BLOB_ANSWER_MS = 20;
  W.streams = new Map();
  const e = { s: 1, gen: 5 };
  W.streams.set(1, e);
  if (stale) setTimeout(() => { e.gen = 6; }, 5);
  try {
    const p = W.fetchBlob(e, 5, 'blob:x', { headers: [] });
    const r = await Promise.race([p, new Promise((res) => setTimeout(res, 500, 'pending'))]);
    return { r, calls, aborted: calls.map((c) => c.aborted), ctrlIsLast: e.ctrl && e.ctrl.signal === calls.at(-1) };
  } finally {
    [globalThis.fetch, W.BLOB_ANSWER_MS, W.streams] = saved;
  }
};
const testAsync = async (name, fn) => {
  try {
    await fn();
    pass++;
    console.log(`ok ${name}`);
  } catch (e) {
    console.log(`FAIL ${name}\n${e.stack}`);
    process.exitCode = 1;
  }
};

await testAsync('fetchBlob: an answer at once is taken, one request', async () => {
  const x = await blobFetch(1);
  assert.equal(x.r.try, 1);
  assert.deepEqual(x.aborted, [false]);
});

await testAsync('fetchBlob: a blob fetch without an answer is asked again', async () => {
  const x = await blobFetch(2);
  assert.equal(x.r.try, 2);
  assert.deepEqual(x.aborted, [true, false]);
  assert.ok(x.ctrlIsLast, 'stop() aborts the request in flight');
});

await testAsync('fetchBlob: the last try waits as long as webio.c lets it', async () => {
  const x = await blobFetch(0);
  assert.equal(x.r, 'pending');
  assert.equal(x.calls.length, W.BLOB_TRIES);
  assert.deepEqual(x.aborted, [...Array(W.BLOB_TRIES - 1).fill(true), false]);
});

await testAsync('fetchBlob: a stale request is not asked again', async () => {
  const x = await blobFetch(0, { stale: true });
  assert.equal(x.calls.length, 1);
});

console.log(`RESULT pass=${pass} fail=${process.exitCode ? 'some' : 0}`);
