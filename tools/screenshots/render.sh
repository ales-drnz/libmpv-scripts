#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Draws the screens of the TUI the README shows, into imgs/. Each is what
# `build _preview <screen>` prints (the TUI's own preview of a screen, with
# sample data and no terminal), drawn by ansi2png.py.
#
# Needs Go, python3 with Pillow and fontTools, and a monospaced font with
# the TUI's symbols. FONT, FONT_BOLD and FONT_FALLBACK name the font files;
# the defaults are Meslo LG L Nerd Font Mono and Noto Sans Mono where Arch
# Linux installs them.
#
# Usage: tools/screenshots/render.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FONT="${FONT:-/usr/share/fonts/TTF/MesloLGLNerdFontMono-Regular.ttf}"
FONT_BOLD="${FONT_BOLD:-/usr/share/fonts/TTF/MesloLGLNerdFontMono-Bold.ttf}"
FONT_FALLBACK="${FONT_FALLBACK:-/usr/share/fonts/noto/NotoSansMono-Regular.ttf}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
(cd "$ROOT/tui" && go build -o "$work/tui" .)

# screen of _preview, then the image's name.
screens=(
  "select-build targets"
  "dash build"
  "verify verify"
  "settings-patches settings"
  "deps dependencies"
  "select-docker docker"
)
cd "$ROOT"
for pair in "${screens[@]}"; do
  read -r screen name <<<"$pair"
  CLICOLOR_FORCE=1 "$work/tui" _preview "$screen" > "$work/$screen.ans"
  python3 "$ROOT/tools/screenshots/ansi2png.py" "$work/$screen.ans" "imgs/tui_$name.png" \
    --font "$FONT" --bold "$FONT_BOLD" --fallback "$FONT_FALLBACK" --title libmpv-scripts
done
