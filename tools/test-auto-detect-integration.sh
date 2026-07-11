#!/bin/sh
# Diagnose the real Auto Detect seam: hook writer -> ActivitySourceMonitor poll.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-auto-detect.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-auto-detect"

cat > "$TEST_MAIN" <<'SWIFT'
import Foundation

enum Settings {
    static var enabledSources: Set<String> = []
    static func isSourceEnabled(_ name: String) -> Bool { enabledSources.contains(name) }
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

let home = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let hook = CommandLine.arguments[2]
let maxSeconds = TimeInterval(ProcessInfo.processInfo.environment["STAYUP_TEST_MAX_SECONDS"] ?? "2.5") ?? 2.5
let sourcesDir = home.appendingPathComponent(".stayup/sources", isDirectory: true)
let monitor = ActivitySourceMonitor(directory: sourcesDir)

func runLoop(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func callHook(_ action: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [hook, action]
    process.environment = [
        "HOME": home.path,
        "STAYUP_SOURCE_NAME": "Tool",
        "STAYUP_SOURCE_SLUG": "tool-cli",
        "STAYUP_SOURCE_DISPLAY": "Tool CLI",
        "STAYUP_SOURCE_KEY": "Tool",
        "STAYUP_SESSION_ID": "auto-detect",
        "STAYUP_SOURCE_PID": String(getpid())
    ]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        input.fileHandleForWriting.write(Data("{\"session_id\":\"auto-detect\"}".utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    } catch {
        fail("could not run hook: \(error)")
    }
    if process.terminationStatus != 0 {
        fail("hook exited with \(process.terminationStatus)")
    }
}

@discardableResult
func waitAggregate(_ expected: Bool, maxSeconds: TimeInterval) -> TimeInterval {
    let started = Date()
    while Date().timeIntervalSince(started) < maxSeconds {
        if monitor.isAnySourceWorking == expected {
            return Date().timeIntervalSince(started)
        }
        runLoop(0.05)
    }
    fail("expected aggregate working=\(expected) within \(maxSeconds)s; got \(monitor.isAnySourceWorking)")
}

monitor.start()
runLoop(0.2)
if monitor.isAnySourceWorking {
    fail("monitor should start idle")
}

callHook("working")
let sourceJSON = sourcesDir.appendingPathComponent("tool-cli/source.json")
if !FileManager.default.fileExists(atPath: sourceJSON.path) {
    fail("first reported heartbeat should create source.json for Settings refresh")
}
runLoop(0.3)
if monitor.isAnySourceWorking {
    fail("a prompt-created source must not protect before the user ticks it")
}

Settings.enabledSources.insert("Tool")
let onLatency = waitAggregate(true, maxSeconds: maxSeconds)

callHook("not-working")
let offLatency = waitAggregate(false, maxSeconds: maxSeconds)

callHook("working")
_ = waitAggregate(true, maxSeconds: maxSeconds)

callHook("stop")
let stopLatency = waitAggregate(false, maxSeconds: maxSeconds)

monitor.stop()
print(String(format: "auto detect integration: ok (on %.2fs, off %.2fs, stop %.2fs)",
             onLatency, offLatency, stopLatency))
SWIFT

swiftc "$ROOT/Sources/SourceCatalog.swift" "$ROOT/Sources/ActivitySourceMonitor.swift" "$TEST_MAIN" -o "$BIN"
"$BIN" "$TMP" "$ROOT/tools/stayup-source-hook.sh"
