import AppKit
import Foundation
import IOKit
import IOKit.hid

/// Accelerometer-based "is the user walking with the laptop right now"
/// detector. Built for the menu-bar Duck animation, not for sleep
/// prevention decisions — false positives are cheap (a brief icon wiggle)
/// so this is intentionally simpler than ThirdEye's parked WalkAutoDetector:
/// no cooldown, no return-detect, no step counter, no UI banner. Just an
/// EMA over the accelerometer's consecutive-sample delta plus a sustain
/// timer for hysteresis.
///
/// Hardware path lifted from olvvier/apple-silicon-accelerometer:
///   1. Wake `AppleSPUHIDDriver` (sensor is OFF by default — opening the
///      HID device without this gives zero data).
///   2. Find an `AppleSPUHIDDevice` whose primary usage page is `0xFF00`
///      and primary usage is `3` (Apple's accelerometer).
///   3. Register an input-report callback. Each report is 22 bytes; X/Y/Z
///      are signed Int32 little-endian at offsets 6/10/14, scaled by 2^16
///      to give Gs.
///
/// Native rate is ~100 Hz; the kernel delivers ~14 Hz via `ReportInterval`.
final class WalkDetector {

    // MARK: - Public

    /// Fired on the main run loop when sustained motion crosses the
    /// "started walking" threshold.
    var onWalkStart: (() -> Void)?
    /// Fired when sustained stillness crosses the "stopped walking" threshold.
    var onWalkStop: (() -> Void)?

    private(set) var isWalking: Bool = false
    private(set) var isAvailable: Bool = false

    /// When the current walk started, or `nil` if not walking. Used by
    /// MenuController to show a live walk timer.
    private(set) var walkStartedAt: Date?

    /// Steps counted in the current walk (or the most recently completed
    /// walk if not currently walking). Reset at each walk-start.
    var sessionSteps: Int { stepCounter.sessionSteps }

    // MARK: - Tunables (animation-tuned, not sleep-prevention-grade)

    /// `deltaEMA` above this counts as motion. Tuned to sit above typing
    /// bursts — keyboard impact spikes the accelerometer briefly but
    /// usually stays under 0.025g, while walking peaks reach 0.04g+.
    private let motionThreshold:  Double       = 0.028

    /// Continuous motion required before we declare "walking". Bumped to
    /// 2.0s so a 1-second typing burst can't trigger; real walks sustain
    /// well past this.
    private let walkSustain:      TimeInterval = 2.0

    /// Continuous stillness required before we declare "stopped". Longer
    /// than walkSustain so stride pauses don't flicker the animation off.
    private let stopSustain:      TimeInterval = 1.5

    /// Brief sub-threshold dips that are forgiven without resetting the
    /// sustain timer. Walking EMA oscillates around the threshold by design
    /// (each footstep is a peak with a quieter passing phase between);
    /// without this, the sustain timer resets between every step and
    /// walk-start never fires.
    private let gapTolerance:     TimeInterval = 0.8

    /// We tell the kernel to deliver reports at ~14 Hz directly (via
    /// `ReportInterval = 70000µs`) so no software downsampling is needed —
    /// every report is processed.
    private let emaAlpha: Double  = 0.25

    // MARK: - Hardware constants (Apple SPU accelerometer)

    private static let kSPUService    = "AppleSPUHIDDevice"
    private static let kAccelPage:  UInt32 = 0xFF00
    private static let kAccelUsage: UInt32 = 3
    private static let kReportLen   = 22
    private static let kDataOffset  = 6      // X starts at byte 6
    private static let kScale       = 65536.0  // Q16 fixed-point → g

    // MARK: - State

