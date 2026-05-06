## [0.1.0] - 05-06-2026

### Added
- Initial release of the build kit that compiles an audio-only `libmpv` for macOS, iOS, Linux, Windows and Android.
- A terminal menu (`./build`) to pick what to build and watch live progress.
- Verify, to audit every produced binary.
- Checksums, to install the binaries into the `mpv_audio_kit` package.
- A `local` / `remote` switch to choose whether `mpv_audio_kit` uses the local libs or downloads them from GitHub Releases.
- Settings to pick which audio decoders and filters are included, and a Dependencies list of the bundled libraries.
- A multi-stage Docker setup with one image per platform, and a Docker tab to build, size and delete them — so you only keep the toolchains you actually use.
