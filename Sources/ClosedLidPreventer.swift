import Foundation
import IOKit.pwr_mgt

/// Prevents clamshell sleep using a `kIOPMAssertionTypePreventSystemSleep`
/// IOKit power-management assertion. No subprocess, no password, no admin
/// rights. Confirmed to hold on AC + closed lid.
///
/// On battery + closed lid this assertion is overridden by Apple Silicon
/// firmware after ~1–3 min. Only `pmset disablesleep 1` via the helper
/// daemon survives that scenario. VirtualDisplay is destroyed by macOS
/// within ~3s of lid-close (confirmed 2026-05-30) and does NOT prevent
/// battery+clamshell sleep — its job is headless remote access: keeping
/// a virtual display alive so CRD/Screen Sharing have something to stream.
class ClosedLidPreventer {
    private(set) var isEnabled = false
    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)

    @discardableResult
    func enable() -> Bool {
        guard assertionID == 0 else { return true }
        var newID: IOPMAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayUp Closed-Lid Mode" as CFString,
            &newID
        )
        guard result == kIOReturnSuccess else { return false }
        assertionID = newID
        isEnabled = true
        return true
    }

    func disable() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(0)
        }
        isEnabled = false
    }
}
