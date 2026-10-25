#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""The server of the webio tests (net_harness.mjs): the page and its files,
and media served the ways the protocol has to cope with.

Two origins: --port serves the page (COOP same-origin, COEP require-corp,
so the pthreads have SharedArrayBuffer) and the media; --port + 1 serves
the same media from another origin, with CORS as the query asks.

    python3 -I net_server.py --root <page dir> --media <dir> --port 8130 [--result <file>]

Media: /media/<mode>/<file under --media>?<query>
  range     Range honoured: 206 with Content-Range, 200 without Range
  norange   Range ignored: 200 with Content-Length
  live      200, chunked, no length, the file in a loop at rate bytes/s
            (default 48000). With icy=1 and Icy-MetaData: 1 in the request,
            icy-metaint 8192 and a StreamTitle "Mak title N" that changes
            every titlesecs (default 1)
  redirect  302 to the query's to (a path or a URL)
  slow      no answer for delay seconds (default 30), then as range
  trickle   the answer at once, then the body at 64 bytes/s
  status    the query's code (default 404)
  drop      as range, but the first answer of each tag breaks off after
            after bytes (default 500000): the connection closes
Query on any mode: cors=0 (no CORS headers), cors=1 (the default:
Access-Control-Allow-Origin, nothing exposed), cors=expose (Content-Range
and icy-* exposed too); hdrs=deny answers the preflight without
Access-Control-Allow-Headers; tag=<name> marks the request in the log.

