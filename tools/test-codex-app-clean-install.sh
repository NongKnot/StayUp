#!/bin/sh
# Regression-test a clean Codex App/CLI hook setup without touching real user state.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-codex-clean.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-codex-clean"
HOME_DIR="$TMP/home"

cat > "$TEST_MAIN" <<'SWIFT'
import Foundation

enum Settings {
    static var autoSourceEnabled = false
    static var reportedHookConnectionAllowed = false
    static var enabledSources: Set<String> = []

    static func isSourceDeleted(_ name: String) -> Bool { false }
    static func isSourceEnabled(_ name: String) -> Bool { enabledSources.contains(name) }
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

func runLoop(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@discardableResult
func waitAggregate(_ monitor: ActivitySourceMonitor, _ expected: Bool, maxSeconds: TimeInterval = 2.5) -> TimeInterval {
    let started = Date()
    while Date().timeIntervalSince(started) < maxSeconds {
        if monitor.isAnySourceWorking == expected {
            return Date().timeIntervalSince(started)
        }
        runLoop(0.05)
    }
    fail("expected aggregate working=\(expected) within \(maxSeconds)s; got \(monitor.isAnySourceWorking)")
}

func jsonRoot(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("root is not an object")
    }
    return root
}

func commands(for event: String, in root: [String: Any]) -> [String] {
    guard let hooks = root["hooks"] as? [String: Any],
          let groups = hooks[event] as? [[String: Any]] else { return [] }
    return groups.flatMap { group -> [String] in
        guard let items = group["hooks"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["command"] as? String }
    }
}

func callWrapper(_ wrapper: URL, action: String, home: URL, payload: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [wrapper.path, action]
    process.environment = [
        "HOME": home.path,
        "STAYUP_SOURCE_PID": String(getpid())
    ]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    } catch {
        fail("could not run wrapper: \(error)")
    }
    if process.terminationStatus != 0 {
        fail("wrapper exited with \(process.terminationStatus)")
    }
}

func touchOld(_ url: URL) {
    let old = Date(timeIntervalSinceNow: -20 * 60)
    try! FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
}

let home = FileManager.default.homeDirectoryForCurrentUser
let sourceScript = URL(fileURLWithPath: CommandLine.arguments[1])
let hooksFile = home.appendingPathComponent(".codex/hooks.json")
let scriptDest = home.appendingPathComponent(".stayup/bin/stayup-source-hook.sh")
let wrapper = home.appendingPathComponent(".stayup/bin/stayup-source-hook-codex-cli.sh")
let sourcesDir = home.appendingPathComponent(".stayup/sources", isDirectory: true)
let codexDir = sourcesDir.appendingPathComponent("codex-cli", isDirectory: true)
let marker = codexDir.appendingPathComponent("active/clean-session")
let toolsDir = URL(fileURLWithPath: marker.path + ".tools", isDirectory: true)
let toolMarker = toolsDir.appendingPathComponent("long-tool")

try! FileManager.default.createDirectory(at: scriptDest.deletingLastPathComponent(), withIntermediateDirectories: true)
try! FileManager.default.copyItem(at: sourceScript, to: scriptDest)
try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptDest.path)

try! ActivitySourceHookInstaller.installCodex(scriptDest: scriptDest, hooksFile: hooksFile)

let hooksRoot = try! jsonRoot(hooksFile)
for (event, action) in [
    ("SessionStart", "waiting"),
    ("UserPromptSubmit", "turn-start"),
    ("PreToolUse", "tool-begin"),
    ("PostToolUse", "tool-end"),
    ("SubagentStart", "active"),
    ("SubagentStop", "active"),
    ("PreCompact", "active"),
    ("PostCompact", "active"),
    ("PermissionRequest", "waiting"),
    ("Stop", "waiting"),
] {
    let eventCommands = commands(for: event, in: hooksRoot)
    if !eventCommands.contains(where: { $0.contains(wrapper.path) && $0.hasSuffix(" \(action)") }) {
        fail("missing Codex hook command for \(event) -> \(action)")
    }
}

let monitor = ActivitySourceMonitor(directory: sourcesDir)
monitor.start()
runLoop(0.2)
if monitor.isAnySourceWorking {
    fail("clean install should start idle")
}

let codexTranscript = home
    .appendingPathComponent(".codex/sessions", isDirectory: true)
    .appendingPathComponent("clean-session.jsonl")
    .path
let basePayload = """
{"session_id":"clean-session","cwd":"/tmp/stayup-clean","transcript_path":"\(codexTranscript)"}
"""
callWrapper(wrapper, action: "turn-start", home: home, payload: basePayload)

let sourceJSON = codexDir.appendingPathComponent("source.json")
guard let sourceData = try? Data(contentsOf: sourceJSON),
      let source = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
      source["name"] as? String == "Codex",
      source["type"] as? String == "reported"
else {
    fail("Codex hook should create a reported source.json")
}

runLoop(0.3)
if monitor.isAnySourceWorking {
    fail("Codex source must not protect before the user ticks it")
}

Settings.enabledSources.insert("Codex")
_ = waitAggregate(monitor, true)

let toolPayload = """
{"session_id":"clean-session","tool_use_id":"long-tool","cwd":"/tmp/stayup-clean"}
"""
callWrapper(wrapper, action: "tool-begin", home: home, payload: toolPayload)
if !FileManager.default.fileExists(atPath: toolMarker.path) {
    fail("Codex PreToolUse should create an in-flight tool marker")
}
touchOld(marker)
touchOld(toolMarker)
runLoop(0.2)
if !monitor.isAnySourceWorking {
    fail("stale long-running Codex tool should still protect while source pid is live")
}

callWrapper(wrapper, action: "tool-end", home: home, payload: toolPayload)
if FileManager.default.fileExists(atPath: toolMarker.path) {
    fail("Codex PostToolUse should remove the matching tool marker")
}
_ = waitAggregate(monitor, true)

callWrapper(wrapper, action: "stop", home: home, payload: basePayload)
_ = waitAggregate(monitor, false)

monitor.stop()
print("codex app clean install: ok")
SWIFT

mkdir -p "$HOME_DIR"
swiftc "$ROOT/Sources/BundledSources.swift" \
    "$ROOT/Sources/SourceCatalog.swift" \
    "$ROOT/Sources/ActivitySourceHookInstaller.swift" \
    "$ROOT/Sources/ActivitySourceMonitor.swift" \
    "$TEST_MAIN" \
    -o "$BIN"
HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" "$BIN" "$ROOT/tools/stayup-source-hook.sh"
