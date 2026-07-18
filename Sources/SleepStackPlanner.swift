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
        /// True on Macs with a built-in panel (laptops). A laptop always has a
        /// real surface — the built-in — so it never needs the fake display;
        /// on lid-close the built-in is dimmed to backlight-0 (MenuController,
        /// not here) rather than swapped for a virtual. Only headless desktops
        /// (Mac mini/Studio, no built-in) spawn the virtual. Defaults false:
        /// the desktop case, matching the historic "spawn the virtual" default.
        var hasBuiltinDisplay: Bool = false
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
            // The virtual display is a substitute surface for a machine with no
            // built-in panel: a headless desktop (Mac mini/Studio) carrying a
            // remote-GUI session. Laptops keep their real built-in — lid open OR
            // shut — and dim it to backlight-0 on lid-close (MenuController), so
            // they never spawn the virtual. Redundant when a real external is
            // present. Bench 2026-07-11: JIT spawn-at-close does NOT trigger
            // clamshell (0/200), and genuine clamshell-off needs a phantom
            // display held open (rejected) — so the laptop path is backlight-0,
            // not a virtual.
            return (d.engaged && d.keepScreenOn && !d.hasExternalDisplay && !d.hasBuiltinDisplay, false)
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
