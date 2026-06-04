#!/bin/bash
# Render assets/dmg-bg.html to a Retina-ready 1080×760 PNG via headless
# Chrome at 2× device scale, then bake 144 DPI metadata so the macOS DMG
# window renderer treats it as a 540×380 logical asset displayed at 2×
# physical sharpness. Re-run when the brand copy changes.
#
# Why 2×: macOS DMG backgrounds get upscaled by Finder on Retina displays
# if the PNG is 1× — Duck illustration + body copy go soft. Shipping a 2×
# asset with 144 DPI metadata is the simplest sharpening path that the
# DMG renderer honors (alternative is a multi-rep TIFF via tiffutil, but
# this is 1 file, 1 step, and works on every macOS that exists).
#
# Usage:
#   bash tools/make-dmg-bg.sh

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJECT_ROOT/assets/dmg-bg.html"
OUT="$PROJECT_ROOT/assets/dmg-bg.png"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
    echo "✗ Google Chrome not found at $CHROME"
    echo "  Install Chrome, or edit this script to point at another"
    echo "  Chromium-based browser (Edge, Brave, Arc all work)."
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "✗ Source file missing: $SRC"
    exit 1
fi

echo "==> Rendering $SRC → $OUT (2× device scale, 1080×760 px)"
"$CHROME" \
    --headless=new \
    --disable-gpu \
    --hide-scrollbars \
    --force-device-scale-factor=2 \
    --window-size=540,380 \
    --default-background-color=fffaf0ff \
    --screenshot="$OUT" \
    "file://$SRC" \
    > /dev/null 2>&1

echo "==> Baking 144 DPI metadata for Retina DMG rendering"
sips -s dpiWidth 144 -s dpiHeight 144 "$OUT" > /dev/null

echo "✓ Wrote $OUT ($(du -h "$OUT" | cut -f1), $(sips -g pixelWidth -g pixelHeight "$OUT" | tail -2 | tr '\n' ' '))"
