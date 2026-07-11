#!/bin/sh
# Regression-test ActivitySourceMonitor policy without touching real user state.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-source-monitor.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-activity-source-monitor"

cat > "$TEST_MAIN" <<'SWIFT'
import Foundation

enum Settings {
    static var enabledSources: Set<String> = ["Test Source"]
    static func isSourceEnabled(_ name: String) -> Bool { enabledSources.contains(name) }
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

func write(_ text: String, to url: URL) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try! text.data(using: .utf8)!.write(to: url)
}

func touchOld(_ url: URL) {
    let old = Date(timeIntervalSinceNow: -20 * 60)
    try! FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let source = root.appendingPathComponent("test-source", isDirectory: true)
write("""
{
  "schema": "app.getstayup.activity-source.v1",
  "name": "Test Source",
  "displayName": "Test Source",
  "type": "reported",
  "method": "reported"
}
""", to: source.appendingPathComponent("source.json"))

let monitor = ActivitySourceMonitor(directory: root)
let pid = getpid()

// Legacy cases model a long-lived owner: markers are backdated but pid=self
// is seconds old. Pin the start-time lookup to the distant past so they keep
// exercising the no-time-cap policy; the recycle cases below override it.
// For dead pids, return nil so pidOwnsMarker falls back to pidAlive check.
monitor.procStartTime = { testPid in
    let realResult = ActivitySourceMonitor.processStartTime(testPid)
    if realResult != nil {
        return .distantPast  // live pid gets ancient start time
    }
    return nil  // dead pid falls through to pidAlive fallback
}

let longTool = source.appendingPathComponent("active/long-tool")
write("active\npid=\(pid)\n", to: longTool)
let toolsDir = URL(fileURLWithPath: longTool.path + ".tools", isDirectory: true)
try! FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
let toolMarker = toolsDir.appendingPathComponent("build")
write("", to: toolMarker)
touchOld(longTool)
touchOld(toolMarker)

var sessions = monitor.snapshotSessions()
guard let longToolSession = sessions.first(where: { $0.id == "long-tool" }) else {
    fail("long-running tool session was not visible")
}
if !longToolSession.working || longToolSession.toolsInFlight != 1 {
    fail("old in-flight tool should still protect while owner pid is live")
}

let staleThinking = source.appendingPathComponent("active/stale-thinking")
write("active\npid=\(pid)\n", to: staleThinking)
touchOld(staleThinking)

sessions = monitor.snapshotSessions()
if sessions.contains(where: { $0.id == "stale-thinking" }) {
    fail("stale active session without tool marker should not remain visible forever")
}

let waiting = source.appendingPathComponent("active/waiting")
write("waiting\npid=\(pid)\n", to: waiting)
let waitingToolsDir = URL(fileURLWithPath: waiting.path + ".tools", isDirectory: true)
try! FileManager.default.createDirectory(at: waitingToolsDir, withIntermediateDirectories: true)
write("", to: waitingToolsDir.appendingPathComponent("leaked"))

sessions = monitor.snapshotSessions()
guard let waitingSession = sessions.first(where: { $0.id == "waiting" }) else {
    fail("waiting session should remain visible")
}
if waitingSession.working || waitingSession.toolsInFlight != 0 {
    fail("waiting session should not protect, even with leaked tool markers")
}

// --- Truth-table + prune hardening cases -----------------------------------

/// A pid that is guaranteed dead: spawn /usr/bin/true and reap it.
func deadPid() -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try! p.run()
    p.waitUntilExit()
    return p.processIdentifier
}

// Junk state token: invisible AND prune-worthy even while fresh.
let junk = source.appendingPathComponent("active/junk-token")
write("bogus\npid=\(pid)\n", to: junk)
if monitor.snapshotSessions().contains(where: { $0.id == "junk-token" }) {
    fail("invalid state token must not be visible")
}

// Fresh active marker, no tools, dead pid: invisible (owner is gone).
let deadOwner = source.appendingPathComponent("active/dead-owner")
write("active\npid=\(deadPid())\n", to: deadOwner)
if monitor.snapshotSessions().contains(where: { $0.id == "dead-owner" }) {
    fail("fresh active marker with dead pid must not be visible")
}

