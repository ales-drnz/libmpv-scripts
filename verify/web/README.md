# verify/web

Checks of the web build (`scripts/build_libmpv_web.sh`). Everything runs on
the build's own outputs: no Docker, no network beyond 127.0.0.1.

## The module and the harness of the build

| file | what |
|---|---|
| `mak_spike.c` | the C harness: create, decode the fixtures to the end, filters, kit patches, cycles |
| `run_node.mjs`, `run_browser.sh` with `harness.html` and `serve_coi.py` | runs it in Node, Firefox or Chrome, cross-origin isolated |
| `lib_harness.mjs`, `run_lib_node.mjs` | drives the module (`libmpv.mjs`) from the calling thread |
| `run_native.sh` | the same C harness on a native libmpv, for the comparison |
| `make_fixtures.sh` | the inputs: fixtures of mpv_audio_kit and two 60 s files |

## http, https and blob: URLs (webio)

The web build reads http and https through fetch: `patches/ffmpeg/patch_ffmpeg_webio.py`
adds the protocols (`patches/ffmpeg/webio/webio.c`), `scripts/web/mak_webio.js`
is their JS side, on a pthread of their own. A `blob:` URL of the page opens
as `makblob://` followed by what comes after `blob:`.

| file | what |
|---|---|
| `net_server.py` | the page, cross-origin isolated, and media served as the protocol must cope with: Range, no Range, live chunked with ICY, redirect, slow answer, slow body, broken connection, HTTP error; the same media from a second origin with or without CORS |
| `net_harness.mjs`, `mpv_net_client.mjs` | mpv in the module opens each case and checks the end of file, seeks, ICY titles, stop and quit during a slow answer, timeouts, open errors, blob: URLs, open and close cycles; it measures read speed, first bytes against a direct fetch, memory and the main thread |
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
