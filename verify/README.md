# verify

Checks of the built libraries and tests of the patches.

## `./build verify`

It checks every library in `builds/release/`:

- architecture, exported API, the patched mpv properties, the decoders and filters, the spdif muxer, the httpproxy, https and tls protocols;
- that no video code slipped in, and the libraries each one depends on;
- the license: neither `gpl` nor `rubberband` among mpv's features nor Rubber Band's code, and the license texts next to the library, in `licenses.zip` and in `manifest.json` (the opposite with `LIBMPV_GPL=1`);
- on Linux, Android, Tizen and webOS: the SONAME and no `DT_RELR`. On Android the 16 KB alignment of the 64-bit libraries. The glibc floor: 2.31 on Linux, 2.30 on Tizen, 2.39 on webOS;
- the hardening: on every ELF library a non-executable stack, RELRO, `BIND_NOW`, a stack canary and no `TEXTREL`; on the Windows DLLs `DYNAMIC_BASE`, `HIGH_ENTROPY_VA` and `NX_COMPAT`;
- where the host can load it, it opens the library and calls into it. The Tizen and webOS libraries load under qemu-user on the TVs' sysroot: the pinned Tizen 6.0 packages, and the sysroot taken out of LG's webOS NDK installer. Both are downloaded at the first run. LG's licence keeps the NDK and its sysroot on your machine;
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

- `UBSAN=1` also builds libmpv and the tests with two checks of UndefinedBehaviorSanitizer: a signed integer overflow, and a float out of the range of the integer it is cast to. A work dir keeps the setting it was built with. CI runs without it.
- A test of the `tsan` kind is built with ThreadSanitizer instead of AddressSanitizer and fails on a data race (`tap_tsan_test.c`). libmpv itself is not built with it.
- `audiotrack_test` needs `jni.h` of the NDK in `ANDROID_NDK_HOME`.

The kinds of test and how to add one are in [`doc/developing.md`](../doc/developing.md).

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

## Tests of the checks and of the tools

Each runs alone, with no library built, and the TUI job of `checks.yml` runs them all:

| Test | What it checks |
| :--- | :--- |
| `verify/tests/hardening_test.sh` | the hardening checks, on recorded `readelf` and `llvm-readobj` output of good and bad libraries, and on small libraries linked here when the host has `cc` and `readelf` |
| `verify/tests/l13_windows_test.sh` | how the exit code of the Windows load helper becomes pass, fail, warn or skip |
| `verify/tests/xcf_slices_test.sh` | the slices of an xcframework |
| `verify/tests/components_test.sh` | the markers of the spdif muxer and of the protocols |
| `verify/tests/manifest_test.sh` | `write_manifest.sh` against the build records |
| `verify/tests/release_branch_test.sh` | `LIBMPV_RELEASE` against the name of a release branch |
| `verify/tests/struct_layout_test.sh` | `verify/struct_layout.py`. It needs clang |
| `verify/tests/patches/anchor_engine_test.py` | the anchor engine of the patch scripts, the rule of the versioned markers included |
| `verify/tests/tizen_sysroot_test.py` | `scripts/tizen/tizen_sysroot.py`, without the network |
| `verify/tests/webos_ndk_test.sh` | `scripts/webos/webos_ndk.sh`: the same NDK version and SHA-256 as the Dockerfile, and an installer that is unpacked and never run |

`verify/tests/webos_l12_test.sh` runs in the `mpv-build-verify` image, after Verify in the Build workflow: a webOS library binds the 32-bit glibc of the NDK's sysroot only.

## Identity after a refactor

```bash
bash verify/tests/patches/patch_identity_test.sh <reference root> <pristine mpv> <pristine ffmpeg> <pristine rubberband> <work dir>
```

Run it by hand. It checks that this tree's `patches/` and those of a reference revision (`git archive <rev> patches | tar -x`) make the same source trees, so a refactor of the patch scripts needs no rebuild. Pass `-` for the rubberband tree to leave out its case.
