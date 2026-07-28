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

    private static let bundledReportedSourceNames = Set(BundledSources.reported.map(\.key))
    private static let bundledSourceNames = Set(BundledSources.all.map(\.key))

    struct ConfiguredSourceInfo {
        let key: String
        let displayName: String
        let type: String
        let method: String
        let folderSlug: String

        var isReported: Bool { SourceCatalog.isReported(method: method, type: type) }
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

    private static let POLL: TimeInterval = 5
    private var timer: Timer?
    private var sources: [Source] = []

    // Canonical paths live with the reader/scaffolder; these forwards keep the
    // watcher's many call sites (and tests) stable.
    static var sourcesFolderURL: URL { SourceCatalog.defaultDirectory }

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
            // Each observed source is opt-in (Settings → Auto). A disabled
            // one is treated as idle, so its marker is cleaned up.
            let live = Settings.isSourceEnabled(s.name) && isActive(s)
            live ? writeHeartbeat(s) : removeHeartbeat(s)
        }
    }

    /// Pure read — provisioning happens at launch and at the explicit mutation
    /// points (`SourceProvisioner.ensureProvisioned()`), never inside a query.
    static func configuredSourceInfo() -> [ConfiguredSourceInfo] {
        let sources = uniqueConfiguredSources(loadRecords()
            .compactMap { record -> ConfiguredSourceInfo? in
                guard !record.type.isEmpty else { return nil }
                return ConfiguredSourceInfo(
                    key: record.name,
                    displayName: publicDisplayName(name: record.name, displayName: record.displayName),
                    type: record.type,
                    method: record.method,
                    folderSlug: record.folderSlug
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
                                 folderSlug: slug(for: $0.name, displayName: $0.displayName))
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

        if source.isReported {
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
        for trimmed in psLines(fields: "%cpu=,command=") {
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
        psLines(fields: "pid=,command=")
            .compactMap { trimmed in
                guard let sp = trimmed.firstIndex(of: " ") else { return nil }
                let pid = Int32(String(trimmed[..<sp]))
                let cmd = trimmed[trimmed.index(after: sp)...].lowercased()
                return cmd.contains(needle) ? pid : nil
            }
    }

    private func psLines(fields: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", fields]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
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

    private static func sourceFolderURL(for source: Source) -> URL {
        sourcesFolderURL.appendingPathComponent(
            source.folderSlug ?? slug(for: source.name, displayName: source.displayName),
            isDirectory: true
        )
    }

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
        // Pure read — no provisioning here; the poll must never write config.
        let sourceSources = Self.loadRecords().compactMap(Self.source(from:))
        return sourceSources.isEmpty ? (Self.defaults + Self.reportedSources) : sourceSources
    }

    private static func source(from record: SourceRecord) -> Source? {
        guard !record.type.isEmpty else { return nil }
        let d = record.raw
        return Source(name: record.name, displayName: record.displayName,
                      folderSlug: record.folderSlug, type: record.type,
                      path: d["path"] as? String, match: d["match"] as? String,
                      activePattern: d["activePattern"] as? String,
                      idlePattern: d["idlePattern"] as? String,
                      minCpu: (d["minCpu"] as? NSNumber)?.doubleValue ?? 0,
                      freshSecs: (d["freshSecs"] as? NSNumber)?.doubleValue ?? 45)
    }

    static func slug(for name: String, displayName: String? = nil) -> String {
        if let bundled = BundledSources.source(named: name) { return bundled.slug }
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
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "source" : trimmed
    }

    /// All on-disk records via `SourceCatalog`, minus retired alias folders
    /// (skipped in the window before the provisioner's migration removes them).
    private static func loadRecords() -> [SourceRecord] {
        SourceCatalog.records(in: sourcesFolderURL)
            .filter { !isRetiredAliasFolder(slug: $0.folderSlug) }
    }

    private static func uniqueConfiguredSources(_ sources: [ConfiguredSourceInfo]) -> [ConfiguredSourceInfo] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.key).inserted }
    }

    private static func isRetiredAliasFolder(slug: String) -> Bool {
        guard let canonicalSlug = SourceProvisioner.retiredReportedAliases[slug] else { return false }
        return FileManager.default.fileExists(
            atPath: sourcesFolderURL.appendingPathComponent(canonicalSlug, isDirectory: true).path)
    }

    /// Bundled observed-source defaults. Exact names are both internal keys and
    /// user-facing labels.
    ///
    /// Do not add broad transcript/session-file freshness as a default. It can
    /// look active after the actual work is done and teach Auto to stay up for
    /// the wrong reason.
    private static let defaults: [Source] = BundledSources.observed.map { b in
        let r = b.recipe!
        return Source(name: b.key, displayName: b.displayName, folderSlug: nil,
                      type: r.type, path: r.path, match: r.match,
                      activePattern: r.activePattern, idlePattern: r.idlePattern,
                      minCpu: r.minCpu, freshSecs: r.freshSecs)
    }

    private static let reportedSources: [Source] = BundledSources.reported.map { b in
        Source(name: b.key, displayName: b.displayName, folderSlug: nil, type: "reported",
               path: nil, match: nil, activePattern: nil, idlePattern: nil, minCpu: 0, freshSecs: 0)
    }

    private static func publicDisplayName(for source: Source) -> String {
        publicDisplayName(name: source.name, displayName: source.displayName)
    }

    private static func publicDisplayName(name: String, displayName: String?) -> String {
        if let bundled = BundledSources.source(named: name) { return bundled.displayName }
        return displayName?.isEmpty == false ? displayName! : name
    }

    private static var reportedSourceInfos: [ConfiguredSourceInfo] {
        reportedSources.map {
            ConfiguredSourceInfo(key: $0.name,
                                 displayName: publicDisplayName(for: $0),
                                 type: $0.type,
                                 method: "reported",
                                 folderSlug: slug(for: $0.name, displayName: $0.displayName))
        }
    }

}
