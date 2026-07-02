import AppKit

/// Cosmetic palette for Duck. Lives in its own file so adding skins
/// later (paid packs, seasonal variants) is just an append to `all`.
///
/// Built-in menu-bar Duck skins fill body / beak / feet without decorative
/// outlines. The `outline` color remains the shared ink color for pupils,
/// closed/blink eyes, Zzz contrast, and custom silhouette strokes.
///
/// Eye sclera is always white (handled in IconRenderer) so eyes pop on
/// any body color.
struct DuckSkin {
    let id:          String   // stable, used as the UserDefaults key value
    let displayName: String
    let body:    NSColor      // body fill (light-mode menu bar)
    let beak:    NSColor      // beak + ball-foot fill (light-mode)
    let outline: NSColor      // facial ink + Zzz/custom stroke (light-mode)
    /// `true` → strip outlines + face details, fill the silhouette with
    /// `body`, mark the rendered NSImage as `isTemplate = true` so macOS
    /// substitutes its system color and adapts to light/dark menu bars.
    var isTemplate: Bool = false

    /// Optional dark-menu-bar overrides. When the system's effective
    /// appearance resolves to `darkAqua` and the skin provides a non-nil
    /// value here, IconRenderer uses these instead of `body`/`beak`/
    /// `outline`. Skins that leave them nil keep their single palette and
    /// render the same on light + dark menu bars (which is fine for Mono,
    /// Charcoal, Rubber — only Classic feels harsh-bright on dark).
    var darkBody:    NSColor? = nil
    var darkBeak:    NSColor? = nil
    var darkOutline: NSColor? = nil

    /// Optional OFF-state palette. When present, IconRenderer uses these
    /// colors for the disengaged / chibi pose instead of `body`/`beak`/
    /// `outline`. Enables "transformation" skins — Saiyan goes SSJ-gold
    /// when engaged, settles back to gi-orange when idle. Most skins
    /// (Classic / Rubber / Charcoal / Mono) leave these nil and use one
    /// palette for both states; the geometric chibi warp does the rest.
    ///
    /// **OFF wins over dark-mode adaptation when defined.** If you want a
    /// skin that adapts to both states *and* dark mode, you'd need to add
    /// `offDarkBody` etc. — not modeled yet; first time a skin actually
    /// needs it, add the four fields and update IconRenderer's resolvers.
    var offBody:    NSColor? = nil
    var offBeak:    NSColor? = nil
    var offOutline: NSColor? = nil

    /// Optional custom geometry for the ON / OFF poses. When non-nil,
    /// `IconRenderer` renders this path instead of the procedural Duck
    /// silhouette — fill = `body` (or `offBody` for OFF), stroke = `outline`
    /// (or `offOutline`). Enables future character-shape skins.
    ///
    /// Paths are in the same 400×500 source viewBox as Duck — the
    /// IconRenderer transform scales them down to 22×22 menu-bar canvas.
    /// Don't try to author at 22×22 directly; design at 400×500 and let
    /// the renderer handle the scale.
    ///
    /// **Free starter skins (Classic / Rubber / Charcoal / Mono) leave
    /// these nil** and use procedural Duck rendering. Parked character
    /// experiments populate them, but those packs are not registered in
    /// public v1.
    ///
    /// Walking animation tilts the ON path ±6° around its center.
    /// Blink animation is skipped for custom paths (no eye geometry).
    /// Zzz animation works as a separate overlay above the OFF path.
    /// Tween between ON↔OFF snaps instantly for custom paths (different
    /// topologies make smooth interpolation undefined).
    var customOnPath:  CGPath? = nil
    var customOffPath: CGPath? = nil

    /// Mark a parked skin as work-in-progress. Public v1 does not surface
    /// these skins; keep the flag for future pack UI.
    var isWorkInProgress: Bool = false
}

/// Manual `Equatable` — compares by `id` only. CGPath is a CoreFoundation
/// class with no Swift Equatable synthesis, so we can't rely on the
/// auto-synthesized conformance once `customOnPath` was added. ID-only
/// comparison is sufficient because skin IDs are unique across packs.
extension DuckSkin: Equatable {
    static func == (lhs: DuckSkin, rhs: DuckSkin) -> Bool {
        lhs.id == rhs.id
    }

