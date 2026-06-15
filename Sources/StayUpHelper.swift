import Foundation
import ServiceManagement

/// Client side of the StayUp root helper daemon.
///
/// The helper is registered via `SMAppService.daemon(plistName:)` — its
/// launchd plist lives at `Contents/Library/LaunchDaemons/...plist` inside
/// the app bundle, and macOS groups it under StayUp in System Settings →
/// Login Items rather than showing a separate row.
///
/// IPC stays the same as the SMJobBless era: a Unix socket at
/// `/var/run/app.getstayup.helper.sock` carries `enable` / `disable`
/// commands. Both calls are synchronous — the socket write is a few bytes
/// and ordering matters (an async enable followed by a sync disable could
/// land in the wrong order, leaving `pmset disablesleep 1` set system-wide).
///
/// Normal engage/disengage calls don't wait for the daemon's "ok\n" reply.
/// The daemon ignores SIGPIPE so our immediate close() is harmless to it.
/// Uninstall is different: it waits for "ok\n" so we know
/// `pmset disablesleep 0` finished before unregistering the daemon.
final class StayUpHelper {
    static let shared = StayUpHelper()

    enum UnregisterPreparationError: LocalizedError {
        case sleepStillDisabled
        case unableToConfirmSleepRestored

        var errorDescription: String? {
            switch self {
            case .sleepStillDisabled:
                return "Duck could not turn macOS sleep back on. Try again while the Helper is running."
            case .unableToConfirmSleepRestored:
                return "Duck could not confirm macOS sleep was restored. Try again while the Helper is running."
            }
        }
    }

    private let socketPath = "/var/run/app.getstayup.helper.sock"
    private let service = SMAppService.daemon(
        plistName: "app.getstayup.helper.plist")
    private var sleepDisabledCache: (checkedAt: Date, value: Bool?)?

    /// Live launchd state. Computed on every access.
    var status: SMAppService.Status { service.status }

    /// Daemon is registered AND user has approved in Login Items.
    var isEnabled: Bool { service.status == .enabled }

    /// Register the daemon with launchd. First call on a fresh machine
    /// posts a "Background item added" notification and creates an
    /// off-by-default entry in System Settings → Login Items. Status
    /// becomes `.requiresApproval` until the user toggles it on.
    func register() throws { try service.register() }

    /// Tear down the launchd registration. The daemon stops; the bundle
    /// plist stays on disk but is no longer loaded.
    func unregister() throws { try service.unregister() }

    /// Open System Settings → Login Items so the user can approve a
    /// pending registration.
    func openLoginItemsPane() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func enable() {
        // Auto-heal stale registrations. If the user reinstalled the app
        // over a previous install (`rm -rf /Applications/StayUp.app` then
        // drag the new DMG in), `SMAppService.status` reports `.enabled`
        // because the launchd registration persisted — but the previous
        // daemon binary is gone, so the socket connect refuses. Detect
        // that and `register()` to refresh the registration to the
        // current bundle's plist. Silently transparent to users.
        var sent = sendCommand("enable")
        if !sent && isEnabled {
            try? service.register()
            // Tiny grace period for launchd to load the new plist;
            // the daemon plist has RunAtLoad so it's near-instant.
            Thread.sleep(forTimeInterval: 0.3)
            sent = sendCommand("enable")
        }
        if sent {
            sleepDisabledCache = nil
        }
    }

    func disable() {
        if sendCommand("disable") {
            sleepDisabledCache = nil
        }
    }

    /// Reads the live kernel-visible `pmset disablesleep` state without
    /// mutating power settings. Returns nil if `ioreg` is unavailable or
    /// the key is absent on this macOS version.
    func sleepDisabledLiveState(forceRefresh: Bool = false) -> Bool? {
        if !forceRefresh,
           let cached = sleepDisabledCache,
           Date().timeIntervalSince(cached.checkedAt) < 2 {
            return cached.value
        }

        let value = readSleepDisabledLiveState()
        sleepDisabledCache = (Date(), value)
        return value
    }

    /// Makes unregister safe. Prefer the helper's own synchronous disable
    /// reply; if a stale registration makes the socket unreachable, refresh
    /// launchd's registration and try once more. If the daemon is still
    /// unreachable but macOS already reports SleepDisabled=false, unregister
    /// is safe because there is no system-wide sleep block to leak.
    func prepareForUnregister() throws {
        if disableAndWait() { return }

        switch sleepDisabledLiveState(forceRefresh: true) {
        case .some(false):
            return
        case .some(true):
            throw UnregisterPreparationError.sleepStillDisabled
        case nil:
            throw UnregisterPreparationError.unableToConfirmSleepRestored
        }
    }

    private func readSleepDisabledLiveState() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-r", "-k", "SleepDisabled"]

        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }

        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("\"SleepDisabled\"") else { continue }
            if line.contains("Yes") || line.contains("true") || line.contains("1") { return true }
            if line.contains("No") || line.contains("false") || line.contains("0") { return false }
        }
        return nil
    }

    /// Used before unregistering the daemon. The helper replies only after
    /// `pmset disablesleep 0` exits, so a true return means it is safe to
    /// unregister without leaving the system-wide disablesleep flag stuck on.
    @discardableResult
    func disableAndWait() -> Bool {
        if sendCommand("disable", waitForReply: true) {
            sleepDisabledCache = (Date(), false)
            return true
        }

        if isEnabled {
            try? service.register()
            Thread.sleep(forTimeInterval: 0.3)
            if sendCommand("disable", waitForReply: true) {
                sleepDisabledCache = (Date(), false)
                return true
            }
        }

        return false
    }

    /// Opens the helper socket, sends `command\n`, and reports whether
    /// the connect+send succeeded. Returns `false` if the daemon is
    /// unreachable (which is the signal `enable()` uses to attempt
    /// auto-heal). Disable failures are non-fatal so we ignore the
    /// boolean there.
    @discardableResult
    private func sendCommand(_ command: String, waitForReply: Bool = false) -> Bool {
        guard isEnabled else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { logFailure("\(command): socket()", errno); return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 108) {
                    _ = strcpy($0, src)
                }
            }
        }

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { logFailure("\(command): connect()", errno); return false }

        if waitForReply {
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
        }

        let msg = command + "\n"
        let n = msg.withCString { Foundation.send(fd, $0, strlen($0), 0) }
        if n < 0 { logFailure("\(command): send()", errno); return false }

        if waitForReply {
            var buf = [UInt8](repeating: 0, count: 16)
            let r = recv(fd, &buf, buf.count, 0)
            guard r > 0 else { logFailure("\(command): recv()", errno); return false }
            let reply = String(bytes: buf.prefix(Int(r)), encoding: .utf8) ?? ""
            return reply.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
        }

        return true
    }

    private func logFailure(_ where_: String, _ errno_: Int32) {
        FileHandle.standardError.write(Data(
            "[StayUpHelper] \(where_) failed errno=\(errno_)\n".utf8))
    }
}
