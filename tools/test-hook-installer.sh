#!/bin/sh
# Regression-test ActivitySourceHookInstaller without touching real user config.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-hook-installer.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

HOOKS="$TMP/hooks.json"
SCRIPT="$TMP/stayup-source-hook.sh"
TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-hook-installer"

printf '#!/bin/sh\nexit 0\n' > "$SCRIPT"
chmod 755 "$SCRIPT"

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

let hooksURL = URL(fileURLWithPath: CommandLine.arguments[1])
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[2])

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
SWIFT

swiftc "$ROOT/Sources/ActivitySourceHookInstaller.swift" "$TEST_MAIN" -o "$BIN"
"$BIN" "$HOOKS" "$SCRIPT"
