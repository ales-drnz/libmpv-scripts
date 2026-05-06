// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

package main

import "strings"

func writeParts(b *strings.Builder, parts ...string) {
	for _, part := range parts {
		b.WriteString(part)
	}
}

func writeLine(b *strings.Builder, parts ...string) {
	writeParts(b, parts...)
	b.WriteByte('\n')
}
