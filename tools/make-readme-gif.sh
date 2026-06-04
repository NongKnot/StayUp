#!/bin/bash
# Generates assets/readme-walk.gif — an animated walking Duck for the
# README hero. Two frames: body tilted ±6° around Duck's foot
# center (the same physics as the in-app menu-bar walk animation in
# IconRenderer.swift). Alternating at 250ms gives the wobble waddle.
#
# Usage:
#   bash tools/make-readme-gif.sh

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$PROJECT_ROOT/assets"
GIF="$ASSETS/readme-walk.gif"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "✗ Chrome not at $CHROME"; exit 1; }
command -v magick >/dev/null || { echo "✗ imagemagick (magick) not on PATH"; exit 1; }

# Render Duck rotated by $1 degrees around (200, 260) to PNG $2.
render_frame() {
    local tilt=$1
    local out=$2
    local html
    html=$(mktemp /tmp/walk-XXXXX.html)
    cat > "$html" <<HTML
<!doctype html>
<html><head><style>
  html, body { margin: 0; padding: 0; background: transparent; }
  body { width: 600px; height: 750px; display: flex; align-items: center; justify-content: center; }
  svg { width: 480px; height: 600px; display: block; }
</style></head>
<body>
  <!-- viewBox padded a bit so tilted Duck doesn't clip at the edges. -->
  <svg viewBox="-30 -10 460 520" xmlns="http://www.w3.org/2000/svg">
    <g transform="rotate(${tilt} 200 260)">
      <path fill="#ffffff" stroke="#1a1a1a" stroke-width="6" stroke-linejoin="round" stroke-linecap="round" d="
        M 200 50 C 145 50, 130 110, 138 180
        C 144 240, 142 300, 132 360
        C 122 410, 132 448, 200 452
        C 268 448, 278 410, 268 360
        C 258 300, 256 240, 262 180
        C 270 110, 255 50, 200 50 Z
      "/>
      <circle cx="138" cy="175" r="34" fill="#ffffff" stroke="#1a1a1a" stroke-width="5"/>
      <circle cx="132" cy="178" r="4.5" fill="#1a1a1a"/>
      <circle cx="262" cy="175" r="34" fill="#ffffff" stroke="#1a1a1a" stroke-width="5"/>
      <circle cx="268" cy="178" r="4.5" fill="#1a1a1a"/>
      <path fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5" stroke-linejoin="round" d="
        M 162 200 C 178 188, 222 188, 238 200
        C 248 214, 232 226, 200 224
        C 168 226, 152 214, 162 200 Z
      "/>
      <circle cx="190" cy="206" r="2.2" fill="#1a1a1a"/>
      <circle cx="210" cy="206" r="2.2" fill="#1a1a1a"/>
      <circle cx="160" cy="462" r="24" fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5"/>
      <circle cx="240" cy="462" r="24" fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5"/>
    </g>
  </svg>
</body></html>
HTML
    "$CHROME" \
        --headless=new \
        --disable-gpu \
        --hide-scrollbars \
        --window-size=600,750 \
        --default-background-color=00000000 \
        --screenshot="$out" \
        "file://$html" \
        > /dev/null 2>&1
    rm -f "$html"
}

FRAME_A="/tmp/duck-walk-a.png"
FRAME_B="/tmp/duck-walk-b.png"

echo "==> Rendering frame A (tilt -6°)"
render_frame -6 "$FRAME_A"
echo "==> Rendering frame B (tilt +6°)"
render_frame 6 "$FRAME_B"

echo "==> Assembling animated GIF (250ms per frame, infinite loop)"
# -delay 25 = 250ms (delay is in centiseconds)
# -loop 0  = infinite
# -layers Optimize  = reduce repeated pixels between frames for size
magick -delay 25 -loop 0 -dispose Background \
    "$FRAME_A" "$FRAME_B" \
    -layers Optimize \
    "$GIF"

rm -f "$FRAME_A" "$FRAME_B"

SIZE=$(du -h "$GIF" | cut -f1)
DIMS=$(magick identify -format "%w x %h, %n frames" "$GIF" 2>&1 | head -1)
echo "==> ✓ $GIF  ($SIZE, $DIMS)"
