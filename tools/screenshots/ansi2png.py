#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
"""Draws the ANSI text of a terminal screen as a PNG, cell by cell.

    ansi2png.py <in.ans> <out.png> --font <regular.ttf> [--bold <bold.ttf>]
                [--fallback <other.ttf>] [--cols N] [--title TEXT]

render.sh feeds it the screens of the TUI for the README. A dark window
with a title bar; the 16 basic colors, the 256 and truecolor ones, bold,
faint, underline and reverse. Each cell is drawn at its own position and
the box lines and blocks are drawn as shapes, so they meet from cell to
cell whatever the font's metrics. A run of blank rows is drawn as one.
Needs Pillow and fontTools.
"""
import re
import sys
import unicodedata

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont


def option(name, default=None):
    args = sys.argv[3:]
    return args[args.index(name) + 1] if name in args else default


src, dst = sys.argv[1], sys.argv[2]
cols = int(option('--cols', '120'))
title = option('--title', '')
regular_path = option('--font')
if not regular_path:
    sys.exit('ansi2png.py: --font <regular.ttf> is required')

SCALE = 2
SIZE = 15 * SCALE
regular = ImageFont.truetype(regular_path, SIZE)
bold = ImageFont.truetype(option('--bold', regular_path), SIZE)
# The glyphs the main font lacks come from a second one.
fallback = ImageFont.truetype(option('--fallback', regular_path), SIZE)
have = TTFont(regular_path).getBestCmap()

CW = round(regular.getlength('M'))
ascent, descent = regular.getmetrics()
CH = ascent + descent
BG, FG = (26, 27, 38), (192, 202, 245)
BASIC = [
    (21, 22, 30), (247, 118, 142), (158, 206, 106), (224, 175, 104),
    (122, 162, 247), (187, 154, 247), (42, 157, 190), (169, 177, 214),
    (65, 72, 104), (247, 118, 142), (158, 206, 106), (224, 175, 104),
    (122, 162, 247), (187, 154, 247), (125, 207, 255), (255, 255, 255),
]
PLAIN = dict(fg=None, bg=None, bold=False, faint=False, under=False, rev=False)
# Box lines as arms from the centre of the cell: left, right, up, down.
ARMS = {
    '─': 'lr', '│': 'ud', '╭': 'rd', '╮': 'ld', '╰': 'ru', '╯': 'lu',
    '┌': 'rd', '┐': 'ld', '└': 'ru', '┘': 'lu', '├': 'udr', '┤': 'udl',
    '┬': 'lrd', '┴': 'lru', '┼': 'lrud',
}


def xterm(n):
    if n < 16:
        return BASIC[n]
    if n < 232:
        n -= 16
        return tuple(0 if v == 0 else 55 + 40 * v for v in (n // 36, n // 6 % 6, n % 6))
    gray = 8 + 10 * (n - 232)
    return (gray, gray, gray)


def apply_sgr(st, params):
    k = 0
    while k < len(params):
        c = params[k]
        if c == 0:
            st = dict(PLAIN)
        elif c == 1:
            st['bold'] = True
        elif c == 2:
            st['faint'] = True
        elif c == 4:
            st['under'] = True
        elif c == 7:
            st['rev'] = True
        elif c == 22:
            st['bold'] = st['faint'] = False
        elif c == 24:
            st['under'] = False
        elif c == 27:
            st['rev'] = False
        elif 30 <= c <= 37:
            st['fg'] = BASIC[c - 30]
        elif 90 <= c <= 97:
            st['fg'] = BASIC[c - 82]
        elif c == 39:
            st['fg'] = None
        elif 40 <= c <= 47:
            st['bg'] = BASIC[c - 40]
        elif 100 <= c <= 107:
            st['bg'] = BASIC[c - 92]
        elif c == 49:
            st['bg'] = None
        elif c in (38, 48):
            key = 'fg' if c == 38 else 'bg'
            if params[k + 1] == 2:
                st[key] = tuple(params[k + 2:k + 5])
                k += 4
            else:
                st[key] = xterm(params[k + 2])
                k += 2
        k += 1
    return st


def cells(line):
    """The characters of a line, each with the style in force at it."""
    st, out, at = dict(PLAIN), [], 0
    for m in re.finditer(r'\x1b\[([0-9;]*)m|\x1b\[[0-9;?]*[A-Za-z]', line):
        out += [(ch, dict(st)) for ch in line[at:m.start()]]
        at = m.end()
        if m.group(1) is not None:
            st = apply_sgr(st, [int(x) if x else 0 for x in m.group(1).split(';')])
    return out + [(ch, dict(st)) for ch in line[at:]]


def blank(row):
    return not ''.join(ch for ch, _ in row).strip()


def blend(color, k):
    return tuple(round(a * k + b * (1 - k)) for a, b in zip(color, BG))


rows = [cells(line)[:cols] for line in open(src, encoding='utf-8').read().split('\n')]
while rows and blank(rows[-1]):
    rows.pop()
rows = [r for i, r in enumerate(rows) if not (blank(r) and i and blank(rows[i - 1]))]

PAD, BAR = 22 * SCALE, 38 * SCALE
W, H = cols * CW + 2 * PAD, len(rows) * CH + BAR + PAD + PAD // 2
img = Image.new('RGBA', (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle([0, 0, W - 1, H - 1], radius=12 * SCALE, fill=BG,
                    outline=(41, 46, 66), width=SCALE)
for n, color in enumerate([(247, 118, 142), (224, 175, 104), (158, 206, 106)]):
    x = PAD + n * 20 * SCALE
    d.ellipse([x, BAR // 2 - 6 * SCALE, x + 12 * SCALE, BAR // 2 + 6 * SCALE], fill=color)
if title:
    d.text(((W - regular.getlength(title)) / 2, BAR / 2 - CH / 2), title,
           font=regular, fill=(86, 95, 137))

for r, row in enumerate(rows):
    col, y = 0, BAR + r * CH
    for ch, st in row:
        wide = 2 if unicodedata.east_asian_width(ch) in 'WF' else 1
        fg, bg = st['fg'] or FG, st['bg']
        if st['rev']:
            fg, bg = (bg or BG), fg
        if st['faint']:
            fg = blend(fg, 0.55)
        px = PAD + col * CW
        cx, cy = px + CW // 2, y + CH // 2
        if bg:
            d.rectangle([px, y, px + wide * CW - 1, y + CH - 1], fill=bg)
        arms = ARMS.get(ch)
        if arms:
            if 'l' in arms:
                d.line([px, cy, cx, cy], fill=fg, width=SCALE)
            if 'r' in arms:
                d.line([cx, cy, px + CW, cy], fill=fg, width=SCALE)
            if 'u' in arms:
                d.line([cx, y, cx, cy], fill=fg, width=SCALE)
            if 'd' in arms:
                d.line([cx, cy, cx, y + CH], fill=fg, width=SCALE)
        elif ch in '█░':
            d.rectangle([px, y, px + CW - 1, y + CH - 1],
                        fill=fg if ch == '█' else blend(fg, 0.3))
        elif ch.strip():
            font = bold if st['bold'] else regular
            if ord(ch) not in have:
                font = fallback
            d.text((px + (CW * wide - font.getlength(ch)) / 2, y), ch, font=font, fill=fg)
        if st['under']:
            d.line([px, y + CH - 3 * SCALE, px + wide * CW, y + CH - 3 * SCALE],
                   fill=fg, width=SCALE)
        col += wide
img.save(dst, optimize=True)
print(f'{dst}: {img.size[0]}x{img.size[1]}')
