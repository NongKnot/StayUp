#!/bin/sh
# Regression-test ActivitySourceHookInstaller without touching real user config.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-hook-installer.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

HOOKS="$TMP/hooks.json"
CURSOR_HOOKS="$TMP/cursor-hooks.json"
CLAUDE_HOOKS="$TMP/claude-settings.json"
SCRIPT="$TMP/stayup-source-hook.sh"
TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-hook-installer"

printf '#!/bin/sh\nexit 0\n' > "$SCRIPT"
chmod 755 "$SCRIPT"
cat > "$CLAUDE_HOOKS" <<'JSON'
{
  "hooks": {
    "SubagentStop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo user-claude-subagent-stop"
          },
          {
            "type": "command",
            "command": "'/Users/example/.stayup/bin/stayup-source-hook-claude-code-cli.sh' active"
          }
        ]
      }
    ]
  }
}
JSON

cat > "$HOOKS" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo user-pre"
          },
          {
            "type": "command",
            "command": "STAYUP_SOURCE_NAME='Codex' '/Users/example/.stayup/bin/stayup-source-hook.sh' tool-begin"
          }
        ]
      },
      {
        "matcher": "other",
        "hooks": [
          {
            "type": "command",
            "command": "echo user-pre-2"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "STAYUP_SOURCE_NAME='Codex' '/Users/example/.stayup/bin/stayup-source-hook.sh' tool-end"
          }
        ]
      }
    ],
    "OtherEvent": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo untouched"
          }
        ]
      }
    ]
  },
  "keep": true
}
JSON

cat > "$CURSOR_HOOKS" <<'JSON'
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "command": "echo cursor-pre"
      },
      {
        "command": "'/Users/example/.stayup/bin/stayup-source-hook-cursor.sh' tool-begin"
      }
    ],
    "stop": [
      {
        "command": "echo cursor-stop"
      }
    ],
    "otherEvent": [
      {
        "command": "echo cursor-untouched"
      }
    ]
  }
}
JSON

cat > "$TEST_MAIN" <<'SWIFT'
import Foundation

enum Settings {
    static var autoSourceEnabled = false
    static var reportedHookConnectionAllowed = false
    static func isSourceDeleted(_ name: String) -> Bool { false }
    static func isSourceEnabled(_ name: String) -> Bool { true }
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
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

func flatCommands(for event: String, in root: [String: Any]) -> [String] {
    guard let hooks = root["hooks"] as? [String: Any],
          let items = hooks[event] as? [[String: Any]] else { return [] }
    return items.compactMap { $0["command"] as? String }
}

func assertContains(_ commands: [String], _ needle: String) {
    if !commands.contains(where: { $0.contains(needle) }) {
        fail("missing command containing \(needle)")
    }
}

func assertNotContains(_ commands: [String], _ needle: String) {
    if commands.contains(where: { $0.contains(needle) }) {
        fail("unexpected command containing \(needle)")
    }
}

func countContaining(_ commands: [String], _ needle: String) -> Int {
    commands.filter { $0.contains(needle) }.count
}

func assertCodexHook(_ root: [String: Any], event: String, action: String) {
    let eventCommands = commands(for: event, in: root)
    if !eventCommands.contains(where: { $0.contains("stayup-source-hook-codex-cli.sh") && $0.hasSuffix(" \(action)") }) {
        fail("missing Codex hook command for \(event) -> \(action)")
    }
}

func assertClaudeHook(_ root: [String: Any], event: String, action: String) {
    let eventCommands = commands(for: event, in: root)
    if !eventCommands.contains(where: { $0.contains("stayup-source-hook-claude-code-cli.sh") && $0.hasSuffix(" \(action)") }) {
        fail("missing Claude hook command for \(event) -> \(action)")
    }
}

func assertCursorHook(_ root: [String: Any], event: String, action: String) {
    let eventCommands = flatCommands(for: event, in: root)
    if !eventCommands.contains(where: { $0.contains("stayup-source-hook-cursor.sh") && $0.hasSuffix(" \(action)") }) {
        fail("missing Cursor hook command for \(event) -> \(action)")
    }
}

let hooksURL = URL(fileURLWithPath: CommandLine.arguments[1])
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[2])
let cursorHooksURL = URL(fileURLWithPath: CommandLine.arguments[3])
let claudeHooksURL = URL(fileURLWithPath: CommandLine.arguments[4])

