#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Minimal HTTP file server with Range support and a byte rate limit, for the
native tests that read a file over HTTP. Logs one line per GET to stderr.

Usage: slow_http.py <dir> <port> <bytes per second> [cut] [option ...]

With cut, the first response that reaches byte offset cut of the file stops
there and closes the connection, and a request to resume from cut gets 503
with Content-Length 0 (a download cut short for good). The options:

  resume          a request that resumes from cut is served, so the
                  client's reconnect repairs the drop
  drop            a request that resumes from cut gets no reply: the
                  connection closes before the status line
  down            the server exits once the cut is sent, so every reconnect
                  is refused (the network is gone)
  outage          once the cut is sent, every request gets no reply, as with
                  drop, until a request for /up (answered 204) ends the
                  outage: a server that comes back
  norange         no Accept-Ranges, and a Range header is ignored (200 with
                  the whole file); cut stops every response
  nolength        the size is never told: no Content-Length, the body ends
                  when the connection closes, a range from 0 gets 200 and a
                  range past the end 416 without Content-Range
  chunked         a live stream: 200 with Transfer-Encoding: chunked (chunks
                  of 16384 bytes, then the last chunk of size 0), no
                  Content-Length, no Range support; cut stops every
                  response inside the chunk that holds it
  between         with chunked, cut stops at the last chunk boundary before
                  it instead
  close           with chunked, the response says Connection: close
  missing=<name>  that file answers 404
  cutfile=<name>  every response for that file stops at half of it

A range that starts at or past the end of the file gets 416.
"""
import http.server, os, sys, time, re
ROOT, PORT, RATE = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
CUT = 0
OPTS = {}
for a in sys.argv[4:]:
    if a.isdigit():
        CUT = int(a)
    elif a:
        k, _, v = a.partition('=')
        OPTS[k] = v
RESUME, NORANGE, NOLENGTH = 'resume' in OPTS, 'norange' in OPTS, 'nolength' in OPTS
DROP, DOWN, OUTAGE = 'drop' in OPTS, 'down' in OPTS, 'outage' in OPTS
CHUNKED, BETWEEN, CLOSE = 'chunked' in OPTS, 'between' in OPTS, 'close' in OPTS
TYPES = {'.flac': 'audio/flac', '.mp3': 'audio/mpeg', '.opus': 'audio/ogg', '.m3u8': 'application/vnd.apple.mpegurl',
         '.ts': 'video/mp2t', '.mpd': 'application/dash+xml', '.m4s': 'audio/mp4'}
cut_done = False
outage_over = False
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global cut_done, outage_over
        name = os.path.basename(self.path)
        if OUTAGE and self.path == '/up':
            outage_over = True
            sys.stderr.write('GET /up: outage over\n')
            self.send_response(204); self.send_header('Content-Length', '0'); self.end_headers()
            return
        if OUTAGE and cut_done and not outage_over:
            sys.stderr.write(f'GET {self.path} {self.headers.get("Range", "")} dropped (outage)\n')
            self.close_connection = True
            return
        p = os.path.join(ROOT, name)
        if name == OPTS.get('missing') or not os.path.isfile(p):
            sys.stderr.write(f'GET {self.path} 404\n')
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()
            return
        size = os.path.getsize(p)
        if CHUNKED:
            self.send_chunked(p, size)
            return
        start, end = 0, size - 1
        m = None if NORANGE else re.match(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        if m and NOLENGTH and int(m.group(1)) == 0:
            m = None
        if m:
            start = int(m.group(1)); end = int(m.group(2)) if m.group(2) else size - 1
        if m and start >= size:
            sys.stderr.write(f'GET {self.path} range={start}- 416\n')
            self.send_response(416)
            if not NOLENGTH:
                self.send_header('Content-Range', f'bytes */{size}')
            self.send_header('Content-Length', '0'); self.end_headers()
            return
        if CUT and cut_done and start == CUT and not RESUME:
            sys.stderr.write(f'GET {self.path} range={start}- {"dropped" if DROP else "refused"}\n')
            if DROP:
                self.close_connection = True
            else:
                self.send_response(503); self.send_header('Content-Length', '0'); self.end_headers()
            return
        # The offset this response stops at, 0 for none.
        stop = size // 2 if name == OPTS.get('cutfile') else 0
        if CUT and (NORANGE or not cut_done):
            stop = CUT
        if m:
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{end}/{"*" if NOLENGTH else size}')
        else:
            self.send_response(200)
        if not NOLENGTH:
            self.send_header('Content-Length', str(end - start + 1))
        else:
            self.send_header('Connection', 'close')
        if not NORANGE:
            self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Type', TYPES.get(os.path.splitext(name)[1], 'application/octet-stream'))
        self.end_headers()
        sys.stderr.write(f'GET {self.path} range={start}-{end}\n')
        with open(p, 'rb') as f:
            f.seek(start); left = end - start + 1; pos = start
            try:
                while left > 0:
                    n = min(16384, left)
                    if stop and pos < stop <= pos + n:
                        cut_done = cut_done or stop == CUT
                        self.wfile.write(f.read(stop - pos))
                        sys.stderr.write(f'CUT at {stop}\n')
                        if DOWN and stop == CUT:
                            self.wfile.flush(); sys.stderr.write('DOWN\n'); sys.stderr.flush()
                            os._exit(0)
                        break
                    b = f.read(n); self.wfile.write(b); left -= len(b); pos += len(b); time.sleep(len(b) / RATE)
            except (BrokenPipeError, ConnectionResetError):
                pass
    def send_chunked(self, p, size):
        self.protocol_version = 'HTTP/1.1'
        self.close_connection = True
        self.send_response(200); self.send_header('Transfer-Encoding', 'chunked')
        if CLOSE:
            self.send_header('Connection', 'close')
        self.send_header('Content-Type', TYPES.get(os.path.splitext(p)[1], 'application/octet-stream'))
        self.end_headers()
        sys.stderr.write(f'GET {self.path} chunked\n')
        with open(p, 'rb') as f:
            try:
                pos = 0
                while pos < size:
                    b = f.read(16384)
                    if CUT and pos + len(b) > CUT:
                        if not BETWEEN:
                            self.wfile.write(b'%x\r\n' % len(b) + b[:CUT - pos])
                        sys.stderr.write(f'CUT at {CUT if not BETWEEN else pos}\n')
                        return
                    self.wfile.write(b'%x\r\n' % len(b) + b + b'\r\n')
                    pos += len(b); time.sleep(len(b) / RATE)
                self.wfile.write(b'0\r\n\r\n')
            except (BrokenPipeError, ConnectionResetError):
                pass
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
