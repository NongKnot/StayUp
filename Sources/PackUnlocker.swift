import Foundation

/// Single entry point for pack-unlock mechanisms.
///
/// `attempt(code:)` validates future user-typed codes against the static
/// `unlockCodes` dict. `unlock(packId:)` is the programmatic path for the
/// parked `getstayup://unlock-pro/<packId>` URL scheme. All paths converge
/// on `Settings.unlockedPackIds`.
///
/// The function shape is stable so swapping the validation mechanism
/// later is a single-file change — no UI rewrite, no Settings-storage
/// migration. No network calls today; if a future mechanism adds one,
/// it must be triggered by an explicit user action, never on launch.
enum PackUnlocker {
    enum UnlockResult: Equatable {
        case success(packId: String)
        case unknownCode
        case alreadyUnlocked(packId: String)
        case error(String)
    }

    /// Memorable static codes mapped to pack IDs. Public v1 ships no
    /// unlockable packs, so this stays empty until the site + pack story
    /// are ready. `attempt(code:)` lowercases user input before lookup.
    private static let unlockCodes: [String: String] = [:]

    /// Attempt to redeem a user-supplied code. Trim + lowercase the input so
    /// trailing newlines and mixed case don't trip honest users when a future
    /// visible entry point exists.
    ///
    /// Returns `.success(packId:)` on a fresh unlock, `.alreadyUnlocked`
    /// if the user re-types a code they've already redeemed, and
    /// `.unknownCode` for anything not in the static dict above.
    static func attempt(code: String) -> UnlockResult {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return .unknownCode }
        guard let packId = unlockCodes[cleaned] else { return .unknownCode }
        return unlock(packId: packId)
    }

    /// Programmatic unlock — called by the `getstayup://unlock-pro/<packId>`
    /// URL scheme handler. Idempotent: unlocking an already-owned pack
    /// reports `.alreadyUnlocked` and changes nothing.
    ///
    /// Packs with `isAvailableForUnlock == false` are refused. Used to
    /// keep work-in-progress packs from being accidentally accessible
    /// during development.
    @discardableResult
    static func unlock(packId: String) -> UnlockResult {
        guard let pack = DuckPack.byId(packId) else {
            return .error("pack \"\(packId)\" does not exist")
        }
        if !pack.isAvailableForUnlock {
            return .error("pack \"\(packId)\" is locked (not available for unlock yet)")
        }
        var current = Settings.unlockedPackIds
        if current.contains(packId) {
            return .alreadyUnlocked(packId: packId)
        }
        current.insert(packId)
        Settings.unlockedPackIds = current
        return .success(packId: packId)
    }

    /// Lock-back path. Reserved for future "refund" / "transfer to another
    /// machine" flows. The starter pack cannot be locked — it's free and
    /// always implicit. No-op if not currently unlocked.
    static func lock(packId: String) {
        guard packId != DuckPack.starter.id else { return }
        var current = Settings.unlockedPackIds
        guard current.contains(packId) else { return }
        current.remove(packId)
        Settings.unlockedPackIds = current
    }
}
