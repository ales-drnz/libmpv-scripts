// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// tap_tsan_test <mode>: tap_ring_test.c built with ThreadSanitizer (the tsan
// kind of run.sh), for its modes on several threads. A data race fails the
// mode.
//   rearm  a writer of label A while the taps go from A to X and back
//   race   a writer, three readers and the taps turned on and off
#include "tap_ring_test.c"
