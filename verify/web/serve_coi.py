#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Serves a directory for the W1 browser harness, cross-origin isolated.

Every response carries COOP same-origin and COEP require-corp (what Safari
needs; Chrome and Firefox take credentialless too), so SharedArrayBuffer and
the pthread workers are available. The page POSTs its JSON result to
/result; the server writes it to --result and exits. A POST to
/signal?name=<name> creates <result>.<name> for the runner (a user gesture
to make, a CPU sample to take). A GET with ?delay=<ms> waits that long
before it answers (a slow network for one file).

    python3 -I serve_coi.py --root <dir> --port 8123 --result <file>
"""
import argparse
import functools
import http.server
import re
import threading
import time


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        '.mjs': 'text/javascript',
        '.js': 'text/javascript',
        '.wasm': 'application/wasm',
    }

    def do_GET(self):
        m = re.search(r'[?&]delay=(\d{1,5})', self.path)
        if m:
            time.sleep(int(m.group(1)) / 1000)
        super().do_GET()

    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Cross-Origin-Resource-Policy', 'same-origin')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def do_POST(self):
        if self.path.startswith('/signal?name='):
            name = self.path.split('=', 1)[1]
            if not re.fullmatch(r'[a-z0-9-]{1,32}', name):
                self.send_error(400)
                return
            open(f'{self.server.result_path}.{name}', 'w').close()
            self.send_response(204)
            self.end_headers()
            return
        if self.path != '/result':
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with open(self.server.result_path, 'wb') as f:
            f.write(body)
        self.send_response(204)
        self.end_headers()
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--port', type=int, default=8123)
    ap.add_argument('--result', required=True)
    a = ap.parse_args()
    handler = functools.partial(Handler, directory=a.root)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', a.port), handler)
    server.result_path = a.result
    server.serve_forever()


if __name__ == '__main__':
    main()
