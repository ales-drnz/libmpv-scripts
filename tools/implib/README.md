# Implib.so (vendored)

[Implib.so](https://github.com/yugr/Implib.so) by Yury Gribov, MIT license
(`LICENSE.txt`), at commit `a3e167cf978a5b8a38ec0f710d8c4331e8dcdd9a`
(2026-08-01). Only the generator and the x86_64 and aarch64 templates are
kept.

The Linux build uses it to turn libpipewire and libpulse into lazily loaded
stubs, so libmpv carries no hard dependency on either: the AO guards in
`patches/mpv/linux/patch_optional_audio_libs.py` check the library is there
before mpv calls into it, and hand the stubs the handle they opened.
