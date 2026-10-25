// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Runs net_harness.mjs on the module in Node, against a running
// net_server.py. Node's fetch has no CORS and no blob: URLs across threads,
// so the cases of the other origin and of blob: stay out.
//
//   node run_net_node.mjs <libmpv.mjs> <base URL> <fixtures dir> [case,...] [repeat]
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { runNetHarness } from './net_harness.mjs';

const [modPath, base, fixtures, cases, repeat] = process.argv.slice(2);
if (!modPath || !base || !fixtures) {
  console.error('usage: node run_net_node.mjs <libmpv.mjs> <base URL> <fixtures dir> [case,...] [repeat]');
  process.exit(2);
}
const { default: factory } = await import(pathToFileURL(modPath).href);
const r = await runNetHarness(factory, {
  base,
  cross: null,
  browser: false,
  fixture: async (name) => readFileSync(join(fixtures, name)),
  cases: cases ? cases.split(',') : null,
  repeat: repeat ? Number(repeat) : 3,
  verbose: process.env.MAK_NET_VERBOSE === '1',
}, (s) => console.log(s));
console.log(`measure node_rss_bytes ${process.memoryUsage().rss}`);
// The pthread workers keep the event loop alive.
process.exit(r.fail ? 1 : 0);
