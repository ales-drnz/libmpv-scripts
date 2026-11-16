#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
HTTP/1.1 file server that keeps its connections open, for the tests that
count how many a client makes. Every response has a Content-Length; a
connection stays open unless the request says Connection: close. Logs one
line per GET to stderr, with the number of its connection:

    GET <path> conn=<n>

Usage: keepalive_http.py <dir> <port>
"""
import http.server
import itertools
import os
import sys

ROOT, PORT = sys.argv[1], int(sys.argv[2])
CONNS = itertools.count(1)


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        self.conn = next(CONNS)

    def do_GET(self):
        p = os.path.join(ROOT, os.path.basename(self.path.split('?')[0]))
        sys.stderr.write(f'GET {self.path} conn={self.conn}\n')
        sys.stderr.flush()
        if not os.path.isfile(p):
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        with open(p, 'rb') as f:
            body = f.read()
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
