import AppKit

/// Renders the StayUp Duck icon for the menu bar.
///
/// Geometry ported from the original StayUp Duck design sketch:
/// `ON`  = tall eggplant Duck, big lashed eyes, lip beak, ball feet (locked-in).
/// `OFF` = round blob, ball feet just peeking, closed-eye hint.
/// The design's mini SVG variant (thicker strokes, dropped detail) is what
/// renders well at menu-bar sizes; that's the one we follow here.
/// Walk animation phase. Two frames alternated by MenuController to give
/// Duck a "stepping" motion when WalkDetector reports walking.
enum WalkPhase: Hashable { case leftForward, rightForward }

/// Eye style for the parameterized Duck renderer.
/// - `.open`  — big white sclera + black pupils (ON pose)
/// - `.closed` — downward arcs (OFF/sad pose)
/// - `.blink` — thin horizontal slits (transient ON blink)
enum DuckEyes { case open, closed, blink }

struct IconRenderer {
    private static var cache:     [Bool: NSImage]      = [:]
    private static var walkCache: [WalkPhase: NSImage] = [:]
    /// Zzz frames keyed by phase (0/1/2 = visible Z, -1 = no-Z rest beat).
    /// `nil` map keys aren't allowed, so we use -1 as the rest sentinel.
    private static var zzzCache:  [Int: NSImage]       = [:]
    private static var blinkCache: NSImage?

    static func icon(active: Bool) -> NSImage {
        if let img = cache[active] { return img }
        let img = render(active: active)
        cache[active] = img
        return img
    }

    static func walkIcon(phase: WalkPhase) -> NSImage {
        if let img = walkCache[phase] { return img }
        let img = renderWalk(phase: phase)
        walkCache[phase] = img
        return img
    }

