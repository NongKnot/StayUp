#!/bin/bash
# Generates Resources/AppIcon.icns for StayUp.
#
# Renders the Duck SVG at 1024×1024 via headless Chrome, then uses sips
# to scale to all macOS iconset sizes, then iconutil to combine.
#
# Run when Duck art changes:
#   bash tools/make-icon.sh
#
# Output:
#   Resources/AppIcon.icns        — committed; build.sh copies into bundle
#   Resources/AppIcon-1024.png    — preview PNG (intermediate)

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON_DIR="$PROJECT_ROOT/Resources"
ICONSET="$ICON_DIR/AppIcon.iconset"
ICNS="$ICON_DIR/AppIcon.icns"
BIG="$ICON_DIR/AppIcon-1024.png"
SRC="$ICON_DIR/icon-source.html"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
    echo "✗ Google Chrome not at $CHROME"
    exit 1
fi

mkdir -p "$ICON_DIR"

# 1024×1024 paper background, Duck centered at 80% height (auto width).
# macOS applies the rounded-square mask itself at display time — we
# deliberately ship a square PNG so the system can apply the current
# OS-version-appropriate corner radius.
cat > "$SRC" <<'HTML'
<!doctype html>
<html>
<head>
<style>
  html, body { margin: 0; padding: 0; }
  body {
    width: 1024px;
    height: 1024px;
    background: #fffaf0;
    display: flex;
    align-items: center;
    justify-content: center;
  }
  svg { height: 80%; width: auto; display: block; }
</style>
</head>
<body>
  <svg viewBox="0 0 400 500" xmlns="http://www.w3.org/2000/svg">
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
</body>
</html>
HTML

echo "==> Rendering 1024×1024 master via Chrome headless"
"$CHROME" \
    --headless=new \
    --disable-gpu \
    --hide-scrollbars \
    --window-size=1024,1024 \
    --default-background-color=00000000 \
    --screenshot="$BIG" \
    "file://$SRC" \
    > /dev/null 2>&1

if [ ! -f "$BIG" ]; then
    echo "✗ Master render failed."
    exit 1
fi

echo "==> Building iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# macOS iconset sizes — every entry: <pixels> <name>
# Apple expects exactly these filenames in an iconset directory.
for spec in \
    "16   icon_16x16.png" \
    "32   icon_16x16@2x.png" \
    "32   icon_32x32.png" \
    "64   icon_32x32@2x.png" \
    "128  icon_128x128.png" \
    "256  icon_128x128@2x.png" \
    "256  icon_256x256.png" \
    "512  icon_256x256@2x.png" \
    "512  icon_512x512.png" \
    "1024 icon_512x512@2x.png"; do
    px=$(echo "$spec" | awk '{print $1}')
    name=$(echo "$spec" | awk '{print $2}')
    sips -z "$px" "$px" "$BIG" --out "$ICONSET/$name" > /dev/null
done

echo "==> iconutil → AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICNS"

SIZE=$(du -h "$ICNS" | cut -f1)
echo "==> ✓ $ICNS  ($SIZE)"
