import Foundation

/// Observes local tools that cannot report activity themselves and feeds them
/// through the same heartbeat contract as reported sources, so the monitor,
/// menu, and dev bench treat every Activity Source identically.
///
/// Reported sources use precise hooks and write their own heartbeat. Observed
/// sources expose local clues, so we synthesise a heartbeat under
/// `~/.stayup/sources/<source>/active/state` while they look busy (removed when
/// idle). Observed source types are cheap + read-only:
///
///   • `file`       — a path/glob whose newest match was written within
///                    `freshSecs` (an actively-appended session log/db).
///   • `logPattern` — newest matching log is fresh and its latest active/idle
///                    marker says work is still running.
///   • `process`    — any process whose command contains `match` with `%cpu ≥
///                    minCpu` (a busy worker, not just an idle open app).
///   • `socket`     — any process whose command contains `match` and currently
///                    has an ESTABLISHED TCP socket (useful when a model runner
///                    stays alive idle, but only connects while generating).
///
/// The public source list lives in `~/.stayup/sources/<source>/source.json`
/// (defaults written on first run). Remote API providers are intentionally
/// absent: they don't run on this Mac, so they can't keep it awake.
final class ExternalSourceWatcher {

    private static let bundledReportedSourceNames: Set<String> = ["Claude", "Codex", "Cursor"]
    private static let bundledObservedSourceNames: Set<String> = ["Ollama", "LM Studio"]
    private static let bundledSourceNames = bundledReportedSourceNames.union(bundledObservedSourceNames)

    struct ConfiguredSourceInfo {
        let key: String
        let displayName: String
        let type: String
        let method: String
        let folderSlug: String
        let isDeleted: Bool
    }

    private struct Source {
        let name: String
        let displayName: String?
        let folderSlug: String?
        let type: String          // "file" | "logPattern" | "process" | "socket"
        let path: String?
        let match: String?
        let activePattern: String?
        let idlePattern: String?
        let minCpu: Double
        let freshSecs: Double
    }

    private static let POLL: TimeInterval = 15
    private var timer: Timer?
    private var sources: [Source] = []

