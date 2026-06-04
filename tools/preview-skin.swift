#!/usr/bin/env swift
//
// preview-skin — render an SVG silhouette through the same transform
// stack as IconRenderer.drawCustomCharacter, so you can SEE what a
// character skin will look like at 22×22 menu-bar size before
// committing the path to DuckSkin.swift.
//
//   swift tools/preview-skin.swift <input.svg> [output-dir]
//
// Writes 4 PNGs to <output-dir> (default /tmp/skin-preview):
//   <name>-light-22.png    actual menu-bar size, light bar
//   <name>-light-176.png   8× zoom, light bar
//   <name>-dark-22.png     actual menu-bar size, dark bar
//   <name>-dark-176.png    8× zoom, dark bar
//
// Then `open`s the output directory.
//
// Uses Saiyan ON palette by default (gold body + amber outline).
// Pass --palette off to render with the calm-palette variant instead.

import Foundation
import AppKit

// MARK: - CLI

var argv = CommandLine.arguments
var palette = "on"
var strokeWidth: Double = 22  // matches IconRenderer.fillStroke default
var transparent = false       // skip background swatch fill — for layering
if let i = argv.firstIndex(of: "--palette"), i + 1 < argv.count {
    palette = argv[i + 1]
    argv.removeSubrange(i...(i + 1))
}
if let i = argv.firstIndex(of: "--stroke"), i + 1 < argv.count,
   let w = Double(argv[i + 1]) {
    strokeWidth = w
    argv.removeSubrange(i...(i + 1))
}
if let i = argv.firstIndex(of: "--transparent") {
    transparent = true
    argv.remove(at: i)
}
guard argv.count >= 2 else {
    FileHandle.standardError.write(Data("""
        usage: swift tools/preview-skin.swift <input.svg> [output-dir] [--palette on|off]

        Renders the SVG's first <path> through IconRenderer's transform
        stack and writes PNG previews at 22px + 176px on both light and
        dark menu-bar backgrounds.

        """.utf8))
    exit(2)
}
let inputPath = argv[1]
let outDir = argv.count >= 3 ? argv[2] : "/tmp/skin-preview"

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("preview-skin: \(msg)\n".utf8))
    exit(1)
}

// MARK: - 2D affine transform (avoids CoreGraphics dep in a Swift script).
// Mirrors the implementation in tools/svg-to-skin.swift — kept in sync
// so both tools handle parent-<g> transforms (e.g. Potrace's y-flip)
// identically.

struct Transform {
    var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    static let identity = Transform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    static func translate(_ tx: Double, _ ty: Double) -> Transform {
        Transform(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty)
    }
    static func scale(_ sx: Double, _ sy: Double) -> Transform {
        Transform(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }
    func apply(_ x: Double, _ y: Double) -> (Double, Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }
    func concatenating(_ inner: Transform) -> Transform {
        Transform(
            a:  inner.a * a + inner.b * c,
            b:  inner.a * b + inner.b * d,
            c:  inner.c * a + inner.d * c,
            d:  inner.c * b + inner.d * d,
            tx: inner.tx * a + inner.ty * c + tx,
            ty: inner.tx * b + inner.ty * d + ty
        )
    }
}

func parseTransform(_ s: String) -> Transform {
    var t = Transform.identity
    let regex = try! NSRegularExpression(pattern: #"(\w+)\s*\(([^)]+)\)"#)
    let ns = s as NSString
    for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        let name = ns.substring(with: m.range(at: 1))
        let args = ns.substring(with: m.range(at: 2))
            .components(separatedBy: CharacterSet(charactersIn: ", \t\n"))
            .compactMap { Double($0) }
        switch name {
        case "translate":
            t = t.concatenating(Transform.translate(
                args.count >= 1 ? args[0] : 0,
                args.count >= 2 ? args[1] : 0))
        case "scale":
            let sx = args.count >= 1 ? args[0] : 1
            t = t.concatenating(Transform.scale(sx, args.count >= 2 ? args[1] : sx))
        case "matrix" where args.count == 6:
            t = t.concatenating(Transform(
                a: args[0], b: args[1], c: args[2],
                d: args[3], tx: args[4], ty: args[5]))
        default:
            continue
        }
    }
    return t
}

// MARK: - Read SVG, extract `d`

let url = URL(fileURLWithPath: inputPath)
let xml: XMLDocument
do {
    xml = try XMLDocument(data: try Data(contentsOf: url),
                          options: .nodePreserveWhitespace)
} catch {
    die("could not read \(inputPath): \(error.localizedDescription)")
}
// Read ALL <path> elements (Potrace splits nested contours into
// separate <path> entries sharing a parent <g>). Concatenate all `d`
// strings since each starts with `M`, producing one parser stream with
// multiple subpaths.
let pathNodes = ((try? xml.nodes(forXPath: "//*[local-name()='path']")) ?? [])
    .compactMap { $0 as? XMLElement }
guard let pathNode = pathNodes.first else {
    die("no <path d=\"…\"> element found in \(inputPath)")
}
let d = pathNodes
    .compactMap { $0.attribute(forName: "d")?.stringValue }
    .joined(separator: " ")
guard !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    die("no <path d=\"…\"> data found in \(inputPath)")
}

