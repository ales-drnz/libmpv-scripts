## [0.2.0] - unreleased

### Breaking
- On Linux and Android the library's SONAME is `libmpv_audio_kit.so`, so it no longer clashes with another plugin's libmpv. The release asset names are unchanged.
- The per-filter tap is keyed on chain labels instead of filter types: `analyzer-taps` and `audio-tap-frames` take and return labels, and two instances of one filter get separate rings.

### Changed
- Linux builds on Ubuntu 20.04, so the library needs glibc 2.31 instead of 2.38, and loads PipeWire and PulseAudio only when they are installed. Linux builds natively, one architecture per host.
- Linux keeps plain RELA relocations: RELR would need glibc 2.36.
- mpv's version string carries the release (`mpv v0.41.0+r15`), and a build writes `manifest.json` with the versions, the compiled filters and the hash of every library.

### Build
- Every source tarball is pinned by SHA-256, and CI stops on an unpinned one.
- A missing git tag stops the build instead of falling back to the default branch.

## [0.1.6] - 24-09-2026

### Fixed
- The bulk analysis re-opens a network source with mpv's own network options (`tls-verify`, `tls-ca-file`, `http-header-fields`, user agent, cookies, proxy), so the waveform and loudness scan no longer skip certificate verification or drop auth headers (mpv_audio_kit [#19](https://github.com/ales-drnz/mpv_audio_kit/issues/19)).
- The bulk waveform downmixes to mono with the same channel average as the progressive path, so peaks stay within `[-1, 1]` instead of reaching about 1.41 on correlated stereo.
- A cancelled analysis worker is joined only once, which could crash the process.
- The detached analysis threads are cancelled and drained before the last core is destroyed or the process exits, so they no longer decode while libav and TLS state are freed under them.

### Added
- `waveform-data` carries a per-bin `rms` array next to `min` and `max`, on the bulk, progressive and rolling paths (mpv_audio_kit [#20](https://github.com/ales-drnz/mpv_audio_kit/issues/20)).
- A GitHub Actions workflow builds every platform, Apple included, on each push to a release branch.

## [0.1.5] - 22-08-2026

### Fixed
- The Android binaries no longer pack their relative relocations as `DT_RELR`, which the Android linker ignores below API 30, leaving every relative pointer unrelocated and crashing libmpv on load (mpv_audio_kit [#16](https://github.com/ales-drnz/mpv_audio_kit/issues/16)). They now use APS2 packing, supported since API 23, which costs about 150 KB on each 64 bit binary.

### Changed
- `mpv_elf_size_ldflags` now takes the packing format as an argument, `android` or `relr`. Linux keeps `relr` and its flags are unchanged; `DT_RELR` stays safe there because glibc emits a `GLIBC_ABI_DT_RELR` version dependency, so an old loader refuses the library instead of crashing.

## [0.1.4] - 18-06-2026

### Changed
- The `timer_resolution` patch now forces mpv's high-resolution-timer policy to `never` (was `perwait`): the Windows libmpv no longer changes the system-wide 1 ms timer resolution at all.

## [0.1.3] - 16-06-2026

### Added
- Offline loudness analysis: a new toggleable `loudness_scan` patch measures whole-file EBU R128 (integrated LUFS, range, sample and true peak) on load (rides `bulk_analysis`, disabled with it).
- Embedded CA root store: a new toggleable `embed_cacert` patch compiles the Mozilla CA bundle into OpenSSL, so HTTPS verification needs no on-device cert file (sandboxed macOS, iOS, Android); `tls-ca-file` still overrides it.
- A Tools action in the build menu to refresh the bundled Mozilla CA list (`update_cacert.sh`).

### Fixed
- Windows UI micro-stutter: a new toggleable `timer_resolution` patch stops mpv pinning the system-wide 1 ms timer at init (it disrupted the compositor's frame pacing). No-op off Windows.

### Changed
- The `bulk_analysis`, `pcm_tap` and `filter_label_tap` patches now ship their C as real `.c` and `.h` files (Python appliers are anchor-only); binaries are byte-identical.

### Build
- Further binary size reduction on every platform: mpv orchestration code and the compression and infrastructure deps (`zlib`, `bzip2`, `xz`, `libxml2`) build at `-Os` and `-Oz` while codec and DSP code stays at `-O2`.

## [0.1.2] - 9-06-2026

### Fixed
- iOS and macOS `libmpv.framework` was signed with the wrong identifier which blocked physical-iPhone installs; the build scripts now sign with `--identifier`.

### Added
- `verify_binaries.sh` Layer 15: asserts each xcframework slice's code-signing identifier matches its `CFBundleIdentifier`.

## [0.1.1] - 9-06-2026

### Changed
- Audio-filter whitelist corrected (86 → 87): removed `headphone`, added `aintegral` and `asetrate`.
- The four size-reduction patches are now toggleable from Settings ▸ Patches, all default-on.

### Build
- Audio-only `libmpv` binaries are **~50–65% smaller** at full feature parity; the `mpv_*` API is unchanged.
- `verify_binaries.sh` gained a macOS `dlopen` test, an adaptive feature-presence layer, and per-slice validation.

## [0.1.0] - 05-06-2026

### Added
- Initial release of the build kit that compiles an audio-only `libmpv` for macOS, iOS, Linux, Windows and Android.
- A terminal menu (`./build`) to pick what to build and watch live progress.
- Verify, to audit every produced binary.
- Checksums, to install the binaries into the `mpv_audio_kit` package.
- A `local` and `remote` switch to choose whether `mpv_audio_kit` uses the local libs or downloads them from GitHub Releases.
- Settings to pick which audio decoders and filters are included, and a Dependencies list of the bundled libraries.
- A multi-stage Docker setup with one image per platform, and a Docker tab to build, size and delete them, so you only keep the toolchains you actually use.
