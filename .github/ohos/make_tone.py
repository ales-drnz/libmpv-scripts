# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""The fixture of mpv_play_check.c: 440 Hz for 3 s, then 660 Hz for 3 s,
44.1 kHz mono s16, as a WAV file (mpv reads it, and seeks in it exactly).

Usage: python3 make_tone.py <wav>
"""
import math
import struct
import sys
import wave

RATE = 44100
samples = []
for freq in (440, 660):
    for i in range(3 * RATE):
        samples.append(int(12000 * math.sin(2 * math.pi * freq * i / RATE)))
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(struct.pack(f'<{len(samples)}h', *samples))