// MARK: - SVG `d` → CGPath
// (Same grammar as tools/svg-to-skin.swift: M/m L/l H/h V/v C/c S/s Z/z.
//  Q/q T/t A/a unsupported. Duplicated here on purpose — keeping each
//  tool single-file and self-contained beats sharing a parser module.)

enum Tok: Equatable { case cmd(Character); case num(Double) }

func tokenize(_ s: String) -> [Tok] {
    var out: [Tok] = []
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c.isWhitespace || c == "," { i += 1; continue }
        if c.isLetter { out.append(.cmd(c)); i += 1; continue }
        let start = i
        if chars[i] == "-" || chars[i] == "+" { i += 1 }
        while i < chars.count, chars[i].isNumber { i += 1 }
        if i < chars.count, chars[i] == "." {
            i += 1
            while i < chars.count, chars[i].isNumber { i += 1 }
        }
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            i += 1
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            while i < chars.count, chars[i].isNumber { i += 1 }
        }
        guard i > start, let n = Double(String(chars[start..<i])) else {
            die("could not parse number at offset \(start)")
        }
        out.append(.num(n))
    }
    return out
}

func buildPath(_ d: String, transform xfm: Transform) -> CGPath {
    let tokens = tokenize(d)
    let p = CGMutablePath()
    var idx = 0
    var cur: (x: Double, y: Double) = (0, 0)
    var sub: (x: Double, y: Double) = (0, 0)
    var lastCubicCtrl: (x: Double, y: Double)? = nil
    var lastCmd: Character = " "

    /// Apply the gathered transform at emission time. Parser state
    /// (`cur`, `lastCubicCtrl`, `sub`) stays in raw SVG coords so
    /// relative deltas and S/s reflections compute correctly.
    func cgPt(_ x: Double, _ y: Double) -> CGPoint {
        let (tx, ty) = xfm.apply(x, y)
        return CGPoint(x: tx, y: ty)
    }

    func num() -> Double {
        guard idx < tokens.count, case .num(let v) = tokens[idx] else {
            die("expected number at token \(idx) (after '\(lastCmd)')")
        }
        idx += 1
        return v
    }
    func peekNum() -> Bool {
        guard idx < tokens.count else { return false }
        if case .num = tokens[idx] { return true } else { return false }
    }
    func cubic(_ c1: (Double, Double), _ c2: (Double, Double), _ end: (Double, Double)) {
        p.addCurve(to: cgPt(end.0, end.1),
                   control1: cgPt(c1.0, c1.1),
                   control2: cgPt(c2.0, c2.1))
        lastCubicCtrl = (c2.0, c2.1)
        cur = (end.0, end.1)
    }

    while idx < tokens.count {
        guard case .cmd(let c) = tokens[idx] else {
            die("expected command at token \(idx)")
        }
        idx += 1
        let rel = c.isLowercase
        switch c {
        case "M", "m":
            var first = true
            repeat {
                var x = num(), y = num()
                let isFirstEver = (lastCmd == " " && first)
                if rel && !isFirstEver { x += cur.x; y += cur.y }
                if first {
                    p.move(to: cgPt(x, y))
                    sub = (x, y)
                } else {
                    p.addLine(to: cgPt(x, y))
                }
                cur = (x, y); first = false; lastCubicCtrl = nil
            } while peekNum()
        case "L", "l":
            repeat {
                var x = num(), y = num()
                if rel { x += cur.x; y += cur.y }
                p.addLine(to: cgPt(x, y))
                cur = (x, y); lastCubicCtrl = nil
            } while peekNum()
        case "H", "h":
            repeat {
                var x = num()
                if rel { x += cur.x }
                p.addLine(to: cgPt(x, cur.y))
                cur.x = x; lastCubicCtrl = nil
            } while peekNum()
        case "V", "v":
            repeat {
                var y = num()
                if rel { y += cur.y }
                p.addLine(to: cgPt(cur.x, y))
                cur.y = y; lastCubicCtrl = nil
            } while peekNum()
        case "C", "c":
            repeat {
                var c1x = num(), c1y = num()
                var c2x = num(), c2y = num()
                var ex  = num(), ey  = num()
                if rel {
                    c1x += cur.x; c1y += cur.y
                    c2x += cur.x; c2y += cur.y
                    ex  += cur.x; ey  += cur.y
                }
                cubic((c1x, c1y), (c2x, c2y), (ex, ey))
            } while peekNum()
        case "S", "s":
            repeat {
                var x2 = num(), y2 = num()
                var x  = num(), y  = num()
                if rel {
                    x2 += cur.x; y2 += cur.y
                    x  += cur.x; y  += cur.y
                }
                let c1: (Double, Double)
                if let lc = lastCubicCtrl {
                    c1 = (2 * cur.x - lc.x, 2 * cur.y - lc.y)
                } else {
                    c1 = (cur.x, cur.y)
                }
                cubic(c1, (x2, y2), (x, y))
            } while peekNum()
        case "Z", "z":
            p.closeSubpath()
            cur = sub; lastCubicCtrl = nil
        case "Q", "q", "T", "t":
            die("quadratic Bézier (\(c)) not supported")
        case "A", "a":
            die("elliptical arc (\(c)) not supported")
        default:
            die("unknown command '\(c)'")
        }
        lastCmd = c
    }
    return p
}

