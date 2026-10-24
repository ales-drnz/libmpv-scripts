#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Serves a directory for the W1 browser harness, cross-origin isolated.

Every response carries COOP same-origin and COEP require-corp (what Safari
needs; Chrome and Firefox take credentialless too), so SharedArrayBuffer and
the pthread workers are available. The page POSTs its JSON result to
/result; the server writes it to --result and exits.

    python3 -I serve_coi.py --root <dir> --port 8123 --result <file>
"""
import argparse
import functools
import http.server
import threading


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        '.mjs': 'text/javascript',
        '.js': 'text/javascript',
        '.wasm': 'application/wasm',
    }

    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Cross-Origin-Resource-Policy', 'same-origin')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def do_POST(self):
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
