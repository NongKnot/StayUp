#!/bin/bash
# Renders the README's two-Duck divider image at 1600×800 via headless
# Chrome. Source: assets/readme-ducks.html. Output: assets/readme-ducks.png.
#
# Run when Duck art changes:
#   bash tools/make-readme-art.sh

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJECT_ROOT/assets/readme-ducks.html"
OUT="$PROJECT_ROOT/assets/readme-ducks.png"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
    echo "✗ Google Chrome not at $CHROME"
    exit 1
fi
if [ ! -f "$SRC" ]; then
    echo "✗ Source missing: $SRC"
    exit 1
fi

echo "==> Rendering $SRC → $OUT"
"$CHROME" \
    --headless=new \
    --disable-gpu \
    --hide-scrollbars \
    --window-size=1200,1000 \
    --default-background-color=00000000 \
    --screenshot="$OUT" \
    "file://$SRC" \
    > /dev/null 2>&1

if [ ! -f "$OUT" ]; then
    echo "✗ Capture failed — no file written."
    exit 1
fi

SIZE=$(du -h "$OUT" | cut -f1)
DIMS=$(sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null \
       | awk '/pixelWidth|pixelHeight/ {print $2}' | paste -sd' x ' -)
echo "==> ✓ $OUT  ($SIZE, $DIMS)"
