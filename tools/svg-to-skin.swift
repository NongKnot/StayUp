#!/usr/bin/env swift
//
// svg-to-skin — turn an SVG `<path d="…">` into a Swift CGPath block.
//
//   swift tools/svg-to-skin.swift <input.svg> <varName>
//
// Reads the first <path> element of <input.svg>, parses its `d`
// attribute, and writes a `static let varName: CGPath = { … }()`
// block to stdout. Paste it into `Sources/DuckSkin.swift` (under the
// matching `static let saiyan` / `static let rubberHero` entries) as
// the `customOnPath` / `customOffPath` value.
//
// Coordinate space:
//   SVG's native y-down. Matches `IconRenderer.makeOnBodyPath()` —
//   no flip applied. Design your silhouettes in a 400×500 viewBox
//   and the renderer scales them down to the 22×22 menu-bar canvas.
//
// Supported SVG path commands:
//   M m  - moveto                 L l  - lineto
//   H h  - horizontal lineto      V v  - vertical lineto
//   C c  - cubic Bézier           S s  - smooth cubic Bézier
//   Z z  - closepath
//
// Errors on Q/q, T/t, A/a with a clear message: convert quadratic
// or elliptical-arc segments to cubics in your vector editor before
// exporting (Figma/Sketch/Illustrator all have a "flatten" option).

import Foundation

// MARK: - CLI

let argv = CommandLine.arguments
guard argv.count == 3 else {
    let bin = (argv.first ?? "svg-to-skin.swift")
        .components(separatedBy: "/").last ?? "svg-to-skin.swift"
    FileHandle.standardError.write(Data("""
        usage: swift \(bin) <input.svg> <varName>

        Reads the first <path> element of <input.svg>, parses its `d`
        attribute, and writes a Swift CGPath construction block to
        stdout. Paste it into Sources/DuckSkin.swift as a customOnPath
        or customOffPath value.

        Example:
            swift tools/svg-to-skin.swift saiyan-on.svg saiyanOnPath

        """.utf8))
    exit(2)
}
let inputPath = argv[1]
let varName   = argv[2]

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("svg-to-skin: \(msg)\n".utf8))
    exit(1)
}

// MARK: - Read the SVG, pull the first <path d="…">

let url = URL(fileURLWithPath: inputPath)
let xml: XMLDocument
do {
    let data = try Data(contentsOf: url)
    xml = try XMLDocument(data: data, options: .nodePreserveWhitespace)
} catch {
    die("could not read \(inputPath): \(error.localizedDescription)")
}

// Read ALL <path> elements, not just the first. Potrace splits nested
// contours (silhouette + each cutout + each dot inside a cutout) into
// separate <path> elements that share a common <g> ancestor. Each `d`
// starts with `M`, so concatenating them produces one path string with
// multiple independent subpaths — correct for our single-CGPath output.
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

// MARK: - Gather effective transform from path + ancestors
//
// SVG composition: the transform applied to a path's coords is the
// product of its own `transform` attribute and every ancestor `<g>`
// transform, applied inner-to-outer. Potrace emits its Y-flip on a
// wrapping <g transform="translate(0,H) scale(0.1, -0.1)"> so we
// MUST handle this or every Potrace-traced silhouette ends up
// upside-down and 10× too small. Figma/Sketch also emit translates
// on groups, so this is broadly useful.
//
// Supported: translate(tx[,ty]) scale(sx[,sy]) matrix(a,b,c,d,e,f).
// Unsupported: rotate, skewX, skewY (rare on exported paths; would
// silently no-op here, which is fine for now).

