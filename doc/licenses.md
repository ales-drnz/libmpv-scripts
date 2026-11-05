# Licenses

## This repository

BSD-3-Clause ([`LICENSE`](../LICENSE)), except the files [`NOTICE`](../NOTICE) lists:

- The FFmpeg protocols, and the patch files that write or adapt mpv code, are LGPL-2.1-or-later like mpv and FFmpeg ([`LICENSE.LGPL-2.1`](../LICENSE.LGPL-2.1)).
- `tools/implib/` (Implib.so) is MIT.
- The Mozilla CA bundle `patches/ffmpeg/embed_cacert/cacert.pem` is MPL-2.0.

The upstream lines a patch script quotes to find its place stay under their project's license. So does every file a patch changes in an upstream tree.

## The libraries

The libraries are **LGPL-3.0-or-later**:

- mpv is built with `-Dgpl=false`, which leaves out the files mpv's `Copyright` lists as GPL-only.
- FFmpeg is built without `--enable-gpl` and with `--enable-version3`. Version 3 is needed because OpenSSL 3 is Apache-2.0, which is compatible with LGPLv3 but not with LGPLv2.1.
- Every other dependency is permissive or LGPL. The embedded CA bundle is MPL-2.0.

In short, the LGPLv3 lets an app of any license link the library on its conditions. The texts are the terms. Among the conditions, the app:

- ships the license texts;
- says that it uses libmpv and that libmpv is under the LGPL;
- provides the source of the library it ships (`README.txt` in `licenses.zip` names the commit of this repository and every upstream source);
- lets the user replace the library with one built from modified source.

Every target ships libmpv as a separate dynamic library or module. Whether an app meets these conditions on a given platform depends on how it is distributed. This repository makes no promise about it.

## `licenses.zip`

It is published with the libraries, with one folder per target. Each folder holds:

- the texts of mpv, FFmpeg and each library the build links into it, taken from the source trees of the versions built;
- the notice of the embedded CA bundle (not on the web);
- the texts of the toolchain runtimes the build links statically, when their license asks for a notice in a binary (from `scripts/shared/licenses`, which says where each comes from);
- this repository's `LICENSE`, `LICENSE.LGPL-2.1` and `NOTICE`;
- `README.txt`, with the commit of this repository and the URL and SHA-256 (or commit) of each source;
- `THIRD_PARTY_LICENSES.txt`, all of the above in one file, each under its name, version and SPDX id. An app can ship it as it is.

`manifest.json` names the license (`"license": "LGPL-3.0-or-later"`).

## Toolchain runtimes

| Target | Included | Why |
| :--- | :--- | :--- |
| Windows | mingw-w64 winpthreads and CRT (`-static`) | MIT, ZPL-2.1 and BSD ask for the notice in binary form |
| Android, Windows arm64, web | LLVM libc++, libc++abi, libunwind, compiler-rt | code older than the relicensing is still NCSA or MIT |
| Web | Emscripten JS glue and system libraries (MIT or NCSA), musl (MIT) | their notices |

Not included, because their licenses ask for no notice:

- GCC's libgcc and libstdc++ (Windows x86_64, Linux), under the GCC Runtime Library Exception;
- glibc's static start files, under the LGPL's linking exception;
- the compiler-rt builtins of Apple's clang, under the LLVM exception.

glibc on Linux and libc++ on Apple are system libraries, linked dynamically.

## The GPL build

Rubber Band (librubberband, GPL-2.0+) is left out, and with it FFmpeg's `rubberband` filter and mpv's `af=rubberband`. Pitch and tempo stay available through mpv's `pitch` and `speed` (`scaletempo2`) and the `atempo`, `asetrate` and `aresample` filters.

`LIBMPV_GPL=1` (or Settings ▸ License in the TUI) builds it in:

- FFmpeg gets `--enable-gpl --enable-librubberband`;
- mpv gets `-Dgpl=true -Drubberband=enabled`;
- every platform builds librubberband.

Such a library is **GPL-3.0-or-later**. An app that ships it is, as a whole, under the terms of the GPLv3, source included. Its record, manifest and texts say so.

The release workflow does not set it. `./build verify` fails an LGPL library that has `gpl` or `rubberband` among mpv's features. Clean `builds/work/` after switching, or the build stops on stages built with the other setting.
