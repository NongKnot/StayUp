import Foundation

/// The one scaffolder for `~/.stayup/sources`: tree creation, help files,
/// bundled source.json files, and retired-default / alias migrations. Runs at
/// app launch and at explicit mutation points (Auto on, Settings
/// Refresh/Add/Restore, hook install) — never inside a query; reads are
/// `SourceCatalog`'s job (see CONTEXT.md "SourceCatalog + SourceProvisioner").
enum SourceProvisioner {

    static var stayUpFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stayup", isDirectory: true)
    }

    private static var sourcesFolderURL: URL { SourceCatalog.defaultDirectory }

    /// Reported-source folders replaced by a canonical slug. When the
    /// canonical folder exists, the alias folder is removed (and skipped by
    /// the watcher's read in the window before this migration runs).
    static let retiredReportedAliases: [String: String] = [
        "codex": "codex-cli",
        "cursor-agent": "cursor",
    ]

    /// Scaffold + migrate. Idempotent and cheap when nothing changed (every
    /// write compares before writing). Returns `~/.stayup` for callers that
    /// reveal the folder.
    @discardableResult
    static func ensureProvisioned() -> URL {
        try? FileManager.default.createDirectory(
            at: sourcesFolderURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        writeSourceHelpFiles()
        removeRetiredBundledDefaults()
        removeRetiredReportedAliases()
        writeBundledSourceFiles()
        return stayUpFolderURL
    }

    static func restoreBundledDefaults() {
        for source in BundledSources.all {
            Settings.setSourceDeleted(source.key, deleted: false)
            Settings.setSource(source.key, enabled: false)
        }
        writeBundledSourceFiles()
    }

    // MARK: - Bundled source.json files

    private static func writeBundledSourceFiles() {
        for source in BundledSources.all {
            writeBundledSourceFile(source)
        }
    }

    private static func writeBundledSourceFile(_ source: BundledSource) {
        if Settings.isSourceDeleted(source.key) { return }
        let folder = sourcesFolderURL.appendingPathComponent(source.slug, isDirectory: true)
        let sourceURL = folder.appendingPathComponent("source.json")

        try? FileManager.default.createDirectory(
            at: folder.appendingPathComponent("active", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        var d: [String: Any] = [
            "schema": "app.getstayup.activity-source.v1",
            "name": source.key,
            "displayName": source.displayName,
        ]
        switch source.kind {
        case .reported:
            d["type"] = "reported"
            d["method"] = "reported"
        case .observed:
            guard let r = source.recipe else { return }
            d["type"] = r.type
            d["method"] = r.type
            if let path = r.path { d["path"] = path }
            if let match = r.match { d["match"] = match }
            if let activePattern = r.activePattern { d["activePattern"] = activePattern }
            if let idlePattern = r.idlePattern { d["idlePattern"] = idlePattern }
            if r.minCpu > 0 { d["minCpu"] = r.minCpu }
            if r.freshSecs > 0 { d["freshSecs"] = r.freshSecs }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return }
        if let existing = try? Data(contentsOf: sourceURL), existing == data { return }
        try? data.write(to: sourceURL, options: .atomic)
    }

    // MARK: - Retired defaults + aliases

    private static func removeRetiredBundledDefaults() {
        removeRetiredSource(folderSlug: "codex-desktop-app",
                            sourceName: "Codex Desktop App",
                            type: "file",
                            path: "~/.codex/sessions/*/*/*/*.jsonl")
        removeRetiredSource(folderSlug: "cli-file-source",
                            sourceName: "Gemini",
                            type: "file",
                            path: "~/.gemini/tmp/*")
        removeRetiredSource(folderSlug: "gemini-cli",
                            sourceName: "Gemini",
                            type: "file",
                            path: "~/.gemini/tmp/*")
        removeRetiredSource(folderSlug: "app-workflow-source",
                            sourceName: "Cursor",
                            type: "file",
                            path: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        removeRetiredSource(folderSlug: "model-server-source",
                            sourceName: "Ollama",
                            type: "socket",
                            path: nil)
        // Ollama moved from socket to a CPU-gated process recipe. Retire the old
        // socket default (an idle-but-ESTABLISHED client connection was a false
        // positive) so existing installs pick up the new `process` recipe.
        removeRetiredSource(folderSlug: "ollama",
                            sourceName: "Ollama",
                            type: "socket",
                            path: nil)
        removeRetiredSource(folderSlug: "model-server-log-source",
                            sourceName: "LM Studio",
                            type: "logPattern",
                            path: "~/.lmstudio/server-logs/*/*.log")
    }

    private static func removeRetiredSource(folderSlug: String, sourceName: String, type: String, path: String?) {
        let folder = sourcesFolderURL.appendingPathComponent(folderSlug, isDirectory: true)
        guard let record = SourceCatalog.record(sourceDir: folder),
              record.name == sourceName,
              record.type == type
        else { return }
        if let path, (record.raw["path"] as? String) != path { return }

        Settings.setSource(sourceName, enabled: false)
        try? FileManager.default.removeItem(at: folder)
    }

    private static func removeRetiredReportedAliases() {
        removeReportedAlias(folderSlug: "codex", canonicalSlug: "codex-cli", sourceName: "Codex")
        removeReportedAlias(folderSlug: "cursor-agent", canonicalSlug: "cursor", sourceName: "Cursor")
    }

    private static func removeReportedAlias(folderSlug: String, canonicalSlug: String, sourceName: String) {
        let folder = sourcesFolderURL.appendingPathComponent(folderSlug, isDirectory: true)
        let canonical = sourcesFolderURL.appendingPathComponent(canonicalSlug, isDirectory: true)
        guard FileManager.default.fileExists(atPath: canonical.path),
              let record = SourceCatalog.record(sourceDir: folder),
              record.name == sourceName,
              record.type == "reported"
        else { return }

        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Help files

    private static func writeTextFileIfChanged(named filename: String, contents: String) {
        let url = sourcesFolderURL.appendingPathComponent(filename)
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeSourceHelpFiles() {
        writeTextFileIfChanged(named: "README.md", contents: """
# StayUp Activity Sources

This folder is for StayUp Auto mode source data.

Each source gets one folder:

```text
<source-slug>/
├── source.json  # source name and signal recipe
└── active/      # live receipts while that source is working
```

There are two ways to add a local tool.

1. Observed source

Use this when the tool cannot report activity directly. Copy
`SOURCE-TEMPLATE.json` into a new folder as `source.json`, edit it, then open
StayUp Settings -> Auto -> Refresh and tick the source.

2. Reported source, for tools that can report working/not-working

Use this when the tool can run a command when local work starts, pauses, or
ends. Do not put hook commands in this folder. Add those commands to the tool's
own hook/config file. See `REPORTED-HOOK-EXAMPLE.md`.

The hook writes live receipts here automatically:

```text
~/.stayup/sources/<source-slug>/active/<session-id>
~/.stayup/sources/<source-slug>/active/<session-id>.tools/
```

Empty `active/` means the source is idle. That is normal.
""")

        writeTextFileIfChanged(named: "SOURCE-TEMPLATE.json", contents: """
{
  "schema": "app.getstayup.activity-source.v1",
  "name": "Tool Name",
  "displayName": "Tool Name",
  "type": "file",
  "path": "~/path/to/file-or-glob",
  "freshSecs": 45
}
""")

        writeTextFileIfChanged(named: "REPORTED-HOOK-EXAMPLE.md", contents: """
# Reported CLI Hook Example

Use this for tools that can run commands when a turn starts, a tool starts, a
tool ends, the source waits, or the session ends.

Put these commands in that tool's own hook/config file, not in this folder.

Example for any reported CLI:

```sh
STAYUP_SOURCE_NAME="Tool Name" \\
STAYUP_SOURCE_SLUG="tool-name-cli" \\
STAYUP_SOURCE_DISPLAY="Tool Name CLI" \\
STAYUP_SOURCE_KEY="Tool Name" \\
STAYUP_SESSION_ID="<stable-session-id-if-the-tool-provides-one>" \\
STAYUP_SOURCE_PID="<long-lived-tool-pid-if-available>" \\
~/.stayup/bin/stayup-source-hook.sh working
```

Before adding hooks, refresh the reusable writer from the installed app:

```sh
mkdir -p ~/.stayup/bin
cp /Applications/StayUp.app/Contents/Resources/stayup-source-hook.sh ~/.stayup/bin/stayup-source-hook.sh
chmod 755 ~/.stayup/bin/stayup-source-hook.sh
```

Map the tool's events to these simple StayUp actions first:

```text
working      source is doing local work; protect the Mac
not-working  source is waiting/idle; do not protect, let StayUp's grace run
stop         session is over; remove the receipt
```

Exact integrations can also use advanced actions when the tool exposes them:

```text
turn-start  user submitted a new prompt / new turn begins
tool-begin  shell command, search, build, test, or local tool starts
tool-end    that local tool finishes
```

Codex CLI/IDE hook surfaces use Codex's user-level hook config at
`~/.codex/hooks.json`. Use the canonical StayUp source identity so Settings can
manage it:

```text
name/display key: Codex
source slug:      codex-cli
display label:    Codex
events:           SessionStart -> waiting
                  UserPromptSubmit -> turn-start
                  PreToolUse -> tool-begin
                  PostToolUse -> tool-end
                  SubagentStart/SubagentStop -> active
                  Stop -> stop
```

Cursor uses `~/.cursor/hooks.json`. Use the canonical StayUp source identity
so Settings can manage it:

```text
name/display key: Cursor
source slug:      cursor
display label:    Cursor
events:           sessionStart -> waiting
                  beforeSubmitPrompt -> turn-start
                  preToolUse -> tool-begin
                  postToolUse/postToolUseFailure -> tool-end
                  subagentStart/subagentStop -> active
                  stop/sessionEnd -> stop
```

After the tool runs one hook, StayUp creates:

```text
~/.stayup/sources/tool-name-cli/source.json
~/.stayup/sources/tool-name-cli/active/<session-id>
```

You can also create `source.json` before the first hook runs so the source
appears in Settings immediately. Do not create files under `active/` by hand
except for a deliberate test heartbeat.

Then open StayUp Settings -> Auto -> Refresh, tick the source, set Mode to
Auto, and choose the Nap after grace period.
""")
    }
}
