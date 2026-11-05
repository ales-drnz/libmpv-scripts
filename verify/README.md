# verify

Checks of the built libraries and tests of the patches.

## `./build verify`

It checks every library in `builds/release/`:

- architecture, exported API, the patched mpv properties, the decoders and filters, the spdif muxer, the httpproxy, https and tls protocols;
- that no video code slipped in, and the libraries each one depends on;
- the license: neither `gpl` nor `rubberband` among mpv's features nor Rubber Band's code, and the license texts next to the library, in `licenses.zip` and in `manifest.json` (the opposite with `LIBMPV_GPL=1`);
- on Linux and Android: the SONAME, no `DT_RELR`, the 16 KB alignment of the 64-bit Android libraries, the glibc 2.31 floor;
- where the host can load it, it opens the library and calls into it;
- for `libmpv_web.zip`: the files, the record, a shared memory wasm under 12 MB, the exports, the patched properties, the FFmpeg patches, decoders and filters, mpv's version.

The report has one row per library. Enter shows the full log.

## The web module

```bash
verify/web/run_checks.sh <module dir> <spike dir> <fixtures dir> <work dir>
```

Node and each browser of `BROWSERS` (Chrome, Firefox) decode, filter, play through the `webaudio` output and read over http. See [`web/README.md`](web/README.md).

## Patch tests

```bash
bash verify/tests/native/run.sh <work dir>
```

It builds a debug libmpv with AddressSanitizer against the system FFmpeg, runs the C tests of the patched mpv, then the tests of the patch scripts. It needs meson, ninja, the `ffmpeg` command, the FFmpeg development files, those of libplacebo (mpv includes its headers) and those of SDL2 (`ao=sdl` on its dummy driver is the pull output of the tests), and takes a few minutes.

## Network tests

```bash
bash verify/tests/network_test.sh <work dir>
```

It builds libsmb2 and a minimal FFmpeg with AddressSanitizer and the network patches, then checks them against a local impacket SMB server, `openssl s_server` and a local HTTP server. It covers:

- the URL parsing;
- a stop while the server stalls, and the connect deadline;
- the embedded CA roots;
- an HTTP body cut short;
- the HLS and DASH segments lost to errors;
- the AAC priming of a fragmented MP4, skipped once and never cut at DASH segments.

It needs cmake, ninja, the OpenSSL and libxml2 development files, the `ffmpeg` command, and impacket for the python in `SMB_PYTHON`. It takes about two minutes.

## Identity after a refactor

```bash
bash verify/tests/patches/patch_identity_test.sh <reference root> <pristine mpv> <pristine ffmpeg> <pristine rubberband> <work dir>
```

Run it by hand. It checks that this tree's `patches/` and those of a reference revision (`git archive <rev> patches | tar -x`) make the same source trees, so a refactor of the patch scripts needs no rebuild. Pass `-` for the rubberband tree to leave out its case.