    static var stayUpFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stayup", isDirectory: true)
    }

    static var sourcesFolderURL: URL {
        stayUpFolderURL.appendingPathComponent("sources", isDirectory: true)
    }

    @discardableResult
    static func ensureStayUpFolder() -> URL {
        let folder = stayUpFolderURL
        try? FileManager.default.createDirectory(
            at: sourcesFolderURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        writeSourceHelpFiles()
        removeRetiredBundledDefaults()
        removeRetiredReportedAliases()
        writeBundledSourceFiles(defaults)
        writeReportedSourceFiles()
        return folder
    }

    func start() {
        sources = loadConfig()
        let t = Timer(timeInterval: Self.POLL, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()   // eager
    }

    func stop() {
        timer?.invalidate(); timer = nil
        removeAllExternal()
    }

    // MARK: - Poll

    private func poll() {
        sources = loadConfig()
        // Only synthesise heartbeats in Auto mode; otherwise leave the dir clean.
        guard Settings.autoSourceEnabled else { removeAllExternal(); return }
        for s in sources {
            if Self.bundledReportedSourceNames.contains(s.name) {
                removeHeartbeat(s)
                continue
            }
            // Each observed source is opt-in (Settings → Advanced). A disabled
            // one is treated as idle, so its marker is cleaned up.
            let live = Settings.isSourceEnabled(s.name) && isActive(s)
            live ? writeHeartbeat(s) : removeHeartbeat(s)
        }
    }

    static func configuredSourceInfo() -> [ConfiguredSourceInfo] {
        _ = ensureStayUpFolder()
        let sources = uniqueConfiguredSources(loadSourceDictionaries()
            .compactMap { dict -> ConfiguredSourceInfo? in
                guard let source = source(from: dict) else { return nil }
                return ConfiguredSourceInfo(
                    key: source.name,
                    displayName: publicDisplayName(for: source),
                    type: source.type,
                    method: (dict["method"] as? String) ?? source.type,
                    folderSlug: source.folderSlug ?? slug(for: source.name, displayName: source.displayName),
                    isDeleted: false
                )
            })
        if !sources.isEmpty {
            return sources
        }

        return bundledSourceInfos().filter { !Settings.isSourceDeleted($0.key) }
    }

    private static func bundledSourceInfos() -> [ConfiguredSourceInfo] {
        reportedSourceInfos + defaults.map {
            ConfiguredSourceInfo(key: $0.name,
                                 displayName: publicDisplayName(for: $0),
                                 type: $0.type,
                                 method: $0.type,
                                 folderSlug: slug(for: $0.name, displayName: $0.displayName),
                                 isDeleted: Settings.isSourceDeleted($0.name))
        }
    }

    static func deleteConfiguredSource(_ source: ConfiguredSourceInfo, cleanupHooks: Bool = false) throws {
        let fm = FileManager.default
        let root = sourcesFolderURL.standardizedFileURL
        let folder = root.appendingPathComponent(source.folderSlug, isDirectory: true).standardizedFileURL

        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard folder.path.hasPrefix(rootPath), folder.path != root.path else {
            throw NSError(domain: "StayUpActivitySource", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Refusing to delete outside ~/.stayup/sources."
            ])
        }

        if source.method == "reported" || source.type == "reported" {
            let canManageHooks = ActivitySourceHookInstaller.canManageHooks(for: source.key)
            if cleanupHooks && canManageHooks {
                try ActivitySourceHookInstaller.cleanupHooks(for: source.key)
            } else {
                try ActivitySourceHookInstaller.disableSource(named: source.key, folderSlug: source.folderSlug)
            }
        }
        if fm.fileExists(atPath: folder.path) {
            try fm.removeItem(at: folder)
        }
        Settings.setSource(source.key, enabled: false)
        if bundledSourceNames.contains(source.key) {
            Settings.setSourceDeleted(source.key, deleted: true)
        }
    }

    static func restoreConfiguredSource(_ source: ConfiguredSourceInfo) throws {
        Settings.setSourceDeleted(source.key, deleted: false)

        if let known = (reportedSources + defaults).first(where: { $0.name.caseInsensitiveCompare(source.key) == .orderedSame }) {
            let normalized = sourceWithKnownDisplayName(known)
            let method = bundledReportedSourceNames.contains(normalized.name) ? "reported" : normalized.type
            writeBundledSourceFile(normalized, method: method)
            if method == "reported" {
                Settings.setReportedHookConnectionAllowed(true)
                try ActivitySourceHookInstaller.installHooks(for: normalized.name)
            }
        }
    }

    static func restoreBundledDefaults() {
        for source in reportedSources + defaults {
            Settings.setSourceDeleted(source.name, deleted: false)
            Settings.setSource(source.name, enabled: false)
        }
        writeBundledSourceFiles(defaults)
        writeReportedSourceFiles()
    }

    private func isActive(_ s: Source) -> Bool {
        switch s.type {
        case "file":       return fileFresh(s)
        case "logPattern": return logPatternActive(s)
        case "process":    return processBusy(s)
        case "socket":     return processHasEstablishedSocket(s)
        default:           return false
        }
    }

    /// Newest file matching the path/glob was written within freshSecs.
    private func fileFresh(_ s: Source) -> Bool {
        guard let raw = s.path else { return false }
        let now = Date()
        for url in matchingFiles(raw) {
            if let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               now.timeIntervalSince(m) < s.freshSecs {
                return true
            }
        }
        return false
    }

    /// A task log whose latest active/idle marker still says work is running.
    /// Patterns are simple case-insensitive substrings separated by `|`.
    private func logPatternActive(_ s: Source) -> Bool {
        guard let raw = s.path,
              let activePattern = s.activePattern, !activePattern.isEmpty else { return false }
        let now = Date()
        let activeNeedles = splitPattern(activePattern)
        let idleNeedles = splitPattern(s.idlePattern ?? "")
        guard !activeNeedles.isEmpty else { return false }

        for url in newestRegularFiles(matching: raw, limit: 4) {
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(mtime) < s.freshSecs,
                  let text = tailText(url, maxBytes: 64 * 1024)?.lowercased()
            else { continue }

            guard let activeIndex = lastIndex(in: text, needles: activeNeedles) else { continue }
            if let idleIndex = lastIndex(in: text, needles: idleNeedles),
               idleIndex > activeIndex {
                continue
            }
            return true
        }
        return false
    }

    /// Any process whose command contains `match` with %cpu ≥ minCpu.
    private func processBusy(_ s: Source) -> Bool {
        guard let needle = s.match?.lowercased(), !needle.isEmpty else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "%cpu=,command="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let sp = trimmed.firstIndex(of: " ") else { continue }
            let cpu = Double(String(trimmed[..<sp])) ?? 0
            let cmd = trimmed[trimmed.index(after: sp)...].lowercased()
            if cpu >= s.minCpu && cmd.contains(needle) { return true }
        }
        return false
    }

    /// Any matching process with an active TCP connection. This catches model
    /// runners that stay resident after a request but only hold an ESTABLISHED
    /// server connection while processing a task.
    private func processHasEstablishedSocket(_ s: Source) -> Bool {
        guard let needle = s.match?.lowercased(), !needle.isEmpty else { return false }
        for pid in matchingProcessIDs(containing: needle) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            p.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:ESTABLISHED"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0,
               String(decoding: data, as: UTF8.self).contains("ESTABLISHED") {
                return true
            }
        }
        return false
    }

    private func matchingProcessIDs(containing needle: String) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let sp = trimmed.firstIndex(of: " ") else { return nil }
                let pid = Int32(String(trimmed[..<sp]))
                let cmd = trimmed[trimmed.index(after: sp)...].lowercased()
                return cmd.contains(needle) ? pid : nil
            }
    }

    private func splitPattern(_ raw: String) -> [String] {
        raw.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func lastIndex(in text: String, needles: [String]) -> String.Index? {
        var best: String.Index?
        for needle in needles {
            guard let found = text.range(of: needle, options: .backwards)?.lowerBound else { continue }
            if best == nil || found > best! { best = found }
        }
        return best
    }

    private func newestRegularFiles(matching pattern: String, limit: Int) -> [URL] {
        matchingFiles(pattern)
            .compactMap { url -> (URL, Date)? in
                guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      vals.isRegularFile == true,
                      let mtime = vals.contentModificationDate else { return nil }
                return (url, mtime)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private func tailText(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > maxBytes {
            try? handle.seek(toOffset: UInt64(size - maxBytes))
        }
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }

    // MARK: - Heartbeat files

    private func heartbeatURL(_ s: Source) -> URL {
        Self.sourceFolderURL(for: s)
            .appendingPathComponent("active", isDirectory: true)
            .appendingPathComponent("state")
    }

    private func writeHeartbeat(_ s: Source) {
        try? FileManager.default.createDirectory(
            at: heartbeatURL(s).deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])   // private per-user state
        // No cwd: we know which tool, not which project, so show just the name.
        var lines = [
            "active",
            "term=\(field(s.name))",
            "pid=0",
            "signal=\(field(s.type))",
            "detail=\(field(signalDetail(s)))",
        ]
        if let path = s.path { lines.append("path=\(field(path))") }
        if let match = s.match { lines.append("match=\(field(match))") }
        let body = lines.joined(separator: "\n") + "\n"
        try? body.data(using: .utf8)?.write(to: heartbeatURL(s), options: .atomic)
    }

    private func signalDetail(_ s: Source) -> String {
        switch s.type {
        case "file":
            return "file fresh < \(Int(s.freshSecs))s"
        case "logPattern":
            return "log marker fresh < \(Int(s.freshSecs))s"
        case "process":
            return "cpu >= \(Int(s.minCpu))%"
        case "socket":
            return "established tcp socket"
        default:
            return s.type
        }
    }

    private func field(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let clean = String(String.UnicodeScalarView(scalars))
        return clean.count > 160 ? String(clean.prefix(160)) : clean
    }

    private func removeHeartbeat(_ s: Source) {
        try? FileManager.default.removeItem(at: heartbeatURL(s))
    }

    private func removeAllExternal() {
        for source in sources where !Self.bundledReportedSourceNames.contains(source.name) {
            try? FileManager.default.removeItem(at: heartbeatURL(source))
        }
        removeObservedStateMarkers()
    }

    private func removeObservedStateMarkers() {
        guard let sourceDirs = try? FileManager.default.contentsOfDirectory(
            at: Self.sourcesFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for dir in sourceDirs {
            let stateURL = dir
                .appendingPathComponent("active", isDirectory: true)
                .appendingPathComponent("state")
            guard observedMarker(at: stateURL) else { continue }
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    private func observedMarker(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .contains { $0.hasPrefix("signal=") }
    }

    // MARK: - Path glob

    private func matchingFiles(_ pattern: String) -> [URL] {
        let expanded = (pattern as NSString).expandingTildeInPath
        guard expanded.contains("*") else { return [URL(fileURLWithPath: expanded)] }

        let fm = FileManager.default
        let absolute = expanded.hasPrefix("/")
        let parts = expanded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var bases = [URL(fileURLWithPath: absolute ? "/" : fm.currentDirectoryPath, isDirectory: true)]

        for part in parts {
            var next: [URL] = []
            for base in bases {
                if part.contains("*") {
                    let entries = (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
                    next += entries
                        .filter { fnmatch(part, $0, 0) == 0 }
                        .map { base.appendingPathComponent($0) }
                } else {
                    next.append(base.appendingPathComponent(part))
                }
            }
            bases = next
            if bases.isEmpty { break }
        }
        return bases
    }

    // MARK: - Config

    private func loadConfig() -> [Source] {
        Self.writeSourceHelpFiles()
        Self.removeRetiredBundledDefaults()
        Self.removeRetiredReportedAliases()
        Self.writeBundledSourceFiles(Self.defaults)
        Self.writeReportedSourceFiles()
        let sourceSources = Self.loadSourceDictionaries().compactMap(Self.source(from:))
        return sourceSources.isEmpty ? (Self.defaults + Self.reportedSources) : sourceSources
    }

    private static func source(from d: [String: Any]) -> Source? {
        guard let name = d["name"] as? String, let type = d["type"] as? String else { return nil }
        return Source(name: name, displayName: d["displayName"] as? String,
                      folderSlug: d["_folderSlug"] as? String, type: type,
                      path: d["path"] as? String, match: d["match"] as? String,
                      activePattern: d["activePattern"] as? String,
                      idlePattern: d["idlePattern"] as? String,
                      minCpu: (d["minCpu"] as? NSNumber)?.doubleValue ?? 0,
                      freshSecs: (d["freshSecs"] as? NSNumber)?.doubleValue ?? 45)
    }

    private static func dictionary(from source: Source) -> [String: Any] {
        var d: [String: Any] = ["name": source.name, "type": source.type]
        d["displayName"] = publicDisplayName(for: source)
        if let path = source.path { d["path"] = path }
        if let match = source.match { d["match"] = match }
        if let activePattern = source.activePattern { d["activePattern"] = activePattern }
        if let idlePattern = source.idlePattern { d["idlePattern"] = idlePattern }
        if source.minCpu > 0 { d["minCpu"] = source.minCpu }
        if source.freshSecs > 0 { d["freshSecs"] = source.freshSecs }
        return d
    }

    private static func sourceFolderURL(for source: Source) -> URL {
        sourcesFolderURL.appendingPathComponent(
            source.folderSlug ?? slug(for: source.name, displayName: source.displayName),
            isDirectory: true
        )
    }

    static func slug(for name: String, displayName: String? = nil) -> String {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude": return "claude-code-cli"
        case "codex": return "codex-cli"
        case "cursor": return "cursor"
        case "ollama": return "ollama"
        case "lm studio": return "lm-studio"
        default:
            let raw = (displayName?.isEmpty == false ? displayName! : name).lowercased()
            var out = ""
            var lastDash = false
            for scalar in raw.unicodeScalars {
                if CharacterSet.alphanumerics.contains(scalar) {
                    out.append(Character(scalar))
                    lastDash = false
                } else if !lastDash {
                    out.append("-")
                    lastDash = true
                }
            }
            return out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty
                ? "source"
                : out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
    }

    private static func loadSourceDictionaries() -> [[String: Any]] {
        guard let sourceDirs = try? FileManager.default.contentsOfDirectory(
            at: sourcesFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return sourceDirs.compactMap { dir in
            guard !isRetiredAliasFolder(dir) else { return nil }
            let sourceURL = dir.appendingPathComponent("source.json")
            guard let data = try? Data(contentsOf: sourceURL),
                  var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            dict["_folderSlug"] = dir.lastPathComponent
            return dict
        }
    }

    private static func uniqueConfiguredSources(_ sources: [ConfiguredSourceInfo]) -> [ConfiguredSourceInfo] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.key).inserted }
    }

    private static func writeReportedSourceFiles() {
        for source in reportedSources {
            writeBundledSourceFile(source, method: "reported")
        }
    }

    private static func writeBundledSourceFiles(_ sources: [Source]) {
        for source in sources {
            let normalized = sourceWithKnownDisplayName(source)
            writeBundledSourceFile(normalized, method: bundledReportedSourceNames.contains(normalized.name) ? "reported" : normalized.type)
        }
    }

    private static func sourceWithKnownDisplayName(_ source: Source) -> Source {
        if source.displayName != nil { return source }
        if let known = (reportedSources + defaults).first(where: { $0.name.caseInsensitiveCompare(source.name) == .orderedSame }) {
            return Source(name: source.name, displayName: publicDisplayName(for: known),
                          folderSlug: source.folderSlug, type: source.type,
                          path: source.path, match: source.match,
                          activePattern: source.activePattern,
                          idlePattern: source.idlePattern,
                          minCpu: source.minCpu, freshSecs: source.freshSecs)
        }
        return source
    }

    private static func writeBundledSourceFile(_ source: Source, method: String) {
        if Settings.isSourceDeleted(source.name) { return }
        let folder = sourceFolderURL(for: source)
        let sourceURL = folder.appendingPathComponent("source.json")

        try? FileManager.default.createDirectory(
            at: folder.appendingPathComponent("active", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        var d = dictionary(from: source)
        d["schema"] = "app.getstayup.activity-source.v1"
        d["method"] = method
        if d["displayName"] == nil { d["displayName"] = source.name }
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) else { return }
        if let existing = try? Data(contentsOf: sourceURL), existing == data { return }
        try? data.write(to: sourceURL, options: .atomic)
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
StayUp Settings -> Advanced -> Refresh and tick the source.

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

Then open StayUp Settings -> Advanced -> Refresh, tick the source, set Mode to
Auto, and choose the After stop grace period.
""")
    }

    private static func writeTextFileIfChanged(named filename: String, contents: String) {
        let url = sourcesFolderURL.appendingPathComponent(filename)
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func removeRetiredBundledDefaults() {
        removeRetiredSource(folderSlug: "codex-desktop-app",
                            sourceName: "Codex Desktop App",
                            type: "file",
                            path: "~/.codex/sessions/*/*/*/*.jsonl")
        removeRetiredSource(folderSlug: "cli-file-source",
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
        removeRetiredSource(folderSlug: "model-server-log-source",
                            sourceName: "LM Studio",
                            type: "logPattern",
                            path: "~/.lmstudio/server-logs/*/*.log")
    }

    private static func removeRetiredSource(folderSlug: String, sourceName: String, type: String, path: String?) {
        let folder = sourcesFolderURL.appendingPathComponent(folderSlug, isDirectory: true)
        let sourceURL = folder.appendingPathComponent("source.json")
        guard let data = try? Data(contentsOf: sourceURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (dict["name"] as? String) == sourceName,
              (dict["type"] as? String) == type
        else { return }
        if let path, (dict["path"] as? String) != path { return }

        Settings.setSource(sourceName, enabled: false)
        try? FileManager.default.removeItem(at: folder)
    }

    private static func removeRetiredReportedAliases() {
        removeReportedAlias(folderSlug: "codex", canonicalSlug: "codex-cli", sourceName: "Codex")
        removeReportedAlias(folderSlug: "cursor-agent", canonicalSlug: "cursor", sourceName: "Cursor")
    }

    private static func isRetiredAliasFolder(_ folder: URL) -> Bool {
        let aliases: [String: String] = [
            "codex": "codex-cli",
            "cursor-agent": "cursor",
        ]
        guard let canonicalSlug = aliases[folder.lastPathComponent] else { return false }
        return FileManager.default.fileExists(
            atPath: sourcesFolderURL.appendingPathComponent(canonicalSlug, isDirectory: true).path)
    }

    private static func removeReportedAlias(folderSlug: String, canonicalSlug: String, sourceName: String) {
        let folder = sourcesFolderURL.appendingPathComponent(folderSlug, isDirectory: true)
        let canonical = sourcesFolderURL.appendingPathComponent(canonicalSlug, isDirectory: true)
        let sourceURL = folder.appendingPathComponent("source.json")
        guard FileManager.default.fileExists(atPath: canonical.path),
              let data = try? Data(contentsOf: sourceURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (dict["name"] as? String) == sourceName,
              (dict["type"] as? String) == "reported"
        else { return }

        try? FileManager.default.removeItem(at: folder)
    }

    /// Bundled observed-source defaults. Exact names are both internal keys and
    /// user-facing labels.
    ///
    /// Do not add broad transcript/session-file freshness as a default. It can
    /// look active after the actual work is done and teach Auto to stay up for
    /// the wrong reason.
    private static let defaults: [Source] = [
        Source(name: "Ollama", displayName: "Ollama", folderSlug: nil,
               type: "socket", path: nil, match: "ollama runner",
               activePattern: nil, idlePattern: nil, minCpu: 0, freshSecs: 0),
        Source(name: "LM Studio", displayName: "LM Studio", folderSlug: nil,
               type: "logPattern", path: "~/.lmstudio/server-logs/*/*.log", match: nil,
               activePattern: "processing task|n_decoded|print_timing",
               idlePattern: "all slots are idle", minCpu: 0, freshSecs: 45),
    ]

    private static let reportedSources: [Source] = [
        Source(name: "Claude", displayName: "Claude", folderSlug: nil, type: "reported",
               path: nil, match: nil, activePattern: nil, idlePattern: nil, minCpu: 0, freshSecs: 0),
        Source(name: "Codex", displayName: "Codex", folderSlug: nil, type: "reported",
               path: nil, match: nil, activePattern: nil, idlePattern: nil, minCpu: 0, freshSecs: 0),
        Source(name: "Cursor", displayName: "Cursor", folderSlug: nil, type: "reported",
               path: nil, match: nil, activePattern: nil, idlePattern: nil, minCpu: 0, freshSecs: 0),
    ]

    private static func publicDisplayName(for source: Source) -> String {
        switch source.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "ollama": return "Ollama"
        case "lm studio": return "LM Studio"
        default:
            return source.displayName?.isEmpty == false ? source.displayName! : source.name
        }
    }

    private static var reportedSourceInfos: [ConfiguredSourceInfo] {
        reportedSources.map {
            ConfiguredSourceInfo(key: $0.name,
                                 displayName: publicDisplayName(for: $0),
                                 type: $0.type,
                                 method: "reported",
                                 folderSlug: slug(for: $0.name, displayName: $0.displayName),
                                 isDeleted: Settings.isSourceDeleted($0.name))
        }
    }

}