// MARK: - Render

// Palette: Saiyan ON (SSJ gold + amber) or OFF (gi orange + black),
// matching the values in Sources/DuckSkin.swift.
let (bodyRGB, outlineRGB): ((Double, Double, Double), (Double, Double, Double))
switch palette {
case "off":
    bodyRGB    = (0.95, 0.40, 0.10)   // gi orange (Saiyan OFF)
    outlineRGB = (0.10, 0.10, 0.10)   // black
case "on":
    bodyRGB    = (1.00, 0.85, 0.20)   // SSJ gold (Saiyan ON)
    outlineRGB = (0.55, 0.28, 0.05)   // deep amber
case "flex":
    // Matches the Flex Happy Sit reference: white Duck w/ thin dark outline.
    bodyRGB    = (1.00, 1.00, 1.00)
    outlineRGB = (0.10, 0.10, 0.10)
case "orange":
    bodyRGB    = (0.99, 0.60, 0.20)   // beak / foot orange
    outlineRGB = (0.99, 0.60, 0.20)
case "pink":
    bodyRGB    = (0.98, 0.55, 0.55)   // cheek pink
    outlineRGB = (0.98, 0.55, 0.55)
default:
    die("--palette must be 'on' or 'off' or 'flex' (got '\(palette)')")
}