/// 2D affine transform written out in matrix form to avoid pulling
/// in CoreGraphics for a script. Convention: applying transform T
/// to point (x, y) gives (a*x + c*y + tx, b*x + d*y + ty). Composition
/// follows SVG semantics — `outer.concatenating(inner)` applies
/// `inner` first, then `outer`.
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
        // outer * inner ; the result applies `inner` to a point first,
        // then `outer` — matching SVG nested-transform semantics.
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
    let pattern = #"(\w+)\s*\(([^)]+)\)"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let ns = s as NSString
    let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
    for m in matches {
        let name = ns.substring(with: m.range(at: 1))
        let argsStr = ns.substring(with: m.range(at: 2))
        let args = argsStr
            .components(separatedBy: CharacterSet(charactersIn: ", \t\n"))
            .compactMap { Double($0) }
        switch name {
        case "translate":
            let tx = args.count >= 1 ? args[0] : 0
            let ty = args.count >= 2 ? args[1] : 0
            t = t.concatenating(Transform.translate(tx, ty))
        case "scale":
            let sx = args.count >= 1 ? args[0] : 1
            let sy = args.count >= 2 ? args[1] : sx
            t = t.concatenating(Transform.scale(sx, sy))
        case "matrix" where args.count == 6:
            t = t.concatenating(Transform(
                a: args[0], b: args[1], c: args[2],
                d: args[3], tx: args[4], ty: args[5]))
        default:
            continue  // rotate / skew / unknown — silently skipped
        }
    }
    return t
}

var effectiveTransform = Transform.identity
var walker: XMLNode? = pathNode
while let n = walker {
    if let el = n as? XMLElement,
       let attr = el.attribute(forName: "transform")?.stringValue {
        // Path-attribute first, then ancestor groups, outer wrapping inner.
        effectiveTransform = parseTransform(attr).concatenating(effectiveTransform)
    }
    walker = n.parent
}

/// Apply the gathered transform to a single point at emission time.
/// State (`cur`, `lastCubicCtrl`, `sub`) stays in raw SVG coords so
/// relative deltas and reflections compute correctly.
func xfm(_ x: Double, _ y: Double) -> (Double, Double) {
    effectiveTransform.apply(x, y)
}

// MARK: - Tokenize the `d` string

// SVG `d` tokens are either a command letter (M/m/L/l/H/h/V/v/C/c/
// S/s/Z/z/Q/q/T/t/A/a) or a signed number. Numbers may run together
// without separators when the leading sign or decimal point makes
// them unambiguous: "100-50.2.3" → [100, -50.2, .3].

enum Tok: Equatable {
    case cmd(Character)
    case num(Double)
}

func tokenize(_ s: String) -> [Tok] {
    var out: [Tok] = []
    let chars = Array(s)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c.isWhitespace || c == "," { i += 1; continue }
        if c.isLetter {
            out.append(.cmd(c))
            i += 1
            continue
        }
        // Number: optional sign, integer part, optional .frac, optional e[±]exp.
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
        guard i > start else {
            die("unexpected character '\(c)' at offset \(start)")
        }
        let slice = String(chars[start..<i])
        guard let n = Double(slice) else {
            die("could not parse number \"\(slice)\" at offset \(start)")
        }
        out.append(.num(n))
    }
    return out
}

let tokens = tokenize(d)

// MARK: - Output formatting helpers

func fmt(_ x: Double) -> String {
    // Match makeOnBodyPath() style: integers print without ".0".
    if x.rounded() == x, abs(x) < 1e15 { return String(Int(x)) }
    return String(format: "%g", x)
}
func pt(_ x: Double, _ y: Double) -> String {
    let (tx, ty) = xfm(x, y)
    return "CGPoint(x: \(fmt(tx)), y: \(fmt(ty)))"
}

var lines: [String] = []
func emit(_ line: String) { lines.append("    " + line) }

// MARK: - Parser state

var idx = 0
var cur: (x: Double, y: Double) = (0, 0)          // current point
var sub: (x: Double, y: Double) = (0, 0)          // start of current subpath (for Z)
var lastCubicCtrl: (x: Double, y: Double)? = nil  // c2 of last C/c/S/s — for S/s reflection
var lastCmd: Character = " "                      // " " sentinel = no command yet

func num() -> Double {
    guard idx < tokens.count, case .num(let v) = tokens[idx] else {
        die("expected number at token \(idx) (after command '\(lastCmd)')")
    }
    idx += 1
    return v
}
func peekIsNum() -> Bool {
    guard idx < tokens.count else { return false }
    if case .num = tokens[idx] { return true } else { return false }
}

