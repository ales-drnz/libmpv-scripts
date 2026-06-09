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
- A `local` / `remote` switch to choose whether `mpv_audio_kit` uses the local libs or downloads them from GitHub Releases.
- Settings to pick which audio decoders and filters are included, and a Dependencies list of the bundled libraries.
- A multi-stage Docker setup with one image per platform, and a Docker tab to build, size and delete them — so you only keep the toolchains you actually use.