let claudeScriptDest = scriptURL.deletingLastPathComponent()
    .appendingPathComponent("claude-bin/stayup-source-hook.sh")
try ActivitySourceHookInstaller.install(
    scriptSource: scriptURL,
    scriptDest: claudeScriptDest,
    settings: claudeHooksURL)
var claudeRoot = try jsonRoot(claudeHooksURL)
let claudeSessionStart = commands(for: "SessionStart", in: claudeRoot)
if countContaining(claudeSessionStart, "stayup-source-hook-claude-code-cli.sh") != 1 ||
    !claudeSessionStart.contains(where: { $0.hasSuffix(" waiting") }) {
    fail("Claude SessionStart should install as waiting so startup/recap does not look active")
}
if claudeSessionStart.contains(where: { $0.hasSuffix(" active") }) {
    fail("Claude SessionStart should not install as active")
}
for (event, action) in [
    ("UserPromptSubmit", "turn-start"),
    ("PreToolUse", "tool-begin"),
    ("PostToolUse", "tool-end"),
    ("PostToolUseFailure", "tool-end"),
    ("PermissionRequest", "waiting"),
    ("PermissionDenied", "waiting"),
    ("StopFailure", "waiting"),
    ("Notification", "waiting"),
    ("Stop", "waiting"),
    ("SessionEnd", "stop"),
] {
    assertClaudeHook(claudeRoot, event: event, action: action)
}
let claudeSubagentStop = commands(for: "SubagentStop", in: claudeRoot)
assertContains(claudeSubagentStop, "echo user-claude-subagent-stop")
assertNotContains(claudeSubagentStop, "stayup-source-hook")
assertNotContains(commands(for: "PreCompact", in: claudeRoot), "stayup-source-hook")
assertNotContains(commands(for: "PostCompact", in: claudeRoot), "stayup-source-hook")

try ActivitySourceHookInstaller.uninstallCodex(hooksFile: hooksURL)
var root = try jsonRoot(hooksURL)
assertContains(commands(for: "PreToolUse", in: root), "echo user-pre")
assertContains(commands(for: "PreToolUse", in: root), "echo user-pre-2")
assertNotContains(commands(for: "PreToolUse", in: root), "stayup-source-hook")
assertNotContains(commands(for: "PostToolUse", in: root), "stayup-source-hook")
assertContains(commands(for: "OtherEvent", in: root), "echo untouched")

try ActivitySourceHookInstaller.installCodex(scriptDest: scriptURL, hooksFile: hooksURL)
root = try jsonRoot(hooksURL)
assertContains(commands(for: "PreToolUse", in: root), "echo user-pre")
assertContains(commands(for: "PreToolUse", in: root), "echo user-pre-2")
assertContains(commands(for: "PreToolUse", in: root), "stayup-source-hook")
assertContains(commands(for: "PostToolUse", in: root), "stayup-source-hook")
assertContains(commands(for: "OtherEvent", in: root), "echo untouched")
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
    assertCodexHook(root, event: event, action: action)
}
// Codex Stop moved stop -> waiting so an idle session stays visible. The stale
// `... stop` command must not survive a fresh install (removingOurHooks strips
// every StayUp entry on the Stop event before re-adding the current one).
let codexStop = commands(for: "Stop", in: root)
if countContaining(codexStop, "stayup-source-hook-codex-cli.sh") != 1 {
    fail("Codex Stop should carry exactly one StayUp entry after install")
}
if codexStop.contains(where: { $0.contains("stayup-source-hook-codex-cli.sh") && $0.hasSuffix(" stop") }) {
    fail("stale Codex Stop->stop command should be gone after install")
}

let beforeDisable = try Data(contentsOf: hooksURL)
try ActivitySourceHookInstaller.disableSource(named: "Codex", folderSlug: "codex-cli", scriptDest: scriptURL)
let afterDisable = try Data(contentsOf: hooksURL)
if beforeDisable != afterDisable {
    fail("safe disable changed hooks.json")
}

