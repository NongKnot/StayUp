import Foundation

/// Wraps `/usr/bin/caffeinate` — Apple's official sleep-prevention tool.
///
/// Runs `caffeinate -dis -w <our_pid>`:
///   -d  prevent display sleep
///   -i  prevent idle system sleep
///   -s  prevent system sleep on AC only; Apple Silicon firmware ignores it
///       on battery for thermal reasons, which is why the StayUp helper exists.
///   -w  auto-exits when our PID dies — crash-safe, Mac won't stay awake forever.
///
/// This runs alongside SleepPreventer (IOKit) and ClosedLidPreventer — all
/// three layers are active while Stay Up is on. Each has different failure
/// modes so holding all of them maximises coverage.
class Caffeinate {
    private(set) var isActive = false
    private var process: Process?

    /// `preventDisplaySleep` maps to caffeinate's `-d`. When false we drop it
    /// (`-is` only): the system stays awake for background work, but the display
    /// is free to sleep — which lets macOS show the lock screen. Driven by the
    /// "let the screen lock" option (see `Settings.virtualDisplayEnabled`).
    func enable(preventDisplaySleep: Bool = true) {
        guard !isActive else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments     = [preventDisplaySleep ? "-dis" : "-is", "-w", String(getpid())]
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice

        do {
            try p.run()
            process  = p
            isActive = true
        } catch {
            FileHandle.standardError.write(Data(
                "[StayUp] Failed to spawn caffeinate: \(error)\n".utf8))
        }
    }

    func disable() {
        guard isActive else { return }
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        isActive = false
    }
}
