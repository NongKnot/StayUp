#!/bin/sh
# Regression-test the prompt-created custom reported source path without real user state.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-custom-reported.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-custom-reported"
HOME_DIR="$TMP/home"

cat > "$TEST_MAIN" <<'SWIFT'
import Foundation

enum Settings {
    static var autoSourceEnabled = false
    static var reportedHookConnectionAllowed = false
    static var enabledSources: Set<String> = []
    static var deletedSources: Set<String> = ["Claude", "Codex", "Cursor", "Gemini", "Qwen", "Copilot", "OpenCode", "Ollama", "LM Studio"]

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

func write(_ text: String, to url: URL) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    try! text.data(using: .utf8)!.write(to: url)
}

let home = FileManager.default.homeDirectoryForCurrentUser
let sources = home.appendingPathComponent(".stayup/sources", isDirectory: true)
let bin = home.appendingPathComponent(".stayup/bin", isDirectory: true)

let initialSources = ExternalSourceWatcher.configuredSourceInfo()
if !initialSources.isEmpty {
    fail("deleted bundled sources should not reappear in clean-room settings")
}

let sourceSlug = "prompt-cli"
let sourceKey = "Prompt Tool"
let sourceDisplay = "Prompt Tool CLI"
let sourceFolder = sources.appendingPathComponent(sourceSlug, isDirectory: true)
write("""
{
  "displayName": "\(sourceDisplay)",
  "method": "reported",
  "name": "\(sourceKey)",
  "schema": "app.getstayup.activity-source.v1",
  "type": "reported"
}
""", to: sourceFolder.appendingPathComponent("source.json"))

let afterPrompt = ExternalSourceWatcher.configuredSourceInfo()
guard let promptSource = afterPrompt.first(where: { $0.key == sourceKey }) else {
    fail("prompt-created reported source should appear after Refresh")
}
if promptSource.displayName != sourceDisplay ||
    promptSource.method != "reported" ||
    promptSource.folderSlug != sourceSlug {
    fail("prompt-created reported source metadata was not preserved")
}
if ActivitySourceHookInstaller.canManageHooks(for: sourceKey) {
    fail("custom reported source should be user-managed, not bundled-managed")
}
if !ActivitySourceHookInstaller.canManageHooks(for: "Codex") {
    fail("bundled reported source should still be bundled-managed")
}
if !ActivitySourceHookInstaller.canManageHooks(for: "Cursor") {
    fail("Cursor should be bundled-managed")
}
if !ActivitySourceHookInstaller.canManageHooks(for: "Gemini") {
    fail("Gemini is now a bundled reported source and should be bundled-managed")
}

Settings.setSource(sourceKey, enabled: true)
let wrapper = bin.appendingPathComponent("stayup-source-hook-\(sourceSlug).sh")
write("""
#!/bin/sh
STAYUP_SOURCE_NAME='Prompt Tool'
exec "$HOME/.stayup/bin/stayup-source-hook.sh" "$@"
""", to: wrapper)

try! ExternalSourceWatcher.deleteConfiguredSource(promptSource, cleanupHooks: true)
if FileManager.default.fileExists(atPath: sourceFolder.path) {
    fail("deleting custom reported source should remove source folder")
}
if Settings.isSourceEnabled(sourceKey) {
    fail("deleting custom reported source should disable the source")
}
let wrapperText = (try? String(contentsOf: wrapper, encoding: .utf8)) ?? ""
if !wrapperText.contains("exit 0") || wrapperText.contains("STAYUP_SOURCE_NAME") {
    fail("custom reported cleanup should safe-disable the standard wrapper")
}

print("custom reported clean-room: ok")
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