let wrapperURL = scriptURL.deletingLastPathComponent()
    .appendingPathComponent("stayup-source-hook-codex-cli.sh")
let wrapper = try String(contentsOf: wrapperURL, encoding: .utf8)
if !wrapper.contains("exit 0") || wrapper.contains("STAYUP_SOURCE_NAME") {
    fail("safe disable did not write a no-op wrapper")
}

try ActivitySourceHookInstaller.installCodex(scriptDest: scriptURL, hooksFile: hooksURL)
root = try jsonRoot(hooksURL)
let preCommandsAfterRestore = commands(for: "PreToolUse", in: root)
let postCommandsAfterRestore = commands(for: "PostToolUse", in: root)
assertContains(preCommandsAfterRestore, "echo user-pre")
assertContains(preCommandsAfterRestore, "echo user-pre-2")
if countContaining(preCommandsAfterRestore, "stayup-source-hook-codex-cli.sh") != 1 {
    fail("restore duplicated or missed the Codex PreToolUse hook")
}
if countContaining(postCommandsAfterRestore, "stayup-source-hook-codex-cli.sh") != 1 {
    fail("restore duplicated or missed the Codex PostToolUse hook")
}

let restoredWrapper = try String(contentsOf: wrapperURL, encoding: .utf8)
if restoredWrapper.contains("exit 0") ||
    !restoredWrapper.contains("STAYUP_SOURCE_NAME='Codex'") ||
    !restoredWrapper.contains("STAYUP_SOURCE_SLUG='codex-cli'") ||
    !restoredWrapper.contains("exec '\(scriptURL.path)' \"$@\"") {
    fail("restore did not overwrite no-op wrapper with the real wrapper")
}

print("hook installer preservation: ok")

try ActivitySourceHookInstaller.uninstallCursor(hooksFile: cursorHooksURL)
root = try jsonRoot(cursorHooksURL)
assertContains(flatCommands(for: "preToolUse", in: root), "echo cursor-pre")
assertNotContains(flatCommands(for: "preToolUse", in: root), "stayup-source-hook")
assertContains(flatCommands(for: "stop", in: root), "echo cursor-stop")
assertContains(flatCommands(for: "otherEvent", in: root), "echo cursor-untouched")

try ActivitySourceHookInstaller.installCursor(scriptDest: scriptURL, hooksFile: cursorHooksURL)
root = try jsonRoot(cursorHooksURL)
assertContains(flatCommands(for: "preToolUse", in: root), "echo cursor-pre")
for (event, action) in [
    ("sessionStart", "waiting"),
    ("beforeSubmitPrompt", "turn-start"),
    ("preToolUse", "tool-begin"),
    ("postToolUse", "tool-end"),
    ("postToolUseFailure", "tool-end"),
    ("subagentStart", "active"),
    ("subagentStop", "active"),
    ("afterAgentThought", "active"),
    ("afterAgentResponse", "waiting"),
    ("stop", "stop"),
    ("sessionEnd", "stop"),
] {
    assertCursorHook(root, event: event, action: action)
}
assertContains(flatCommands(for: "stop", in: root), "echo cursor-stop")
assertContains(flatCommands(for: "otherEvent", in: root), "echo cursor-untouched")

let cursorBeforeDisable = try Data(contentsOf: cursorHooksURL)
try ActivitySourceHookInstaller.disableSource(named: "Cursor", folderSlug: "cursor", scriptDest: scriptURL)
let cursorAfterDisable = try Data(contentsOf: cursorHooksURL)
if cursorBeforeDisable != cursorAfterDisable {
    fail("safe disable changed Cursor hooks.json")
}

let cursorWrapperURL = scriptURL.deletingLastPathComponent()
    .appendingPathComponent("stayup-source-hook-cursor.sh")
let cursorWrapper = try String(contentsOf: cursorWrapperURL, encoding: .utf8)
if !cursorWrapper.contains("exit 0") || cursorWrapper.contains("STAYUP_SOURCE_NAME") {
    fail("safe disable did not write a Cursor no-op wrapper")
}

