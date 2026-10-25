// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The webio harness: mpv in the web module opens the media of net_server.py
// over http, https stand-in, redirects, live streams and blob: URLs, from
// the calling thread, as the Dart backend will. Shared by run_net_node.mjs
// (Node, where fetch has no CORS) and net.html (Firefox and Chrome).
//
//   const r = await runNetHarness(factory, env, log);
// env: { base, cross (the other origin), browser (CORS applies),
//        fixture(name) -> Uint8Array, blobUrl(name) -> blob: URL (browser),
//        cases (names, or null for all), repeat (timing cases, default 3),
//        verbose (every log line of mpv) }

import { openModule, FMT, EV, END } from './mpv_net_client.mjs';

const CORE = {
  ao: 'null', 'ao-null-untimed': 'yes', vid: 'no', idle: 'yes', config: 'no',
  'audio-display': 'no', 'network-timeout': '20',
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const now = () => performance.now();
const DECODE_ERRORS = /Header missing|Error while decoding|Failed to decode|overread|Invalid data found|invalid frame/i;

export async function runNetHarness(factory, env, log) {
  const res = { checks: [], measures: {} };
  const check = (ok, name, detail = '') => {
    res.checks.push({ ok: !!ok, name, detail });
    log(`${ok ? 'ok' : 'FAIL'} ${name} ${detail}`);
    return ok;
  };
  const measure = (k, v) => {
    res.measures[k] = v;
    log(`measure ${k} ${typeof v === 'number' ? v.toFixed(3) : v}`);
  };
  const repeat = env.repeat || 3;
  const want = (name) => !env.cases || env.cases.includes(name);
  const serverLog = async (clear) => (await fetch(`${env.base}/log${clear ? '?clear=1' : ''}`)).json();
  const tagged = async (tag) => (await serverLog(false)).filter((e) => e.tag === tag);
  const rangeStart = (e) => (e.range ? Number(/bytes=(\d+)/.exec(e.range)?.[1] ?? -1) : -1);

  // Main thread responsiveness: the longest gap of a 10 ms timer.
  let lastTick = now(), maxGap = 0;
  const ticker = setInterval(() => {
    const t = now();
    maxGap = Math.max(maxGap, t - lastTick);
    lastTick = t;
  }, 10);

  let t = now();
  const mod = await openModule(factory, log);
  measure('instantiate_ms', now() - t);
  const memory0 = mod.memory();

  const newCore = (extra = {}) => {
    const c = mod.core({ ...CORE, ...extra });
    c.requestLog('v');
    return c;
  };
  const waitLive = async (ms = 2000) => {
    const until = now() + ms;
    while (mod.liveStreams() > 0 && now() < until) await sleep(20);
    return mod.liveStreams();
  };
  const waitAborted = async (tag, ms = 2000) => {
    const until = now() + ms;
    for (;;) {
      const es = await tagged(tag);
      if (es.some((e) => e.aborted)) return true;
      if (now() > until) return false;
      await sleep(50);
    }
  };

  // loadfile, then FILE_LOADED or END_FILE. The END_FILE wait starts before
  // the load, so a fast end is not missed.
  const load = async (core, url, ms = 20000) => {
    const t0 = now();
    const ended = core.waitEvent((e) => e.id === EV.END_FILE, 180000);
    const loaded = core.waitEvent((e) => e.id === EV.FILE_LOADED || e.id === EV.END_FILE, ms);
    const r = await core.command(['loadfile', url]);
    const ev = await loaded;
    return { ok: r.error >= 0 && ev && ev.id === EV.FILE_LOADED, ev, ms: now() - t0, ended, t0 };
  };
  const seekTo = async (core, secs) => {
    const restart = core.waitEvent((e) => e.id === EV.PLAYBACK_RESTART, 20000);
    const r = await core.command(['seek', String(secs), 'absolute']);
    const ev = await restart;
    const pos = await core.get('time-pos', FMT.DOUBLE);
    return { ok: r.error >= 0 && !!ev, pos: pos.value };
  };
  const logs = (core, re) => core.logs.filter((l) => re.test(l));
  // The seek cases load paused (ao-null-untimed would reach the end before
  // the seek), seek, then play to the end.
  const PAUSED = { cache: 'no', pause: 'yes' };
  const resume = (core) => core.command(['set', 'pause', 'no']);

  // One case: a fresh core, a time limit, the leftovers checked.
  const run = async (name, fn, { extra = {}, limit = 120000, group = null } = {}) => {
    if (!want(group || name.replace(/#\d+$/, ''))) return;
    const core = newCore(extra);
    const gap0 = maxGap;
    maxGap = 0;
    const t0 = now();
    try {
      const done = await Promise.race([fn(core).then(() => true), sleep(limit).then(() => false)]);
      check(done, `${name}.finished`, done ? '' : `still running after ${limit} ms`);
    } catch (e) {
      check(false, `${name}.exception`, String(e && e.stack || e));
    }
    if (core.destroy) {
      try {
        core.destroy();
      } catch (e) {
        check(false, `${name}.destroy`, String(e));
      }
    }
    const left = await waitLive();
    check(left <= 0, `${name}.streams_freed`, `live webio streams ${left}`);
    measure(`${name}.main_thread_max_gap_ms`, maxGap);
    measure(`${name}.case_ms`, now() - t0);
    maxGap = Math.max(maxGap, gap0);
    const shown = env.verbose ? core.logs : core.logs.filter((x) => /webio|ffmpeg|error/i.test(x)).slice(0, 12);
    for (const l of shown) log(`  log ${l}`);
  };

  await serverLog(true);

  // ── seekable file over Range ──────────────────────────────────────────
  await run('range_flac', async (core) => {
    const l = await load(core, `${env.base}/media/range/long_60s.flac?tag=rflac`);
    check(l.ok, 'range_flac.loaded', `${l.ms.toFixed(1)} ms`);
    const dur = await core.get('duration', FMT.DOUBLE);
    check(Math.abs((dur.value ?? 0) - 60) < 0.5, 'range_flac.duration', String(dur.value));
    const sk = await core.get('seekable', FMT.FLAG);
    check(sk.value === true, 'range_flac.seekable', String(sk.value));
    const e = await l.ended;
    check(e && e.reason === END.EOF, 'range_flac.eof', JSON.stringify(e && { reason: e.reason, err: e.fileError }));
    measure('range_flac.load_to_eof_ms', now() - l.t0);
  });

  await run('range_seek', async (core) => {
    const l = await load(core, `${env.base}/media/range/long_60s.flac?tag=rseek`);
    check(l.ok, 'range_seek.loaded');
    const fwd = await seekTo(core, 50);
    check(fwd.ok && Math.abs(fwd.pos - 50) < 1.5, 'range_seek.forward', `time-pos ${fwd.pos}`);
    const back = await seekTo(core, 5);
    check(back.ok && Math.abs(back.pos - 5) < 1.5, 'range_seek.backward', `time-pos ${back.pos}`);
    await resume(core);
    const e = await l.ended;
    check(e && e.reason === END.EOF, 'range_seek.eof', String(e && e.reason));
    const starts = (await tagged('rseek')).map(rangeStart);
    check(starts.some((s) => s > 1500000 && s < 3900000), 'range_seek.range_request', `Range starts ${starts.join(',')}`);
  }, { extra: PAUSED });

  // ── a connection that breaks off: read again from where it broke ─────
  await run('reconnect', async (core) => {
    const l = await load(core, `${env.base}/media/drop/long_60s.flac?after=600000&tag=drop`);
    check(l.ok, 'reconnect.loaded');
    const e = await l.ended;
    check(e && e.reason === END.EOF, 'reconnect.eof', `reason ${e && e.reason}`);
    // From the last byte the reader got: Chrome hands over less than the
    // server sent before it reports the break, at times nothing.
    const size = (await env.fixture('long_60s.flac')).length;
    const es = await tagged('drop');
    const from = es.length === 2 ? rangeStart(es[1]) : -1;
    check(es.length === 2 && es[0].dropped && from >= 0 && from <= 600000 && es[1].bytes === size - from,
      'reconnect.rest_of_file_from_the_break', JSON.stringify(es.map((x) => [x.range, x.bytes, !!x.dropped])));
    check(logs(core, /\] error: /).length === 0, 'reconnect.no_error', logs(core, /webio/).slice(-3).join(' | '));
    check(e && e.readError === false && e.skippedSegments === 0, 'reconnect.no_read_error',
      JSON.stringify(e && { readError: e.readError, skipped: e.skippedSegments }));
  }, { extra: { cache: 'no' } });

  // ── a body that breaks off and whose resume is refused: a read error ──
  // END_FILE tells it from a complete file (patch_read_error.py, through
  // the error webio returns).
  await run('truncated', async (core) => {
    const l = await load(core, `${env.base}/media/drop/long_60s.flac?after=600000&again=503&tag=trunc`);
    check(l.ok, 'truncated.loaded');
    const e = await l.ended;
    check(e && e.reason === END.EOF && e.readError === true && e.skippedSegments === 0, 'truncated.read_error',
      JSON.stringify(e && { reason: e.reason, readError: e.readError, skipped: e.skippedSegments }));
    const es = await tagged('trunc');
    check(es.length >= 2 && es[0].dropped && es.slice(1).every((x) => x.status === 503), 'truncated.resume_refused',
      JSON.stringify(es.map((x) => [x.range, x.status, !!x.dropped])));
  }, { extra: { cache: 'no' } });

  // ── HLS with a segment that is not there: one segment skipped ─────────
  await run('hls_gap', async (core) => {
    const l = await load(core, `${env.base}/media/range/hls/gap.m3u8?tag=gap`);
    check(l.ok, 'hls_gap.loaded');
    const e = await l.ended;
    check(e && e.reason === END.EOF && e.skippedSegments === 1 && e.readError === false, 'hls_gap.skipped_segment',
      JSON.stringify(e && { reason: e.reason, readError: e.readError, skipped: e.skippedSegments }));
  });

  // ── server without Range ─────────────────────────────────────────────
  await run('norange', async (core) => {
    const l = await load(core, `${env.base}/media/norange/long_60s.mp3?tag=nr`);
    check(l.ok, 'norange.loaded');
    const sk = await core.get('seekable', FMT.FLAG);
    check(sk.value === false, 'norange.not_seekable', String(sk.value));
    await core.command(['seek', '50', 'absolute']);
    await core.command(['seek', '2', 'absolute']);
    const e = await l.ended;
    check(e && e.reason === END.EOF, 'norange.eof_after_seeks', String(e && e.reason));
    const es = await tagged('nr');
    check(es.length >= 1 && es.every((x) => rangeStart(x) <= 0), 'norange.no_seek_request',
      `requests ${es.map((x) => x.range).join(',')}`);
  }, { extra: { cache: 'no' } });

  // ── live stream without length ────────────────────────────────────────
  await run('live', async (core) => {
    const l = await load(core, `${env.base}/media/live/live.mp3?rate=48000&tag=live`);
    check(l.ok, 'live.loaded', `${l.ms.toFixed(1)} ms`);
    const sk = await core.get('seekable', FMT.FLAG);
    check(sk.value === false, 'live.not_seekable', String(sk.value));
    // The demuxer guesses a duration from the bitrate; the stream has no size.
    check(logs(core, /webio: .*size -1, not seekable/).length === 1, 'live.no_size', logs(core, /webio: .*HTTP/).join(' | '));
    await sleep(3000);
    const pos = await core.get('time-pos', FMT.DOUBLE);
    check(pos.value > 1, 'live.plays', `time-pos ${pos.value}`);
    const t0 = now();
    await core.command(['stop']);
    const e = await l.ended;
    check(e && e.reason === END.STOP && now() - t0 < 1000, 'live.stop', `${(now() - t0).toFixed(1)} ms`);
    check(await waitAborted('live'), 'live.fetch_aborted');
  });

  // ── ICY metadata ──────────────────────────────────────────────────────
  // mpv reads the ICY packet after each demuxed packet and keeps it as
  // timed metadata at the demuxer's newest timestamp (demux.c,
  // update_cache and add_timed_metadata); demux_update publishes it when
  // playback crosses that time. With ao-null-untimed and a server slower
  // than the decoder, playback runs at the demuxer's edge, already past the
  // title when it is found, and mpv skips it, as with http.c on native. So
  // these cases play in real time, as a real output does, with a title
  // every 0.5 s of the server (1.5 s of audio at rate 48000), and every
  // title must show, in order.
  const icyCase = async (name, url, { expectTitles, expectIcyHeader, extra = {} }) => {
    await run(name, async (core) => {
      const titles = new Set();
      const seen = [];
      let icyName = null;
      let lastPos = null;
      let t0 = now();
      core.on((ev) => {
        if (ev.id === EV.PROPERTY_CHANGE && ev.name === 'time-pos') lastPos = ev.value;
        if (ev.id === EV.PROPERTY_CHANGE && ev.name === 'metadata' && ev.value) {
          const v = ev.value;
          if (v['icy-title'] && !titles.has(v['icy-title'])) {
            titles.add(v['icy-title']);
            seen.push([v['icy-title'], Math.round(ev.t - t0), lastPos && Number(lastPos.toFixed(2))]);
          }
          if (v['icy-name']) icyName = v['icy-name'];
        }
      });
      core.observe('metadata', FMT.NODE);
      core.observe('time-pos', FMT.DOUBLE);
      t0 = now();
      const l = await load(core, url);
      check(l.ok, `${name}.loaded`);
      await sleep(4000);
      const pos = await core.get('time-pos', FMT.DOUBLE);
      check(pos.value > 2, `${name}.plays`, `time-pos ${pos.value}`);
      const list = [...titles];
      measure(`${name}.titles_seen`, JSON.stringify(seen));
      if (expectTitles) {
        const nums = list.map((x) => Number(/^Mak title (\d+)$/.exec(x)?.[1]));
        check(list.length >= 2 && nums.every((n, i) => n === i + 1), `${name}.titles`, JSON.stringify(list));
        check(icyName === 'Mak Test Radio', `${name}.icy_name`, String(icyName));
      } else {
        check(list.length === 0, `${name}.no_titles`, JSON.stringify(list));
      }
      const errs = logs(core, DECODE_ERRORS);
      check(errs.length === 0, `${name}.clean_audio`, errs.slice(0, 3).join(' | '));
      const tag = /tag=([^&]+)/.exec(url)[1];
      const gets = (await tagged(tag)).filter((e) => e.method === 'GET');
      check(expectIcyHeader(gets), `${name}.requests`, JSON.stringify(gets.map((e) => ({ icy: e.icy, sent: e.icy_sent }))));
      await core.command(['stop']);
      await l.ended;
    }, { extra: { 'ao-null-untimed': 'no', ...extra } });
  };
  await icyCase('icy_same', `${env.base}/media/live/live.mp3?icy=1&rate=48000&titlesecs=0.5&tag=icy1`, {
    expectTitles: true, expectIcyHeader: (g) => g.length === 1 && g[0].icy === '1' && g[0].icy_sent,
  });
  if (env.browser) {
    await icyCase('icy_cross_exposed', `${env.cross}/media/live/live.mp3?icy=1&cors=expose&rate=48000&titlesecs=0.5&tag=icy2`, {
      expectTitles: true, extra: { 'stream-lavf-o': 'icy_cross_origin=1' },
      expectIcyHeader: (g) => g.length === 1 && g[0].icy === '1' && g[0].icy_sent,
    });
    await icyCase('icy_cross_hidden', `${env.cross}/media/live/live.mp3?icy=1&cors=1&rate=48000&tag=icy3`, {
      expectTitles: false, extra: { 'stream-lavf-o': 'icy_cross_origin=1' },
      expectIcyHeader: (g) => g.length === 2 && g[0].icy === '1' && g[1].icy === null,
    });
    await icyCase('icy_cross_default', `${env.cross}/media/live/live.mp3?icy=1&rate=48000&tag=icy4`, {
      expectTitles: false, expectIcyHeader: (g) => g.length === 1 && g[0].icy === null,
    });
  }

  // ── redirects ─────────────────────────────────────────────────────────
  await run('redirect', async (core) => {
    const to = encodeURIComponent('/media/range/long_60s.flac?tag=redir2');
    const l = await load(core, `${env.base}/media/redirect/long_60s.flac?tag=redir&to=${to}`);
    check(l.ok, 'redirect.loaded');
    const s = await seekTo(core, 50);
    check(s.ok && Math.abs(s.pos - 50) < 1.5, 'redirect.seek', `time-pos ${s.pos}`);
    await resume(core);
    const e = await l.ended;
    check(e && e.reason === END.EOF, 'redirect.eof');
    const hops = await tagged('redir');
    const finals = (await tagged('redir2')).map(rangeStart);
    check(hops.length === 1 && finals.some((x) => x > 1500000), 'redirect.seek_on_final_url',
      `redirects ${hops.length}, final Range starts ${finals.join(',')}`);
  }, { extra: PAUSED });
  if (env.browser) {
    await run('redirect_cross', async (core) => {
      const to = encodeURIComponent(`${env.cross}/media/range/mp3_44100_stereo.mp3?tag=redirx2`);
      const l = await load(core, `${env.base}/media/redirect/x?tag=redirx&to=${to}`);
      check(l.ok, 'redirect_cross.loaded');
      const e = await l.ended;
      check(e && e.reason === END.EOF, 'redirect_cross.eof');
    });
  }

  // ── HLS and DASH (nested opens of the demuxers) ───────────────────────
  await run('hls', async (core) => {
    const l = await load(core, `${env.base}/media/range/hls/index.m3u8?tag=hls`);
    check(l.ok, 'hls.loaded', `${l.ms.toFixed(1)} ms`);
    const dur = await core.get('duration', FMT.DOUBLE);
    check(Math.abs((dur.value ?? 0) - 30) < 1.5, 'hls.duration', String(dur.value));
    const s = await seekTo(core, 20);
    check(s.ok && Math.abs(s.pos - 20) < 2.5, 'hls.seek', `time-pos ${s.pos}`);
    await resume(core);
    const e = await l.ended;
    check(e && e.reason === END.EOF, 'hls.eof', String(e && e.reason));
  }, { extra: PAUSED });
  await run('dash', async (core) => {
    const l = await load(core, `${env.base}/media/range/dash/manifest.mpd`);
    check(l.ok, 'dash.loaded', `${l.ms.toFixed(1)} ms`);
    const e = await l.ended;
    check(e && e.reason === END.EOF, 'dash.eof', String(e && e.reason));
  });

  // ── errors ────────────────────────────────────────────────────────────
  await run('status404', async (core) => {
    const l = await load(core, `${env.base}/media/status/none?code=404`, 5000);
    const e = await l.ended;
    check(e && e.reason === END.ERROR && now() - l.t0 < 3000, 'status404.error', `${(now() - l.t0).toFixed(1)} ms`);
    check(logs(core, /HTTP 404/).length > 0, 'status404.message', logs(core, /webio/).slice(0, 2).join(' | '));
  });
  if (env.browser) {
    await run('nocors', async (core) => {
      const l = await load(core, `${env.cross}/media/range/long_60s.mp3?cors=0&tag=nocors`, 5000);
      const e = await l.ended;
      check(e && e.reason === END.ERROR && now() - l.t0 < 3000, 'nocors.error', `${(now() - l.t0).toFixed(1)} ms`);
      check(logs(core, /CORS/).length > 0, 'nocors.message', logs(core, /webio/).slice(0, 2).join(' | '));
    });
    await run('cross_cors', async (core) => {
      const l = await load(core, `${env.cross}/media/range/long_60s.flac?cors=1&tag=xc`);
      check(l.ok, 'cross_cors.loaded');
      const sk = await core.get('seekable', FMT.FLAG);
      check(sk.value === true, 'cross_cors.seekable', String(sk.value));
      const s = await seekTo(core, 50);
      check(s.ok && Math.abs(s.pos - 50) < 1.5, 'cross_cors.seek', `time-pos ${s.pos}`);
      await resume(core);
      const e = await l.ended;
      check(e && e.reason === END.EOF, 'cross_cors.eof');
    }, { extra: PAUSED });
  }

  // ── request headers ───────────────────────────────────────────────────
  const hdrCore = { 'http-header-fields': 'X-Mak-Test: hello', 'user-agent': 'MakTest/1.0' };
  await run('headers_same', async (core) => {
    const l = await load(core, `${env.base}/media/range/mp3_44100_stereo.mp3?tag=hdr1`);
    check(l.ok, 'headers_same.loaded');
    await l.ended;
    const g = (await tagged('hdr1')).filter((e) => e.method === 'GET');
    check(g.length && g[0].xmak === 'hello', 'headers_same.custom_header', String(g[0] && g[0].xmak));
    measure('headers_same.user_agent', JSON.stringify(g[0] && g[0].ua));
  }, { extra: hdrCore });
  if (env.browser) {
    await run('headers_cross_allowed', async (core) => {
      const l = await load(core, `${env.cross}/media/range/mp3_44100_stereo.mp3?tag=hdr2`);
      check(l.ok, 'headers_cross_allowed.loaded');
      await l.ended;
      const es = await tagged('hdr2');
      const g = es.filter((e) => e.method === 'GET');
      check(es.some((e) => e.method === 'OPTIONS') && g.length && g[0].xmak === 'hello',
        'headers_cross_allowed.custom_header', JSON.stringify(es.map((e) => [e.method, e.xmak, e.acrh])));
      measure('headers_cross_allowed.user_agent', JSON.stringify(g[0] && g[0].ua));
    }, { extra: hdrCore });
    await run('headers_cross_refused', async (core) => {
      const l = await load(core, `${env.cross}/media/range/mp3_44100_stereo.mp3?hdrs=deny&tag=hdr3`);
      check(l.ok, 'headers_cross_refused.loaded');
      const e = await l.ended;
      check(e && e.reason === END.EOF, 'headers_cross_refused.eof');
      const g = (await tagged('hdr3')).filter((x) => x.method === 'GET');
      check(g.length >= 1 && g.every((x) => x.xmak === null), 'headers_cross_refused.sent_without',
        JSON.stringify(g.map((x) => x.xmak)));
      check(logs(core, /preflight/).length > 0, 'headers_cross_refused.warning', logs(core, /webio/).slice(0, 2).join(' | '));
    }, { extra: hdrCore });
  }

  // ── stop, quit and timeout while the server is slow ───────────────────
  for (let i = 1; i <= repeat; i++) {
    await run(`stop_slow#${i}`, async (core) => {
      const tag = `stop${i}`;
      const l = await load(core, `${env.base}/media/slow/long_60s.mp3?delay=30&tag=${tag}`, 700);
      check(!l.ok, `stop_slow#${i}.still_opening`);
      const t0 = now();
      await core.command(['stop']);
      const e = await l.ended;
      const dt = now() - t0;
      check(e && dt < 500, `stop_slow#${i}.stop_returns`, `${dt.toFixed(1)} ms, reason ${e && e.reason}`);
      measure(`stop_slow#${i}.stop_ms`, dt);
      check(await waitAborted(tag), `stop_slow#${i}.fetch_aborted`);
    });
    await run(`quit_slow#${i}`, async (core) => {
      const tag = `quit${i}`;
      const l = await load(core, `${env.base}/media/slow/long_60s.mp3?delay=30&tag=${tag}`, 700);
      check(!l.ok, `quit_slow#${i}.still_opening`);
      const t0 = now();
      core.destroy();
      core.destroy = null;
      const dt = now() - t0;
      check(dt < 500, `quit_slow#${i}.destroy_returns`, `${dt.toFixed(1)} ms`);
      measure(`quit_slow#${i}.destroy_ms`, dt);
      check(await waitAborted(tag), `quit_slow#${i}.fetch_aborted`);
    });
    await run(`stop_trickle#${i}`, async (core) => {
      const tag = `trickle${i}`;
      const l = await load(core, `${env.base}/media/trickle/long_60s.mp3?tag=${tag}`, 1500);
      const t0 = now();
      await core.command(['stop']);
      const e = await l.ended;
      const dt = now() - t0;
      check(e && dt < 500, `stop_trickle#${i}.stop_returns`, `${dt.toFixed(1)} ms, loaded ${l.ok}`);
      measure(`stop_trickle#${i}.stop_ms`, dt);
      check(await waitAborted(tag), `stop_trickle#${i}.fetch_aborted`);
    });
    await run(`timeout#${i}`, async (core) => {
      const l = await load(core, `${env.base}/media/slow/long_60s.mp3?delay=30&tag=to${i}`, 5000);
      const e = await l.ended;
      const dt = now() - l.t0;
      check(e && e.reason === END.ERROR && dt > 900 && dt < 2500, `timeout#${i}.error_in_time`, `${dt.toFixed(1)} ms`);
      check(logs(core, /no answer within/).length > 0, `timeout#${i}.message`);
    }, { extra: { 'network-timeout': '1' } });
  }

  // ── blob: URLs ────────────────────────────────────────────────────────
  if (env.blobUrl) {
    await run('blob', async (core) => {
      const url = await env.blobUrl('long_60s.flac');
      const l = await load(core, `makblob://${url.slice('blob:'.length)}`);
      check(l.ok, 'blob.loaded', `${l.ms.toFixed(1)} ms`);
      const sk = await core.get('seekable', FMT.FLAG);
      check(sk.value === true, 'blob.seekable', String(sk.value));
      const s = await seekTo(core, 50);
      check(s.ok && Math.abs(s.pos - 50) < 1.5, 'blob.seek', `time-pos ${s.pos}`);
      await resume(core);
      const e = await l.ended;
      check(e && e.reason === END.EOF, 'blob.eof');
      measure('blob.answer', JSON.stringify(logs(core, /webio: blob/).map((x) => /HTTP \d+/.exec(x)?.[0])));
    }, { extra: PAUSED });
  }

  // ── open and close cycles ─────────────────────────────────────────────
  await run('cycles', async (core) => {
    let ok = 0;
    for (let i = 0; i < 10; i++) {
      const l = await load(core, `${env.base}/media/range/long_60s.mp3?tag=cyc`);
      await core.command(['stop']);
      await l.ended;
      if (l.ok) ok++;
      if (i === 0) measure('cycles.memory_after_1', mod.memory());
    }
    check(ok === 10, 'cycles.loaded', `${ok} of 10`);
    check(await waitLive() === 0, 'cycles.streams_freed');
    measure('cycles.memory_after_10', mod.memory());
  });

  // ── measures: speed, first byte, memory ───────────────────────────────
  if (want('measure')) {
    const ttfb = async (url) => {
      const t0 = now();
      const r = await fetch(url, { headers: { Range: 'bytes=0-' } });
      const rd = r.body.getReader();
      await rd.read();
      const dt = now() - t0;
      await rd.cancel();
      return dt;
    };
    const firstBytes = (core) => {
      const l = core.logs.find((x) => /webio: first bytes/.test(x));
      return l ? Number(/bytes ([\d.]+) ms/.exec(l)[1]) : NaN;
    };
    for (const name of ['long_300s.wav', 'long_60s.flac']) {
      for (let i = 1; i <= repeat; i++) {
        await run(`measure_http_${name}#${i}`, async (core) => {
          const direct = await ttfb(`${env.base}/media/range/${name}`);
          const l = await load(core, `${env.base}/media/range/${name}?tag=meas`);
          const e = await l.ended;
          const ms = now() - l.t0;
          check(e && e.reason === END.EOF, `measure_http_${name}#${i}.eof`);
          const bytes = (await env.fixture(name)).length;
          measure(`measure_http_${name}#${i}.load_ms`, l.ms);
          measure(`measure_http_${name}#${i}.eof_ms`, ms);
          measure(`measure_http_${name}#${i}.MB_per_s`, bytes / 1e6 / (ms / 1000));
          measure(`measure_http_${name}#${i}.first_bytes_ms`, firstBytes(core));
          measure(`measure_http_${name}#${i}.direct_fetch_first_bytes_ms`, direct);
          measure(`measure_http_${name}#${i}.memory`, mod.memory());
        }, { extra: { cache: 'no' }, group: 'measure' });
        await run(`measure_wasmfs_${name}#${i}`, async (core) => {
          mod.writeFile(`/in/${name}`, await env.fixture(name));
          const l = await load(core, `/in/${name}`);
          const e = await l.ended;
          const ms = now() - l.t0;
          check(e && e.reason === END.EOF, `measure_wasmfs_${name}#${i}.eof`);
          measure(`measure_wasmfs_${name}#${i}.load_ms`, l.ms);
          measure(`measure_wasmfs_${name}#${i}.eof_ms`, ms);
          mod.m.FS.unlink(`/in/${name}`);
        }, { extra: { cache: 'no' }, group: 'measure' });
      }
    }
  }

  clearInterval(ticker);
  measure('memory_start', memory0);
  measure('memory_end', mod.memory());
  res.pass = res.checks.filter((c) => c.ok).length;
  res.fail = res.checks.length - res.pass;
  log(`RESULT pass=${res.pass} fail=${res.fail}`);
  return res;
}
