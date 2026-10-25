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
  norange         no Accept-Ranges, and a Range header is ignored (200 with
                  the whole file); cut stops every response
  nolength        no Content-Length: the body ends when the connection closes
  missing=<name>  that file answers 404
  cutfile=<name>  every response for that file stops at half of it
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
DROP, DOWN = 'drop' in OPTS, 'down' in OPTS
TYPES = {'.flac': 'audio/flac', '.mp3': 'audio/mpeg', '.m3u8': 'application/vnd.apple.mpegurl',
         '.ts': 'video/mp2t', '.mpd': 'application/dash+xml', '.m4s': 'audio/mp4'}
cut_done = False
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global cut_done
        name = os.path.basename(self.path)
        p = os.path.join(ROOT, name)
        if name == OPTS.get('missing') or not os.path.isfile(p):
            sys.stderr.write(f'GET {self.path} 404\n')
            self.send_response(404); self.send_header('Content-Length', '0'); self.end_headers()
            return
        size = os.path.getsize(p)
        start, end = 0, size - 1
        m = None if NORANGE else re.match(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
        if m:
            start = int(m.group(1)); end = int(m.group(2)) if m.group(2) else size - 1
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
            self.send_response(206); self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
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
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