try ActivitySourceHookInstaller.installCursor(scriptDest: scriptURL, hooksFile: cursorHooksURL)
root = try jsonRoot(cursorHooksURL)
if countContaining(flatCommands(for: "preToolUse", in: root), "stayup-source-hook-cursor.sh") != 1 {
    fail("restore duplicated or missed the Cursor preToolUse hook")
}
if countContaining(flatCommands(for: "postToolUse", in: root), "stayup-source-hook-cursor.sh") != 1 {
    fail("restore duplicated or missed the Cursor postToolUse hook")
}
let restoredCursorWrapper = try String(contentsOf: cursorWrapperURL, encoding: .utf8)
if restoredCursorWrapper.contains("exit 0") ||
    !restoredCursorWrapper.contains("STAYUP_SOURCE_NAME='Cursor'") ||
    !restoredCursorWrapper.contains("STAYUP_SOURCE_SLUG='cursor'") ||
    !restoredCursorWrapper.contains("exec '\(scriptURL.path)' \"$@\"") {
    fail("restore did not overwrite Cursor no-op wrapper with the real wrapper")
}

print("cursor hook installer preservation: ok")

// ── Codex Stop stop -> waiting migration ────────────────────────────────────
// An existing install carries the retired `Stop -> stop` StayUp command. A fresh
// install must replace it with `Stop -> waiting` and leave no stale entry.
let scratch = claudeHooksURL.deletingLastPathComponent()
let codexWrapperPath = scriptURL.deletingLastPathComponent()
    .appendingPathComponent("stayup-source-hook-codex-cli.sh").path
let migrationHooks = scratch.appendingPathComponent("codex-migration.json")
try """
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "echo user-stop" },
          { "type": "command", "command": "'\(codexWrapperPath)' stop" }
        ]
      }
    ]
  }
}
""".data(using: .utf8)!.write(to: migrationHooks)
try ActivitySourceHookInstaller.installCodex(scriptDest: scriptURL, hooksFile: migrationHooks)
let migRoot = try jsonRoot(migrationHooks)
let migStop = commands(for: "Stop", in: migRoot)
assertContains(migStop, "echo user-stop")
if migStop.contains(where: { $0.contains("stayup-source-hook") && $0.hasSuffix(" stop") }) {
    fail("Codex migration left the stale Stop->stop StayUp command")
}
if !migStop.contains(where: { $0.contains("stayup-source-hook-codex-cli.sh") && $0.hasSuffix(" waiting") }) {
    fail("Codex migration did not install Stop->waiting")
}
if countContaining(migStop, "stayup-source-hook-codex-cli.sh") != 1 {
    fail("Codex migration duplicated the Stop StayUp entry")
}
try ActivitySourceHookInstaller.uninstallCodex(hooksFile: migrationHooks)
let migAfter = commands(for: "Stop", in: try jsonRoot(migrationHooks))
assertContains(migAfter, "echo user-stop")
assertNotContains(migAfter, "stayup-source-hook")
print("codex stop migration: ok")

