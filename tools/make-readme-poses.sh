#!/bin/bash
# Generates the secondary Duck poses used throughout the README:
#   assets/duck-sleeping.png — closing visual near License
#   assets/duck-blink.png    — small section break (idle, eyes closed-ish)
#   assets/duck-walk-tiny.png — small section break (mid-stride)
#
# All transparent backgrounds, rendered via headless Chrome.
# Run when Duck art changes:
#   bash tools/make-readme-poses.sh

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$PROJECT_ROOT/assets"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "✗ Chrome not at $CHROME"; exit 1; }

# render <html_path> <output_png> <window_w> <window_h>
render() {
    "$CHROME" \
        --headless=new \
        --disable-gpu \
        --hide-scrollbars \
        --window-size=$3,$4 \
        --default-background-color=00000000 \
        --screenshot="$2" \
        "file://$1" \
        > /dev/null 2>&1
}

# ─── Pose 1: Sleeping Duck (closed-arc eyes + Z's drifting upward) ───
SLEEP_HTML=$(mktemp /tmp/duck-sleep-XXXXX.html)
cat > "$SLEEP_HTML" <<'HTML'
<!doctype html>
<html><head><style>
  html, body { margin: 0; padding: 0; background: transparent; }
  body { width: 700px; height: 700px; display: flex; align-items: center; justify-content: center; }
  svg { width: 560px; height: 560px; display: block; }
</style></head>
<body>
  <svg viewBox="20 0 460 460" xmlns="http://www.w3.org/2000/svg">
    <!-- Body -->
    <path fill="#ffffff" stroke="#1a1a1a" stroke-width="6" stroke-linejoin="round" stroke-linecap="round" d="
      M 200 50 C 145 50, 130 110, 138 180
      C 144 240, 142 300, 132 360
      C 122 410, 132 448, 200 452
      C 268 448, 278 410, 268 360
      C 258 300, 256 240, 262 180
      C 270 110, 255 50, 200 50 Z
    "/>
    <!-- Closed sleeping eyes (downward arcs) -->
    <path fill="none" stroke="#1a1a1a" stroke-width="6" stroke-linecap="round" d="
      M 110 175 Q 138 200, 166 175
    "/>
    <path fill="none" stroke="#1a1a1a" stroke-width="6" stroke-linecap="round" d="
      M 234 175 Q 262 200, 290 175
    "/>
    <!-- Beak -->
    <path fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5" stroke-linejoin="round" d="
      M 162 200 C 178 188, 222 188, 238 200
      C 248 214, 232 226, 200 224
      C 168 226, 152 214, 162 200 Z
    "/>
    <circle cx="190" cy="206" r="2.2" fill="#1a1a1a"/>
    <circle cx="210" cy="206" r="2.2" fill="#1a1a1a"/>
    <!-- Feet -->
    <circle cx="160" cy="462" r="24" fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5"/>
    <circle cx="240" cy="462" r="24" fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5"/>
    <!-- Z's drifting upward (small → medium → large) -->
    <g font-family="-apple-system, BlinkMacSystemFont, 'Helvetica Neue', Arial" font-weight="800" fill="#1a1a1a">
      <text x="300" y="100" font-size="36">z</text>
      <text x="340" y="65"  font-size="48">Z</text>
      <text x="385" y="22"  font-size="64">Z</text>
    </g>
  </svg>
</body></html>
HTML
echo "==> Rendering sleeping Duck"
render "$SLEEP_HTML" "$ASSETS/duck-sleeping.png" 700 700
rm -f "$SLEEP_HTML"

# ─── Pose 2: Idle Duck (eyes open, standing, small) — section break ───
IDLE_HTML=$(mktemp /tmp/duck-idle-XXXXX.html)
cat > "$IDLE_HTML" <<'HTML'
<!doctype html>
<html><head><style>
  html, body { margin: 0; padding: 0; background: transparent; }
  body { width: 400px; height: 400px; display: flex; align-items: center; justify-content: center; }
  svg { width: 280px; height: 350px; display: block; }
</style></head>
<body>
  <svg viewBox="60 30 280 460" xmlns="http://www.w3.org/2000/svg">
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
  </svg>
</body></html>
HTML
echo "==> Rendering idle Duck (small)"
render "$IDLE_HTML" "$ASSETS/duck-idle.png" 400 400
rm -f "$IDLE_HTML"

# ─── Pose 3: Side-eye Duck (eyes glancing right) — small section break ───
PEEK_HTML=$(mktemp /tmp/duck-peek-XXXXX.html)
cat > "$PEEK_HTML" <<'HTML'
<!doctype html>
<html><head><style>
  html, body { margin: 0; padding: 0; background: transparent; }
  body { width: 400px; height: 400px; display: flex; align-items: center; justify-content: center; }
  svg { width: 280px; height: 350px; display: block; }
</style></head>
<body>
  <svg viewBox="60 30 280 460" xmlns="http://www.w3.org/2000/svg">
    <path fill="#ffffff" stroke="#1a1a1a" stroke-width="6" stroke-linejoin="round" stroke-linecap="round" d="
      M 200 50 C 145 50, 130 110, 138 180
      C 144 240, 142 300, 132 360
      C 122 410, 132 448, 200 452
      C 268 448, 278 410, 268 360
      C 258 300, 256 240, 262 180
      C 270 110, 255 50, 200 50 Z
    "/>
    <circle cx="138" cy="175" r="34" fill="#ffffff" stroke="#1a1a1a" stroke-width="5"/>
    <!-- Pupils shifted right for side-eye effect -->
    <circle cx="153" cy="175" r="4.5" fill="#1a1a1a"/>
    <circle cx="262" cy="175" r="34" fill="#ffffff" stroke="#1a1a1a" stroke-width="5"/>
    <circle cx="277" cy="175" r="4.5" fill="#1a1a1a"/>
    <path fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5" stroke-linejoin="round" d="
      M 162 200 C 178 188, 222 188, 238 200
      C 248 214, 232 226, 200 224
      C 168 226, 152 214, 162 200 Z
    "/>
    <circle cx="190" cy="206" r="2.2" fill="#1a1a1a"/>
    <circle cx="210" cy="206" r="2.2" fill="#1a1a1a"/>
    <circle cx="160" cy="462" r="24" fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5"/>
    <circle cx="240" cy="462" r="24" fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5"/>
  </svg>
</body></html>
HTML
echo "==> Rendering side-eye Duck (small)"
render "$PEEK_HTML" "$ASSETS/duck-side-eye.png" 400 400
rm -f "$PEEK_HTML"

echo "==> ✓ Done"
for f in duck-sleeping.png duck-idle.png duck-side-eye.png; do
    SIZE=$(du -h "$ASSETS/$f" | cut -f1)
    echo "    $ASSETS/$f  ($SIZE)"
done