GET /log returns the requests as JSON (/log?clear=1 empties it after).
POST /result writes the body to --result and stops the server.
"""
import argparse
import functools
import http.server
import json
import os
import re
import select
import socket
import threading
import time
import urllib.parse

LOG = []
LOG_LOCK = threading.Lock()
ICY_METAINT = 8192


def log_entry(**kw):
    kw['t'] = time.time()
    with LOG_LOCK:
        LOG.append(kw)
    return kw


class Handler(http.server.SimpleHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        '.mjs': 'text/javascript',
        '.js': 'text/javascript',
        '.wasm': 'application/wasm',
        '.m3u8': 'application/vnd.apple.mpegurl',
        '.mpd': 'application/dash+xml',
        '.flac': 'audio/flac',
        '.mp3': 'audio/mpeg',
    }

    def log_message(self, fmt, *args):
        pass

    # ── headers ──────────────────────────────────────────────────────────

    def cross(self):
        return self.server.server_address[1] != self.server.page_port

    def cors_headers(self, q):
        mode = q.get('cors', '1')
        if mode == '0':
            return
        self.send_header('Access-Control-Allow-Origin', '*')
        if mode == 'expose':
            self.send_header('Access-Control-Expose-Headers',
                             'Content-Range, Accept-Ranges, icy-metaint, icy-name, icy-genre, icy-br')

    def common(self, q):
        if self.cross():
            self.cors_headers(q)
        else:
            self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
            self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
            self.send_header('Cross-Origin-Resource-Policy', 'same-origin')
        self.send_header('Cache-Control', 'no-store')

    def end_headers(self):
        # The static files of the page (SimpleHTTPRequestHandler).
        if not getattr(self, 'media', False):
            self.common({})
        super().end_headers()

    # ── requests ─────────────────────────────────────────────────────────

    def parse(self):
        u = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        return u.path, q

    def entry(self, mode, rel, q, **kw):
        h = self.headers
        return log_entry(port=self.server.server_address[1], method=self.command,
                         mode=mode, file=rel, tag=q.get('tag'), range=h.get('Range'),
                         ua=h.get('User-Agent'), xmak=h.get('X-Mak-Test'),
                         icy=h.get('Icy-MetaData'), origin=h.get('Origin'),
                         status=None, bytes=0, aborted=False, **kw)

    def do_OPTIONS(self):
        self.media = True
        path, q = self.parse()
        e = self.entry('preflight', path, q, acrh=self.headers.get('Access-Control-Request-Headers'))
        self.send_response(204)
        e['status'] = 204
        if q.get('cors', '1') != '0':
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET')
            req = self.headers.get('Access-Control-Request-Headers')
            if req and q.get('hdrs') != 'deny':
                self.send_header('Access-Control-Allow-Headers', req)
        self.send_header('Content-Length', '0')
        super().end_headers()

    def do_GET(self):
        path, q = self.parse()
        if path == '/log':
            self.media = True
            with LOG_LOCK:
                body = json.dumps(LOG).encode()
                if q.get('clear') == '1':
                    LOG.clear()
            self.send_response(200)
            self.common(q)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            super().end_headers()
            self.wfile.write(body)
            return
        m = re.match(r'^/media/([a-z]+)/(.+)$', path)
        if not m:
            self.media = False
            return super().do_GET()
        self.media = True
        mode, rel = m.group(1), urllib.parse.unquote(m.group(2))
        e = self.entry(mode, rel, q)
        try:
            getattr(self, 'media_' + mode, self.media_unknown)(rel, q, e)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            e['aborted'] = True
            e['aborted_at'] = time.time()
            self.close_connection = True

    def do_POST(self):
        self.media = True
        if self.path != '/result' or not self.server.result_path:
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with open(self.server.result_path, 'wb') as f:
            f.write(body)
        self.send_response(204)
        self.send_header('Content-Length', '0')
        super().end_headers()
        threading.Thread(target=self.server.stop_all, daemon=True).start()

    # ── media ────────────────────────────────────────────────────────────

    def file(self, rel):
        root = os.path.realpath(self.server.media_root)
        p = os.path.realpath(os.path.join(root, rel))
        if not p.startswith(root + os.sep) or not os.path.isfile(p):
            return None
        return p

    def ctype(self, p):
        return self.guess_type(p)

    def media_unknown(self, rel, q, e):
        self.send_error(400)

    def media_status(self, rel, q, e):
        code = int(q.get('code', '404'))
        body = b'no\n'
        self.send_response(code)
        e['status'] = code
        self.common(q)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        super().end_headers()
        self.wfile.write(body)

    def media_redirect(self, rel, q, e):
        to = q.get('to', '/media/range/' + rel)
        self.send_response(302)
        e['status'] = 302
        self.common(q)
        self.send_header('Location', to)
        self.send_header('Content-Length', '0')
        super().end_headers()

    def send_body(self, f, start, length, e, rate=None):
        f.seek(start)
        left = length
        step = 65536 if not rate else max(1, rate // 20)
        while left > 0:
            chunk = f.read(min(step, left))
            if not chunk:
                break
            self.wfile.write(chunk)
            e['bytes'] += len(chunk)
            left -= len(chunk)
            if rate:
                time.sleep(len(chunk) / rate)

    def media_range(self, rel, q, e, ignore_range=False, rate=None):
        p = self.file(rel)
        if not p:
            return self.media_status(rel, {**q, 'code': '404'}, e)
        size = os.path.getsize(p)
        rng = None if ignore_range else self.headers.get('Range')
        start, end = 0, size - 1
        if rng:
            m = re.match(r'^bytes=(\d+)-(\d*)$', rng.strip())
            if not m:
                rng = None
            else:
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
                if start >= size:
                    self.send_response(416)
                    e['status'] = 416
                    self.common(q)
                    self.send_header('Content-Range', f'bytes */{size}')
                    self.send_header('Content-Length', '0')
                    super().end_headers()
                    return
        length = end - start + 1
        code = 206 if rng else 200
        self.send_response(code)
        e['status'] = code
        self.common(q)
        self.send_header('Content-Type', self.ctype(p))
        self.send_header('Content-Length', str(length))
        if not ignore_range:
            self.send_header('Accept-Ranges', 'bytes')
        if rng:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        super().end_headers()
        with open(p, 'rb') as f:
            self.send_body(f, start, length, e, rate)

    def media_drop(self, rel, q, e):
        key = (q.get('tag'), rel)
        with LOG_LOCK:
            first = key not in self.server.dropped
            self.server.dropped.add(key)
        if not first:
            return self.media_range(rel, q, e)
        p = self.file(rel)
        if not p:
            return self.media_status(rel, {**q, 'code': '404'}, e)
        size = os.path.getsize(p)
        after = int(q.get('after', '500000'))
        self.send_response(206 if self.headers.get('Range') else 200)
        e['status'] = 206 if self.headers.get('Range') else 200
        self.common(q)
        self.send_header('Content-Type', self.ctype(p))
        self.send_header('Content-Length', str(size))
        self.send_header('Accept-Ranges', 'bytes')
        if self.headers.get('Range'):
            self.send_header('Content-Range', f'bytes 0-{size - 1}/{size}')
        super().end_headers()
        with open(p, 'rb') as f:
            self.send_body(f, 0, after, e)
        e['dropped'] = True
        self.wfile.flush()
        self.connection.shutdown(socket.SHUT_RDWR)
        self.close_connection = True

    def media_norange(self, rel, q, e):
        self.media_range(rel, q, e, ignore_range=True)

    def media_trickle(self, rel, q, e):
        self.media_range(rel, q, e, rate=64)

    def client_gone(self):
        r, _, _ = select.select([self.connection], [], [], 0)
        if not r:
            return False
        try:
            return self.connection.recv(1, socket.MSG_PEEK) == b''
        except OSError:
            return True

    def media_slow(self, rel, q, e):
        until = time.time() + float(q.get('delay', '30'))
        while time.time() < until:
            if self.client_gone():
                e['aborted'] = True
                e['aborted_at'] = time.time()
                self.close_connection = True
                return
            time.sleep(0.05)
        self.media_range(rel, q, e)

    def chunk(self, data, e):
        self.wfile.write(b'%x\r\n%s\r\n' % (len(data), data))
        e['bytes'] += len(data)

    def media_live(self, rel, q, e):
        p = self.file(rel)
        if not p:
            return self.media_status(rel, {**q, 'code': '404'}, e)
        rate = int(q.get('rate', '48000'))
        icy = q.get('icy') == '1' and self.headers.get('Icy-MetaData') == '1'
        titlesecs = float(q.get('titlesecs', '1'))
        self.send_response(200)
        e['status'] = 200
        e['icy_sent'] = icy
        self.common(q)
        self.send_header('Content-Type', self.ctype(p))
        self.send_header('Transfer-Encoding', 'chunked')
        if q.get('icy') == '1':
            self.send_header('icy-name', 'Mak Test Radio')
            self.send_header('icy-genre', 'Test')
            self.send_header('icy-br', '192')
        if icy:
            self.send_header('icy-metaint', str(ICY_METAINT))
        super().end_headers()
        data = open(p, 'rb').read()
        pos = 0
        left = ICY_METAINT
        t0 = time.time()
        step = max(1024, rate // 20)
        last_title = None
        while True:
            take = data[pos:pos + step]
            if len(take) < step:
                take += data[:step - len(take)]
            pos = (pos + step) % len(data)
            if icy:
                out = bytearray()
                i = 0
                while i < len(take):
                    k = min(left, len(take) - i)
                    out += take[i:i + k]
                    i += k
                    left -= k
                    if not left:
                        title = f"Mak title {int((time.time() - t0) / titlesecs) + 1}"
                        if title != last_title:
                            meta = f"StreamTitle='{title}';".encode()
                            n = (len(meta) + 15) // 16
                            out += bytes([n]) + meta.ljust(n * 16, b'\0')
                            last_title = title
                        else:
                            out += b'\0'
                        left = ICY_METAINT
                take = bytes(out)
            self.chunk(take, e)
            time.sleep(step / rate)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    ap.add_argument('--media', required=True)
    ap.add_argument('--port', type=int, default=8130)
    ap.add_argument('--result')
    a = ap.parse_args()
    handler = functools.partial(Handler, directory=a.root)
    servers = [Server(('127.0.0.1', a.port + i), handler) for i in range(2)]

    def stop_all():
        for s in servers:
            s.shutdown()

    for s in servers:
        s.page_port = a.port
        s.media_root = a.media
        s.result_path = a.result
        s.stop_all = stop_all
        s.dropped = set()
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for t in threads:
        t.start()
    print(f'net_server: page http://127.0.0.1:{a.port}, other origin http://127.0.0.1:{a.port + 1}', flush=True)
    for t in threads:
        t.join()


if __name__ == '__main__':
    main()
