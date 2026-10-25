// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The W2 harness: mpv's webaudio output in a browser, driven from the main
// thread through the module (libmpv.mjs) and Module.makWebAudio. It plays
// files in real time and reads what the AudioWorklet did from the slots of
// the shared table (makWebAudio.stats()): frames consumed, underruns,
// silent frames, the peak of the samples put out.
//
//   const r = await runAudioHarness(factory, files, log, opts);
// files: {name: bytes}; opts:
//   ao        'webaudio' (default) or 'null', the real-time ao=null that the
//             checks of the worklet must fail on
//   gesture   the AudioContext is expected suspended (autoplay policy): the
//             checks wait, then signal('click') asks the runner for a user
//             gesture and the output must start
//   signal    async (name) => void, tells the runner (click, cpu-start,
//             cpu-end)
//   resumeOnGesture  false: makWebAudio does not resume on a gesture, the
//             run gesture=1 must fail on
//   slowProcessorUrl the worklet module served late, for the context that
//             replaces the first one
//
// Fixtures (make_fixtures.sh): long_60s.flac (48 kHz), tone_48k_20s.flac and
// tone_44k_20s.flac (1 kHz at -12 dBFS), sine_stereo_48k_5s.flac.

import { createCore, EV, FMT } from './mpv_client.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function runAudioHarness(factory, files, log, opts = {}) {
  const ao = opts.ao ?? 'webaudio';
  const signal = opts.signal ?? (async () => {});
  const res = { checks: [], measures: {} };
  const check = (ok, name, detail) => {
    res.checks.push({ ok, name, detail });
    log(`${ok ? 'ok' : 'FAIL'} ${name} ${detail}`);
    return ok;
  };
  const measure = (k, v) => {
    res.measures[k] = v;
    log(`measure ${k} ${typeof v === 'number' ? +v.toFixed(4) : v}`);
  };

  let core = null;
  const m = await factory({ print: log, printErr: log });
  const wa = m.makWebAudio;
  if (!check(!!wa, 'glue', `makWebAudio ${wa ? 'present' : 'missing'}`)) return finish();
  const ti = performance.now();
  await wa.init({ channels: 2, resumeOnGesture: opts.resumeOnGesture !== false });
  measure('webaudio_init_ms', performance.now() - ti);
  const ctx = wa.context;
  const rate = ctx.sampleRate;
  measure('context_rate', rate);
  measure('base_latency_ms', (ctx.baseLatency || 0) * 1000);
  log(`context state ${wa.state}, output latency ${ctx.outputLatency}`);

  m.FS.mkdir('/in');
  for (const [name, bytes] of Object.entries(files)) m.FS.writeFile(`/in/${name}`, bytes);

  const st = { ended: null, starts: 0, outState: [], warnings: [], restarts: 0 };
  core = createCore(m, [
    ['ao', ao], ['ao-null-untimed', 'no'], ['vid', 'no'], ['idle', 'yes'],
    ['config', 'no'], ['audio-display', 'no'], ['audio-fallback-to-null', 'no'],
  ], (id, err, reply, data) => {
    const w = core.w, d = w.dv();
    if (id === EV.START_FILE) {
      // The END_FILE of the entry a loadfile replaced comes first.
      st.ended = null;
      st.starts++;
    } else if (id === EV.END_FILE) {
      st.ended = { reason: d.getInt32(data, true), error: d.getInt32(data + 4, true), at: performance.now() };
    } else if (id === EV.PLAYBACK_RESTART) {
      st.restarts++;
    } else if (id === EV.LOG) {
      const text = `[${w.str(w.u32(data + 4))}] ${w.str(w.u32(data))}: ${(w.str(w.u32(data + 8)) || '').trimEnd()}`;
      st.warnings.push(text);
      if (st.warnings.length <= 30) log(`log ${text}`);
    } else if (id === EV.PROPERTY_CHANGE) {
      const name = w.str(w.u32(data)), fmt = d.getInt32(data + 4, true);
      if (name === 'audio-output-state' && fmt === FMT.STRING) {
        st.outState.push(w.str(w.u32(w.u32(data + 8))));
      }
    }
  });
  check(core.initErr === 0, 'initialize', `error ${core.initErr}`);
  core.logs('warn');
  core.observe(1, 'audio-output-state', FMT.STRING);

  // The open slot of output 0 with the newest stream.
  const slot = () => wa.stats().filter((s) => s.open && s.output === 0).sort((a, b) => b.gen - a.gen)[0];
  const consumed = () => slot()?.consumed ?? 0;
  const timePos = async () => (await core.get('time-pos', FMT.DOUBLE)).v ?? NaN;
  // Waits on a predicate of state outside mpv's events (the slots).
  const poll = async (pred, ms, step = 20) => {
    const t0 = performance.now();
    while (performance.now() - t0 < ms) {
      if (await pred()) return true;
      await sleep(step);
    }
    return pred();
  };
  // loadfile replace, back once the new entry started (st.ended is then its
  // own).
  const load = async (file, extra) => {
    const n = st.starts;
    const args = ['loadfile', file, 'replace'];
    if (extra) args.push('-1', extra);
    const c = await core.command(args);
    await core.until(() => st.starts > n, 5000);
    return c;
  };
  const loadAndStart = async (file, extra) => {
    const s0 = slot();
    const c = await load(file, extra);
    // Started: frames played since the load, in the same slot (a gapless
    // follow-up) or a new one (ao=null never has one).
    const started = await poll(() => {
      const s = slot();
      if (!s) return st.ended;
      const fresh = !s0 || s.slot !== s0.slot || s.gen !== s0.gen;
      return (fresh ? s.consumed > 0 : s.consumed > s0.consumed + 0.05 * rate) || st.ended;
    }, 5000);
    return { err: c.err, started };
  };
  const peakOver = async (ms) => {
    wa.stats(); // resets the peaks
    await sleep(ms);
    return slot()?.peak ?? 0;
  };

  // ── Autoplay policy: suspended until a gesture ───────────────────────
  if (opts.gesture) {
    check(wa.state === 'suspended', 'gesture.suspended', `state ${wa.state}`);
    await load('/in/long_60s.flac');
    await sleep(1500);
    const s = slot();
    const pos = await timePos();
    const aos = (await core.get('audio-output-state')).v;
    check(s && s.consumed === 0 && s.queued > 0, 'gesture.waits',
      `consumed ${s?.consumed}, queued ${s?.queued} frames, ring ${s?.capacity}`);
    check(pos < 0.05, 'gesture.position', `time-pos ${pos} after 1.5 s suspended, audio-output-state ${aos}`);
    await signal('click');
    const running = await poll(() => wa.state === 'running', 10000, 50);
    check(running, 'gesture.resumed', `state ${wa.state}`);
    const c0 = consumed(), p0 = await timePos(), t0 = performance.now();
    await sleep(1500);
    const c1 = consumed(), p1 = await timePos(), dt = (performance.now() - t0) / 1000;
    check(running && (c1 - c0) / dt > 0.9 * rate && p1 - p0 > 0.9 * dt * 0.9, 'gesture.plays',
      `${((c1 - c0) / dt).toFixed(0)} frames/s, time-pos ${p0.toFixed(3)} to ${p1.toFixed(3)} in ${dt.toFixed(3)} s`);
    await core.command(['stop']);
    return finish();
  }

  // ── Real time, latency, pause, seek: long_60s.flac (48 kHz) ──────────
  const a = await loadAndStart('/in/long_60s.flac');
  check(a.err >= 0, 'load', `loadfile ${a.err}, worklet started ${!!a.started}`);
  if (ao === 'webaudio') {
    const s = slot();
    measure('ring_frames', s?.capacity ?? 0);
    measure('ring_ms', ((s?.capacity ?? 0) / rate) * 1000);
  }
  await sleep(500);

  // Latency: time-pos against the frames the worklet played. mpv's time-pos
  // is the last written frame minus ao_get_delay (queued frames plus the
  // published latency), worked out at its last playloop pass, so it equals
  // consumed / rate - latency right after a pass and falls behind until the
  // next one: by at most the output's refill period (buffer.c wakes every
  // quarter of the ring, 50 ms) plus one render burst of the browser (the
  // worklet reads several quanta at once). 30 samples at uneven intervals;
  // read before any seek: consumed counts from the open, at the file's
  // start.
  const errs = [];
  for (let i = 0; i < 30; i++) {
    const cb = consumed();
    const t0 = performance.now();
    const p = await timePos();
    const rtt = performance.now() - t0;
    const ca = consumed();
    errs.push(p - ((cb + ca) / 2 / rate - wa.latency));
    if (i < 5) log(`latency sample ${(errs.at(-1) * 1000).toFixed(2)} ms (get in ${rtt.toFixed(2)} ms)`);
    await sleep(17 + ((i * 37) % 71));
  }
  const meanErr = errs.reduce((x, y) => x + y, 0) / errs.length;
  const maxErr = Math.max(...errs.map(Math.abs));
  const minErr = Math.min(...errs.map(Math.abs));
  measure('declared_latency_ms', wa.latency * 1000);
  measure('latency_error_mean_ms', meanErr * 1000);
  measure('latency_error_min_ms', minErr * 1000);
  measure('latency_error_max_ms', maxErr * 1000);
  check(minErr < 0.002 && maxErr < 0.1 && Math.max(...errs) < 0.002, 'latency',
    `time-pos minus (consumed/rate - ${(wa.latency * 1000).toFixed(1)} ms): from ${(Math.min(...errs) * 1000).toFixed(2)} to ${(Math.max(...errs) * 1000).toFixed(2)} ms, exact at ${errs.filter((e) => Math.abs(e) < 0.002).length} of ${errs.length} samples`);

  // Real time: the worklet consumes rate frames per second and time-pos
  // moves one second per second, with no underrun.
  await signal('cpu-start');
  const r0 = { c: consumed(), p: await timePos(), t: performance.now(), u: slot()?.underruns ?? 0 };
  await sleep(4000);
  const r1 = { c: consumed(), p: await timePos(), t: performance.now(), u: slot()?.underruns ?? 0 };
  await signal('cpu-end');
  const dt = (r1.t - r0.t) / 1000;
  const fps = (r1.c - r0.c) / dt;
  const speed = (r1.p - r0.p) / dt;
  measure('consumed_frames_per_s', fps);
  measure('time_pos_speed', speed);
  check(Math.abs(fps / rate - 1) < 0.02, 'realtime.consumed',
    `${fps.toFixed(1)} frames/s for a context at ${rate} (${((fps / rate - 1) * 100).toFixed(2)} %)`);
  check(Math.abs(speed - 1) < 0.02, 'realtime.time-pos', `${speed.toFixed(4)} s per s over ${dt.toFixed(3)} s`);
  check(ao === 'webaudio' && r1.u === r0.u && (slot()?.underruns ?? 0) === 0, 'realtime.underruns',
    `${slot()?.underruns ?? 'no slot'} underruns, ${slot()?.starved ?? '-'} silent frames`);
  // ao=null has no slot: the checks above are the ones it must fail.
  if (!slot()) return finish();

  // Pause: the frames stay, silence goes out, time-pos stands still.
  await core.set('pause', 'yes');
  await sleep(300);
  const q0 = slot(); // also resets the peak
  const pp0 = await timePos();
  await sleep(1000);
  const q1 = slot();
  const pp1 = await timePos();
  check(q1 && q1.paused && q1.consumed === q0.consumed && q1.peak === 0 && q1.queued > 0,
    'pause.silence', `consumed +${q1 ? q1.consumed - q0.consumed : '-'} frames, peak ${q1?.peak}, queued ${q1?.queued}`);
  check(Math.abs(pp1 - pp0) < 0.001, 'pause.position', `time-pos ${pp0.toFixed(4)} then ${pp1.toFixed(4)}`);
  await core.set('pause', 'no');
  const tr = performance.now();
  await sleep(1000);
  const pp2 = await timePos();
  const q2 = slot();
  const resumed = (performance.now() - tr) / 1000;
  check(pp2 - pp1 > 0.8 * resumed && pp2 - pp1 < resumed + 0.05 && q2.consumed - q1.consumed > 0.8 * rate * resumed,
    'pause.resume', `time-pos +${(pp2 - pp1).toFixed(3)} s and +${q2.consumed - q1.consumed} frames in ${resumed.toFixed(3)} s`);

  // Seek: the ring drops what it held, the position jumps, audio goes on.
  const u0 = slot().underruns;
  const ts = performance.now();
  await core.command(['seek', '30', 'absolute']);
  const cs = consumed();
  const restarted = await poll(async () => consumed() - cs > 0.05 * rate, 3000);
  measure('seek_restart_ms', performance.now() - ts);
  await sleep(1000);
  const sp = await timePos();
  check(restarted && sp > 30.6 && sp < 31.6 && slot().underruns === u0, 'seek',
    `time-pos ${sp.toFixed(3)} about 1 s after seek 30, playing again in ${res.measures.seek_restart_ms.toFixed(0)} ms, underruns ${slot().underruns}`);

  // ── ao-volume: the output's gain, after the tap ──────────────────────
  await loadAndStart('/in/tone_48k_20s.flac');
  await sleep(500);
  const p100 = await peakOver(300);
  await core.set('ao-volume', '50');
  await sleep(200);
  const p50 = await peakOver(300);
  const vol = (await core.get('ao-volume', FMT.DOUBLE)).v;
  measure('peak_volume_100', p100);
  measure('peak_volume_50', p50);
  check(p100 > 0.2 && Math.abs(p50 / p100 - 0.125) < 0.01 && vol === 50, 'volume.gain',
    `peak ${p100.toFixed(4)} at 100, ${p50.toFixed(4)} at 50 (ratio ${(p50 / p100).toFixed(4)}, cubic 0.125), ao-volume reads ${vol}`);
  await core.set('ao-mute', 'yes');
  await sleep(200);
  const pm = await peakOver(300);
  const mute = (await core.get('ao-mute', FMT.FLAG)).v;
  check(pm === 0 && mute === true, 'volume.mute', `peak ${pm} muted, ao-mute reads ${mute}`);
  await core.set('ao-mute', 'no');

  // ── A file at another rate reopens the output; the volume stays ──────
  const g0 = slot().gen;
  const i0 = slot().slot;
  await loadAndStart('/in/tone_44k_20s.flac');
  const s44 = slot();
  await sleep(500);
  const f0 = { c: consumed(), t: performance.now() };
  const p44 = await peakOver(1500);
  const f1 = { c: consumed(), t: performance.now() };
  const ap = (await core.get('audio-params/samplerate')).v;
  const aop = (await core.get('audio-out-params/samplerate')).v;
  const vol44 = (await core.get('ao-volume', FMT.DOUBLE)).v;
  const fps44 = (f1.c - f0.c) / ((f1.t - f0.t) / 1000);
  check(s44 && (s44.slot !== i0 || s44.gen !== g0) && +ap === 44100 && +aop === rate &&
    Math.abs(fps44 / rate - 1) < 0.03, 'format.reopen',
    `slot ${i0} then ${s44?.slot}, audio-params ${ap} Hz, audio-out-params ${aop} Hz, ${fps44.toFixed(0)} frames/s`);
  check(vol44 === 50 && Math.abs(p44 / p100 - 0.125) < 0.01, 'format.volume-kept',
    `ao-volume ${vol44} after the reopen, peak ratio ${(p44 / p100).toFixed(4)}`);
  await core.set('ao-volume', '100');

  // ── Drain at the end of a file, audio-output-state ───────────────────
  // END_FILE comes once the decoder's end reached the output (gapless: the
  // next file could start); the output then drains what it holds and
  // closes. Every frame of the file must be played before it closes.
  const d0 = slot();
  await load('/in/sine_stereo_48k_5s.flac');
  let tStart = 0, ds = null;
  await poll(() => {
    const s = slot();
    if (s && (!d0 || s.slot !== d0.slot || s.gen !== d0.gen) && s.consumed > 0) {
      tStart = performance.now();
      ds = s;
    }
    return tStart || st.ended;
  }, 5000, 5);
  const during = (await core.get('audio-output-state')).v;
  st.outState.length = 0;
  const ended = await core.until(() => st.ended, 15000);
  const tEnded = performance.now();
  const closed = await core.until(() => st.outState.at(-1) === 'closed', 5000);
  const tClosed = performance.now();
  const last = wa.stats().filter((s) => s.slot === ds?.slot && s.gen === ds?.gen)[0];
  const played = (last?.consumed ?? 0) / rate;
  measure('end_file_after_s', (tEnded - tStart) / 1000);
  measure('drain_closed_after_s', (tClosed - tStart) / 1000);
  measure('drain_played_s', played);
  check(tStart && ended && st.ended.reason === 0 && closed && !last?.open && played > 4.98 && played < 5.05 &&
    (tClosed - tStart) / 1000 > 4.9 && (tClosed - tStart) / 1000 < 5.5, 'drain',
    `END_FILE ${st.ended?.reason} at ${((tEnded - tStart) / 1000).toFixed(3)} s, output closed at ${((tClosed - tStart) / 1000).toFixed(3)} s with ${played.toFixed(4)} s of 5 played`);
  check(during === 'active' && st.outState.at(-1) === 'closed', 'audio-output-state',
    `${during} while playing, then ${st.outState.join(' > ')}`);

  // No output underrun so far: a seek, a pause or a file replacing another
  // leave the output its whole capacity at once.
  const early = st.warnings.filter((w) => /underrun/i.test(w));
  check(early.length === 0, 'no-underrun-before', `${early.length} underrun warning(s) from mpv before the underrun test`);

  // ── Underrun: a live source that stops feeding, then resumes ─────────
  const chunk = (secs) => {
    const frames = Math.round(48000 * secs);
    const buf = new Int16Array(frames * 2);
    for (let i = 0; i < frames; i++) buf[2 * i] = buf[2 * i + 1] = Math.round(8000 * Math.sin(2 * Math.PI * 440 * i / 48000));
    return new Uint8Array(buf.buffer);
  };
  const feed = (id, bytes) => {
    const p = m._malloc(bytes.length);
    new Uint8Array(m.wasmMemory.buffer).set(bytes, p);
    const n = m._mak_pcm_write(id, p, BigInt(bytes.length));
    m._free(p);
    return Number(n);
  };
  const pid = m._mak_pcm_create(0n);
  feed(pid, chunk(1));
  st.warnings.length = 0;
  const lp = await loadAndStart(`mak-pcm://${pid}`, 'demuxer=rawaudio,demuxer-rawaudio-format=s16le,'
    + 'demuxer-rawaudio-rate=48000,demuxer-rawaudio-channels=2,cache-pause=no,'
    + 'demuxer-termination-timeout=0,demuxer-seekable-cache=no,gapless-audio=no');
  await sleep(1600);
  const gap = slot();
  const gapPeak = await peakOver(300);
  const gap2 = slot();
  feed(pid, chunk(1));
  m._mak_pcm_finish(pid);
  const pend = await core.until(() => st.ended, 10000);
  const after = wa.stats().filter((s) => s.output === 0 && s.slot === gap2?.slot && s.gen === gap2?.gen)[0];
  m._mak_pcm_release(pid);
  const logged = st.warnings.some((w) => /underrun/i.test(w));
  measure('underruns', after?.underruns ?? -1);
  measure('starved_frames', after?.starved ?? -1);
  check(lp.started && gap && gap.queued === 0 && gapPeak === 0 && gap2.starved > gap.starved,
    'underrun.silence', `in the gap: queued ${gap?.queued}, peak ${gapPeak}, silent frames ${gap?.starved} then ${gap2?.starved}`);
  check(pend && st.ended.reason === 0 && after && after.underruns === 1 && logged,
    'underrun.counted', `${after?.underruns} underrun(s) once the source fed again, mpv logged it: ${logged}, END_FILE ${st.ended?.reason}`);

  // ── A new AudioContext at another rate: the output reopens at it ─────
  await loadAndStart('/in/tone_48k_20s.flac');
  await sleep(300);
  const old = slot();
  const rate2 = rate === 48000 ? 44100 : 48000;
  // The worklet module comes late: the outputs must wait for the new
  // context, not reopen on no context at all.
  await wa.init({ channels: 2, sampleRate: rate2, resumeOnGesture: opts.resumeOnGesture !== false,
    ...(opts.slowProcessorUrl ? { processorUrl: opts.slowProcessorUrl } : {}) });
  const moved = await poll(() => {
    const s = slot();
    return s && (s.slot !== old.slot || s.gen !== old.gen) && s.consumed > 0;
  }, 5000);
  await sleep(300);
  const e0 = { c: consumed(), t: performance.now() };
  await sleep(1500);
  const e1 = { c: consumed(), t: performance.now() };
  const aop2 = (await core.get('audio-out-params/samplerate')).v;
  const fps2 = (e1.c - e0.c) / ((e1.t - e0.t) / 1000);
  check(moved && wa.context.sampleRate === rate2 && +aop2 === rate2 && Math.abs(fps2 / rate2 - 1) < 0.03,
    'context.replace', `context at ${wa.context.sampleRate}, audio-out-params ${aop2} Hz, ${fps2.toFixed(0)} frames/s`);

  // The output node is a plain AudioNode: the media session route of W4
  // (a MediaStreamAudioDestinationNode into an <audio>) takes it.
  const dest = wa.context.createMediaStreamDestination();
  wa.output(0).connect(dest);
  const tracks = dest.stream.getAudioTracks();
  check(tracks.length === 1 && tracks[0].readyState === 'live', 'route.media-stream',
    `${tracks.length} audio track, ${tracks[0]?.readyState}`);
  wa.output(0).disconnect(dest);

  // ── No context any more: the output fails and mpv says why ───────────
  st.warnings.length = 0;
  st.outState.length = 0;
  await wa.close();
  const failed = await core.until(() => st.outState.at(-1) === 'failed', 5000);
  const said = st.warnings.find((w) => /No AudioContext/.test(w));
  check(failed && !!said, 'context.closed', `audio-output-state ${st.outState.join(' > ')}, mpv: ${said}`);

  return finish();

  async function finish() {
    try {
      core?.destroy();
    } catch (e) {
      log(`destroy: ${e}`);
    }
    try {
      await wa?.close();
    } catch (e) {
      log(`close: ${e}`);
    }
    res.pass = res.checks.filter((c) => c.ok).length;
    res.fail = res.checks.length - res.pass;
    log(`RESULT pass=${res.pass} fail=${res.fail}`);
    return res;
  }
}
