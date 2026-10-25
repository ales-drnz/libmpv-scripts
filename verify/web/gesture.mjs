// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Clicks the page of a headless browser through its remote protocol: a
// trusted input event, which counts as the user gesture the autoplay policy
// waits for (audio_harness.mjs with gesture=1).
//
//   node gesture.mjs chrome <profile dir>   DevTools protocol, the port from
//                                           <profile>/DevToolsActivePort
//   node gesture.mjs firefox <port>         WebDriver BiDi on that port
//
// Node's global WebSocket, no dependency.

const [browser, where] = process.argv.slice(2);

function rpc(url) {
  const ws = new WebSocket(url);
  let next = 1;
  const pending = new Map();
  ws.onmessage = (e) => {
    const msg = JSON.parse(e.data);
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(`${msg.error}: ${msg.message ?? JSON.stringify(msg.error)}`));
      else resolve(msg.result);
    }
  };
  const open = new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = () => reject(new Error(`cannot connect to ${url}`));
  });
  return {
    open,
    call: (method, params = {}) => new Promise((resolve, reject) => {
      const id = next++;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    }),
    close: () => ws.close(),
  };
}

if (browser === 'chrome') {
  const { readFileSync } = await import('node:fs');
  const port = readFileSync(`${where}/DevToolsActivePort`, 'utf8').split('\n')[0];
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((t) => t.type === 'page');
  const c = rpc(page.webSocketDebuggerUrl);
  await c.open;
  for (const type of ['mousePressed', 'mouseReleased']) {
    await c.call('Input.dispatchMouseEvent', { type, x: 20, y: 20, button: 'left', clickCount: 1 });
  }
  c.close();
} else if (browser === 'firefox') {
  const c = rpc(`ws://127.0.0.1:${where}/session`);
  await c.open;
  await c.call('session.new', { capabilities: {} });
  const tree = await c.call('browsingContext.getTree', {});
  const context = tree.contexts[0].context;
  await c.call('input.performActions', {
    context,
    actions: [{
      type: 'pointer', id: 'mouse', parameters: { pointerType: 'mouse' },
      actions: [
        { type: 'pointerMove', x: 20, y: 20 },
        { type: 'pointerDown', button: 0 },
        { type: 'pointerUp', button: 0 },
      ],
    }],
  });
  c.close();
} else {
  console.error('usage: node gesture.mjs chrome <profile dir> | firefox <port>');
  process.exit(2);
}
console.log(`gesture: clicked the ${browser} page`);
process.exit(0);
