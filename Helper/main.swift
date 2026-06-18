import Foundation

// StayUp root helper daemon.
// Runs as root via LaunchDaemon. Listens on a Unix socket, executes pmset
// commands on behalf of StayUp.
//
// Commands:   "enable"  → pmset -a disablesleep 1
//             "disable" → pmset -a disablesleep 0
// Response:   "ok\n" (best-effort; clients may close before reading)

// The Swift client closes its socket immediately after send() without reading
// the "ok\n" reply. When the daemon then writes the reply, it raises SIGPIPE
// — whose default action is process termination. KeepAlive=true would restart
// us, but any connection already queued in the listen backlog is lost on
// restart, causing rapid back-to-back commands to drop the second one.
// Ignoring SIGPIPE turns that write into a harmless EPIPE return code.
signal(SIGPIPE, SIG_IGN)

let socketPath = "/var/run/app.getstayup.helper.sock"

func runPmset(_ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = args
    try? p.run()
    p.waitUntilExit()
}

// The socket lives in world-traversable /var/run and stays world-connectable so
// StayUp (running as the logged-in user, not root) can reach it. That alone would
// let *any* local uid toggle system sleep, so gate on the peer's credentials here:
// honor only a real interactive user (uid >= 501, what the app runs as) or root,
// and reject system/service uids and any peer we can't verify. Same-uid callers
// share the app's own trust domain and can't be distinguished here — and no socket
// auth could stop them — so this closes exactly the extra exposure the open socket
// adds (other accounts / system contexts), nothing more. The legit client is always
// uid >= 501, so this never rejects the real engage/disengage path.
func peerAllowed(_ fd: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else { return false }
    return uid == 0 || uid >= 501
}

func handleClient(_ fd: Int32) {
    guard peerAllowed(fd) else { close(fd); return }

    var buf = [UInt8](repeating: 0, count: 64)
    let n = recv(fd, &buf, 63, 0)
    guard n > 0 else { close(fd); return }

    let cmd = String(bytes: buf.prefix(Int(n)), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    switch cmd {
    case "enable":  runPmset(["-a", "disablesleep", "1"])
    case "disable": runPmset(["-a", "disablesleep", "0"])
    default: break
    }

    _ = "ok\n".withCString { send(fd, $0, strlen($0), 0) }
    close(fd)
}

// Defensive rescue at daemon launch. `pmset disablesleep` is a system-wide
// property that persists across daemon restarts — once set to 1, only an
// explicit `pmset disablesleep 0` (or a reboot) clears it. Any path that
// kills the daemon while engaged leaks the leak:
//   * SIGKILL (can't be intercepted)
//   * crash
//   * SMAppService.unregister() racing the daemon before it processes
//     a pending `disable` socket command
//   * SettingsWindow's Uninstall path before it learned to send `disable`
//     first (the bug that caught this in the first place)
// Forcing `disablesleep 0` on every launch self-heals all of those cases.
//
// Trade-off: if launchd auto-restarts the daemon (KeepAlive=true) WHILE
// StayUp is mid-engagement, this also clears the legitimate active state,
// leaving layer 5 silently off until StayUp next sends "enable". The
// SIGPIPE fix above makes such mid-engagement restarts rare in practice;
// if this edge case bites in production, the right fix is periodic
// re-arming from the client side, not reverting this rescue.
runPmset(["-a", "disablesleep", "0"])

unlink(socketPath)

let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverFd >= 0 else { exit(1) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
socketPath.withCString { src in
    withUnsafeMutablePointer(to: &addr.sun_path) { dst in
        dst.withMemoryRebound(to: CChar.self, capacity: 108) { _ = strcpy($0, src) }
    }
}

let bindResult = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0 else { exit(1) }

chmod(socketPath, 0o777)
listen(serverFd, 8)

while true {
    let clientFd = accept(serverFd, nil, nil)
    if clientFd >= 0 { handleClient(clientFd) }
}
