import Foundation

/// Pure decision core for the five-layer sleep-prevention stack. No engine
/// instances, no IOKit, no AppKit — just "given the transition, which layers
/// change and how." This is the test surface (`tools/test-sleep-stack-planner.sh`);
/// `SleepStack` executes the returned actions against the real engines.
///
/// A caseless-enum namespace so `plan` / `Layer` / `Desired` aren't generic
/// top-level globals in the single-module app.
enum SleepPlanner {

    /// What the caller wants the stack to be — the four facts the policy needs.
    struct Desired: Equatable {
        var engaged: Bool
        /// false = screen-lock mode: hold the system awake but let the display sleep.
        var keepScreenOn: Bool
        /// A real external screen makes the virtual display redundant.
        var hasExternalDisplay: Bool
        /// Lid shut (or the machine has no lid — desktops pass true so the
        /// headless remote-GUI display still spawns). Lid open = the real
        /// built-in screen is available, so no fake display is needed.
        /// Defaults true: pre-lid-gating behavior for callers/tests that
        /// don't care.
        var lidClosed: Bool = true
    }

    /// The five layers, by name. Not a uniform protocol — they differ (flags, the
    /// singleton helper, only one re-arms); see `SleepStack`. Declaration order is
    /// the action order, matching the historic engage sequence.
    enum Layer: CaseIterable {
        case caffeinate, sleepPreventer, closedLid, virtualDisplay, helper
    }

    /// A single change to one layer. `preventDisplaySleep` is honored only by
    /// caffeinate and sleepPreventer; the other layers ignore it.
    enum LayerAction: Equatable {
        case enable(Layer, preventDisplaySleep: Bool)
        case disable(Layer)
        case rearm(Layer, preventDisplaySleep: Bool)   // disable+enable, for a keepScreenOn flip
    }

    /// The desired on-state + display-sleep flag for one layer under a given Desired.
    private static func layerState(_ layer: Layer, _ d: Desired) -> (on: Bool, preventDisplaySleep: Bool) {
        switch layer {
        case .caffeinate, .sleepPreventer:
            // preventDisplaySleep stays tied to keepScreenOn even lid-closed:
            // the virtual display idle-sleeps without it (~4 min), turning any
            // remote GUI session black (CRD regression, bench 2026-07-04). The
            // shut built-in panel is not at risk — firmware keeps it dark in
            // clamshell regardless of this assertion.
            return (d.engaged, d.keepScreenOn)
        case .closedLid, .helper:
            return (d.engaged, false)
        case .virtualDisplay:
            // Mimics an external screen while keep-screen-on is wanted but no real
            // screen is visible — lid shut and no external (desktops pass
            // lidClosed=true, so the headless remote-GUI display still spawns).
            // Bench 2026-07-03: a CGVirtualDisplay survives lid-close and can be
            // created lid-closed while the Helper holds sleep, so gating on the
            // lid is safe.
            return (d.engaged && d.keepScreenOn && !d.hasExternalDisplay && d.lidClosed, false)
        }
    }

    /// Diff the stack from `old` (nil = nothing applied yet) to `new`, emitting the
    /// minimal set of per-layer actions in a stable layer order.
    static func plan(from old: Desired?, to new: Desired) -> [LayerAction] {
        Layer.allCases.compactMap { layer in
            let want = layerState(layer, new)
            let have = old.map { layerState(layer, $0) } ?? (on: false, preventDisplaySleep: false)
            switch (have.on, want.on) {
            case (false, true):
                return .enable(layer, preventDisplaySleep: want.preventDisplaySleep)
            case (true, false):
                return .disable(layer)
            case (true, true) where have.preventDisplaySleep != want.preventDisplaySleep:
                return .rearm(layer, preventDisplaySleep: want.preventDisplaySleep)
            default:
                return nil
            }
        }
    }
}
