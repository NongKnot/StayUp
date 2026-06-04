import Cocoa
import Foundation

/// Wraps Apple's private `CGVirtualDisplay` API to spawn one invisible
/// virtual display. This is the "remote GUI still has a screen to stream"
/// layer when no real external display is attached.
///
/// This is not the hard battery + closed-lid sleep-prevention mechanism on
/// Apple Silicon. The helper daemon's `pmset disablesleep` path owns that.
/// VirtualDisplay is here for headless-ish GUI workflows: Screen Sharing,
/// Chrome Remote Desktop, and similar tools that behave better when macOS has
/// a display-shaped thing in the screen list.
///
/// Same approach as the open-source BetterDummy app, trimmed to a single
/// fixed-resolution display. Failure is silent: if creation fails (private
/// API drift, future macOS), `enable()` does nothing.
class VirtualDisplay {
    private(set) var isActive = false
    private var display: CGVirtualDisplay?

    func enable() {
        guard !isActive else { return }

        guard let descriptor = CGVirtualDisplayDescriptor() else { return }
        descriptor.queue = DispatchQueue.global(qos: .userInteractive)
        descriptor.name = "StayUp Display"
        // Generic RGB profile values lifted from BetterDummy.
        descriptor.whitePoint   = CGPoint(x: 0.950, y: 1.000)
        descriptor.redPrimary   = CGPoint(x: 0.454, y: 0.242)
        descriptor.greenPrimary = CGPoint(x: 0.353, y: 0.674)
        descriptor.bluePrimary  = CGPoint(x: 0.157, y: 0.084)
        descriptor.maxPixelsWide = 1920
        descriptor.maxPixelsHigh = 1080
        // 24" diagonal at 16:9 — the size doesn't matter much for our use,
        // but realistic dimensions help if anything actually inspects them.
        let diag = (24.0 * 25.4) / sqrt(1920.0 * 1920.0 + 1080.0 * 1080.0)
        descriptor.sizeInMillimeters = CGSize(
            width:  1920.0 * diag,
            height: 1080.0 * diag
        )
        // Fixed serial so macOS recognises the same virtual display across
        // engage/disengage cycles. A random serial would log a new entry in
        // System Settings → Displays history every time.
        descriptor.serialNum = 0x57415944   // "WAYD" — BetterDummy convention
        descriptor.productID = 0x0001
        descriptor.vendorID  = 0xF0F0   // BetterDummy uses the same; not registered with anyone

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            FileHandle.standardError.write(Data(
                "[StayUp] VirtualDisplay: CGVirtualDisplay init returned nil\n".utf8))
            return
        }

        guard let settings = CGVirtualDisplaySettings() else { return }
        settings.hiDPI = 1
        if let mode = CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60) {
            settings.modes = [mode]
        }

        if display.applySettings(settings) {
            self.display = display
            self.isActive = true
        } else {
            FileHandle.standardError.write(Data(
                "[StayUp] VirtualDisplay: applySettings failed\n".utf8))
        }
    }

    func disable() {
        guard isActive else { return }
        // Releasing the reference triggers the virtual display teardown.
        // CGVirtualDisplay's dealloc disconnects it from the IOService tree.
        display = nil
        isActive = false
    }
}
