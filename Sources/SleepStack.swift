import Foundation

/// The five-layer sleep-prevention stack as one deep module. A dumb executor:
/// it knows layers and screen state, nothing else — no Auto mode, Don't Die, or
/// duck animation. Those fire *around* engage but aren't sleep prevention, so
/// they stay in MenuController.
///
/// The policy lives in `plan` (SleepStackPlanner.swift — pure + unit-tested);
/// this class runs the resulting actions against the real engines and is the
/// *only* caller of `caffeinate.enable()` et al. Inputs are passed in
/// (`Desired`), never read from `Settings`/`NSScreen`.
final class SleepStack {

    /// Read-only snapshot of each layer's live state, for the INFO state dump.
    struct State {
        let caffeinate, sleepPreventer, closedLid, virtualDisplay, helper: Bool
    }

    private let caffeinate         = Caffeinate()
    private let sleepPreventer     = SleepPreventer()
    private let closedLidPreventer = ClosedLidPreventer()
    private let virtualDisplay     = VirtualDisplay()
    // Layer 5 (StayUpHelper) is a process-wide singleton with cross-process,
    // survives-a-crash semantics — referenced via `.shared`, not owned here.

    /// Last applied state — the planner diffs against it. Also the engaged truth.
    private var last: SleepPlanner.Desired?

    /// Mode TABLE the phantom advertises. Executor detail, not planner state.
    /// A panel's usable-mode list is a constant hardware property, so this
    /// changes at most once per engage (nil default → real table when a
    /// built-in first comes online, e.g. after an engage-under-closed-lid).
    /// The phantom is deliberately NEVER respawned on a current-mode change —
    /// chasing the built-in's mode-of-the-moment respawned the display on
    /// every user resolution pick, and each respawn raced macOS's async
    /// teardown + session mirror memory (HITL 2026-07-27: sticky vetoes, a
    /// black flash, and a revert loop that overrode the user's choice
    /// every ~3s). The full table means there is never anything to chase.
    private var virtualDisplayModes: [VirtualDisplay.Mode]?

    var isEngaged: Bool { last?.engaged ?? false }

    /// Reconcile the live stack to this state. The one entry point: engage,
    /// disengage, a screen-policy flip, an external-display change, and a lid
    /// flip are all just this. No-ops cleanly when nothing changed. `Desired`
    /// stays an internal detail — callers pass the four facts directly.
    /// Returns true when the table upgrade cycled a live phantom (a real
    /// teardown+arrival topology transition the before/after snapshot diff
    /// cannot see — the caller's yank watch needs to know).
    func apply(engaged: Bool, keepScreenOn: Bool, hasExternalDisplay: Bool,
               suppressVirtualDisplay: Bool, virtualDisplayModes modes: [VirtualDisplay.Mode]?) -> Bool {
        let desired = SleepPlanner.Desired(
            engaged: engaged, keepScreenOn: keepScreenOn,
            hasExternalDisplay: hasExternalDisplay, suppressVirtualDisplay: suppressVirtualDisplay)
        // The table upgrade (default → the built-in's real table, at most once
        // per engage — see `virtualDisplayModes`) is the ONLY reason a live
        // phantom respawns outside the planner. nil is "no opinion" (built-in
        // offline mid-clamshell), never a reset.
        var phantomCycled = false
        if virtualDisplay.isActive, let modes, modes != virtualDisplayModes {
            virtualDisplay.disable()
            phantomCycled = true
        }
        virtualDisplayModes = modes ?? virtualDisplayModes
        for action in SleepPlanner.plan(from: last, to: desired) { execute(action) }
        // The planner diffs on/off, so a respawn after the table-upgrade
        // disable needs an explicit re-enable when the plan (rightly) saw no
        // change.
        if desired.engaged, desired.keepScreenOn, !desired.hasExternalDisplay,
           !desired.suppressVirtualDisplay, !virtualDisplay.isActive {
            virtualDisplay.enable(modes: virtualDisplayModes)
        }
        last = desired
        return phantomCycled
    }

    /// Re-assert protection on wake. Only SleepPreventer needs it — the other
    /// layers persist across sleep. No-op when not engaged.
    func refresh() {
        guard isEngaged else { return }
        sleepPreventer.refresh()
    }

    /// Unconditional teardown of every layer, ignoring tracked state. Used by
    /// app cleanup and the defensive launch self-heal: a leaked layer-5
    /// assertion leaves `pmset disablesleep` set system-wide until reboot, so we
    /// disable defensively rather than trust `last`.
    func shutdown() {
        for layer in SleepPlanner.Layer.allCases { disable(layer) }
        last = nil
    }

    func snapshot() -> State {
        State(caffeinate:     caffeinate.isActive,
              sleepPreventer: sleepPreventer.isActive,
              closedLid:      closedLidPreventer.isEnabled,
              virtualDisplay: virtualDisplay.isActive,
              helper:         StayUpHelper.shared.isEnabled)
    }

    // MARK: - Execute planner actions against the real engines

    private func execute(_ action: SleepPlanner.LayerAction) {
        switch action {
        case let .enable(layer, pds): enable(layer, preventDisplaySleep: pds)
        case let .disable(layer):     disable(layer)
        case let .rearm(layer, pds):  disable(layer); enable(layer, preventDisplaySleep: pds)
        }
    }

    private func enable(_ layer: SleepPlanner.Layer, preventDisplaySleep pds: Bool) {
        switch layer {
        case .caffeinate:     caffeinate.enable(preventDisplaySleep: pds)
        case .sleepPreventer: sleepPreventer.enable(preventDisplaySleep: pds)
        case .closedLid:      _ = closedLidPreventer.enable()
        case .virtualDisplay: virtualDisplay.enable(modes: virtualDisplayModes)
        case .helper:         StayUpHelper.shared.enable()
        }
    }

    private func disable(_ layer: SleepPlanner.Layer) {
        switch layer {
        case .caffeinate:     caffeinate.disable()
        case .sleepPreventer: sleepPreventer.disable()
        case .closedLid:      closedLidPreventer.disable()
        case .virtualDisplay: virtualDisplay.disable()
        case .helper:         StayUpHelper.shared.disable()
        }
    }
}