    static let classic = DuckSkin(
        id: "classic",
        displayName: "Classic",
        body:    NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        beak:    NSColor(srgbRed: 1.00, green: 0.61, blue: 0.24, alpha: 1),
        outline: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
        // Dark-menu-bar adapt was tried (`darkBody`/`darkBeak`/`darkOutline`)
        // but the lighter-grey outline reads worse than letting the dark
        // outline disappear against the dark menu bar — the white body
        // already gives a clean silhouette without needing an explicit
        // edge. Reverted 2026-05-18. Infrastructure still there if a
        // future skin needs it; Classic stays on its base palette.
    )

    static let rubber = DuckSkin(
        id: "rubber",
        displayName: "Rubber",
        body:    NSColor(srgbRed: 1.00, green: 0.84, blue: 0.20, alpha: 1),  // yellow Duck
        beak:    NSColor(srgbRed: 1.00, green: 0.55, blue: 0.10, alpha: 1),  // a hair darker so it reads on yellow
        outline: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    )

    static let charcoal = DuckSkin(
        id: "charcoal",
        displayName: "Charcoal",
        body:    NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1),  // dark body
        beak:    NSColor(srgbRed: 1.00, green: 0.61, blue: 0.24, alpha: 1),  // orange still pops
        outline: NSColor(srgbRed: 0.45, green: 0.45, blue: 0.48, alpha: 1)   // medium grey reads on dark body AND on white sclera
    )

    /// Minimalist white silhouette. No outline, no face details — just
    /// the body shape + ball feet. `isTemplate = true` so macOS adapts
    /// it: appears white on a dark menu bar, dark on a light one. Last
    /// in the picker so Classic stays the default.
    static let mono = DuckSkin(
        id: "mono",
        displayName: "Mono",
        body:    .white,
        beak:    .white,
        outline: .white,
        isTemplate: true
    )

    // MARK: - Parked character-pack experiments
    //
    // Transformation skins: ON state is the powered-up form, OFF state
    // settles back to the calm form. Visual story = Duck powers up
    // when StayUp is engaged. Both skins use the `offBody/offBeak/
    // offOutline` palette overrides — see DuckSkin docs for resolver order.

    /// Transformation skin. ON = bright/powered-up palette (gold body,
    /// amber ink). OFF = calm palette (orange body, peach beak,
    /// black ink).
    static let saiyan = DuckSkin(
        id: "saiyan",
        displayName: "Saiyan",
        body:    NSColor(srgbRed: 1.00, green: 0.85, blue: 0.20, alpha: 1),
        beak:    NSColor(srgbRed: 1.00, green: 0.55, blue: 0.10, alpha: 1),
        outline: NSColor(srgbRed: 0.55, green: 0.28, blue: 0.05, alpha: 1),
        offBody:    NSColor(srgbRed: 0.95, green: 0.40, blue: 0.10, alpha: 1),
        offBeak:    NSColor(srgbRed: 0.95, green: 0.75, blue: 0.55, alpha: 1),
        offOutline: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        isWorkInProgress: true
    )

    /// Transformation skin. ON = ivory body + magenta accent + electric
    /// blue ink. OFF = red body, peach beak, black ink.
    static let rubberHero = DuckSkin(
        id: "rubber-hero",
        displayName: "Rubber Hero",
        body:    NSColor(srgbRed: 1.00, green: 0.98, blue: 0.96, alpha: 1),
        beak:    NSColor(srgbRed: 0.95, green: 0.30, blue: 0.50, alpha: 1),
        outline: NSColor(srgbRed: 0.25, green: 0.20, blue: 0.55, alpha: 1),
        offBody:    NSColor(srgbRed: 0.85, green: 0.20, blue: 0.20, alpha: 1),
        offBeak:    NSColor(srgbRed: 0.95, green: 0.75, blue: 0.55, alpha: 1),
        offOutline: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        isWorkInProgress: true
    )

    /// All skins across all packs, flattened in pack display order. Classic
    /// stays first because `DuckPack.starter` is first in `DuckPack.all`.
    /// Adding a new pack appends its skins to this list automatically —
    /// no separate maintenance.
    static var all: [DuckSkin] {
        DuckPack.all.flatMap { $0.skins }
    }

    static func byId(_ id: String) -> DuckSkin {
        all.first(where: { $0.id == id }) ?? .classic
    }

}
