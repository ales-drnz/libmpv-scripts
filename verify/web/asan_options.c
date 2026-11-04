// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The AddressSanitizer defaults of a sanitized web module
// (WEB_SANITIZE=address in scripts/build_libmpv_web.sh). LeakSanitizer is
// off: the leaks the native tests suppress (verify/tests/native/lsan.supp)
// have no suppression list here yet, and run_asan.sh looks for memory
// errors. Linked into the module and the harness of that build only.
const char *__asan_default_options(void);
const char *__asan_default_options(void)
{
    return "detect_leaks=0";
}
