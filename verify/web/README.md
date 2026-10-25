# verify/web

Checks of the web build (`scripts/build_libmpv_web.sh`). Everything runs on
the build's own outputs: no Docker, no network beyond 127.0.0.1.

## All of them

```
verify/web/make_net_fixtures.sh <mpv_audio_kit checkout> <fixtures>
BROWSERS="chrome firefox" CHROME=<chrome> \
  verify/web/run_checks.sh <module dir> <spike dir> <fixtures> <work dir>
```

`run_checks.sh` runs every check below one after the other, on the module
as published (`libmpv_web.zip` unpacked, or the build's `RELEASE_DIR`) and
the build's harness module (`$BUILD_DIR/spike`): in Node the rules of
`mak_webio.js`, the webaudio ring, the C harness with 10 cycles, the module
from the calling thread and http; in each browser of `BROWSERS` (default
chrome) the C harness and the webaudio output with the main thread busy,
the module, the AudioContext that waits for a gesture, and http. Each
output lands in `<work dir>/<check>.txt`; the exit status is non-zero when
one failed, and `SKIP=<names>` leaves checks out on purpose. The ring needs
emcc (or `EMSDK`). `CHROME` may be chrome-headless-shell or a full Chrome,
which runs with `--headless=new`.

The Build on GitHub runs it in its web job, on the zip and with the
runner's Chrome, before the release takes the module.

## The release asset

`libmpv_web.zip` (`scripts/web/package_web.py`) holds `libmpv.mjs`,
`libmpv.wasm`, `mak_webaudio_processor.js` and `build_web.json`. The record
has the patches and filters of the build and `module`: `abi` (MAK_WEB_ABI of
`scripts/web/mak_web.c`, which `mak_web_abi_version()` returns), `webaudioAbi`
(MAK_WA_ABI, the first word of the webaudio output's table) and
`emscripten`. `lib_harness.mjs` checks both versions against the module and
the record beside it, and the layout table of `mak_web_layout()`, which
gives the offsets of the two END_FILE fields of `patch_read_error.py` (0
without the patch). `scripts/verify_binaries.sh` checks the zip statically.

## The module and the harness of the build

| file | what |
|---|---|
| `mak_spike.c` | the C harness: create, decode the fixtures to the end, filters, kit patches, cycles |
| `run_node.mjs`, `run_browser.sh` with `harness.html` and `serve_coi.py` | runs it in Node, Firefox or Chrome, cross-origin isolated |
| `lib_harness.mjs`, `run_lib_node.mjs` | drives the module (`libmpv.mjs`) from the calling thread |
| `run_native.sh` | the same C harness on a native libmpv, for the comparison |
| `make_fixtures.sh` | the inputs: fixtures of mpv_audio_kit and two 60 s files |

## The audio output (webaudio)

mpv plays through `patches/mpv/web/patch_ao_webaudio.py`: rings in wasm
memory that the AudioWorklet of `scripts/web/mak_webaudio_processor.js`
reads, set up by `Module.makWebAudio` (`scripts/web/mak_webaudio.js`).

| file | what |
|---|---|
| `ring_test.c`, `ring_test.mjs`, `ring_test.sh` | the ring alone: the C producer against the worklet's consumer on one shared memory in Node |
| `audio_harness.mjs`, `mpv_client.mjs` | mpv plays in real time through the output: frames consumed, latency, underruns with the main thread busy, pause, seek, format change, volume, a new AudioContext |
| `gesture.mjs` | a trusted click through the browser's remote protocol, for the AudioContext that waits for a gesture |
| `proc_cpu.py` | the CPU time of the browser's processes |
| `firefox_sound.sh` | the sound device of the test Firefox: the null sink `PULSE_SINK` names, JACK and ALSA cut off |

No browser plays on the speakers. Chrome renders into its fake output
(`--disable-audio-output`). Firefox plays into the null sink that
`PULSE_SINK` names, on that sink's clock, so the AudioWorklet runs in real
time; it must exist and not be the default output (with PipeWire or
PulseAudio: `pactl load-module module-null-sink sink_name=mak_tests`).
Without it Firefox gets no device, its AudioContext does not start and its
audio checks fail.

```
EMSDK=<emsdk> verify/web/ring_test.sh <out dir>
LIBDIR=<module dir> verify/web/run_browser.sh <chrome|firefox> <build dir> "mode=audio&files=long_60s.flac,tone_48k_20s.flac,tone_44k_20s.flac,sine_stereo_48k_5s.flac&busy=1"
```

## http, https and blob: URLs (webio)

The web build reads http and https through fetch: `patches/ffmpeg/patch_ffmpeg_webio.py`
adds the protocols (`patches/ffmpeg/webio/webio.c`), `scripts/web/mak_webio.js`
is their JS side, on a pthread of their own. A `blob:` URL of the page opens
as `makblob://` followed by what comes after `blob:`.

| file | what |
|---|---|
| `net_server.py` | the page, cross-origin isolated, and media served as the protocol must cope with: Range, no Range, live chunked with ICY, redirect, slow answer, slow body, broken connection, HTTP error; the same media from a second origin with or without CORS |
| `net_harness.mjs`, `mpv_net_client.mjs` | mpv in the module opens each case and checks the end of file, seeks, ICY titles, stop and quit during a slow answer, timeouts, open errors, blob: URLs, open and close cycles, and the read errors END_FILE reports (a cut file whose resume is refused, a missing HLS segment); it measures read speed, first bytes against a direct fetch, memory and the main thread |
| `run_net.sh` with `net.html` and `run_net_node.mjs` | runs it in Node, Firefox or Chrome |
| `make_net_fixtures.sh` | the media: the fixtures above, a radio-like MP3, a 300 s WAV, HLS and DASH |
| `webio_logic_test.mjs` | the rules of `mak_webio.js` (headers, Range answers, ICY splitter) in plain Node, without the module |

```
verify/web/make_net_fixtures.sh <mpv_audio_kit checkout> <fixtures>
node verify/web/webio_logic_test.mjs
verify/web/run_net.sh node <dir of libmpv.mjs> <fixtures> [case,...] [repeat]
CHROME=<chrome-headless-shell> verify/web/run_net.sh chrome <dir of libmpv.mjs> <fixtures>
verify/web/run_net.sh firefox <dir of libmpv.mjs> <fixtures>
```

Node's fetch has no CORS and no blob: URLs across threads: there the cases
of the second origin and of blob: stay out. `MAK_NET_VERBOSE=1` (or
`verbose=1` in the page query) prints every log line of mpv. The patch
itself is checked by `verify/tests/patches/webio_patch_test.sh`.
