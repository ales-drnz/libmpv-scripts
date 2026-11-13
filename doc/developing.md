# Developing

How to change a patch of mpv or FFmpeg, test it, and release the
binaries. The README covers building and the menu; `verify/README.md`
lists each check with its requirements.

## The patches

`patches/` holds one Python script per patch, by project (`mpv/`,
`ffmpeg/`, `rubberband/`) and for mpv by platform (`shared/`, `android/`,
`apple/`, `ios/`, `linux/`, `web/`, `windows/`). The build scripts run
them on the pristine sources: `apply_mpv_patches_common` in
`scripts/shared/_audio_only.sh` for the patches of every platform, then each
platform script for its own.

A script edits by anchors, with the engine of `patches/_lib/anchor.py`: an
anchor is a piece of upstream text that must be found exactly, and the edit
replaces it. A missing or repeated anchor stops the build and leaves the
tree as it was, so an upstream change cannot slip a patch into the wrong
place.

```python
def apply(p):
    p.edits('player/playloop.c', [(old, new), ...])

anchor.main(apply, 'patch_example', marker='MAK_EXAMPLE_PATCH_V1')
```

The marker goes into the patched text: a file that has it is left alone,
so a second run changes nothing. A change to what a patch writes bumps its
marker (`_V2`). Each script states its problem and its fix in its
docstring; a new one does the same. Every script takes `--check` (all the
checks, nothing written) and `--list-anchors`.

## Testing a patch

A fix starts with a test that fails without it.

**Native tests**: `verify/tests/native/`, C programs run against a debug
libmpv with AddressSanitizer:

```bash
bash verify/tests/native/run.sh <work dir>                        # all
bash verify/tests/native/run.sh --reuse <work dir> keep_open_park_test:unload
DISABLED_PATCHES=keep_open_park bash verify/tests/native/run.sh --reuse <work dir> keep_open_park_test
```

The first run downloads mpv and FFmpeg and builds libmpv, a few minutes;
`--reuse` keeps them. `DISABLED_PATCHES` builds without a patch, to see
its test fail. The `CASES` table at the top of `run.sh` lists each test,
its kind and its modes:

- `lib`: linked with the patched libmpv, one process per mode;
- `unit`: includes one patched source file of mpv, with stubs around it,
  for a function no API reaches (`pull_pause_tail_test.c` and `buffer.c`);
- `audiotrack`: includes `ao_audiotrack.c` with its patch and a simulated
  JNI. It needs `jni.h` of the NDK in `ANDROID_NDK_HOME`.

A new test is a `.c` file in that folder and a row of `CASES`. It prints
`RESULT PASS` and exits 0; anything AddressSanitizer or LeakSanitizer finds
fails it.

The tests need the packages listed at the top of `run.sh`. On a host that
lacks them, an Ubuntu 24.04 container with them works. Give it
`--security-opt seccomp=unconfined`, and run the tests under
`setarch x86_64 -R`: AddressSanitizer fails under address randomization.

**Tests of the patch scripts**: `verify/tests/patches/`, run at the end of
`run.sh`. They apply the scripts to pristine sources and break each anchor
in turn (`anchor_corrupt_test.sh`). A script whose patched text changes
updates its test there (for `patch_audiotrack.py`, the `FIXES` list of
`audiotrack_patch_test.sh`).

**Network tests**: `verify/tests/network_test.sh`, for the FFmpeg patches
of HTTP, SMB, HLS and DASH.

**After a refactor of the scripts**: `patch_identity_test.sh` checks that
two revisions of `patches/` make the same trees, so no rebuild is needed.

## Hardening flags

The ELF builds of Linux, Tizen and webOS take their hardening from two
functions of `scripts/shared/_audio_only.sh`:

- `hardening_cflags`: `-fstack-protector-strong` and `-D_FORTIFY_SOURCE=2`.
  It is in the `CFLAGS` and `CXXFLAGS` every dependency reads, in FFmpeg's
  `--extra-cflags` and in mpv's `-Dc_args`. A dependency built with a
  `CFLAGS` of its own (bzip2) adds it by hand.
- `hardening_ldflags`: `-Wl,-z,relro,-z,now,-z,noexecstack`, in mpv's link
  arguments: full RELRO, so the GOT is read-only once the library is loaded.

meson drops the `CFLAGS` and `LDFLAGS` of the environment for a language
whose `-Dc_args` or `-Dc_link_args` is given, which is why mpv takes both
explicitly.

Android and Windows add nothing: the NDK already gives the canary, fortify,
full RELRO and `BIND_NOW`, and binutils and llvm-mingw set `DYNAMIC_BASE`,
`HIGH_ENTROPY_VA` and `NX_COMPAT`. The Windows DLLs have no stack canary.

Each build asserts its result (`assert_hardening`), and L16 of
`verify_binaries.sh` checks the shipped files again: a non-executable
`GNU_STACK`, `GNU_RELRO`, `BIND_NOW`, `__stack_chk_fail` among the undefined
symbols and no `TEXTREL` on ELF, the three DllCharacteristics on Windows.
`verify/tests/hardening_test.sh` runs those checks on good and bad samples.

## In CI

- `build.yml` builds everything on a push to `release/rN`, or by hand
  (`gh workflow run build.yml --ref <branch>`). Its native job runs the
  native tests with AddressSanitizer.
- `check-mpv-audio-kit.yml` runs the tests of mpv_audio_kit against the
  binaries of a Build:

  ```bash
  gh workflow run check-mpv-audio-kit.yml --ref <branch> \
    -f libs_run=<Build run id> -f kit_ref=<kit branch> -f tags='[native]'
  ```

  Without a tag it runs the kit's tests on macOS and Windows, the app builds
  and the iOS simulator. `[full check]` adds the Android emulators;
  `[android emu]`, `[native]` and the others at the top of the workflow
  run only their part. The Android emulators are API 24, 29 and 34 on
  phones, and API 36 on Android TV; `.github/diag/android_emulator.sh`
  runs the integration tests of the kit's `test_app` on each.

## Releases

Work goes to `wip/rN-<topic>` branches, and to `release/rN` once its CI is
green and the change has had a review. A push to `release/rN` builds the
release: `LIBMPV_RELEASE` must be `rN` there, or the first job stops.

1. The Build of `release/rN` is green, verify included.
2. The `libmpv-rN` release goes on `mpv_audio_kit` with the libraries,
   `libmpv_web.zip`, `licenses.zip` and `manifest.json` of the
   `libmpv-release` artifact. Its notes come from the CHANGELOG.
3. `release/rN` goes to `main`, and mpv_audio_kit runs
   `scripts/update_libmpv.sh rN`.

Each version of mpv_audio_kit runs on the one release of its pin
(`doc/adr` of the kit, record 0003): a fix of the binaries is a new `rN`,
never a new upload to an old one.
