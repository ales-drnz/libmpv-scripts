# libmpv-scripts

#### Audio-only libmpv, built for every platform.

[![](https://img.shields.io/badge/libmpv--scripts-0.1.6-7DCFFF.svg?style=for-the-badge)](CHANGELOG.md)
[![](https://img.shields.io/badge/mpv-v0.41.0-orange.svg?style=for-the-badge)]()
[![](https://img.shields.io/badge/FFmpeg-8.1.1-green.svg?style=for-the-badge)]()
[![](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg?style=for-the-badge)](LICENSE)
[![](https://img.shields.io/github/stars/ales-drnz/libmpv-scripts?style=for-the-badge&logo=github&logoColor=white)](https://github.com/ales-drnz/libmpv-scripts)
[![](https://img.shields.io/discord/1485588004029333516?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/g2Qf4Mq9MP)
[![](https://img.shields.io/badge/Patreon-F96854?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/ales_drnz)
[![](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/ales.drnz)

The build scripts for the libmpv inside [`mpv_audio_kit`](https://pub.dev/packages/mpv_audio_kit). They compile [mpv](https://mpv.io) and FFmpeg without video, with a set of patches the package relies on (waveform, loudness scan, audio taps and more), for macOS, iOS, Android, Windows and Linux.

Everything runs from `./build`, a terminal menu where you pick the targets and follow the builds.

---

## Quick start

```bash
git clone https://github.com/ales-drnz/libmpv-scripts
git clone https://github.com/ales-drnz/mpv_audio_kit

cd libmpv-scripts
./build
```

On Windows use `build.cmd`. You need Go, plus Docker for Linux, Windows and Android, and Xcode for Apple targets.

---

## What it produces

| Platform | Architectures | File in `builds/release/` |
| :--- | :--- | :--- |
| macOS | arm64 and x86_64 (universal) | `libmpv_macos.xcframework.zip` |
| iOS | arm64 device, arm64 and x86_64 simulator | `libmpv_ios.xcframework.zip` |
| Android | arm64-v8a, armeabi-v7a, x86_64 | `libmpv_android-<abi>.so` |
| Linux | x86_64, aarch64 | `libmpv_linux-<arch>.so` |
| Windows | x86_64, arm64 | `libmpv_windows-<arch>.dll` |

Each library exports only the `mpv_*` C API and carries no video decoders. The versions of mpv, FFmpeg and every other dependency are pinned in `scripts/shared/_versions.sh`.

---

## Contents

*   [Quick start](#quick-start)
*   [What it produces](#what-it-produces)
*   [Visuals](#visuals)
*   [Guide](#guide)
    <details>
    <summary><a href="#1-requirements"><b>1. Requirements</b></a></summary>

    * [1.1 Tools](#11-tools)
    * [1.2 What each host can build](#12-what-each-host-can-build)
    * [1.3 Folder layout](#13-folder-layout)

    </details>

    <details>
    <summary><a href="#2-the-menu"><b>2. The menu</b></a></summary>

    * [2.1 Build](#21-build)
    * [2.2 Settings](#22-settings)
    * [2.3 Dependencies](#23-dependencies)

    </details>

    <details>
    <summary><a href="#3-building"><b>3. Building</b></a></summary>

    * [3.1 macOS and iOS](#31-macos-and-ios)
    * [3.2 Linux and Windows](#32-linux-and-windows)
    * [3.3 Android](#33-android)
    * [3.4 From the command line](#34-from-the-command-line)
    * [3.5 On GitHub Actions](#35-on-github-actions)

    </details>

    <details>
    <summary><a href="#4-using-the-binaries"><b>4. Using the binaries</b></a></summary>

    * [4.1 Installing into mpv_audio_kit](#41-installing-into-mpv_audio_kit)
    * [4.2 Local or downloaded libraries](#42-local-or-downloaded-libraries)
    * [4.3 Verifying](#43-verifying)
    * [4.4 Publishing a release](#44-publishing-a-release)

    </details>

    <details>
    <summary><a href="#5-how-it-works"><b>5. How it works</b></a></summary>
    </details>
*   [Troubleshooting](#troubleshooting)
*   [Project background](#project-background)

---

## Visuals

<p align="center">
  <img src="https://raw.githubusercontent.com/ales-drnz/libmpv-scripts/main/imgs/tui.gif" width="100%">
</p>

---

## Guide

### 1. Requirements

#### 1.1 Tools

| Tool | Needed for |
| :--- | :--- |
| [Go](https://go.dev/dl/) | always, it runs `./build` |
| [Docker](https://docs.docker.com/get-docker/) | Linux, Windows and Android (Android on macOS builds without it) |
| Xcode | macOS and iOS |

The Android NDK is downloaded by the build, you don't need to install it.

#### 1.2 What each host can build

| Host | Targets |
| :--- | :--- |
| macOS | all of them |
| Linux | all except macOS and iOS |
| Windows | all except macOS and iOS |

Apple targets need a Mac. Without one, [GitHub Actions](#35-on-github-actions) can build them for you.

#### 1.3 Folder layout

Building needs only this repo. Installing the results needs `mpv_audio_kit` next to it:

```
your-projects/
├── libmpv-scripts/
└── mpv_audio_kit/
```

If the package lives somewhere else, set `MPV_AUDIO_KIT_ROOT=/path/to/mpv_audio_kit`.

---

### 2. The menu

Run `./build`. Arrow keys move, Space selects, Enter confirms, Q quits. The keys for each screen are listed at the bottom. There are three screens, switched with B, S and D.

#### 2.1 Build

Three tabs:

- **Compile**: pick platforms and architectures, then press Build. Each build shows its progress, time and warning count, and Enter opens its log.
- **Tools**: install the results into `mpv_audio_kit` (Checksums), check them (Verify), switch the package between local and downloaded libraries, remove the bundled ones (Clean), and refresh the bundled CA certificates (Update CA).
- **Docker**: see, build or delete the Docker images. The image a build needs is created automatically the first time.

#### 2.2 Settings

Choose which audio decoders, audio filters and patches go into the build. Fewer decoders and filters make a smaller library, but a format you remove won't play. Your choices are saved separately from the defaults, and you can reset them at any time.

#### 2.3 Dependencies

Every library in the build, with its version and license.

---

### 3. Building

#### 3.1 macOS and iOS

On a Mac with Xcode:

```bash
./build macos          # universal xcframework
./build ios            # device and simulator xcframework
./build macos-arm64    # one architecture
```

#### 3.2 Linux and Windows

On any host with Docker running. Both architectures are cross-compiled inside the image:

```bash
./build linux          # x86_64 and aarch64
./build windows        # x86_64 and arm64
./build linux-x86_64   # one architecture
```

#### 3.3 Android

On macOS it builds directly on the host, which is the fastest option. Elsewhere it builds in Docker. The Docker tab can force Docker on macOS too.

```bash
./build android                  # all three ABIs
./build android-arm64-v8a        # one ABI
```

#### 3.4 From the command line

`./build` accepts targets as arguments and runs them in order, stopping at the first failure:

```bash
./build all            # everything this host can build, then checksums
./build macos verify   # build macOS, then verify it
./build list           # every target
```

These variables are passed to the Docker builds:

| Variable | Effect |
| :--- | :--- |
| `JOBS=N` | parallel jobs, all cores by default |
| `ENABLE_LTO_DEPS=0` | turn off link-time optimization for the dependencies |
| `FORCE_DOWNLOAD=1` | download the sources again |
| `KEEP_BUILD=1` | keep the build folders |
| `WIPE_ALL=1` | also delete the downloaded sources |

To build another version of a dependency, set `MPV_VERSION`, `FFMPEG_VERSION` and so on (see `scripts/shared/_versions.sh`).

#### 3.5 On GitHub Actions

Every push to a `release/` branch runs `.github/workflows/build.yml`, which builds all nine libraries on GitHub's runners, Apple included. The run ends with a `libmpv-release` artifact holding the libraries and a `SHA256SUMS` file.

---

### 4. Using the binaries

#### 4.1 Installing into mpv_audio_kit

```bash
./build checksums
```

This copies each library from `builds/release/` into the package (`Frameworks`, `jniLibs`, `libs`) and writes its SHA-256 into the package's build files: `build.gradle.kts`, the two `CMakeLists.txt`, the podspecs and `Package.swift`.

#### 4.2 Local or downloaded libraries

`mpv_audio_kit` can use the libraries copied into it, or download them from its GitHub releases.

| Command | Effect |
| :--- | :--- |
| `./build lib-local` | installs the local builds and makes every platform use them, never downloading |
| `./build lib-remote` | makes every platform download the release when the local copy is missing or doesn't match |
| `./build lib-clean` | removes the copied libraries from the package |

The switch edits the regions marked `mpvkit:` in the package's build files, so don't edit those by hand. Set it back to remote before publishing the package.

#### 4.3 Verifying

`./build verify` checks every library in `builds/release/`: architecture, exported API, the patched mpv properties, the included decoders and filters, that no video code slipped in, and the libraries it depends on. Where the host can load it, it also opens the library and calls into it. The report has one row per library, and Enter shows the full log.

#### 4.4 Publishing a release

1. Build all nine libraries, usually by pushing a `release/` branch (see [3.5](#35-on-github-actions)).
2. Create the `libmpv-rN` release on `mpv_audio_kit` and upload the libraries.
3. In `mpv_audio_kit`, set `RELEASE_VERSION` in `scripts/bump_version.sh` and run it, then run `./build checksums` from here.

---

### 5. How it works

`./build` is a small Go program ([Bubble Tea](https://github.com/charmbracelet/bubbletea)) that runs the shell scripts in `scripts/`, one per platform. Apple targets build with Xcode on the host. Linux, Windows and Android build inside a Docker image from `docker/Dockerfile`, which has one stage per platform, so you only keep the toolchains you use.

Each build downloads the pinned sources, applies the patches in `patches/` to mpv and FFmpeg, compiles only the audio parts, and strips the library down to the `mpv_*` API. Every patch finds its place by exact text and stops the build if upstream has changed underneath it.

---

## Troubleshooting

- **"Go not found"**: install Go and run again.
- **A Linux, Windows or Android build fails right away**: Docker isn't running.
- **macOS and iOS are greyed out**: they need a Mac with Xcode. GitHub Actions can build them instead.
- **"could not locate the mpv_audio_kit repo"**: clone it next to this folder or set `MPV_AUDIO_KIT_ROOT`.
- **The first Docker build is slow**: it is building the image, later builds reuse it.
- **Android in Docker is slow on Apple Silicon**: the NDK is x86_64 only. Build on the host (the default), or turn on Rosetta in Docker Desktop.

---

## Project background

The build pipeline, the Go TUI and the patches for mpv and FFmpeg were written with Claude Code.

---

*Developed by Alessandro Di Ronza*