// ── Generic adapter fixtures for the new bundled sources ────────────────────
func readText(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

// Gemini — mergeGrouped into a shared settings.json with a pre-existing user hook.
let gemini = BundledSources.source(forKey: "Gemini")!
let geminiCfg = scratch.appendingPathComponent("gemini-settings.json")
try """
{
  "hooks": {
    "BeforeTool": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "echo user-gemini" } ] }
    ]
  },
  "keep": true
}
""".data(using: .utf8)!.write(to: geminiCfg)
try ActivitySourceHookInstaller.installSource(gemini, scriptDest: scriptURL, configFile: geminiCfg)
if !ActivitySourceHookInstaller.isSourceInstalled(gemini, scriptDest: scriptURL, configFile: geminiCfg) {
    fail("Gemini isSourceInstalled false right after install")
}
var geminiRoot = try jsonRoot(geminiCfg)
assertContains(commands(for: "BeforeTool", in: geminiRoot), "echo user-gemini")
for (event, action) in [
    ("SessionStart", "waiting"), ("BeforeAgent", "turn-start"),
    ("BeforeTool", "tool-begin"), ("AfterTool", "tool-end"),
    ("AfterAgent", "waiting"), ("SessionEnd", "stop"),
] {
    let cmds = commands(for: event, in: geminiRoot)
    if !cmds.contains(where: { $0.contains("stayup-source-hook-gemini-cli.sh") && $0.hasSuffix(" \(action)") }) {
        fail("Gemini missing \(event) -> \(action)")
    }
}
// Simulate the agent clobbering our block, then repair via reinstall.
try """
{ "hooks": { "BeforeTool": [ { "matcher": "", "hooks": [ { "type": "command", "command": "echo user-gemini" } ] } ] } }
""".data(using: .utf8)!.write(to: geminiCfg)
if ActivitySourceHookInstaller.isSourceInstalled(gemini, scriptDest: scriptURL, configFile: geminiCfg) {
    fail("Gemini should read as not-installed after clobber")
}
try ActivitySourceHookInstaller.installSource(gemini, scriptDest: scriptURL, configFile: geminiCfg)
if !ActivitySourceHookInstaller.isSourceInstalled(gemini, scriptDest: scriptURL, configFile: geminiCfg) {
    fail("Gemini repair did not re-add hooks")
}
try ActivitySourceHookInstaller.uninstallSource(gemini, configFile: geminiCfg)
geminiRoot = try jsonRoot(geminiCfg)
assertContains(commands(for: "BeforeTool", in: geminiRoot), "echo user-gemini")
assertNotContains(commands(for: "BeforeTool", in: geminiRoot), "stayup-source-hook")
print("gemini grouped adapter: ok")

// Copilot — ownFile. StayUp owns the whole JSON; uninstall deletes it.
let copilot = BundledSources.source(forKey: "Copilot")!
let copilotFile = scratch.appendingPathComponent("copilot-stayup.json")
try ActivitySourceHookInstaller.installSource(copilot, scriptDest: scriptURL, configFile: copilotFile)
if !FileManager.default.fileExists(atPath: copilotFile.path) {
    fail("Copilot ownFile not written on install")
}
if !ActivitySourceHookInstaller.isSourceInstalled(copilot, scriptDest: scriptURL, configFile: copilotFile) {
    fail("Copilot isSourceInstalled false right after install")
}
let copilotText = readText(copilotFile)
if !copilotText.contains("stayup-source-hook-copilot-cli.sh") ||
    !copilotText.contains("userPromptSubmitted") ||
    !copilotText.contains("\"version\"") {
    fail("Copilot ownFile content missing expected keys: \(copilotText)")
}
try ActivitySourceHookInstaller.uninstallSource(copilot, configFile: copilotFile)
if FileManager.default.fileExists(atPath: copilotFile.path) {
    fail("Copilot ownFile not deleted on uninstall")
}
print("copilot ownFile adapter: ok")

// OpenCode — ownPlugin. StayUp owns a JS plugin file.
let opencode = BundledSources.source(forKey: "OpenCode")!
let pluginFile = scratch.appendingPathComponent("opencode-stayup.js")
try ActivitySourceHookInstaller.installSource(opencode, scriptDest: scriptURL, configFile: pluginFile)
if !ActivitySourceHookInstaller.isSourceInstalled(opencode, scriptDest: scriptURL, configFile: pluginFile) {
    fail("OpenCode isSourceInstalled false right after install")
}
let pluginText = readText(pluginFile)
if !pluginText.contains("export const StayUp") ||
    !pluginText.contains("tool.execute.before") ||
    !pluginText.contains("stayup-source-hook-opencode.sh") {
    fail("OpenCode plugin content missing expected pieces")
}
try ActivitySourceHookInstaller.uninstallSource(opencode, configFile: pluginFile)
if FileManager.default.fileExists(atPath: pluginFile.path) {
    fail("OpenCode plugin not deleted on uninstall")
}
print("opencode ownPlugin adapter: ok")

// --- Hook health: content-aware wrapper check (stub-zombie regression) ---
let healthDest = scriptURL.deletingLastPathComponent()
    .appendingPathComponent("health-bin/stayup-source-hook.sh")
let healthSettings = scriptURL.deletingLastPathComponent()
    .appendingPathComponent("health-claude-settings.json")
try ActivitySourceHookInstaller.install(
    scriptSource: scriptURL, scriptDest: healthDest, settings: healthSettings)
let claudeSource = BundledSources.source(forKey: "Claude")!
if !ActivitySourceHookInstaller.isSourceHealthy(
    claudeSource, scriptDest: healthDest, configFile: healthSettings) {
    fail("freshly installed Claude source should be healthy")
}
// Stub the wrapper the way safe-disable does — config entries stay intact.
let healthWrapper = healthDest.deletingLastPathComponent()
    .appendingPathComponent("stayup-source-hook-claude-code-cli.sh")
try Data("#!/bin/sh\nexit 0\n".utf8).write(to: healthWrapper, options: .atomic)
if ActivitySourceHookInstaller.isSourceHealthy(
    claudeSource, scriptDest: healthDest, configFile: healthSettings) {
    fail("stubbed wrapper must report unhealthy even with intact config (stub zombie)")
}
// Reinstall heals: wrapper content restored, healthy again.
try ActivitySourceHookInstaller.install(
    scriptSource: scriptURL, scriptDest: healthDest, settings: healthSettings)
if !ActivitySourceHookInstaller.isSourceHealthy(
    claudeSource, scriptDest: healthDest, configFile: healthSettings) {
    fail("reinstall should restore health after a stubbed wrapper")
}
// Config-side damage also reports unhealthy.
try ActivitySourceHookInstaller.uninstall(settings: healthSettings)
if ActivitySourceHookInstaller.isSourceHealthy(
    claudeSource, scriptDest: healthDest, configFile: healthSettings) {
    fail("missing config entries must report unhealthy")
}

// --- Legacy v0 purge: remove stayup-agent-hook entries, keep everything else ---
let legacySettings = scriptURL.deletingLastPathComponent()
    .appendingPathComponent("legacy-claude-settings.json")
let legacyJSON = """
{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "echo user-hook" },
        { "type": "command", "command": "\\"/Users/example/.stayup/bin/stayup-agent-hook.sh\\" tool-begin" }
      ]}
    ],
    "Stop": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "\\"/Users/example/.stayup/bin/stayup-agent-hook.sh\\" waiting" }
      ]}
    ],
    "SessionStart": [
      { "matcher": "", "hooks": [
        { "type": "command", "command": "'/Users/example/.stayup/bin/stayup-source-hook-claude-code-cli.sh' waiting" }
      ]}
    ]
  }
}
"""
try Data(legacyJSON.utf8).write(to: legacySettings, options: .atomic)
if try !ActivitySourceHookInstaller.purgeLegacyAgentHooks(settings: legacySettings) {
    fail("purge should report a change when v0 entries are present")
}
var legacyRoot = try jsonRoot(legacySettings)
assertNotContains(commands(for: "PreToolUse", in: legacyRoot), "stayup-agent-hook")
assertContains(commands(for: "PreToolUse", in: legacyRoot), "echo user-hook")
assertContains(commands(for: "SessionStart", in: legacyRoot), "stayup-source-hook-claude-code-cli")
if (legacyRoot["model"] as? String) != "opus" { fail("purge must not touch non-hook settings") }
if (legacyRoot["hooks"] as? [String: Any])?["Stop"] != nil {
    fail("event left with only v0 entries should be removed entirely")
}
// Idempotent: second run reports no change and leaves the file byte-identical.
let beforeSecond = try Data(contentsOf: legacySettings)
if try ActivitySourceHookInstaller.purgeLegacyAgentHooks(settings: legacySettings) {
    fail("second purge run should be a no-op")
}
if try Data(contentsOf: legacySettings) != beforeSecond {
    fail("no-op purge must not rewrite the file")
}
SWIFT

swiftc "$ROOT/Sources/BundledSources.swift" "$ROOT/Sources/SourceCatalog.swift" "$ROOT/Sources/ActivitySourceHookInstaller.swift" "$TEST_MAIN" -o "$BIN"
"$BIN" "$HOOKS" "$SCRIPT" "$CURSOR_HOOKS" "$CLAUDE_HOOKS"
