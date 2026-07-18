import Foundation

/// Pure decision core for the layer-5 watchdog. `pmset disablesleep` is
/// system-wide, cross-process state: a second app instance's launch self-heal,
/// the daemon's own restart rescue, or any root process can strip it behind an
/// engaged app — silently, with every in-process assertion still looking
/// healthy (the 2026-07-18 incident: lid close slept the Mac on battery and
/// killed every agent connection). No entry-point guard can close external
/// mutation, so while engaged the caller ticks this policy against the live
/// kernel flag and re-arms when it's been stripped. No timers, no ioreg, no
/// helper socket — this is the test surface (`tools/test-helper-watchdog.sh`);
/// MenuController owns the timer, the live read, and the strike counter.
enum HelperWatchdog {

    /// Verify cadence while engaged. Cheap (one ioreg read), and 30 s bounds
    /// the unprotected window well under the ~1–3 min firmware needs to force
    /// battery+clamshell sleep past the assertions.
    static let intervalSecs: TimeInterval = 30

    /// Consecutive stripped ticks before the menu warns. One is a blip the
    /// re-arm fixes invisibly; two means the re-arm isn't sticking — tell on
    /// whoever keeps turning it off instead of ping-ponging in silence.
    static let warnStrikes = 2

    struct Verdict: Equatable {
        /// Re-send "enable" to the helper daemon.
        var rearm: Bool
        /// New consecutive-stripped count; the caller stores it and passes it
        /// back next tick. `degraded(strikes:)` turns it into the warning.
        var strikes: Int
    }

    /// One tick: compare what the stack believes (engaged ⇒ layer 5 up)
    /// against the live kernel flag. `sleepDisabled` nil = ioreg unreadable —
    /// hold steady rather than thrash the helper or accuse it.
    static func tick(engaged: Bool, sleepDisabled: Bool?, strikes: Int) -> Verdict {
        guard engaged else { return Verdict(rearm: false, strikes: 0) }
        switch sleepDisabled {
        case true:  return Verdict(rearm: false, strikes: 0)
        case false: return Verdict(rearm: true, strikes: strikes + 1)
        case nil:   return Verdict(rearm: false, strikes: strikes)
        }
    }

    /// True when the strip is persistent enough to surface in the menu.
    static func degraded(strikes: Int) -> Bool { strikes >= warnStrikes }
}
