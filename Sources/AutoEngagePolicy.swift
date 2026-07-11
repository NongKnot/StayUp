import Foundation

/// Pure decision core for Auto mode. All three decision paths — the source-
/// activity edge, the grace-timer fire re-check, and the mode changes from
/// Settings — go through `decide`; MenuController only runs the returned
/// actions against engage/disengage and the grace timer. No Settings, no
/// timers, no AppKit — this is the test surface
/// (`tools/test-auto-engage-policy.sh`); see CONTEXT.md "AutoEngagePolicy".
///
/// Two rules live *inside* the policy, not around it:
///   • **Manual mode wins.** Auto only releases what auto raised.
///   • **Don't Die wins on battery.** After the low-battery cutout fired,
///     auto must not re-engage or it would drain the battery to zero.
enum AutoEngagePolicy {

    /// Plain values — the six facts the policy needs, read by the caller.
    struct Facts {
        var autoEnabled: Bool
        var working: Bool
        var engaged: Bool
        /// True when auto raised the current engagement (engageReason == .auto).
        var engagedByAuto: Bool
        var dontDieTriggered: Bool
        var graceSecs: Int
    }

    enum Event {
        case sourceChanged       // the monitor's any-source-working edge
        case graceFired          // the stand-down timer's re-check
        case autoToggled         // Settings flipped Auto on/off
        case adoptedFromManual   // setMode(.auto) while manually engaged
    }

    /// Ordered — compound moves stay explicit ([.cancelStandDown, .engage]).
    enum Action: Equatable {
        case engage              // raise the stack, owned by auto
        case adoptAsAuto         // a manual engagement becomes auto-owned
        case standDown(after: Int)
        case disengage
        case cancelStandDown
    }

    static func decide(_ event: Event, _ f: Facts) -> [Action] {
        switch event {
        case .sourceChanged:
            guard f.autoEnabled else { return [] }   // late signal outside Auto
            return reconcile(f)

        case .graceFired:
            // The timer is already gone; only act if auto still owns an
            // engagement and the source is still idle.
            guard f.engaged, f.engagedByAuto, !f.working else { return [] }
            return [.disengage]

        case .autoToggled:
            if f.autoEnabled {
                // Turned on: bring the stack in line with the current signal
                // immediately instead of waiting for the next edge.
                return reconcile(f)
            }
            // Turned off: drop any pending stand-down; release the stack only
            // if auto is what raised it.
            return f.engaged && f.engagedByAuto
                ? [.cancelStandDown, .disengage]
                : [.cancelStandDown]

        case .adoptedFromManual:
            // Only a live manual engagement can be adopted.
            guard f.engaged, !f.engagedByAuto else { return [] }
            return f.working ? [.adoptAsAuto] : [.disengage]
        }
    }

    /// The shared busy/idle reconciliation behind sourceChanged and
    /// autoToggled(on).
    private static func reconcile(_ f: Facts) -> [Action] {
        if f.working {
            // Busy: any pending stand-down dies. Engage only from idle, and
            // never past the Don't Die cutout.
            if !f.engaged && !f.dontDieTriggered {
                return [.cancelStandDown, .engage]
            }
            return [.cancelStandDown]
        }
        // Idle: only release what auto raised. Grace 0 is policy — disengage
        // now, never a zero-length timer.
        guard f.engaged, f.engagedByAuto else { return [] }
        return f.graceSecs > 0 ? [.standDown(after: f.graceSecs)] : [.disengage]
    }
}
