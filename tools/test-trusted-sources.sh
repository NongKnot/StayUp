#!/bin/sh
# Regression-test the fresh-install trusted source list without touching real user state.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-trusted-sources.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-trusted-sources"
HOME_DIR="$TMP/home"

cat > "$TEST_MAIN" <<'SWIFT'
import Foundation

enum Settings {
    static var autoSourceEnabled = false
    static var reportedHookConnectionAllowed = false
    static var enabledSources: Set<String> = []
    static var deletedSources: Set<String> = []

    static func isSourceDeleted(_ name: String) -> Bool { deletedSources.contains(name) }
    static func setSourceDeleted(_ name: String, deleted: Bool) {
        if deleted { deletedSources.insert(name) } else { deletedSources.remove(name) }
    }
    static func isSourceEnabled(_ name: String) -> Bool { enabledSources.contains(name) }
    static func setSource(_ name: String, enabled: Bool) {
        if enabled { enabledSources.insert(name) } else { enabledSources.remove(name) }
    }
    static func setReportedHookConnectionAllowed(_ allowed: Bool) {
        reportedHookConnectionAllowed = allowed
    }
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

let home = FileManager.default.homeDirectoryForCurrentUser
let sourcesDir = home.appendingPathComponent(".stayup/sources", isDirectory: true)
let retiredGeminiDir = sourcesDir.appendingPathComponent("gemini-cli", isDirectory: true)
try! FileManager.default.createDirectory(
    at: retiredGeminiDir,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
try! """
{
  "displayName": "Gemini CLI",
  "freshSecs": 45,
  "method": "file",
  "name": "Gemini",
  "path": "~/.gemini/tmp/*",
  "schema": "app.getstayup.activity-source.v1",
  "type": "file"
}
""".data(using: .utf8)!.write(to: retiredGeminiDir.appendingPathComponent("source.json"))

_ = SourceProvisioner.ensureProvisioned()
let sources = ExternalSourceWatcher.configuredSourceInfo()
let byKey = Dictionary(uniqueKeysWithValues: sources.map { ($0.key, $0) })
let expected: [(key: String, display: String, method: String, slug: String)] = [
    ("Claude", "Claude", "reported", "claude-code-cli"),
    ("Codex", "Codex", "reported", "codex-cli"),
    ("Cursor", "Cursor", "reported", "cursor"),
    ("Gemini", "Gemini", "reported", "gemini-cli"),
    ("Qwen", "Qwen", "reported", "qwen-code"),
    ("Copilot", "Copilot", "reported", "copilot-cli"),
    ("OpenCode", "OpenCode", "reported", "opencode"),
    ("LM Studio", "LM Studio", "logPattern", "lm-studio"),
    ("Ollama", "Ollama", "process", "ollama"),
]

if Set(byKey.keys) != Set(expected.map { $0.key }) {
    fail("fresh install source keys were \(byKey.keys.sorted()), expected exactly \(expected.map { $0.key }.sorted())")
}

for item in expected {
    guard let source = byKey[item.key] else { fail("missing \(item.key)") }
    if source.displayName != item.display ||
        source.method != item.method ||
        source.folderSlug != item.slug {
        fail("\(item.key) metadata was \(source), expected display=\(item.display) method=\(item.method) slug=\(item.slug)")
    }
    let sourceJSON = sourcesDir
        .appendingPathComponent(item.slug, isDirectory: true)
        .appendingPathComponent("source.json")
    guard let data = try? Data(contentsOf: sourceJSON),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { fail("missing source.json for \(item.key)") }
    if dict["name"] as? String != item.key ||
        dict["displayName"] as? String != item.display ||
        ((dict["method"] as? String) ?? (dict["type"] as? String)) != item.method {
        fail("source.json for \(item.key) did not use exact canonical metadata")
    }
}

// Gemini is now a bundled *reported* source. The legacy file-type Gemini folder
// under the same slug must be migrated to the reported recipe, not left as file.
// Ollama migrated socket -> CPU-gated process. Verify the written recipe fields.
let ollamaJSON = sourcesDir
    .appendingPathComponent("ollama", isDirectory: true)
    .appendingPathComponent("source.json")
guard let ollamaData = try? Data(contentsOf: ollamaJSON),
      let ollamaDict = try? JSONSerialization.jsonObject(with: ollamaData) as? [String: Any]
else { fail("missing Ollama source.json") }
if (ollamaDict["type"] as? String) != "process" ||
    (ollamaDict["match"] as? String) != "ollama" ||
    ((ollamaDict["minCpu"] as? NSNumber)?.doubleValue ?? 0) != 8 {
    fail("Ollama recipe should be process/match=ollama/minCpu=8, was \(ollamaDict)")
}

guard let geminiDict = try? JSONSerialization.jsonObject(
    with: Data(contentsOf: retiredGeminiDir.appendingPathComponent("source.json"))) as? [String: Any]
else { fail("Gemini source.json missing after migration") }
if (geminiDict["type"] as? String) != "reported" ||
    ((geminiDict["method"] as? String) ?? "") != "reported" {
    fail("legacy file-type Gemini source should migrate to reported, was \(geminiDict)")
}
if !ActivitySourceHookInstaller.canManageHooks(for: "Claude") ||
    !ActivitySourceHookInstaller.canManageHooks(for: "Codex") ||
    !ActivitySourceHookInstaller.canManageHooks(for: "Cursor") {
    fail("Claude, Codex, and Cursor should be managed reported sources")
}
if ActivitySourceHookInstaller.canManageHooks(for: "LM Studio") ||
    ActivitySourceHookInstaller.canManageHooks(for: "Ollama") {
    fail("LM Studio and Ollama should be observed sources, not hook-managed")
}

Settings.autoSourceEnabled = true
Settings.setSource("Codex", enabled: true)
let codexLog = home
    .appendingPathComponent("Library/Logs/com.openai.codex/2026/06/14", isDirectory: true)
    .appendingPathComponent("codex-desktop-test.log")
try! FileManager.default.createDirectory(
    at: codexLog.deletingLastPathComponent(),
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
try! "2026-06-14T09:00:00.000Z info method=turn/start\n"
    .data(using: .utf8)!.write(to: codexLog)
let watcher = ExternalSourceWatcher()
watcher.start()
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
let syntheticCodexMarker = sourcesDir
    .appendingPathComponent("codex-cli", isDirectory: true)
    .appendingPathComponent("active", isDirectory: true)
    .appendingPathComponent("state")
if FileManager.default.fileExists(atPath: syntheticCodexMarker.path) {
    fail("Codex desktop logs should not synthesize a logPattern source marker")
}
watcher.stop()
Settings.autoSourceEnabled = false
Settings.setSource("Codex", enabled: false)

guard let cursor = byKey["Cursor"] else { fail("missing Cursor before delete test") }
Settings.setSource("Cursor", enabled: true)
let cursorWrapper = home
    .appendingPathComponent(".stayup/bin", isDirectory: true)
    .appendingPathComponent("stayup-source-hook-cursor.sh")
try! FileManager.default.createDirectory(
    at: cursorWrapper.deletingLastPathComponent(),
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
try! """
#!/bin/sh
STAYUP_SOURCE_NAME='Cursor'
exec "$HOME/.stayup/bin/stayup-source-hook.sh" "$@"
""".data(using: .utf8)!.write(to: cursorWrapper)

try! ExternalSourceWatcher.deleteConfiguredSource(cursor, cleanupHooks: false)
if FileManager.default.fileExists(atPath: sourcesDir.appendingPathComponent("cursor", isDirectory: true).path) {
    fail("deleting bundled Cursor should remove its source folder")
}
if Settings.isSourceEnabled("Cursor") {
    fail("deleting bundled Cursor should disable it")
}
if !Settings.isSourceDeleted("Cursor") {
    fail("deleting bundled Cursor should mark the bundled source deleted")
}
let cursorWrapperText = (try? String(contentsOf: cursorWrapper, encoding: .utf8)) ?? ""
if !cursorWrapperText.contains("exit 0") || cursorWrapperText.contains("STAYUP_SOURCE_NAME") {
    fail("deleting bundled Cursor should safe-disable the wrapper")
}

guard let codex = byKey["Codex"] else { fail("missing Codex before cleanup-hooks delete test") }
Settings.setSourceDeleted("Codex", deleted: false)
Settings.setSource("Codex", enabled: true)
let codexHooksFile = home.appendingPathComponent(".codex/hooks.json")
let sourceScript = home
    .appendingPathComponent(".stayup/bin", isDirectory: true)
    .appendingPathComponent("stayup-source-hook.sh")
let codexWrapper = home
    .appendingPathComponent(".stayup/bin", isDirectory: true)
    .appendingPathComponent("stayup-source-hook-codex-cli.sh")
try! FileManager.default.createDirectory(
    at: sourceScript.deletingLastPathComponent(),
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
try! FileManager.default.createDirectory(
    at: codexHooksFile.deletingLastPathComponent(),
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
try! "#!/bin/sh\nexit 0\n".data(using: .utf8)!.write(to: sourceScript)
try! """
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "user-pre",
        "hooks": [
          {
            "type": "command",
            "command": "echo codex-user-pre"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "user-stop",
        "hooks": [
          {
            "type": "command",
            "command": "echo codex-user-stop"
          }
        ]
      }
    ],
    "OtherEvent": [
      {
        "matcher": "user-other",
        "hooks": [
          {
            "type": "command",
            "command": "echo codex-user-other"
          }
        ]
      }
    ]
  },
  "keep": true
}
""".data(using: .utf8)!.write(to: codexHooksFile)
try! ActivitySourceHookInstaller.installCodex(scriptDest: sourceScript, hooksFile: codexHooksFile)

try! ExternalSourceWatcher.deleteConfiguredSource(codex, cleanupHooks: true)
if FileManager.default.fileExists(atPath: sourcesDir.appendingPathComponent("codex-cli", isDirectory: true).path) {
    fail("cleanup-hooks delete for Codex should remove its source folder")
}
let codexHooksText = (try? String(contentsOf: codexHooksFile, encoding: .utf8)) ?? ""
if codexHooksText.contains("stayup-source-hook") {
    fail("cleanup-hooks delete for Codex should remove StayUp entries from hooks.json")
}
for userCommand in ["echo codex-user-pre", "echo codex-user-stop", "echo codex-user-other"] {
    if !codexHooksText.contains(userCommand) {
        fail("cleanup-hooks delete for Codex removed user hook \(userCommand)")
    }
}
if !codexHooksText.contains("\"keep\" : true") {
    fail("cleanup-hooks delete for Codex removed unrelated root settings")
}
let codexWrapperText = (try? String(contentsOf: codexWrapper, encoding: .utf8)) ?? ""
if !codexWrapperText.contains("exit 0") || codexWrapperText.contains("STAYUP_SOURCE_NAME") {
    fail("cleanup-hooks delete for Codex should safe-disable the wrapper for already-open sessions")
}

print("trusted sources fresh install: ok")
SWIFT

mkdir -p "$HOME_DIR"
swiftc "$ROOT/Sources/BundledSources.swift" \
    "$ROOT/Sources/SourceCatalog.swift" \
    "$ROOT/Sources/SourceProvisioner.swift" \
    "$ROOT/Sources/ActivitySourceHookInstaller.swift" \
    "$ROOT/Sources/ExternalSourceWatcher.swift" \
    "$TEST_MAIN" \
    -o "$BIN"
HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" "$BIN"