// External marker: fresh presence = working, stale = gone.
let extFresh = source.appendingPathComponent("active/ext-observed")
write("active\nsignal=process\ndetail=cpu busy\n", to: extFresh)
var snap = monitor.snapshotSessions()
guard let ext = snap.first(where: { $0.id == "ext-observed" }), ext.working, ext.isExternal else {
    fail("fresh external marker should be visible and working")
}
touchOld(extFresh)
if monitor.snapshotSessions().contains(where: { $0.id == "ext-observed" }) {
    fail("stale external marker should drop")
}

// Empty marker file: fail-safe toward awake while fresh.
let torn = source.appendingPathComponent("active/torn-read")
write("", to: torn)
snap = monitor.snapshotSessions()
guard let tornSession = snap.first(where: { $0.id == "torn-read" }), tornSession.working else {
    fail("empty (torn) marker must fail safe toward working while fresh")
}
try! FileManager.default.removeItem(at: torn)

// --- pid-recycle guard -------------------------------------------------------

// Real sysctl: our own start time is sane; a reaped pid has none.
guard let selfStart = ActivitySourceMonitor.processStartTime(getpid()) else {
    fail("processStartTime(self) should resolve")
}
let sinceStart = Date().timeIntervalSince(selfStart)
if sinceStart < 0 || sinceStart > 3600 {
    fail("processStartTime(self) implausible: \(sinceStart)s ago")
}
if ActivitySourceMonitor.processStartTime(deadPid()) != nil {
    fail("processStartTime(dead pid) should be nil")
}

// Recycled pid: marker written long ago, "owner" process started after it.
// Seam: pretend every pid lookup returns a just-started process.
let recycled = source.appendingPathComponent("active/recycled")
write("active\npid=\(pid)\n", to: recycled)
let recycledTools = URL(fileURLWithPath: recycled.path + ".tools", isDirectory: true)
try! FileManager.default.createDirectory(at: recycledTools, withIntermediateDirectories: true)
write("", to: recycledTools.appendingPathComponent("build"))
touchOld(recycled)
monitor.procStartTime = { _ in Date() }          // started AFTER the marker → recycled
if monitor.snapshotSessions().contains(where: { $0.id == "recycled" }) {
    fail("tool marker owned by a recycled pid must not be visible")
}
monitor.procStartTime = { _ in .distantPast }    // long-lived owner again
guard let recovered = monitor.snapshotSessions().first(where: { $0.id == "recycled" }),
      recovered.working else {
    fail("same marker with a pre-existing owner must be working (no time cap)")
}
// Reset to smart seam for pruning phase: distinguish live pids (distant past) from dead pids (nil fallback)
monitor.procStartTime = { testPid in
    let realResult = ActivitySourceMonitor.processStartTime(testPid)
    if realResult != nil {
        return .distantPast
    }
    return nil
}
try! FileManager.default.removeItem(at: recycled)
try! FileManager.default.removeItem(at: recycledTools)

// Pruning: start the poll loop and verify dead markers leave the disk.
// junk-token and dead-owner are fresh — old code kept both up to 15 min.
monitor.start()
Thread.sleep(forTimeInterval: 2.5)
monitor.stop()
if FileManager.default.fileExists(atPath: junk.path) {
    fail("junk-token marker should be pruned from disk immediately")
}
if FileManager.default.fileExists(atPath: deadOwner.path) {
    fail("fresh dead-pid marker should be pruned from disk immediately")
}
if FileManager.default.fileExists(atPath: extFresh.path) {
    fail("stale external marker should be pruned from disk")
}
if !FileManager.default.fileExists(atPath: waiting.path) {
    fail("live waiting marker must survive pruning")
}
if !FileManager.default.fileExists(atPath: longTool.path) {
    fail("live long-tool marker must survive pruning")
}

print("activity source monitor policy: ok")
SWIFT

swiftc "$ROOT/Sources/SourceCatalog.swift" "$ROOT/Sources/ActivitySourceMonitor.swift" "$TEST_MAIN" -o "$BIN"
"$BIN" "$TMP/sources"
