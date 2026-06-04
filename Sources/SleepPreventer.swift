import Foundation
import IOKit.pwr_mgt

/// Prevents idle system + display sleep.
///
/// Three layers:
///   1. IOKit kIOPMAssertionTypePreventUserIdleSystemSleep
///   2. IOKit kIOPMAssertionTypePreventUserIdleDisplaySleep
///   3. ProcessInfo.beginActivity — Apple's high-level API, more reliably
///      honoured by Apple Silicon power management than raw IOKit alone.
///
/// IOKit assertions are valid until released — no heartbeat needed. The
/// previous heartbeat-refresh version is parked at
/// `parked/SleepPreventer_with_heartbeat.swift` if we ever need it back.
class SleepPreventer {
    private(set) var isActive = false
    private var idleAssertion:    IOPMAssertionID = IOPMAssertionID(0)
    private var displayAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var activity:         NSObjectProtocol?

    /// When false, we hold the *system* awake but skip the display-sleep
    /// assertion so the screen can sleep and the Mac can show its lock screen.
    /// Remembered here so `refresh()` (fired on wake) re-arms the same way.
    private var preventDisplay = true

    func enable(preventDisplaySleep: Bool = true) {
        guard !isActive else { return }
        preventDisplay = preventDisplaySleep
        createAssertions()
        isActive = true
    }

    func disable() {
        releaseAssertions()
        isActive = false
    }

    /// Refresh all layers without dropping protection — the wake observer
    /// in MenuController calls this on `didWakeNotification` so that if Apple
    /// Silicon firmware overrode our PreventSystemSleep on battery, we re-arm
    /// the moment the lid opens.
    func refresh() {
        guard isActive else { return }
        releaseAssertions()
        createAssertions()
    }

    // MARK: - Private

    private func createAssertions() {
        // Layer 3 — ProcessInfo activity (most reliable on Apple Silicon)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "StayUp - keeping Mac awake"
        )

        // Layer 1 — prevent idle system sleep
        var idle: IOPMAssertionID = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayUp Sleep Prevention" as CFString,
            &idle
        ) == kIOReturnSuccess {
            idleAssertion = idle
        }

        // Layer 2 — prevent display sleep. Skipped when the user has opted to
        // let the screen lock: we still hold the system awake above, but the
        // display is free to sleep so macOS can show the lock screen.
        guard preventDisplay else { return }
        var display: IOPMAssertionID = IOPMAssertionID(0)
        if IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayUp Display Awake" as CFString,
            &display
        ) == kIOReturnSuccess {
            displayAssertion = display
        }
    }

    private func releaseAssertions() {
        if idleAssertion != 0 {
            IOPMAssertionRelease(idleAssertion)
            idleAssertion = IOPMAssertionID(0)
        }
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = IOPMAssertionID(0)
        }
        if let act = activity {
            ProcessInfo.processInfo.endActivity(act)
            activity = nil
        }
    }
}
