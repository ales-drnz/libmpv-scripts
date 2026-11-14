#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Writes the files of fixtures.sh that no encoder makes: a header that says
something else than the data after it.

Usage: hostile_files.py join <first.flac> <second.flac> <out.flac>
       hostile_files.py declare <in.flac> <samples> <out.flac>
       hostile_files.py wav <seconds declared> <out.wav>

join     one FLAC stream out of two files of the same rate, sample size and
         block size: the frames of the second follow those of the first,
         numbered on from them, and the STREAMINFO of the first declares the
         samples of both. Each frame keeps the channel count of its own
         file, so the count changes inside one stream, at a known sample,
         with timestamps that go on: what a seek into the second part needs
         to land where it asked. Every frame of the first file must be a
         whole block.
declare  the same file with another number of samples in its STREAMINFO.
wav      3 s of a 1 kHz sine at -20 dBFS, 48 kHz stereo 16-bit, in a WAV
         whose header declares more: a RIFF size for the seconds given, or
         RF64 with a ds64 chunk past 4 GB. FFmpeg cuts a RIFF size to the
         size of the file when it knows it, and believes a ds64 chunk.
"""
import math
import struct
import sys


def crc_table(poly, bits):
    top = 1 << (bits - 1)
    mask = (1 << bits) - 1
    table = []
    for n in range(256):
        c = n << (bits - 8)
        for _ in range(8):
            c = ((c << 1) ^ poly) if c & top else (c << 1)
        table.append(c & mask)
    return table


CRC8 = crc_table(0x07, 8)
CRC16 = crc_table(0x8005, 16)


def crc8(data):
    c = 0
    for b in data:
        c = CRC8[c ^ b]
    return c


def crc16(data):
    c = 0
    for b in data:
        c = ((c << 8) & 0xFFFF) ^ CRC16[(c >> 8) ^ b]
    return c


def utf8_number(value):
    """The frame number as FLAC writes it: UTF-8 extended to 36 bits."""
    if value < 0x80:
        return bytes([value])
    for length in range(2, 8):
        if value < 1 << (5 * length + 1):
            break
    out = [0x80 | (value >> (6 * i)) & 0x3F for i in range(length - 1)]
    lead = (0xFF << (8 - length)) & 0xFF | value >> (6 * (length - 1))
    return bytes([lead] + out[::-1])


def parse_header(data, at):
    """(header length, frame number, channels, block size code) or None."""
    if at + 6 > len(data) or data[at] != 0xFF or data[at + 1] != 0xF8:
        return None
    size_code, rate_code = data[at + 2] >> 4, data[at + 2] & 15
    channels, sample_size = data[at + 3] >> 4, (data[at + 3] >> 1) & 7
    if size_code == 0 or rate_code == 15 or channels > 10 or sample_size in (3, 7) or data[at + 3] & 1:
        return None
    first = data[at + 4]
    length = 1
    if first & 0x80:
        length = 8 - (first ^ 0xFF).bit_length()
        if length < 2 or length > 7:
            return None
    number = first & (0x7F >> length if length > 1 else 0x7F)
    for i in range(1, length):
        b = data[at + 4 + i] if at + 4 + i < len(data) else 0
        if b & 0xC0 != 0x80:
            return None
        number = number << 6 | b & 0x3F
    end = at + 4 + length
    end += {6: 1, 7: 2}.get(size_code, 0) + {12: 1, 13: 2, 14: 2}.get(rate_code, 0)
    if end >= len(data) or crc8(data[at:end]) != data[end]:
        return None
    return end + 1 - at, number, 2 if channels > 7 else channels + 1, size_code


def frames(data):
    """The frames after the metadata: (offset, length, header) of each."""
    if data[:4] != b"fLaC":
        sys.exit("not a FLAC file")
    at = 4
    while True:
        last, length = data[at] & 0x80, int.from_bytes(data[at + 1:at + 4], "big")
        at += 4 + length
        if last:
            break
    starts = [i for i in range(at, len(data) - 1)
              if data[i] == 0xFF and data[i + 1] == 0xF8 and parse_header(data, i)]
    starts.append(len(data))
    out = []
    k = 0
    while k < len(starts) - 1:
        # A sync code inside a frame is no frame: the one that ends this
        # frame is the first whose CRC-16 closes it.
        for j in range(k + 1, len(starts)):
            body = data[starts[k]:starts[j]]
            if len(body) > 2 and crc16(body[:-2]) == int.from_bytes(body[-2:], "big"):
                out.append((starts[k], len(body), parse_header(data, starts[k])))
                k = j
                break
        else:
            sys.exit(f"no frame ends after offset {starts[k]}")
    return at, out


def set_samples(head, samples):
    """The STREAMINFO of [head] with [samples] and no MD5."""
    head = bytearray(head)
    head[21] = head[21] & 0xF0 | samples >> 32 & 0x0F
    head[22:26] = (samples & 0xFFFFFFFF).to_bytes(4, "big")
    head[26:42] = bytes(16)
    return head


def samples_of(head):
    return (head[21] & 0x0F) << 32 | int.from_bytes(head[22:26], "big")


def join(first, second, out):
    a = open(first, "rb").read()
    b = open(second, "rb").read()
    a_audio, a_frames = frames(a)
    _, b_frames = frames(b)
    if {f[2][3] for f in a_frames} | {f[2][3] for f in b_frames[:-1]} != {a_frames[0][2][3]}:
        sys.exit("the frames are not all of one block size")
    if a[18:21] != b[18:21] and (a[18:20] != b[18:20] or (a[20] ^ b[20]) & 0xF1):
        sys.exit("the files differ in rate or sample size")
    parts = [set_samples(a[:a_audio], samples_of(a) + samples_of(b))]
    parts += [a[at:at + length] for at, length, _ in a_frames]
    for at, length, (head_len, number, _, _) in b_frames:
        old = len(utf8_number(number))
        head = b[at:at + 4] + utf8_number(number + len(a_frames)) + b[at + 4 + old:at + head_len - 1]
        frame = head + bytes([crc8(head)]) + b[at + head_len:at + length - 2]
        parts.append(frame + crc16(frame).to_bytes(2, "big"))
    open(out, "wb").write(b"".join(parts))
    print(f"{out}: {len(a_frames)} frames of {a_frames[0][2][2]} channels, "
          f"{len(b_frames)} of {b_frames[0][2][2]}, {samples_of(a) + samples_of(b)} samples")


def declare(src, samples, out):
    data = open(src, "rb").read()
    if data[:4] != b"fLaC":
        sys.exit("not a FLAC file")
    open(out, "wb").write(set_samples(data[:42], samples) + data[42:])


def wav(seconds, out):
    rate = 48000
    amp = 32767 * 10 ** (-20 / 20)
    pcm = b"".join(struct.pack("<hh", *[round(amp * math.sin(2 * math.pi * 1000 * n / rate))] * 2)
                   for n in range(3 * rate))
    declared = int(seconds * rate) * 4
    fmt = b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, rate, rate * 4, 4, 16)
    if declared + 36 < 1 << 32:
        head = b"RIFF" + struct.pack("<I", declared + 36) + b"WAVE" + fmt
        head += b"data" + struct.pack("<I", declared)
    else:
        head = b"RF64" + struct.pack("<I", 0xFFFFFFFF) + b"WAVE"
        head += b"ds64" + struct.pack("<IQQQI", 28, declared + 72, declared, declared // 4, 0)
        head += fmt + b"data" + struct.pack("<I", 0xFFFFFFFF)
    open(out, "wb").write(head + pcm)


def main(argv):
    if len(argv) == 5 and argv[1] == "join":
        join(argv[2], argv[3], argv[4])
    elif len(argv) == 5 and argv[1] == "declare":
        declare(argv[2], int(argv[3]), argv[4])
    elif len(argv) == 4 and argv[1] == "wav":
        wav(float(argv[2]), argv[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
