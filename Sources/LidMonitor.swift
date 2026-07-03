import Foundation
import IOKit

/// Watches the MacBook clamshell (lid) via IOPMrootDomain's
/// `AppleClamshellState`. Drives the lid-gated virtual display: the fake
/// screen only needs to exist while the real one is shut.
///
/// `isClosed == nil` means this Mac has no lid sensor (Mac mini, Studio,
/// Pro) — callers treat that as "virtual display allowed", preserving the
/// headless remote-GUI behavior those machines rely on.
final class LidMonitor {
    private(set) var isClosed: Bool?
    var onChange: ((Bool) -> Void)?

    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var service: io_service_t = 0

    static func readClamshellState() -> Bool? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let cf = IORegistryEntryCreateCFProperty(
            svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return cf.takeRetainedValue() as? Bool
    }

    /// Idempotent. Registers a general-interest notification on
    /// IOPMrootDomain; any power-domain message triggers a cheap re-read of
    /// the clamshell property, and `onChange` fires only on a real flip.
    func start() {
        guard port == nil else { return }
        isClosed = Self.readClamshellState()
        guard isClosed != nil else { return }   // no lid sensor — nothing to watch
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return }
        guard let p = IONotificationPortCreate(kIOMainPortDefault) else {
            IOObjectRelease(service); service = 0
            return
        }
        port = p
        IONotificationPortSetDispatchQueue(p, DispatchQueue.main)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let kr = IOServiceAddInterestNotification(
            p, service, kIOGeneralInterest,
            { refcon, _, _, _ in
                guard let refcon else { return }
                Unmanaged<LidMonitor>.fromOpaque(refcon).takeUnretainedValue().reread()
            },
            ctx, &notifier)
        if kr != KERN_SUCCESS { stop() }
    }

    private func reread() {
        guard let now = Self.readClamshellState(), now != isClosed else { return }
        isClosed = now
        onChange?(now)
    }

    func stop() {
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        if let p = port { IONotificationPortDestroy(p); port = nil }
        if service != 0 { IOObjectRelease(service); service = 0 }
    }
}
