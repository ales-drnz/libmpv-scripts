// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Runs the W1 harness module (spike.mjs, from verify/web/mak_spike.c) in
// Node, where Emscripten's pthreads are worker_threads.
//
//   node run_node.mjs <spike.mjs> [-n loops] [-x step]... [-a af] [-l long_file]... file...
//
// The host files are copied into WasmFS under /in and the arguments point
// there. The exit status is the harness's.
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { basename } from 'node:path';
import { pathToFileURL } from 'node:url';

// Counts the workers the glue makes: the pool, plus one per thread created
// while the pool was empty. The glue takes Worker from this same object.
const workerThreads = createRequire(import.meta.url)('node:worker_threads');
const RealWorker = workerThreads.Worker;
let workersCreated = 0;
workerThreads.Worker = class extends RealWorker {
  constructor(...a) {
    super(...a);
    workersCreated++;
  }
};

const [modPath, ...args] = process.argv.slice(2);
if (!modPath) {
  console.error('usage: node run_node.mjs <spike.mjs> [-n loops] [-x step]... [-a af] [-l long]... file...');
  process.exit(2);
}
const files = [];
const mainArgs = [];
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '-n' || a === '-x' || a === '-a') {
    mainArgs.push(a, args[++i]);
  } else if (a === '-l') {
    const f = args[++i];
    files.push(f);
    mainArgs.push('-l', `/in/${basename(f)}`);
  } else {
    files.push(a);
    mainArgs.push(`/in/${basename(a)}`);
  }
}

const t0 = performance.now();
const { default: factory } = await import(pathToFileURL(modPath).href);
const mod = await factory({
  print: (s) => console.log(s),
  printErr: (s) => console.error(s),
  onExit: (code) => {
    const rss = process.memoryUsage().rss;
    console.log(`measure node_rss_bytes ${rss}`);
    console.log(`measure workers_created ${workersCreated}`);
    console.log(`node: harness exit ${code}`);
  },
});
console.log(`measure instantiate_ms ${(performance.now() - t0).toFixed(3)}`);
mod.FS.mkdir('/in');
for (const f of files) mod.FS.writeFile(`/in/${basename(f)}`, readFileSync(f));
mod.callMain(mainArgs);
