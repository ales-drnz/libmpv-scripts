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

## In CI

- `checks.yml` runs on a push to any branch but `release/` and `ci/`, and
  on every pull request, unless the commit changes only the documents:
  lint as warnings, `go vet` and `go test` of the TUI with the tests of
  `verify/tests`, and the native tests with AddressSanitizer. It needs no
  secret, so a pull request from a fork runs it too.
- `build.yml` builds everything on a push to `release/rN`, or by hand
  (`gh workflow run build.yml --ref <branch>`). It calls the jobs of
  `checks.yml` instead of copying them, and its release waits for the
  native ones.
- `check-mpv-audio-kit.yml` runs the tests of mpv_audio_kit against the
  binaries of a Build:

  ```bash
  gh workflow run check-mpv-audio-kit.yml --ref <branch> \
    -f libs_run=<Build run id> -f kit_ref=<kit branch> -f tags='[native]'
  ```

  Without `libs_run` it takes the latest successful Build of `release/rN`
  started by a push, `rN` being `LIBMPV_RELEASE` of that branch, and stops
  when there is none. A push to a `ci/` branch starts it too, with the
  tags, and `[libs_run <id>]` if needed, in the commit message.

  Without a tag it runs the kit's tests on macOS and Windows, the app builds
  and the iOS simulator. `[full check]` adds the Android emulators;
  `[android emu]`, `[native]` and the others at the top of the workflow
  run only their part, and leave the rest out. The Android emulators are
  API 24, 29 and 34 on phones, and API 36 on Android TV;
  `.github/diag/android_emulator.sh` runs the integration tests of the
  kit's `test_app` on each.

  A run that left jobs out is still green. Its Summary job lists every
  job with its result and the tag that left it out, and says whether the
  run is a complete check: `[full check]` with no other tag, every job
  green, on a Build started by a push to `release/rN`. The runners and
  Flutter are named by version in the workflow; a new Flutter is tried
  with `-f flutter=<version>` before the pin moves.

## Releases

Work goes to `wip/rN-<topic>` branches, and to `release/rN` once its CI is
green and the change has had a review. A push to `release/rN` builds the
release: `LIBMPV_RELEASE` must be `rN` there, or the first job stops.

1. The Build of `release/rN` is green, verify included. Its run id is the
   one of every step below: the libraries published are the ones checked.
2. A complete check of that Build is green:

   ```bash
   gh workflow run check-mpv-audio-kit.yml --ref release/rN \
     -f libs_run=<Build run id> -f tags='[full check]'
   .github/ci/release_gate.sh <Build run id>
   ```

   `release_gate.sh` exits 0 only when a check of that run was complete
   and green, and names it. A check of `[native]` or of another Build does
   not count, and a file that never started on a simulator or an emulator
   is run again first. No release without it: a later commit to
   `release/rN` is a new Build, and needs its own check.
3. The `libmpv-rN` release goes on `mpv_audio_kit` with the libraries,
   `libmpv_web.zip`, `licenses.zip` and `manifest.json` of the
   `libmpv-release` artifact of that run. Its notes come from the
   CHANGELOG.
4. The commit of that Build (`source.commit` of `manifest.json`) gets the
   annotated tag `libmpv-rN` here, so the source of the published binaries
   stays reachable once the branch is gone.
5. `release/rN` goes to `main` with the version in the CHANGELOG, that
   commit gets the annotated tag `vX.Y.Z`, and mpv_audio_kit runs
   `scripts/update_libmpv.sh rN`.

   ```bash
   git tag -a libmpv-rN <commit of the Build> -m 'Source of the libmpv-rN binaries (manifest commit)'
   git tag -a vX.Y.Z <release commit on main> -m 'libmpv-scripts X.Y.Z (libmpv-rN)'
   git push origin libmpv-rN vX.Y.Z
   ```

   A tag starts no workflow.

Each version of mpv_audio_kit runs on the one release of its pin
(`doc/adr` of the kit, record 0003): a fix of the binaries is a new `rN`,
never a new upload to an old one.