    private var device: IOHIDDevice?
    /// Heap-allocated stable pointer for IOKit. A Swift `[UInt8]` could be
    /// relocated by ARC, so `&array` isn't safe to hold across async calls.
    private let reportBufferPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: WalkDetector.kReportLen)

    private var prevX: Double = 0, prevY: Double = 0, prevZ: Double = 0
    private var hasFirst = false
    private var deltaEMA: Double = 0

    private var motionStartedAt: Date?
    private var lastMotionAt:    Date?     // for gap tolerance
    private var stillStartedAt:  Date?
    private var stepCounter      = StepCounter()

    deinit { reportBufferPtr.deallocate() }

    // MARK: - Hardware probe
    //
    // Cheap IOKit scan that answers "does this Mac have an Apple SPU
    // accelerometer?" *without* powering the sensor on or opening the HID
    // device. Used by the Settings UI to gray out the Walk-mode toggle on
    // Macs that physically can't walk a Duck (Intel-era, Mac mini, Mac
    // Studio, Mac Pro, external monitor setups with no laptop attached).
    //
    // Safe to call before `start()` — does not affect `isAvailable`, does
    // not allocate the report buffer, releases all IOKit handles before
    // returning. ~milliseconds, no side effects.
    static var isHardwareAvailable: Bool {
        guard let matching = IOServiceMatching(Self.kSPUService) else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }

        var svc = IOIteratorNext(iterator)
        while svc != 0 {
            guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, svc) else {
                IOObjectRelease(svc); svc = IOIteratorNext(iterator); continue
            }
            let page  = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? UInt32) ?? 0
            let usage = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey     as CFString) as? UInt32) ?? 0
            IOObjectRelease(svc)
            if page == Self.kAccelPage && usage == Self.kAccelUsage {
                return true
            }
            svc = IOIteratorNext(iterator)
        }
        return false
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard device == nil else { return isAvailable }

        wakeSPUDriver()

        guard let dev = findAccelerometer() else {
            log("AppleSPUHIDDevice accelerometer not found (needs M-series MacBook)")
            return false
        }

        guard IOHIDDeviceOpen(dev, IOOptionBits(0)) == kIOReturnSuccess else {
            log("IOHIDDeviceOpen failed")
            return false
        }

        reportBufferPtr.initialize(repeating: 0, count: Self.kReportLen)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            dev, reportBufferPtr, CFIndex(Self.kReportLen),
            { ctx, _, _, _, _, report, reportLength, _ in
                guard let ctx else { return }
                Unmanaged<WalkDetector>.fromOpaque(ctx).takeUnretainedValue()
                    .handleReport(report, length: Int(reportLength))
            }, ctx
        )

        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(),
                                       CFRunLoopMode.commonModes.rawValue)

        device = dev
        isAvailable = true
        log("✓ accelerometer live (threshold=\(motionThreshold)g, sustain=\(walkSustain)s)")
        return true
    }

    func stop() {
        if let d = device {
            IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(),
                                             CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(d, IOOptionBits(0))
        }
        device = nil
        isAvailable = false
        hasFirst = false
        deltaEMA = 0
        motionStartedAt = nil
        stillStartedAt  = nil
        if isWalking {
            isWalking = false
            onWalkStop?()
        }
    }

    // MARK: - SPU wakeup

    /// The sensor is powered down by default. Setting these three keys via
    /// `IORegistryEntrySetCFProperty` on the `AppleSPUHIDDriver` service
    /// turns it on. Without this `IOHIDDeviceOpen` succeeds but no reports
    /// arrive.
    private func wakeSPUDriver() {
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        // ReportInterval is in microseconds. ThirdEye used 1000 (1 kHz)
        // and downsampled in software, but the kernel's IOKit dispatch
        // overhead is the real CPU cost. 70000 µs = ~14 Hz native, which
        // matches our intended processing rate exactly — same walk-
        // detection quality at ~10× lower idle CPU.
        let props: [(String, Int32)] = [
            ("SensorPropertyReportingState", 1),
            ("SensorPropertyPowerState",     1),
            ("ReportInterval",               70_000),
        ]

        var svc = IOIteratorNext(iterator)
        while svc != 0 {
            for (key, value) in props {
                var v = value
                if let cfVal = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &v) {
                    IORegistryEntrySetCFProperty(svc, key as CFString, cfVal)
                }
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iterator)
        }
    }

    private func findAccelerometer() -> IOHIDDevice? {
        guard let matching = IOServiceMatching(Self.kSPUService) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
                == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var svc = IOIteratorNext(iterator)
        while svc != 0 {
            guard let dev = IOHIDDeviceCreate(kCFAllocatorDefault, svc) else {
                IOObjectRelease(svc); svc = IOIteratorNext(iterator); continue
            }
            let page  = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? UInt32) ?? 0
            let usage = (IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsageKey     as CFString) as? UInt32) ?? 0
            if page == Self.kAccelPage && usage == Self.kAccelUsage {
                IOObjectRelease(svc)
                return dev
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(iterator)
        }
        return nil
    }

    // MARK: - Report processing

    private func handleReport(_ report: UnsafePointer<UInt8>, length: Int) {
        guard length >= Self.kDataOffset + 12 else { return }

        func readI32(at offset: Int) -> Double {
            let raw = Int32(bitPattern:
                UInt32(report[offset    ])        |
                UInt32(report[offset + 1]) <<  8  |
                UInt32(report[offset + 2]) << 16  |
                UInt32(report[offset + 3]) << 24)
            return Double(raw) / Self.kScale
        }

        let x = readI32(at: Self.kDataOffset)
        let y = readI32(at: Self.kDataOffset + 4)
        let z = readI32(at: Self.kDataOffset + 8)

        guard hasFirst else {
            prevX = x; prevY = y; prevZ = z
            hasFirst = true
            return
        }

        let dx = x - prevX, dy = y - prevY, dz = z - prevZ
        let delta = (dx*dx + dy*dy + dz*dz).squareRoot()
        prevX = x; prevY = y; prevZ = z

        deltaEMA = deltaEMA + (delta - deltaEMA) * emaAlpha

        let now = Date()

        // Step counter is only meaningful during locomotion. Running it on
        // desk-typing samples would count keystrokes as steps.
        if isWalking {
            _ = stepCounter.processSample(x: x, y: y, z: z, now: now)
        }

        updateState(now: now)
    }

    private var lastEMALogAt:  Date = .distantPast
    private var lastWasMoving: Bool = false

    /// Verbose per-sample EMA logging is gated behind `STAYUP_TEST=1` so it
    /// doesn't spam stderr in production. Walk-start / walk-stop events
    /// still log unconditionally — those are rare and useful for diagnosing
    /// "Duck won't walk" reports.
    private static let verboseLogging: Bool = {
        ProcessInfo.processInfo.environment["STAYUP_TEST"] != nil
    }()

    private func updateState(now: Date) {
        let moving = deltaEMA > motionThreshold

        if Self.verboseLogging,
           moving != lastWasMoving || now.timeIntervalSince(lastEMALogAt) > 2.0 {
            log(String(format: "ema=%.4fg %@", deltaEMA,
                       moving ? "← MOVING" : "(still)"))
            lastEMALogAt = now
            lastWasMoving = moving
        }

        if moving {
            lastMotionAt = now
            stillStartedAt = nil
            if !isWalking {
                if motionStartedAt == nil {
                    motionStartedAt = now
                } else if now.timeIntervalSince(motionStartedAt!) >= walkSustain {
                    isWalking = true
                    motionStartedAt = nil
                    walkStartedAt = now
                    stepCounter.reset()
                    log("→ WALK START")
                    onWalkStart?()
                }
            }
        } else {
            // Below threshold: forgive brief sub-threshold dips. Walking is
            // an oscillating signal — stride peaks above threshold, passing
            // phases dip below — so we only reset the sustain timer once
            // we've been quiet for `gapTolerance` continuously.
            if let last = lastMotionAt, now.timeIntervalSince(last) > gapTolerance {
                motionStartedAt = nil
                lastMotionAt    = nil
            }
            if isWalking {
                if stillStartedAt == nil {
                    stillStartedAt = now
                } else if now.timeIntervalSince(stillStartedAt!) >= stopSustain {
                    isWalking = false
                    stillStartedAt = nil
                    lastMotionAt   = nil
                    log("→ WALK STOP")
                    onWalkStop?()
                }
            }
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write(Data("[WalkDetector] \(s)\n".utf8))
    }
}
