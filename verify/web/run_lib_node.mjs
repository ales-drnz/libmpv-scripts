// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Runs lib_harness.mjs on the module (libmpv.mjs) in Node, from the main
// thread.
//
//   node run_lib_node.mjs <libmpv.mjs> file...
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runLibHarness } from './lib_harness.mjs';

const [modPath, ...paths] = process.argv.slice(2);
if (!modPath) {
  console.error('usage: node run_lib_node.mjs <libmpv.mjs> file...');
  process.exit(2);
}
const { default: factory } = await import(pathToFileURL(modPath).href);
const files = paths.map((p) => ({ name: basename(p), bytes: readFileSync(p) }));
const r = await runLibHarness(factory, files, (s) => console.log(s));
console.log(`measure node_rss_bytes ${process.memoryUsage().rss}`);
// The pthread workers keep the event loop alive.
process.exit(r.fail ? 1 : 0);
