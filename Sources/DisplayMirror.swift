import CoreGraphics

// ============================================================================
// Thin wrapper over macOS's PUBLIC display-mirroring configuration API. Used
// on laptops to mirror the phantom (VirtualDisplay) onto the built-in panel:
// lid-open the phantom is invisible (a mirror adds no desktop space), and at
// lid-close a display that ALREADY exists lets macOS's own clamshell logic
// power the built-in genuinely off (bench: JIT spawn-at-close never triggers
// clamshell, 0/200 — pre-existence is the whole trick).
//
// Every call here mutates live display topology → callers MUST stay inside
// the settle-deferred reapplyScreenPolicy path (1.3.2 Dock-crash rule).
// Failure is a Bool, never a throw: the caller's fallback (mirror veto →
// backlight-0) is shipped 1.3.6 behavior, so failing is always safe.
// ============================================================================
enum DisplayMirror {

    /// Locate the phantom by its fixed vendor+serial (VirtualDisplay's
    /// descriptor — keep in sync). Searches the ONLINE list, not the active
    /// list: a mirror-slave display leaves the active list by design.
    static func phantomDisplayID() -> CGDirectDisplayID? {
        onlineDisplays().first {
            CGDisplayVendorNumber($0) == 0xF0F0 && CGDisplaySerialNumber($0) == 0x57415944
        }
    }

    /// True while the built-in panel is in the ONLINE display list. After a
    /// lid-close this is the clamshell verdict: false = macOS powered the
    /// panel off (the goal); true = clamshell didn't engage → backlight-0
    /// fallback. Distinct from the ACTIVE list (a mirror-slave is online but
    /// not active; a clamshelled panel is neither).
    static func builtinIsInOnlineList() -> Bool {
        onlineDisplays().contains { CGDisplayIsBuiltin($0) != 0 }
    }

    static func isMirrored(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
    }

    /// Make `phantom` a mirror of `builtin` (built-in stays primary). `.forSession`
    /// scope: a crash or logout dissolves the mirror on its own — no persisted
    /// topology state the app could get wrong (the BuiltinDisplayGate lesson).
    static func mirror(_ phantom: CGDirectDisplayID, to builtin: CGDirectDisplayID) -> Bool {
        configure { CGConfigureDisplayMirrorOfDisplay($0, phantom, builtin) }
    }

    static func unmirror(_ phantom: CGDirectDisplayID) -> Bool {
        configure { CGConfigureDisplayMirrorOfDisplay($0, phantom, kCGNullDirectDisplay) }
    }

    /// Set `id`'s active mode to the one with this exact logical (point) and
    /// framebuffer (pixel) size. True when already there or set successfully.
    /// Used to pin the standalone phantom to its 2x mode after clamshell-off —
    /// left to itself macOS picks the raw 1x framebuffer mode (HITL 2026-07-27).
    static func setLogicalMode(_ id: CGDirectDisplayID,
                               pointsWide: Int, pointsHigh: Int,
                               pixelsWide: Int, pixelsHigh: Int) -> Bool {
        if let cur = CGDisplayCopyDisplayMode(id),
           cur.width == pointsWide, cur.pixelWidth == pixelsWide { return true }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode],
              let target = modes.first(where: {
                  $0.width == pointsWide && $0.height == pointsHigh
                  && $0.pixelWidth == pixelsWide && $0.pixelHeight == pixelsHigh
              }) else { return false }
        return CGDisplaySetDisplayMode(id, target, nil) == .success
    }

    // MARK: - Plumbing

    private static func configure(_ body: (CGDisplayConfigRef) -> CGError) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard body(config) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}
