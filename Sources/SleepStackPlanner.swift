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
        /// True when MenuController has vetoed the laptop mirror-phantom this
        /// engage (mirroring changed the built-in's resolution, or kept
        /// failing). Suppresses only the virtual display; every other layer
        /// holds. Default false: spawn the phantom — on laptops it is mirrored
        /// onto the built-in (invisible lid-open) so lid-close triggers
        /// genuine clamshell-off; on desktops it is the headless surface.
        var suppressVirtualDisplay: Bool = false
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
            // The phantom serves two machines: a headless desktop's only
            // surface, and a laptop's clamshell trigger (pre-existing display
            // at lid-close → macOS powers the built-in genuinely off; bench:
            // JIT spawn-at-close never triggers it, 0/200). Redundant when a
            // real external is present; suppressed only by an explicit mirror
            // veto (MenuController). Mirrored-vs-extended is executor policy,
            // not a planner fact.
            return (d.engaged && d.keepScreenOn && !d.hasExternalDisplay && !d.suppressVirtualDisplay, false)
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