/// Emit a cubic Bézier `addCurve(...)` block (matching makeOnBodyPath's
/// formatting) and advance parser state. All coordinates are absolute.
func cubicTo(c1: (Double, Double), c2: (Double, Double), end: (Double, Double)) {
    emit("p.addCurve(to: \(pt(end.0, end.1)),")
    emit("           control1: \(pt(c1.0, c1.1)),  control2: \(pt(c2.0, c2.1)))")
    lastCubicCtrl = (c2.0, c2.1)
    cur = (end.0, end.1)
}

// MARK: - Command dispatch

while idx < tokens.count {
    guard case .cmd(let c) = tokens[idx] else {
        die("expected command letter at token \(idx), got a stray number")
    }
    idx += 1
    let rel = c.isLowercase

    switch c {

    case "M", "m":
        // First pair = moveto. Implicit subsequent pairs = lineto
        // (per SVG spec). The very first `m` in `d` is treated as
        // absolute regardless of case since there is no current point.
        var firstPair = true
        repeat {
            var x = num(), y = num()
            let isFirstEverCommand = (lastCmd == " " && firstPair)
            if rel && !isFirstEverCommand { x += cur.x; y += cur.y }
            if firstPair {
                emit("p.move(to: \(pt(x, y)))")
                sub = (x, y)
            } else {
                emit("p.addLine(to: \(pt(x, y)))")
            }
            cur = (x, y)
            firstPair = false
            lastCubicCtrl = nil
        } while peekIsNum()

    case "L", "l":
        repeat {
            var x = num(), y = num()
            if rel { x += cur.x; y += cur.y }
            emit("p.addLine(to: \(pt(x, y)))")
            cur = (x, y)
            lastCubicCtrl = nil
        } while peekIsNum()

    case "H", "h":
        repeat {
            var x = num()
            if rel { x += cur.x }
            emit("p.addLine(to: \(pt(x, cur.y)))")
            cur.x = x
            lastCubicCtrl = nil
        } while peekIsNum()

    case "V", "v":
        repeat {
            var y = num()
            if rel { y += cur.y }
            emit("p.addLine(to: \(pt(cur.x, y)))")
            cur.y = y
            lastCubicCtrl = nil
        } while peekIsNum()

    case "C", "c":
        // Cubic Bézier curveto: 6 numbers per segment
        // (c1.x c1.y c2.x c2.y end.x end.y). Lowercase 'c' = all
        // deltas off the current point. Implicit-repeat: each extra
        // 6-tuple is another cubic chained off the previous end.
        repeat {
            var c1x = num(), c1y = num()
            var c2x = num(), c2y = num()
            var ex  = num(), ey  = num()
            if rel {
                c1x += cur.x; c1y += cur.y
                c2x += cur.x; c2y += cur.y
                ex  += cur.x; ey  += cur.y
            }
            cubicTo(c1: (c1x, c1y), c2: (c2x, c2y), end: (ex, ey))
        } while peekIsNum()

    case "S", "s":
        // Smooth cubic: c1 is the reflection of the previous segment's
        // c2 through the current point. If the previous command wasn't
        // C/c/S/s, the reflection point is the current point itself.
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
            cubicTo(c1: c1, c2: (x2, y2), end: (x, y))
        } while peekIsNum()

    case "Z", "z":
        emit("p.closeSubpath()")
        cur = sub
        lastCubicCtrl = nil

    case "Q", "q", "T", "t":
        die("""
            quadratic Bézier (\(c)) is not supported.
            Flatten quadratics to cubics in your vector editor before
            exporting — Figma/Sketch/Illustrator all have a "flatten
            paths" or "outline" option that converts them.
            """)

    case "A", "a":
        die("""
            elliptical arc (\(c)) is not supported.
            Approximate arcs with cubic Béziers in your vector editor
            before exporting (most tools do this automatically when
            you "outline" or "flatten" the path).
            """)

    default:
        die("unknown SVG path command '\(c)'")
    }
    lastCmd = c
}

// MARK: - Emit the Swift block

print("""
static let \(varName): CGPath = {
    let p = CGMutablePath()
\(lines.joined(separator: "\n"))
    return p
}()
""")
