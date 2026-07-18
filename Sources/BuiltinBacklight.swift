import Cocoa
import CoreGraphics

// ============================================================================
// Dims the built-in laptop panel to backlight-0 while the lid is shut and a
// remote-GUI session is live, so the panel draws almost no power and shows
// nothing under the closed lid — while its framebuffer keeps streaming over
// CRD, so the built-in *is* the remote screen. Part of "Keep screen on when
// lid closed"; only laptops take this path (desktops have no built-in and use
// the virtual display instead — see SleepStackPlanner).
// ============================================================================
//
// Replaces the retired `BuiltinDisplayGate` (CGSConfigureDisplayEnabled). That
// primitive's OFF state was unconditionally sticky — it survived process death
// and lid-open, so any liveness gap stranded the user on a black screen whose
// only recovery was a blind power-cycle. Two frontier consults (2026-07-11,
// verbatim in docs/builtin-display-gate-consult-verbatim.md) killed it.
//
// Backlight-0 cannot strand: its worst case is a dark panel that the *hardware
// brightness keys* bring back — those work with the app dead, hung, or
// force-quit, and lid-open wake restores it too. So there is deliberately NO
// persistence and NO restore-on-launch here: the saved brightness lives only in
// memory, and the safety net is hardware, not bookkeeping the app could get
// wrong. Honest label: "backlight off," not "display off" — the panel is still
// driven, just dark (consult's honesty note; BRAND: claims need proof).
//
// Accepted edge (operator-signed-off 2026-07-18): if StayUp is killed while
// dimmed AND the lid is opened before it relaunches, the fresh instance can't
// know it was the one that dimmed the panel (memory is gone) and won't auto-
// brighten — one brightness-up keypress restores it. Persisting a "dimmed by us"
// flag would fix the moment but risk brightening a panel the *user* set to 0, so
// we take the keypress over the wrong-restore. This is the dead-man HITL case.
//
// `DisplayServicesGet/SetBrightness` are the same private DisplayServices.framework
// calls brightness utilities ship. Symbols verified present on this machine
// (macOS 27.0 beta 26A5368g) via dlsym; a live built-in read returned rc=0.
// Private API: resolved once via dlopen, fails closed (panel stays as-is) if the
// symbols ever drift away.
private let displayServices: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

private let getBrightness: GetBrightnessFn? = displayServices
    .flatMap { dlsym($0, "DisplayServicesGetBrightness") }
    .map { unsafeBitCast($0, to: GetBrightnessFn.self) }
private let setBrightness: SetBrightnessFn? = displayServices
    .flatMap { dlsym($0, "DisplayServicesSetBrightness") }
    .map { unsafeBitCast($0, to: SetBrightnessFn.self) }

/// Reconciles the built-in panel's backlight. Call ONLY from the settle-deferred
/// screen-policy path (`reapplyScreenPolicy`), matching the retired gate's call
/// site — a brightness set is far tamer than a compositor reconfiguration, but
/// keeping it out of the immediate engage/disengage callbacks costs nothing.
final class BuiltinBacklight {
    /// The user's brightness before we dimmed, so `restore` returns their level
    /// rather than a guess. In-memory only (see file header). nil while we hold
    /// no captured value.
    private var savedBrightness: Float?
    /// Whether we are currently holding the panel dark. Separate from
    /// `savedBrightness` because a dim that starts from an already-dark panel
    /// (e.g. re-dim after a crash that lost this state) captures nothing yet
    /// still counts as dimmed.
    private var dimmed = false

    /// Brightness to restore to when we dimmed from an already-dark panel and so
    /// never captured a real value — a visible mid-level beats leaving it dark.
    private static let restoreFallback: Float = 0.5
    /// Treat anything at/below this as "already dark" — don't capture it as the
    /// value to restore, or a later restore would strand the panel dark.
    private static let darkEpsilon: Float = 0.01

    func apply(dim: Bool) {
        dim ? dimBuiltin() : restoreBuiltin()
    }

    private func dimBuiltin() {
        guard let id = Self.builtinDisplayID() else { return }   // no built-in in list → no-op
        if !dimmed {
            let current = Self.readBrightness(id)
            // Only capture a real, non-dark level. Capturing ~0 (a re-dim after a
            // crash left it dark) would make restore return it to dark.
            if let current, current > Self.darkEpsilon { savedBrightness = current }
            dimmed = true
        }
        if Self.writeBrightness(id, 0) {
            FileHandle.standardError.write(Data(
                "[StayUp] BuiltinBacklight: built-in dimmed to 0\n".utf8))
        }
    }

    private func restoreBuiltin() {
        guard dimmed else { return }   // never dimmed — don't touch the user's brightness
        // Clear state ONLY after the write lands. If the built-in is transiently
        // absent (mid lid-open topology churn) or the write fails, keep `dimmed`
        // and `savedBrightness` so the next settle-deferred reapply retries — a
        // live app must not forget it dimmed and strand the panel at 0.
        guard let id = Self.builtinDisplayID() else { return }
        let target = savedBrightness ?? Self.restoreFallback
        guard Self.writeBrightness(id, target) else { return }
        dimmed = false
        savedBrightness = nil
        FileHandle.standardError.write(Data(
            "[StayUp] BuiltinBacklight: built-in restored to \(target)\n".utf8))
    }

    // MARK: - Private-API plumbing (fails closed)

    private static func builtinDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func readBrightness(_ id: CGDirectDisplayID) -> Float? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        return getBrightness(id, &value) == 0 ? value : nil
    }

    @discardableResult
    private static func writeBrightness(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        guard let setBrightness else { return false }
        return setBrightness(id, value) == 0
    }
}
