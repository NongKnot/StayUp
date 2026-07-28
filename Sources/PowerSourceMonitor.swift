import Foundation
import IOKit.ps

/// Single source of truth for power source state (AC vs battery) and battery
/// percentage, backed by IOKit (no `pmset -g batt` subprocess).
///
/// Fires `onChange` when the source flips. Polls IOPS on each call to
/// `detect()` / `batteryPercent()` — the data is cached at the kernel level
/// so this is cheap.
final class PowerSourceMonitor {
    enum Source: Equatable { case ac, battery, unknown }

    /// Latest known source. Updated on every change notification + on demand.
    private(set) var current: Source = .unknown

    /// Fired on the main run loop when source flips (battery → AC or AC → battery).
    var onChange: ((Source) -> Void)?

    private var runLoopSource: CFRunLoopSource?

    func start() {
        stop()
        current = detect()

        let context = Unmanaged.passUnretained(self).toOpaque()
        let cb: IOPowerSourceCallbackType = { rawSelf in
            guard let raw = rawSelf else { return }
            let me = Unmanaged<PowerSourceMonitor>.fromOpaque(raw).takeUnretainedValue()
            let new = me.detect()
            // Ignore transient `.unknown` reads — IOPS occasionally fails to
            // populate during USB-PD renegotiation. Wait for a real ac/battery
            // value before propagating a change.
            guard new != .unknown, new != me.current else { return }
            me.current = new
            me.onChange?(new)
        }

        if let src = IOPSNotificationCreateRunLoopSource(cb, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = src
        }
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = nil
        }
    }

    /// Description dictionaries for all current power sources; empty on failure.
    private func sourceDescriptions() -> [[String: Any]] {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return [] }
        guard let sources  = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return sources.compactMap { src in
            IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue() as? [String: Any]
        }
    }

    /// Current power source. Re-detects on each call.
    func detect() -> Source {
        for info in sourceDescriptions() {
            if let state = info[kIOPSPowerSourceStateKey as String] as? String {
                return state == kIOPSACPowerValue ? .ac : .battery
            }
        }
        return .unknown
    }

    /// Battery charge 0–100, nil if no battery (rare on a MacBook).
    func batteryPercent() -> Int? {
        for info in sourceDescriptions() {
            if let cap = info[kIOPSCurrentCapacityKey as String] as? Int,
               let max = info[kIOPSMaxCapacityKey     as String] as? Int, max > 0 {
                return Int((Double(cap) / Double(max)) * 100)
            }
        }
        return nil
    }
}
