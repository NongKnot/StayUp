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
/// We don't wait for the daemon's "ok\n" reply. The daemon ignores SIGPIPE
/// so our immediate close() is harmless to it.
final class StayUpHelper {
    static let shared = StayUpHelper()

    private let socketPath = "/var/run/app.getstayup.helper.sock"
    private let service = SMAppService.daemon(
        plistName: "app.getstayup.helper.plist")

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
        if !sendCommand("enable") && isEnabled {
            try? service.register()
            // Tiny grace period for launchd to load the new plist;
            // the daemon plist has RunAtLoad so it's near-instant.
            Thread.sleep(forTimeInterval: 0.3)
            _ = sendCommand("enable")
        }
    }

    func disable() { _ = sendCommand("disable") }

    /// Opens the helper socket, sends `command\n`, and reports whether
    /// the connect+send succeeded. Returns `false` if the daemon is
    /// unreachable (which is the signal `enable()` uses to attempt
    /// auto-heal). Disable failures are non-fatal so we ignore the
    /// boolean there.
    @discardableResult
    private func sendCommand(_ command: String) -> Bool {
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

        let msg = command + "\n"
        let n = msg.withCString { Foundation.send(fd, $0, strlen($0), 0) }
        if n < 0 { logFailure("\(command): send()", errno); return false }
        return true
    }

    private func logFailure(_ where_: String, _ errno_: Int32) {
        FileHandle.standardError.write(Data(
            "[StayUpHelper] \(where_) failed errno=\(errno_)\n".utf8))
    }
}