    /// Render the ON Duck at an arbitrary size for the About panel and any
    /// other large-format use. Always renders the Classic colored Duck
    /// regardless of the user's menu-bar skin — the About card is a brand
    /// surface, the picker shouldn't change it.
    static func aboutIcon(size: CGFloat) -> NSImage {
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Force Classic for this render pass. The override is process-
            // global state but Cocoa drives this drawing handler on the
            // main thread, so the set/restore pair is safe.
            let prevSkin = skinOverride
            skinOverride = .classic
            defer { skinOverride = prevSkin }

            let s = size / canvasPx
            ctx.translateBy(x: 0, y: size)
            ctx.scaleBy(x: s, y: -s)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            drawOn(ctx)
            return true
        }
    }

    static func invalidateCache() {
        cache.removeAll()
        walkCache.removeAll()
        zzzCache.removeAll()
        blinkCache = nil
    }

    // MARK: - Sizing
    //
    // Source viewBox is 400×500. We render to a 22×22 canvas so NSStatusItem's
    // variableLength stays stable across state changes (rather than letting the
    // Duck's natural aspect drive the menu-bar item width). Both states are
    // anchored on the same vertical scale so ON looks taller than OFF — that's
    // the silhouette signal users read.

    private static let canvasPx: CGFloat = 22

    /// Vertical scale applied to both states. Picked so the ON Duck (tallest
    /// content, ~436 SVG units) fits within the 22px canvas with 1px padding.
    private static let unitScale: CGFloat = canvasPx / 440.0

    // MARK: - Colors
    //
    // Body / beak / outline come from the active DuckSkin so users can swap
    // Duck variants. Eye sclera stays white across all skins so the eyes
    // always read.

    /// Optional skin override scoped to a single render pass. `aboutIcon`
    /// uses this to always show the Classic colored Duck even when the
    /// user's selected menu-bar skin is Mono / Charcoal / etc. Set inside
    /// the NSImage drawing handler and cleared via `defer` so the global
    /// menu-bar render isn't affected.
    private static var skinOverride: DuckSkin?

    /// Skin used by all draw* / color helpers — the override if set,
    /// otherwise the user's persisted choice.
    private static var activeSkin: DuckSkin { skinOverride ?? Settings.currentSkin }

    /// True when the system's effective appearance resolves to `darkAqua`.
    /// macOS menu bar appearance follows system appearance on Apple Silicon
    /// (the "menu bar matches Desktop" setting is gone in modern macOS), so
    /// reading `NSApp.effectiveAppearance` is the right signal. Cached per
    /// render pass — the appearance can't change mid-draw, and cache
    /// invalidation on appearance change is handled by the observer
    /// registered in AppDelegate.
    private static var isDarkMenuBar: Bool {
        guard let match = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) else {
            return false
        }
        return match == .darkAqua
    }

    /// True while a render pass is drawing the OFF (disengaged / chibi)
    /// pose. Lets the color resolvers below pick a skin's OFF-state
    /// override palette (e.g. Saiyan goes back to gi-orange when idle).
    /// Set by `render(active:)` before calling `drawOff`; reset after.
    /// Skinned access only — not exposed to other classes.
    private static var renderingOffState: Bool = false

    /// Color resolver order:
    /// 1. If rendering OFF and skin has an off-state override → use it
    /// 2. Else if dark menu bar and skin has a dark override → use it
    /// 3. Else → use the base light/ON palette
    ///
    /// OFF wins over dark to keep transformation skins (Saiyan, Rubber
    /// Hero) visually consistent across menu-bar appearances. Skins that
    /// want OFF *and* dark adaptation would need `offDarkBody` etc. —
    /// add when the first skin actually needs it.
    private static var body:  CGColor {
        if renderingOffState, let off = activeSkin.offBody    { return off.cgColor }
        if isDarkMenuBar,     let dark = activeSkin.darkBody  { return dark.cgColor }
        return activeSkin.body.cgColor
    }
    private static var beak:  CGColor {
        if renderingOffState, let off = activeSkin.offBeak    { return off.cgColor }
        if isDarkMenuBar,     let dark = activeSkin.darkBeak  { return dark.cgColor }
        return activeSkin.beak.cgColor
    }
    private static var ink:   CGColor {
        if renderingOffState, let off = activeSkin.offOutline { return off.cgColor }
        if isDarkMenuBar,     let dark = activeSkin.darkOutline { return dark.cgColor }
        return activeSkin.outline.cgColor
    }
    /// Eye sclera + the white inner core of the Zzz strokes. Constant white
    /// regardless of skin so they pop on any body color (especially Charcoal).
    private static let sclera = NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1).cgColor

    // MARK: - Render dispatch

    private static func render(active: Bool) -> NSImage {
        let size = NSSize(width: canvasPx, height: canvasPx)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // SVG y-down → Cocoa y-up flip, plus uniform scale.
            // Centering offsets are computed per-state (ON is portrait, OFF
            // is squarer) so each Duck sits centered on the canvas.
            ctx.translateBy(x: 0, y: canvasPx)
            ctx.scaleBy(x: 1, y: -1)

            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            if active {
                if let customPath = activeSkin.customOnPath {
                    drawCustomCharacter(ctx, path: customPath)
                } else {
                    drawOn(ctx)
                }
            } else {
                renderingOffState = true
                defer { renderingOffState = false }
                // OFF state can use a separate custom path, fall back to
                // customOnPath if only one was provided, or fall through
                // to the procedural OFF Duck if neither is set.
                if let customPath = activeSkin.customOffPath ?? activeSkin.customOnPath {
                    drawCustomCharacter(ctx, path: customPath)
                } else {
                    drawOff(ctx)
                }
            }
            return true
        }
        img.isTemplate = activeSkin.isTemplate
        return img
    }

    /// Render a Pro-pack character silhouette. Fill with `body` (or
    /// `offBody` when OFF), stroke with `outline` (or `offOutline` when
    /// OFF). Same 400×500 source viewBox as Duck — the existing
    /// `applyContentTransform` scales it down to the menu-bar canvas.
    ///
    /// No eye dots, no beak, no ball feet — character skins are filled
    /// silhouettes by design (22×22 doesn't give us pixels for face
    /// detail). If a future character needs face details, the path
    /// should encode them as subpaths and we'd need a multi-color
    /// rendering pipeline. Out of scope for now.
    private static func drawCustomCharacter(_ ctx: CGContext, path: CGPath) {
        ctx.saveGState()
        applyContentTransform(ctx, contentTop: 30)
        fillStroke(ctx, path: path, fill: body, stroke: ink, width: 22)
        ctx.restoreGState()
    }

    // MARK: - ON / OFF / transition — one parameterized renderer
    //
    // ON and OFF share the same body path, eyes, beak, and feet — only the
    // warp factors and eye style differ. Exposing the warp lets us tween
    // smoothly between them for the engage/disengage animation, and lets us
    // reuse this for the eye-blink frame.

    /// Warp factors for the chibi OFF pose. Body anchors at the foot
    /// center (200, 462) so feet stay planted while the body shrinks
    /// upward into the rounder silhouette.
    static let offDx: CGFloat = 2.10
    static let offDy: CGFloat = 0.62

    /// Render Duck at any warp + eye state.
    private static func drawDuck(_ ctx: CGContext,
                                 dx: CGFloat, dy: CGFloat,
                                 eyes: DuckEyes) {
        ctx.saveGState()
        applyContentTransform(ctx, contentTop: 30)

        let pivot = CGPoint(x: 200, y: 462)
        var warp = CGAffineTransform(translationX: pivot.x, y: pivot.y)
            .scaledBy(x: dx, y: dy)
            .translatedBy(x: -pivot.x, y: -pivot.y)

        func wp(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x, y: y).applying(warp)
        }

        let bodyPath = makeOnBodyPath()
        let warpedBody = bodyPath.copy(using: &warp)!

        if activeSkin.isTemplate {
            // Mono / template silhouette — fill body + ball feet, then
            // punch out small eye dots so the menu bar shows through and
            // Duck has a face. No outlines, no beak. macOS handles
            // system-color substitution via `isTemplate = true` on the image.
            ctx.setFillColor(body)
            ctx.addPath(warpedBody)
            ctx.fillPath()
            for cx: CGFloat in [160, 240] {
                let c = wp(cx, 462)
                let r: CGFloat = 28
                ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            // Eye dots — only when eyes are open. Closed/blink states show
            // a faceless silhouette, which reads correctly as "asleep".
            if eyes == .open {
                ctx.saveGState()
                ctx.setBlendMode(.destinationOut)
                ctx.setFillColor(NSColor.black.cgColor)
                let eyeR: CGFloat = 14
                for (sx, sy): (CGFloat, CGFloat) in [(138, 175), (262, 175)] {
                    let c = wp(sx, sy)
                    ctx.fillEllipse(in: CGRect(x: c.x - eyeR, y: c.y - eyeR,
                                                width: eyeR * 2, height: eyeR * 2))
                }
                ctx.restoreGState()
            }
            ctx.restoreGState()
            return
        }

        // Color skin — full face render
        fillStroke(ctx, path: warpedBody, fill: body, stroke: ink, width: 22)

        let leftEye  = wp(138, 175)
        let rightEye = wp(262, 175)
        switch eyes {
        case .open:   drawEyesOpen(ctx,   leftAt: leftEye, rightAt: rightEye)
        case .closed: drawEyesClosed(ctx, leftAt: leftEye, rightAt: rightEye)
        case .blink:  drawEyesBlink(ctx,  leftAt: leftEye, rightAt: rightEye)
        }
        drawLipBeak(ctx, at: wp(200, 212))
        drawBallFoot(ctx, at: wp(160, 462))
        drawBallFoot(ctx, at: wp(240, 462))

        ctx.restoreGState()
    }

    private static func drawOn(_ ctx: CGContext) {
        drawDuck(ctx, dx: 1.0, dy: 1.0, eyes: .open)
    }

    /// ON pose with eyes momentarily shut. Used as a 120ms transient frame
    /// every few seconds so Duck looks alive instead of frozen. Cached:
    /// the blink frame never changes, no point re-rendering.
    static func iconBlink() -> NSImage {
        if let img = blinkCache { return img }
        let img = uncachedRender { drawDuck($0, dx: 1.0, dy: 1.0, eyes: .blink) }
        blinkCache = img
        return img
    }

    /// Render at arbitrary warp + eye state. Bypasses the cache because
    /// the transition animator picks fresh dx/dy each frame.
    static func iconWarped(dx: CGFloat, dy: CGFloat, eyes: DuckEyes) -> NSImage {
        uncachedRender { drawDuck($0, dx: dx, dy: dy, eyes: eyes) }
    }

    private static func uncachedRender(_ draw: @escaping (CGContext) -> Void) -> NSImage {
        let size = NSSize(width: canvasPx, height: canvasPx)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 0, y: canvasPx)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            draw(ctx)
            return true
        }
        img.isTemplate = activeSkin.isTemplate
        return img
    }

    // MARK: - WALK state — body tilted, ball feet in stride

    private static func renderWalk(phase: WalkPhase) -> NSImage {
        let size = NSSize(width: canvasPx, height: canvasPx)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 0, y: canvasPx)
            ctx.scaleBy(x: 1, y: -1)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            drawWalk(ctx, phase: phase)
            return true
        }
        img.isTemplate = activeSkin.isTemplate
        return img
    }

    private static func drawWalk(_ ctx: CGContext, phase: WalkPhase) {
        ctx.saveGState()
        applyContentTransform(ctx, contentTop: 30)

        let leftLeading = (phase == .leftForward)
        let bodyTilt:    CGFloat = leftLeading ? -6 : 6           // degrees
        let frontFootCx: CGFloat = leftLeading ? 126 : 274        // lifted, forward
        let backFootCx:  CGFloat = leftLeading ? 248 : 152        // planted, behind
        let frontFootCy: CGFloat = 452                            // higher = lifted
        let backFootCy:  CGFloat = 472                            // lower = planted

        let template = activeSkin.isTemplate

        // BODY (+ face if not template) — rotated around mid-body
        ctx.saveGState()
        ctx.translateBy(x: 200, y: 260)
        ctx.rotate(by: bodyTilt * .pi / 180)
        ctx.translateBy(x: -200, y: -260)

        if template {
            ctx.setFillColor(body)
            ctx.addPath(makeOnBodyPath())
            ctx.fillPath()
            // Eye cutouts inside the rotated context so they tilt with the
            // body lean — same as a real walking Duck's gaze.
            ctx.saveGState()
            ctx.setBlendMode(.destinationOut)
            ctx.setFillColor(NSColor.black.cgColor)
            let eyeR: CGFloat = 14
            for cx: CGFloat in [138, 262] {
                ctx.fillEllipse(in: CGRect(x: cx - eyeR, y: 175 - eyeR,
                                            width: eyeR * 2, height: eyeR * 2))
            }
            ctx.restoreGState()
        } else {
            fillStroke(ctx, path: makeOnBodyPath(), fill: body, stroke: ink, width: 22)
            drawEyesOpen(ctx, leftAt:  CGPoint(x: 138, y: 175),
                              rightAt: CGPoint(x: 262, y: 175))
            drawLipBeak(ctx, at: CGPoint(x: 200, y: 212))
        }
        ctx.restoreGState()

        // FEET — drawn outside the body rotation so they read as planted on
        // the canvas floor regardless of body lean.
        if template {
            ctx.setFillColor(body)
            for (cx, cy) in [(frontFootCx, frontFootCy), (backFootCx, backFootCy)] {
                let r: CGFloat = 28
                ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
        } else {
            drawBallFoot(ctx, at: CGPoint(x: frontFootCx, y: frontFootCy))
            drawBallFoot(ctx, at: CGPoint(x: backFootCx,  y: backFootCy))
        }

        ctx.restoreGState()
    }

    private static func drawOff(_ ctx: CGContext) {
        drawDuck(ctx, dx: offDx, dy: offDy, eyes: .closed)
    }

    // MARK: - OFF Zzz frame — chibi Duck with a "z" drifting up

    /// One frame of the sleeping-Zzz animation. `phase` 0..2 cycles through
    /// the Z growing and rising; `nil` is the "no Z" rest frame. Cached so
    /// the 0.6s tick doesn't re-render — just swaps a pointer.
    static func iconOffZ(phase: Int?) -> NSImage {
        let key = phase ?? -1
        if let img = zzzCache[key] { return img }
        let img = uncachedRender { ctx in
            drawDuck(ctx, dx: offDx, dy: offDy, eyes: .closed)
            if let p = phase {
                drawZzz(ctx, phase: p)
            }
        }
        zzzCache[key] = img
        return img
    }

    private static func drawZzz(_ ctx: CGContext, phase: Int) {
        ctx.saveGState()
        applyContentTransform(ctx, contentTop: 30)

        // Z grows + rises over the phases. SVG y-down: smaller y = higher
        // visually, so the Z goes from y≈300 (low, near head) up to y≈100.
        let positions: [(cx: CGFloat, cy: CGFloat, size: CGFloat, alpha: CGFloat)] = [
            (305, 290, 52, 0.95),
            (340, 200, 70, 0.85),
            (360, 110, 90, 0.55),
        ]
        let p = max(0, min(2, phase))
        let z = positions[p]

        // Stylized "Z" — three strokes (top horizontal, diagonal, bottom
        // horizontal). Drawn as a dark outer stroke + a white inner stroke
        // on the same path so the letter reads on both light and dark
        // menu bar backgrounds, mirroring Duck body's outlined-white
        // convention. Without the white inner pass the Z disappears in
        // dark mode.
        let half = z.size / 2
        let path = CGMutablePath()
        path.move(to:    CGPoint(x: z.cx - half, y: z.cy - half))
        path.addLine(to: CGPoint(x: z.cx + half, y: z.cy - half))
        path.addLine(to: CGPoint(x: z.cx - half, y: z.cy + half))
        path.addLine(to: CGPoint(x: z.cx + half, y: z.cy + half))

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Outer dark halo
        ctx.setStrokeColor(ink.copy(alpha: z.alpha)!)
        ctx.setLineWidth(28)
        ctx.addPath(path)
        ctx.strokePath()

        // Inner white core (always white sclera color, NOT the body —
        // a yellow Z core on the Rubber skin would fail the dark-mode test)
        ctx.setStrokeColor(sclera.copy(alpha: z.alpha)!)
        ctx.setLineWidth(14)
        ctx.addPath(path)
        ctx.strokePath()

        ctx.restoreGState()
    }

    // MARK: - Shared geometry helpers

    private static func applyContentTransform(_ ctx: CGContext, contentTop: CGFloat) {
        let scale = unitScale
        let scaledW = 400.0 * scale
        let xOffset = (canvasPx - scaledW) / 2.0
        ctx.translateBy(x: xOffset, y: -contentTop * scale)
        ctx.scaleBy(x: scale, y: scale)
    }

    private static func makeOnBodyPath() -> CGMutablePath {
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 200, y: 50))
        body.addCurve(to: CGPoint(x: 138, y: 180),
                      control1: CGPoint(x: 145, y: 50),  control2: CGPoint(x: 130, y: 110))
        body.addCurve(to: CGPoint(x: 132, y: 360),
                      control1: CGPoint(x: 144, y: 240), control2: CGPoint(x: 142, y: 300))
        body.addCurve(to: CGPoint(x: 200, y: 452),
                      control1: CGPoint(x: 122, y: 410), control2: CGPoint(x: 132, y: 448))
        body.addCurve(to: CGPoint(x: 268, y: 360),
                      control1: CGPoint(x: 268, y: 448), control2: CGPoint(x: 278, y: 410))
        body.addCurve(to: CGPoint(x: 262, y: 180),
                      control1: CGPoint(x: 258, y: 300), control2: CGPoint(x: 256, y: 240))
        body.addCurve(to: CGPoint(x: 200, y: 50),
                      control1: CGPoint(x: 270, y: 110), control2: CGPoint(x: 255, y: 50))
        body.closeSubpath()
        return body
    }

    private static func drawEyesOpen(_ ctx: CGContext, leftAt: CGPoint, rightAt: CGPoint) {
        for c in [leftAt, rightAt] {
            let r: CGFloat = 38
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(sclera)        // always white so eyes read on any skin
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(14)
            ctx.fillEllipse(in: rect)
            ctx.strokeEllipse(in: rect)
        }
        // Pupils: nudged 6 source units toward each other, like in the design
        ctx.setFillColor(ink)
        ctx.fillEllipse(in: CGRect(x: leftAt.x  - 6 - 9, y: leftAt.y  + 3 - 9, width: 18, height: 18))
        ctx.fillEllipse(in: CGRect(x: rightAt.x + 6 - 9, y: rightAt.y + 3 - 9, width: 18, height: 18))
    }

    /// Eyes for the brief mid-blink frame. Same position as `.open`, just
    /// rendered as thin horizontal slits instead of full circles.
    private static func drawEyesBlink(_ ctx: CGContext, leftAt: CGPoint, rightAt: CGPoint) {
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(14)
        ctx.setLineCap(.round)
        for c in [leftAt, rightAt] {
            let p = CGMutablePath()
            p.move(to:    CGPoint(x: c.x - 28, y: c.y))
            p.addLine(to: CGPoint(x: c.x + 28, y: c.y))
            ctx.addPath(p)
            ctx.strokePath()
        }
    }

    private static func drawEyesClosed(_ ctx: CGContext, leftAt: CGPoint, rightAt: CGPoint) {
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(22)
        ctx.setLineCap(.round)
        for c in [leftAt, rightAt] {
            let arc = CGMutablePath()
            arc.move(to: CGPoint(x: c.x - 28, y: c.y))
            arc.addQuadCurve(to: CGPoint(x: c.x + 28, y: c.y),
                              control: CGPoint(x: c.x, y: c.y + 22))
            ctx.addPath(arc)
            ctx.strokePath()
        }
    }

    private static func drawLipBeak(_ ctx: CGContext, at center: CGPoint) {
        let cx = center.x, cy = center.y
        // Lip-shape lifted from the design, recentered on `at`.
        // Source: M 162 200, C 178 188, 222 188, 238 200,
        //         C 248 214, 232 226, 200 224,
        //         C 168 226, 152 214, 162 200 Z
        // Original beak center ≈ (200, 212). Translate that to (cx, cy).
        let off = CGPoint(x: cx - 200, y: cy - 212)
        func t(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + off.x, y: y + off.y) }

        let p = CGMutablePath()
        p.move(to: t(162, 200))
        p.addCurve(to: t(238, 200),
                   control1: t(178, 188), control2: t(222, 188))
        p.addCurve(to: t(200, 224),
                   control1: t(248, 214), control2: t(232, 226))
        p.addCurve(to: t(162, 200),
                   control1: t(168, 226), control2: t(152, 214))
        p.closeSubpath()
        fillStroke(ctx, path: p, fill: beak, stroke: ink, width: 14)
    }

    private static func drawBallFoot(_ ctx: CGContext, at center: CGPoint) {
        let r: CGFloat = 28
        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        ctx.setFillColor(beak)
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(14)
        ctx.fillEllipse(in: rect)
        ctx.strokeEllipse(in: rect)
    }

    // MARK: - Helpers

    private static func fillStroke(_ ctx: CGContext, path: CGPath,
                                    fill: CGColor, stroke: CGColor, width: CGFloat) {
        ctx.setFillColor(fill)
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(width)
        ctx.addPath(path)
        ctx.drawPath(using: .fillStroke)
    }

    // MARK: - Debug — dump PNGs for visual verification

    /// Set env `STAYUP_DUMPICONS=1` (handled in AppDelegate) to write
    /// 22×22 and 88×88 (4×) renderings of both states to /tmp/stayup-icons/.
    static func dumpToDisk() {
        let dir = "/tmp/stayup-icons"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        enum Variant { case on, off, walkLeft, walkRight, blink, zzz0, zzz1, zzz2, transitionMid }
        let variants: [(Variant, String)] = [
            (.on,            "on"),
            (.off,           "off"),
            (.walkLeft,      "walk-L"),
            (.walkRight,     "walk-R"),
            (.blink,         "blink"),
            (.zzz0,          "zzz0"),
            (.zzz1,          "zzz1"),
            (.zzz2,          "zzz2"),
            (.transitionMid, "tween"),
        ]
        for (v, label) in variants {
            for scale: CGFloat in [1, 4] {
                let target = canvasPx * scale
                let img = NSImage(size: NSSize(width: target, height: target), flipped: false) { _ in
                    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                    ctx.translateBy(x: 0, y: target)
                    ctx.scaleBy(x: scale, y: -scale)
                    ctx.setLineCap(.round)
                    ctx.setLineJoin(.round)
                    // Track OFF-state palette during dump so transformation
                    // skins (Saiyan, Rubber Hero) render their off-pose
                    // colors correctly. Same flag the live render path uses.
                    let isOffVariant = (v == .off || v == .zzz0 || v == .zzz1 || v == .zzz2)
                    if isOffVariant { renderingOffState = true }
                    defer { renderingOffState = false }
                    switch v {
                    case .on:            drawOn(ctx)
                    case .off:           drawOff(ctx)
                    case .walkLeft:      drawWalk(ctx, phase: .leftForward)
                    case .walkRight:     drawWalk(ctx, phase: .rightForward)
                    case .blink:         drawDuck(ctx, dx: 1.0, dy: 1.0, eyes: .blink)
                    case .zzz0:          drawDuck(ctx, dx: offDx, dy: offDy, eyes: .closed); drawZzz(ctx, phase: 0)
                    case .zzz1:          drawDuck(ctx, dx: offDx, dy: offDy, eyes: .closed); drawZzz(ctx, phase: 1)
                    case .zzz2:          drawDuck(ctx, dx: offDx, dy: offDy, eyes: .closed); drawZzz(ctx, phase: 2)
                    case .transitionMid: drawDuck(ctx, dx: 1.55, dy: 0.81, eyes: .closed)  // halfway OFF→ON
                    }
                    return true
                }
                if let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    let path = "\(dir)/duck-\(label)-\(Int(target)).png"
                    try? png.write(to: URL(fileURLWithPath: path))
                    FileHandle.standardError.write(Data("[IconDump] wrote \(path)\n".utf8))
                }
            }
        }
    }
}
