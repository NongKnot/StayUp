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
/// On laptops the phantom is spawned at the built-in's native mode and mirrored onto it — see DisplayMirror + MenuController.
///
/// Same approach as the open-source BetterDummy app, trimmed to a single
/// fixed-resolution display. Failure is silent: if creation fails (private
/// API drift, future macOS), `enable()` does nothing.
class VirtualDisplay {
    /// A concrete pixel mode for the phantom to advertise. When mirroring onto
    /// a laptop's built-in, this MUST be the built-in's exact native pixel
    /// mode — the 2026-07-08 mirror rejection (built-in dropped 2056→1728)
    /// happened because the phantom only offered 1920×1080, so macOS mirrored
    /// at the best *common* mode. nil = the historic 1920×1080 desktop default.
    struct Mode: Equatable {
        var pixelsWide: Int
        var pixelsHigh: Int
        /// Logical (point) size — what the desktop "looks like". Advertising
        /// the pixel size as the mode makes the standalone phantom run 1x
        /// (HITL 2026-07-27: closed-lid desktop jumped to 2940×1912 logical,
        /// windows reflowed on reopen). The mode is advertised in POINTS with
        /// the pixel size as the framebuffer cap, so hiDPI engages and the
        /// closed-lid desktop is identical to the open-lid one.
        var pointsWide: Int
        var pointsHigh: Int
        var refreshRate: Double
    }

    /// The virtual display's name in the screen list. MenuController's
    /// real-external-display check filters on this — keep them one constant
    /// or a rename silently breaks external-display detection.
    static let displayName = "StayUp Display"

    private(set) var isActive = false
    private var display: CGVirtualDisplay?

    func enable(modes: [Mode]? = nil) {
        guard !isActive else { return }

        // Advertise the caller's full mode table (a laptop built-in's usable
        // list — constant hardware property, so the phantom never needs a
        // respawn to follow a user's resolution pick). nil = the historic
        // single-mode 1920×1080 desktop default. maxPixels must cover the
        // largest advertised framebuffer.
        let table = (modes?.isEmpty == false) ? modes!
            : [Mode(pixelsWide: 1920, pixelsHigh: 1080, pointsWide: 1920, pointsHigh: 1080, refreshRate: 60)]
        let pxW = table.map(\.pixelsWide).max()!
        let pxH = table.map(\.pixelsHigh).max()!

        guard let descriptor = CGVirtualDisplayDescriptor() else { return }
        descriptor.queue = DispatchQueue.global(qos: .userInteractive)
        descriptor.name = Self.displayName
        // Generic RGB profile values lifted from BetterDummy.
        descriptor.whitePoint   = CGPoint(x: 0.950, y: 1.000)
        descriptor.redPrimary   = CGPoint(x: 0.454, y: 0.242)
        descriptor.greenPrimary = CGPoint(x: 0.353, y: 0.674)
        descriptor.bluePrimary  = CGPoint(x: 0.157, y: 0.084)
        descriptor.maxPixelsWide = UInt32(pxW)
        descriptor.maxPixelsHigh = UInt32(pxH)
        // 24" diagonal at the mode's aspect — the size doesn't matter much for
        // our use, but realistic dimensions help if anything inspects them.
        let diag = (24.0 * 25.4) / sqrt(Double(pxW * pxW + pxH * pxH))
        descriptor.sizeInMillimeters = CGSize(
            width:  Double(pxW) * diag,
            height: Double(pxH) * diag
        )
        // Fixed serial so macOS recognises the same virtual display across
        // engage/disengage cycles. A random serial would log a new entry in
        // System Settings → Displays history every time. DisplayMirror finds
        // the phantom by this vendor+serial pair — keep them in sync.
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
        // Modes in POINTS, maxPixels in pixels: a Retina spec (points <
        // pixels) yields a proper 2x mode; the desktop default (points ==
        // pixels) is the historic 1x config unchanged.
        settings.modes = table.compactMap {
            CGVirtualDisplayMode(width: UInt32($0.pointsWide), height: UInt32($0.pointsHigh),
                                 refreshRate: $0.refreshRate)
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
