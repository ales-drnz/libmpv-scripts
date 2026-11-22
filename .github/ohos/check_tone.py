# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""What the emulator's sound card played, as QEMU's wav audiodev wrote it,
for mpv_play_check.c: the fixture is 440 Hz for 3 s then 660 Hz, the
client plays past 2.5 s, seeks to 3.5 s and plays 1.5 s more. The WAV is
read in 50 ms windows, each a tone (its frequency from the zero crossings
of the first channel) or silence. Passes with at least 2 s of 440 Hz,
then at least 1 s of 660 Hz, and no 440 Hz window after the first 660 Hz
one: audio from before the seek, played after it, is a flush that kept
old frames.

Usage: python3 check_tone.py <wav> [prefix]
"""
import math
import struct
import sys

path = sys.argv[1]
prefix = sys.argv[2] if len(sys.argv) > 2 else 'MAK_OHOS_TONE'
# Read by hand: QEMU writes the sizes of the RIFF and data chunks only
# when it closes the file, and the emulator is still running.
raw = open(path, 'rb').read()
if raw[:4] != b'RIFF' or raw[8:12] != b'WAVE':
    print(f'{prefix} FAIL {path} is not a WAV file')
    sys.exit(1)
pos, rate, channels, width, frames = 12, 0, 0, 0, b''
while pos + 8 <= len(raw):
    cid, size = raw[pos:pos + 4], struct.unpack('<I', raw[pos + 4:pos + 8])[0]
    body = pos + 8
    if cid == b'fmt ':
        _, channels, rate, _, _, bits = struct.unpack('<HHIIHH', raw[body:body + 16])
        width = bits // 8
    elif cid == b'data':
        frames = raw[body:body + size] if size else raw[body:]
        break
    pos = body + size + (size & 1)
if width != 2:
    print(f'{prefix} FAIL {width * 8}-bit samples, the check reads 16-bit')
    sys.exit(1)
n = len(frames) // (2 * channels)
left = struct.unpack(f'<{n * channels}h', frames[:n * channels * 2])[::channels]

win = rate // 20
labels = []
for i in range(0, n - win + 1, win):
    w = left[i:i + win]
    rms = math.sqrt(sum(s * s for s in w) / win)
    if rms < 500:
        labels.append('-')
        continue
    rises = sum(1 for a, b in zip(w, w[1:]) if a < 0 <= b)
    freq = rises * rate / win
    labels.append('a' if abs(freq - 440) <= 40 else 'b' if abs(freq - 660) <= 40 else '?')

line = ''.join(labels)
a_first = line.find('a')
b_first = line.find('b')
a_secs = line.count('a') / 20
b_secs = line.count('b') / 20
stale = line.count('a', b_first) if b_first >= 0 else 0
other = line.count('?')
ok = a_secs >= 2 and b_secs >= 1 and 0 <= a_first < b_first and stale == 0
print(f'{prefix} {"PASS" if ok else "FAIL"} {n / rate:.2f} s at {rate} Hz x{channels}: '
      f'{a_secs:.2f} s of 440 Hz, then {b_secs:.2f} s of 660 Hz, '
      f'{stale} windows of 440 Hz after it, {other} other')
print(f'{prefix} windows {line}')
sys.exit(0 if ok else 1)
