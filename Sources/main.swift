import AppKit

// Debug: dump icon PNGs and exit. Runs *before* the single-instance guard
// so we can preview new icon variants while the production app is also
// running. Production users never set this env var.
if ProcessInfo.processInfo.environment["STAYUP_DUMPICONS"] != nil {
    IconRenderer.dumpToDisk()
    exit(0)
}

// Single-instance guard. The "Launch at Login" toggle bootstraps a
// LaunchAgent with RunAtLoad=true, which fires immediately and would spawn
// a duplicate StayUp on top of the one the user clicked from. Same applies
// at login time if the app is already running for any reason. Whichever
// process loses this race exits silently — the existing one keeps running.
let bundleID = Bundle.main.bundleIdentifier ?? "app.getstayup"
let myPID    = ProcessInfo.processInfo.processIdentifier
let others   = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != myPID }
if !others.isEmpty { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