/// Replicates IconRenderer's transform stack for a given canvas size.
/// At 22px this is byte-identical to what the real menu-bar icon
/// produces. Larger sizes are linearly zoomed via canvasPx scale.
func renderPNG(path: CGPath, size: Int, background: (Double, Double, Double)) -> Data {
    let pixels = size
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: pixels * 4,
                              space: cs, bitmapInfo: info) else {
        die("CGContext allocation failed at size \(size)")
    }

    // Background swatch — fills the whole canvas before the glyph draws.
    // Skipped in --transparent mode so the output can be composited over
    // another render.
    if !transparent {
        ctx.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    }

    let canvas = CGFloat(pixels)

    // SVG y-down → CGContext y-up flip (same as IconRenderer.render).
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    // IconRenderer.applyContentTransform replica.
    let unitScale: CGFloat = canvas / 440.0
    let scaledW: CGFloat = 400.0 * unitScale
    let xOffset = (canvas - scaledW) / 2.0
    let contentTop: CGFloat = 30
    ctx.translateBy(x: xOffset, y: -contentTop * unitScale)
    ctx.scaleBy(x: unitScale, y: unitScale)

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // IconRenderer.fillStroke(... width: 22) — 22 SOURCE units, which
    // becomes 22*unitScale device px. At 22px canvas that's 1.1px.
    ctx.setFillColor(red: bodyRGB.0, green: bodyRGB.1, blue: bodyRGB.2, alpha: 1)
    ctx.setStrokeColor(red: outlineRGB.0, green: outlineRGB.1, blue: outlineRGB.2, alpha: 1)
    ctx.setLineWidth(CGFloat(strokeWidth))
    ctx.addPath(path)
    // .eoFillStroke (even-odd) instead of .fillStroke (nonzero):
    // Potrace emits nested contours (silhouette + cutouts + dots inside
    // cutouts) with mixed winding direction. Nonzero fill cancels
    // overlapping windings — leaving big chunks of the body unfilled.
    // Even-odd flips fill/no-fill on each contour crossing regardless
    // of direction, which is what we want here.
    ctx.drawPath(using: .eoFillStroke)

    guard let cgImage = ctx.makeImage(),
          let rep = NSBitmapImageRep(cgImage: cgImage)
              .representation(using: .png, properties: [:])
    else {
        die("PNG encoding failed at size \(size)")
    }
    return rep
}

// MARK: - Main

// Gather the effective transform from the path's own attribute plus
// every ancestor <g> transform. Walks inner→outer; concatenation order
// puts outer wrapping inner, matching SVG nested-transform semantics.
var effectiveTransform = Transform.identity
var walker: XMLNode? = pathNode
while let n = walker {
    if let el = n as? XMLElement,
       let attr = el.attribute(forName: "transform")?.stringValue {
        effectiveTransform = parseTransform(attr).concatenating(effectiveTransform)
    }
    walker = n.parent
}

let path = buildPath(d, transform: effectiveTransform)
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let base = (inputPath as NSString).lastPathComponent
    .replacingOccurrences(of: ".svg", with: "")

// Light + dark menu-bar background swatches (close to actual macOS bars).
let lightBG = (0.94, 0.94, 0.94)
let darkBG  = (0.10, 0.10, 0.11)

struct Output { let name: String; let data: Data }
var outputs: [Output] = []
for size in [22, 176] {
    outputs.append(Output(
        name: "\(base)-\(palette)-light-\(size).png",
        data: renderPNG(path: path, size: size, background: lightBG)))
    outputs.append(Output(
        name: "\(base)-\(palette)-dark-\(size).png",
        data: renderPNG(path: path, size: size, background: darkBG)))
}

for out in outputs {
    let p = "\(outDir)/\(out.name)"
    do { try out.data.write(to: URL(fileURLWithPath: p)) }
    catch { die("could not write \(p): \(error.localizedDescription)") }
    print(p)
}

// Pop the folder so the renders are visible immediately.
Process.launchedProcess(launchPath: "/usr/bin/open", arguments: [outDir]).waitUntilExit()
