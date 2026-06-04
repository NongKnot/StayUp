import AppKit

/// Top-level category for the skin picker. The Look tab shows a
/// segmented control with these two options; selecting a category
/// filters the skin dropdown to packs of that kind. The split exists
/// because the user's mental model is *what shape is my Duck* before
/// *which exact variant* — picking "Duck" then a recolor is one
/// decision; picking "Other" then a character is a different one.
enum SkinCategory: String, CaseIterable {
    /// Procedural Duck silhouette. Color-variant packs (starter +
    /// future seasonal recolors). The default category.
    case duck   = "Duck"
    /// Custom-geometry packs — characters like Saiyan, Rubber Hero,
    /// any future non-Duck silhouette.
    case other  = "Other"

    var displayName: String { rawValue }
}

/// A themed collection of Duck skins. Packs ship inside the app
/// bundle; updates flow through Sparkle.
///
/// Ownership is **pack-scoped**, persisted in `Settings.unlockedPackIds`.
/// The `starter` pack is implicitly unlocked for every user (the four
/// free skins live inside it). Future paid packs can require a successful
/// `PackUnlocker.unlock(packId:)` call before their skins appear in the picker.
struct DuckPack: Equatable {
    let id:          String      // stable, used as the Settings.unlockedPackIds key
    let displayName: String
    let blurb:       String      // short copy for the picker / unlock sheet
    let priceUSD:    Decimal?    // nil = free; non-nil = paid pack
    let skins:       [DuckSkin]
    let category:    SkinCategory  // picker-level grouping
    /// True only for `starter`. Saves us from having to remember to add
    /// the starter pack ID to `unlockedPackIds` for every fresh install.
    var isUnlockedByDefault: Bool = false

    /// Hard lock — refuse unlock attempts entirely when false, even via the
    /// `getstayup://unlock-pro/<packId>` URL scheme or direct
    /// `PackUnlocker.unlock(packId:)` calls. Used to keep work-in-progress
    /// parked packs (placeholder palettes, unfinished character geometry)
    /// from being accidentally accessible during development.
    var isAvailableForUnlock: Bool = true

    /// The free, default pack — the four skins that shipped with v1.0.
    /// Always implicitly unlocked. Never charge for these. Per BRAND.md:
    /// "the engine stays free forever; cosmetics are paint, not features."
    static let starter = DuckPack(
        id: "starter",
        displayName: "Starter",
        blurb: "The four Ducks that ship with the app.",
        priceUSD: nil,
        skins: [.classic, .rubber, .charcoal, .mono],
        category: .duck,
        isUnlockedByDefault: true
    )

    /// Parked transformation-themed pack. Not registered in public v1 because
    /// the site + unlock story are not launch-ready.
    static let heroMode = DuckPack(
        id: "hero-mode",
        displayName: "Hero Mode",
        blurb: "Duck transforms when it goes to work.",
        priceUSD: nil,
        skins: [.saiyan, .rubberHero],
        category: .other,
        isAvailableForUnlock: false
    )

    /// All packs visible in public v1. Append new packs here; do NOT mutate
    /// `starter` in place (we'd break ownership semantics for users who
    /// already selected a starter skin).
    ///
    /// To ship a new pack:
    /// 1. Add a `static let myPack = DuckPack(...)` above
    /// 2. Append to this `all` array
    /// 3. Add a code mapping in `PackUnlocker.unlockCodes`
    /// 4. Document the unlock path wherever the pack is distributed
    static let all: [DuckPack] = [.starter]

    static func byId(_ id: String) -> DuckPack? {
        return all.first(where: { $0.id == id })
    }

    /// True if the user owns this pack right now. Free packs are always
    /// owned. Future paid packs require a successful `PackUnlocker` flow.
    var isUnlocked: Bool {
        if isUnlockedByDefault { return true }
        return Settings.unlockedPackIds.contains(id)
    }
}
