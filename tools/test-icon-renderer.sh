#!/bin/sh
# Regression-test menu-bar Duck rendering without touching user defaults.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-icon-renderer.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-icon-renderer"

cat > "$TEST_MAIN" <<'SWIFT'
import AppKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

let defaults = UserDefaults(suiteName: "app.getstayup.icon-renderer-test")!
defaults.removePersistentDomain(forName: "app.getstayup.icon-renderer-test")
Settings.d = defaults
Settings.skinId = DuckSkin.classic.id

let image = IconRenderer.icon(active: true)
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff)
else {
    fail("could not read rendered Duck image pixels")
}

func isDarkDetail(_ color: NSColor) -> Bool {
    guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
    return rgb.alphaComponent > 0.9 &&
        rgb.redComponent < 0.65 &&
        rgb.greenComponent < 0.65 &&
        rgb.blueComponent < 0.65
}

func darkDetailCount(xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> Int {
    var count = 0
    for y in yRange {
        for x in xRange {
            guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh,
                  let color = rep.colorAt(x: x, y: y)
            else { continue }
            if isDarkDetail(color) { count += 1 }
        }
    }
    return count
}

let lowerLeftBodyEdgeInk = darkDetailCount(xRange: 5...8, yRange: 11...18)
if lowerLeftBodyEdgeInk != 0 {
    fail("Classic Duck active icon still has \(lowerLeftBodyEdgeInk) dark outline pixels on the lower-left body edge")
}

let faceInk = darkDetailCount(xRange: 5...16, yRange: 5...9)
if faceInk == 0 {
    fail("Classic Duck active icon lost all facial ink while removing the outline")
}
SWIFT

swiftc -target arm64-apple-macos13.0 \
    "$TEST_MAIN" \
    "$ROOT/Sources/IconRenderer.swift" \
    "$ROOT/Sources/DuckSkin.swift" \
    "$ROOT/Sources/DuckPack.swift" \
    "$ROOT/Sources/Settings.swift" \
    -framework AppKit \
    -framework Foundation \
    -o "$BIN"

"$BIN"
echo "test-icon-renderer: ok"
