## [0.3.0] - Unreleased

### Breaking
- The playlist prefetch runs a new hook, `on_prefetch`, before it opens the next entry ahead of time, while the current one plays, with `prefetch-open-filename` and `prefetch-playlist-entry-id` readable during it. `on_load` runs once per entry, when it starts, instead of a second time for the prefetch (`patch_prefetch_hook.py`).
- `mpv_event_end_file` ends with two new fields, `mak_read_error` and `mak_skipped_segments`, so the struct is 8 bytes longer. A client that reads it through `mpv/client.h` needs nothing more.

### Added
- libmpv for the browser: `libmpv_web.zip`, a WebAssembly module built with Emscripten and pthreads that exports the mpv client API and `mak_pcm_*` (mpv_audio_kit [#26](https://github.com/ales-drnz/mpv_audio_kit/issues/26)). It reads `http://`, `https://` and `blob:` URLs through `fetch` (`patch_ffmpeg_webio.py`), plays through `ao=webaudio`, a ring an AudioWorklet plays, and states its ABI version and the layout of the client structs. The manifest lists it, and Verify and the Build check it in Chrome.
- A file cut short by a read error says so: `END_FILE` and the new `demuxer-read-error` tell it from a file that ended, and `demuxer-skipped-segments` counts the HLS and DASH segments lost to an error. FFmpeg reports the read errors it hid from mpv: a resume refused with an error reply and a chunked body that stops before its last chunk end with EIO instead of a complete file (`read_error` toggle).
- `waveform-duration-hint`, a per-file length in seconds: an HTTP stream that cannot seek and tells no length, such as a music server's transcode, decodes its waveform and loudness from mpv's cache (mpv_audio_kit [#29](https://github.com/ales-drnz/mpv_audio_kit/issues/29)). An entry whose per-file options differ only in it is still prefetched.

### Fixed
- The prefetch hook runs while the current file plays: the audio output no longer runs dry and `time-pos` no longer stands still while a client resolves the next URL, and `playlist-next` and `stop` no longer wait for it.
- A seek after a read error tries the read again, instead of serving the end of the file from the cache or never resuming the demuxer.
- A refused `http://` or `smb2://` connection fails at once on Windows, instead of after the network timeout: FFmpeg's poll over `select()` now waits for a failed connect in the exception set, where Winsock reports it (`patch_ffmpeg_winsock_poll.py`).
- An `af-command` that took is kept in the arguments of its filter, so a seek, a loop, a track switch, the next file or an `af` set rebuild the filter with its live value.
- The http reconnect puts its state back only for a body of known size: a body without `Content-Length` that ends at its connection's close no longer retries for seconds and ends with EIO.
- The end of a file with gapless audio is played to its last sample when a push output (ALSA, PulseAudio, the web output, `ao=null`) ran dry in its final buffer: mpv took the stopped output for played out, and `keep-open` parked with up to 0.4 s still queued, `time-pos` short of the end. The output is started again while audio waits in its queue, and before the drain at the end of a playlist (`gapless_tail` toggle).
- A DASH keep-alive refused for another host, as every segment redirected to a CDN is, logs at verbose level instead of a warning every few seconds.
- A patch script whose anchor moved leaves the tree as it was: every script now runs on one anchor engine, which checks all anchors before writing and reports each one that fails.
- The manifest lists the toggleable patches and the audio filters each build recorded, instead of those of the settings present when it ran.

### Build
- The TUI builds the web module (`./build web`) and lists the `read_error` toggle; Verify checks the web module and the traces of `read_error`.
- The native tests run the read error, hint, Windows poll and gapless tail cases, and stop when an mpv patch fails. The Android emulators run the media session tests of the kit, a call included.
- The Build pins its actions by commit, and Check mpv_audio_kit tells the kit's tests which libmpv release they check.
- Updated the stamp to `libmpv-r20`: `mpv-version` reads `mpv v0.41.0+r20`.

## [0.2.3] - 22-10-2026

### Fixed
- The waveform of an HTTP file decoded from the cache reads `decoding`, with the bins it reached as `coverage_bins` and `progress`, until `ready`, instead of `progressive` (mpv_audio_kit [#28](https://github.com/ales-drnz/mpv_audio_kit/issues/28), by [@erikjara](https://github.com/erikjara)). When the pass hands over to the re-open, `progress` starts again from 0.

## [0.2.2] - 19-10-2026

### Fixed
- While an `on_load` hook runs for the playlist prefetch, the playing file keeps its demuxer, so `dump-cache` no longer aborts and its tracks and metadata stay. `path` names the entry being loaded (`patch_prefetch_hook.py`).
- Two players in one process prefetch independently, and the prefetch skips an entry whose per-file options differ from the playing one, so its HTTP headers never reach the next host.
- `prefetch-state` turns `failed` as soon as the prefetch open fails, and going idle closes the prefetched file and resets the state.
- The waveform and the loudness scan no longer crash past 8 channels or on an MP3 that turns mono, and they describe the track that plays. An external track grows its waveform from playback.
- An `fd://` or `fdclose://` source, what an Android `content://` URI becomes, gets its waveform and loudness scan instead of `failed`.
- Stopping or leaving a file stops its analysis and download, whichever player of the process started it. Turning the loudness scan off stops a pass it ran alone, and a failed worker ends it as `failed`.
- The analysis follows the playback axis of a file whose timestamps do not start at zero, and an HTTP file whose duration is estimated past its end is analyzed from the cache instead of being downloaded again.
- Windows: the audio output closes on mpv's core thread when a core is destroyed, before the device watcher (`patch_hotplug_core_thread.py`).
- iOS: mpv no longer sets the `MoviePlayback` session mode at each output init, so the app keeps its own mode.
- `audio-spdif` passthrough works and https plays through an HTTP proxy: FFmpeg keeps its spdif muxer and the httpproxy protocol.
- FFmpeg audio filters such as chorus, pan and aiir refuse values that read or write out of their buffers, and live dynaudnorm and adrc commands no longer leak (`patch_ffmpeg_filter_bounds.py`).
- SMB honours FFmpeg's interrupt, so stop and quit no longer wait about 120 s for a silent server, and a close after a dropped connection no longer writes into freed memory.
- An `smb2://` URL reads the password from the authority only and keeps a `%` that starts no valid escape; a `%00` escape fails the open. With `network-timeout` 0 the SMB connect gets 30 s.
- The PCM tap starts over when the output changes channel count or rate, and stops copying audio when nobody reads it, keeping the frame of a pause.
- A live PCM entry with `loop-file` or an A-B loop on plays once to its end instead of spinning on a failing seek (`patch_pcm_stream.py`).
- A shorter `chapter-list` after a chapter seek no longer crashes in `chapter-metadata` (`patch_chapter_list_reset.py`).
- Android: the audiotrack output waits when there is nothing to play instead of spinning on a whole core, and feeds silence with `audio-stream-silence` (`patch_audiotrack.py`).
- Android: after audioserver dies, audiotrack reopens the output instead of a track that never starts. A pause keeps the audio and the position the track held instead of skipping 0.1 to 0.3 s.

### Changed
- The embedded CA bundle and the system store load only when TLS verification is on.

### Build
- Verify fails when the x86_64 DLL crashes or stalls under native Wine, and checks every library for the spdif muxer and the httpproxy, https and tls protocols.
- The macOS and iOS builds run on the `macos-26` image and log the Xcode, SDK and tool versions.
- The iOS audio session patch, the libsmb2 FFmpeg patch and `patch_prefetch_state.py` stop the build when an anchor is missing instead of shipping without the change.
- The patches have native tests: `verify/tests/native/run.sh` runs the C tests of the fixes on an AddressSanitizer libmpv, and `network_test.sh` checks SMB and TLS against local servers. The release waits for them.
- The TUI shows the per-slice, feature and code-signing checks of Verify, and its version follows this CHANGELOG. It lists the Android `audiotrack` patch, on by default.

### Docs
- The comments of the bulk analysis, the taps and the Android JNI bridge match the code.

## [0.2.1] - 15-10-2026

### Fixed
- A `playlist-remove` or `playlist-clear` sent from an `on_load` hook during the playlist prefetch no longer reads the freed entry: the prefetch keeps it until the hook returns and skips it when it was removed (`patch_prefetch_hook.py`).
- Two players tapping the same filter label no longer write one ring from two threads, which could write past its buffer. The tap writers share a lock that a single player never waits on.
- The tap and the progressive waveform keep every sample of a frame larger than 8192 floats, such as a FLAC block of 4608 stereo samples, so the tap PTS no longer drifts.
- Turning `waveform-enabled` off during a loudness scan no longer leaves `loudness-scan-data` on `scanning`: the scan restarts on its own.
- After a stop or a skip the cache-fed analysis stops decoding the old file and ends as `failed`, instead of leaving the waveform on `progressive` and the loudness on `scanning`.
- The SMB timeout is read in microseconds, as mpv passes it, so `network-timeout` applies to SMB too.

### Build
- Every mpv patch checks all its anchors before writing a file, and runs a second time without effect.
- Every build extracts a fresh FFmpeg tree. A second Windows build no longer fails on `--enable-libsmb2`.
- `filter_label_tap` builds without `bulk_analysis`, and the build warns when `bulk_analysis` runs without it.
- libiconv falls back to two GNU mirrors, checked against the same pin.
- The NDK, llvm-mingw and Hangover downloads are checked against their published hashes.
- CI uses the Node 24 actions, caches the Docker images and runs with a read-only token.
- `write_manifest.sh` also writes `SHA256SUMS`.

## [0.2.0] - 14-10-2026

### Breaking
- On Linux and Android the library's SONAME is `libmpv_audio_kit.so`, so it no longer clashes with another plugin's libmpv. The release asset names are unchanged.
- The per-filter tap is keyed on chain labels instead of filter types: `analyzer-taps` and `audio-tap-frames` take and return labels, and two instances of one filter get separate rings.
- The Checksums, libs and Clean actions are gone, since mpv_audio_kit 0.5.0 takes libmpv through its build hook. The new Manifest action writes `manifest.json`.

### Added
- Live PCM input: the mak-pcm protocol plays raw PCM that the app feeds through the exported `mak_pcm_*` functions, with no temp file or callback on an mpv thread (mpv_audio_kit [#27](https://github.com/ales-drnz/mpv_audio_kit/issues/27)). The analysis, the playlist prefetch and `force-seekable` never open it twice or skip its data.
- The raw audio demuxer passes live PCM on as it arrives instead of in 125 ms packets, and decodes a short packet at its real length.

### Fixed
- Removing or rebuilding a filter that holds the end of the file, such as `rubberband` in the last few hundred milliseconds, no longer stops playback there for good: mpv re-seeks to decode the end again (`patch_chain_eof.py`).
- The same holds right after a seek: a filter with a long look-ahead, such as `dynaudnorm`, can take a short file whole with its end before playback restarts, and replacing it then stalled playback for good after a fraction of a second (`patch_chain_eof.py`).
- A new audio filter whose first input is the end of the stream, as during the refresh seek of `patch_chain_eof.py`, passes it on and waits for data instead of building on a dummy float format. A filter that takes no float, such as `hdcd`, was disabled for good (`patch_lavfi_eof_passthrough.py`).
- PipeWire and PulseAudio stay loaded until the process exits: the stubs unloaded them from an exit handler, under the audio thread of an app that exits without destroying the player.
- The loudness scan of a Matroska file no longer reads -70 LUFS: it placed frames by their timestamps, rounded to 1 ms, so no block was complete. It now counts samples, and the waveform of an MP3 no longer ends one encoder delay short.
- The analysis of a local file gives the result of one decode of it: the parallel workers seeked with no pre-roll, so loudness and peaks drifted at each boundary. Each worker now decodes half a second before its region, and formats whose seek is not sample exact use one worker.
- The loudness scan of an MP2 file no longer crashes the process or reads garbage peaks: it converted the decoded samples as the probe's sample format, float, while the decoder outputs 16 bit.
- Enabling the waveform or the loudness scan while a file opens no longer opens it a second time: the scan starts once the file is loaded. An HTTP file was requested twice, and a Jellyfin HLS transcode could fail to open (mpv_audio_kit [#22](https://github.com/ales-drnz/mpv_audio_kit/issues/22)).

### Changed
- The waveform and loudness scan of an HTTP file that plays from its start decode it from mpv's demuxer cache instead of opening it again, so the file is downloaded once (mpv_audio_kit [#22](https://github.com/ales-drnz/mpv_audio_kit/issues/22)). When one clean pass from the start is not possible, such as after a seek past the cache, the analysis opens the file again as before, with the same result.
- Linux builds on Ubuntu 20.04, so the library needs glibc 2.31 instead of 2.38, plus ALSA (`libasound.so.2`). It loads PipeWire and PulseAudio only when they are installed, and skips a PipeWire older than 0.3.57 in favour of PulseAudio, then ALSA.
- Linux builds natively, one architecture per host: the menu greys out the other one, and `./build all` skips what the host cannot build.
- Linux keeps plain RELA relocations: RELR would need glibc 2.36.
- mpv's version string carries the release (`mpv v0.41.0+r16`), and a build writes `manifest.json` with the versions, the compiled filters and the hash of every library.

### Build
- Every source tarball, Windows included, is pinned by SHA-256, and every git source (libplacebo, libsmb2, PipeWire) by the commit of its tag. CI stops on an unpinned source and uploads the line to add.
- A missing git tag stops the build instead of falling back to the default branch.
- CI runs `scripts/verify_binaries.sh` on the nine libraries once they are built, and the verify image can load the foreign Linux arch.
- Verify also checks the SONAME, the absence of `DT_RELR`, the 16 KB alignment of the 64 bit Android libraries, the glibc 2.31 floor and every audio filter, and counts a failing tool as a failure.
- CI loads the Linux x86_64 library in a Debian 11 container without PipeWire and PulseAudio, lists the audio devices and plays a tone, falling through to ALSA and then the null output. The container falls back to archive.debian.org as Debian 11 moves there.
- The Android build stops on `DT_RELR` or on 64 bit libraries not aligned for 16 KB pages.
- The PipeWire and PulseAudio stubs come from Implib.so, vendored in `tools/implib`. They build without asserts, so no build path ends up in the library, and rebuild when `PIPEWIRE_VERSION` changes.

## [0.1.7] - 10-10-2026

### Fixed
- Windows: `playlist-prev-playlist` across two playlist files no longer aborts on the ta canary assertion. It appended a separator to a string that the previous append had moved (`patch_playlist_prev_dos_path.py`).
- Windows: destroying a libmpv core that had read `audio-device-list` no longer crashes the process or corrupts its heap. The device watcher (WASAPI, which is COM) was torn down on the thread destroying the core instead of the core thread that created it (`patch_hotplug_core_thread.py`).
- OpenSSL no longer cleans up from an exit handler, which ran before the analysis drain and freed TLS state under a running scan.
- When an analysis worker fails to start, the ones already running are stopped before the join instead of decoding their whole region.

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
