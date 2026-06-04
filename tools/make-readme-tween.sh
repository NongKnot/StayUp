#!/bin/bash
# Generates assets/duck-tween.gif — the OFF→ON engage animation.
#
# OFF state: chibi warp (scale 2.10 × 0.62 around foot center (200, 462)) with
# eyes closed as soft arcs. Fat, settled Duck.
# ON  state: identity transform, eyes open with pupils. Upright Duck.
# 5 frames in between, plays forward + reverse for a clean infinite loop.
#
# Mirrors the in-app tween animation described in IconRenderer.swift.
#
# Usage:  bash tools/make-readme-tween.sh

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$PROJECT_ROOT/assets"
GIF="$ASSETS/duck-tween.gif"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "✗ Chrome not at $CHROME"; exit 1; }
command -v magick >/dev/null || { echo "✗ imagemagick (magick) not on PATH"; exit 1; }

# Render one frame at progress p (0.0 = OFF / fat chibi, 1.0 = ON / upright)
render_tween() {
    local p=$1
    local out=$2

    # Linear interpolation of the in-app warp values.
    # scale_x : 2.10 → 1.00  (width: fat → normal)
    # scale_y : 0.62 → 1.00  (height: squished → normal)
    local sx
    local sy
    sx=$(echo "scale=3; 2.10 - 1.10 * $p" | bc)
    sy=$(echo "scale=3; 0.62 + 0.38 * $p" | bc)

    # Crossfade eyes at the halfway mark. Before 0.5 Duck is still mostly
    # off (sleepy → closed arcs); from 0.5 on, eyes pop open.
    local eyes
    if (( $(echo "$p < 0.5" | bc -l) )); then
        eyes='<path fill="none" stroke="#1a1a1a" stroke-width="6" stroke-linecap="round" d="M 110 175 Q 138 200, 166 175"/><path fill="none" stroke="#1a1a1a" stroke-width="6" stroke-linecap="round" d="M 234 175 Q 262 200, 290 175"/>'
    else
        eyes='<circle cx="138" cy="175" r="34" fill="#ffffff" stroke="#1a1a1a" stroke-width="5"/><circle cx="132" cy="178" r="4.5" fill="#1a1a1a"/><circle cx="262" cy="175" r="34" fill="#ffffff" stroke="#1a1a1a" stroke-width="5"/><circle cx="268" cy="178" r="4.5" fill="#1a1a1a"/>'
    fi

    local html
    html=$(mktemp /tmp/duck-tween-XXXXX.html)
    cat > "$html" <<HTML
<!doctype html>
<html><head><style>
  html, body { margin: 0; padding: 0; background: transparent; }
  body { width: 600px; height: 600px; display: flex; align-items: center; justify-content: center; }
  svg { width: 480px; height: 480px; display: block; }
</style></head>
<body>
  <!-- ViewBox padded horizontally so the OFF state's wide chibi pose
       (sx=2.10) doesn't get clipped at the edges. -->
  <svg viewBox="-80 0 560 510" xmlns="http://www.w3.org/2000/svg">
    <!-- Body + eyes + beak: all warped together around the foot center. -->
    <g transform="translate(200 462) scale(${sx} ${sy}) translate(-200 -462)">
      <path fill="#ffffff" stroke="#1a1a1a" stroke-width="6" stroke-linejoin="round" stroke-linecap="round" d="
        M 200 50 C 145 50, 130 110, 138 180
        C 144 240, 142 300, 132 360
        C 122 410, 132 448, 200 452
        C 268 448, 278 410, 268 360
        C 258 300, 256 240, 262 180
        C 270 110, 255 50, 200 50 Z
      "/>
      ${eyes}
      <path fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5" stroke-linejoin="round" d="
        M 162 200 C 178 188, 222 188, 238 200
        C 248 214, 232 226, 200 224
        C 168 226, 152 214, 162 200 Z
      "/>
      <circle cx="190" cy="206" r="2.2" fill="#1a1a1a"/>
      <circle cx="210" cy="206" r="2.2" fill="#1a1a1a"/>
    </g>
    <!-- Feet drawn OUTSIDE the warp group so they stay planted -
         this matches the in-app behaviour (CLAUDE.md: 'feet stay
         planted while body shrinks upward'). -->
    <circle cx="160" cy="462" r="24" fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5"/>
    <circle cx="240" cy="462" r="24" fill="#ff9b3d" stroke="#1a1a1a" stroke-width="5"/>
  </svg>
</body></html>
HTML

    "$CHROME" \
        --headless=new \
        --disable-gpu \
        --hide-scrollbars \
        --window-size=600,600 \
        --default-background-color=00000000 \
        --screenshot="$out" \
        "file://$html" \
        > /dev/null 2>&1
    rm -f "$html"
}

echo "==> Rendering 5 tween frames..."
render_tween 0.00 /tmp/duck-tween-0.png
render_tween 0.25 /tmp/duck-tween-1.png
render_tween 0.50 /tmp/duck-tween-2.png
render_tween 0.75 /tmp/duck-tween-3.png
render_tween 1.00 /tmp/duck-tween-4.png

echo "==> Assembling GIF (hold OFF, transition, hold ON, reverse)"
# Per-frame delays in centiseconds (1 = 10ms):
#   60 = 600ms hold at OFF and ON ends
#    8 = 80ms per transition frame
magick \
    -loop 0 \
    -dispose Background \
    -delay 60 /tmp/duck-tween-0.png \
    -delay 8  /tmp/duck-tween-1.png \
    -delay 8  /tmp/duck-tween-2.png \
    -delay 8  /tmp/duck-tween-3.png \
    -delay 60 /tmp/duck-tween-4.png \
    -delay 8  /tmp/duck-tween-3.png \
    -delay 8  /tmp/duck-tween-2.png \
    -delay 8  /tmp/duck-tween-1.png \
    -layers Optimize \
    "$GIF"

rm -f /tmp/duck-tween-*.png

SIZE=$(du -h "$GIF" | cut -f1)
DIMS=$(magick identify -format "%w x %h, %n frames" "$GIF" 2>&1 | head -1)
echo "==> ✓ $GIF  ($SIZE, $DIMS)"
