import Foundation

/// One live Activity Source session, parsed from a heartbeat file. See the contract.
struct ActivitySourceSession {
    let id: String
    let state: String          // "active" | "waiting"
    let cwd: String?
    let terminal: String?      // $TERM_PROGRAM / STAYUP_SOURCE_NAME; nil = unknown surface
    let transcriptPath: String?
    let signal: String?        // observed source type, e.g. "file" / "socket"
    let detail: String?        // short explanation of the source signal
    let mtime: Date
    let working: Bool          // true = keeping the Mac awake right now
    let toolsInFlight: Int     // how many tools are running right now (0 when waiting/idle)
    let isExternal: Bool       // observed source marker: best-effort, exact state unknown

    /// "Which terminal" label: terminal app + the project folder name.
    var terminalLabel: String {
        let app: String
        switch terminal {
        case "Apple_Terminal":      app = "Terminal"
        case "iTerm.app":           app = "iTerm"
        case "vscode":              app = "VS Code"
        case "Claude", "Claude Code CLI":
            app = "Claude"
        case "Codex", "Codex CLI":
            app = "Codex"
        case "Cursor":
            app = "Cursor"
        case "Ollama":
            app = "Ollama"
        case "LM Studio":
            app = "LM Studio"
        case .some(let t) where !t.isEmpty: app = Self.clean(t)
        default:                    app = "Local app"
        }
        if let cwd, let last = cwd.split(separator: "/").last {
            return "\(app) · ~/\(Self.clean(String(last)))"
        }
        return app
    }

    var signalLabel: String? {
        guard let signal else { return nil }
        let cleanSignal = Self.clean(signal)
        if let detail, !detail.isEmpty {
            return "\(cleanSignal) · \(Self.clean(detail))"
        }
        return cleanSignal
    }

    /// The smallest verifiable receipt for "why StayUp believes this source."
    /// Reported sources prove themselves with a heartbeat; observed sources
    /// prove themselves with a fresh local clue such as file/log/socket/CPU.
    func proofLabel(now: Date = Date()) -> String {
        if isExternal {
            let clue = signalLabel ?? "observed clue"
            return "\(clue) · seen \(Self.ago(now.timeIntervalSince(mtime)))"
        }
        return "heartbeat \(Self.ago(now.timeIntervalSince(mtime)))"
    }

    /// Marker fields are untrusted file content — strip control characters and
    /// cap length before showing them in a menu item, so a crafted or oversized
    /// `cwd`/`term` can't inject control chars or an absurdly long line.
    private static func clean(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let out = String(String.UnicodeScalarView(scalars))
        return out.count > 40 ? String(out.prefix(40)) + "…" : out
    }

    private static func ago(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs.rounded()))
        if s < 60 { return "\(s)s ago" }
        let m = s / 60
        if m < 60 { return "\(m)m ago" }
        return "\(m / 60)h ago"
    }
}

/// Watches the Activity Source contract directory and reports whether any
/// selected local source is currently working.
///
/// The receipt contract: one file per
/// live source session under `~/.stayup/sources/<source>/active/`, first line is
/// a state token (`active` / `waiting`), the file's mtime is a heartbeat, and
/// the writer removes the file when the session ends. A session counts as *working* while
/// it is `active` and fresh: tool-in-flight turns stay awake as long as the
/// owning process is alive, and between-tool/model-thinking gaps stay awake
/// within the staleness ceiling. Waiting, idle, and stopped all count as *not
/// working* — the post-idle grace (MenuController) decides how long to linger
/// before letting the Mac sleep.
///
/// Source-agnostic by design: bundled writers are just integrations; anything
/// that follows the file convention can participate.
///
/// Mechanism mirrors `PowerSourceMonitor`: a long-lived observer with an
/// `onChange` callback delivered on the main queue. A lightweight poll scans
/// `sources/*/active` and also expires stale files, since no filesystem event
/// fires when a present file merely ages past the ceiling.
final class ActivitySourceMonitor {

    /// Delivered on the main queue whenever the aggregate working-state flips.
    var onChange: ((Bool) -> Void)?

    /// Delivered on the main queue after *every* evaluate,
    /// not just on a flip — lets the app republish live status as markers change.
    var onEvaluate: (() -> Void)?

    /// Latest aggregate state, mutated on `queue` in `evaluate()`. Don't read
    /// this directly off `queue` — use `isAnySourceWorking`.
    private var anySourceWorking = false

    /// Thread-safe read of the aggregate state. Hops to `queue` so a main-thread
    /// caller (the grace timer, reconcile) can't observe a half-written flip.
    var isAnySourceWorking: Bool { queue.sync { anySourceWorking } }

    // Active/fresh counts as "working"; waiting / idle / stopped are all "not
    // working", and the user-set post-idle grace (autoGraceSecs, in
    // MenuController) decides how long to linger before sleep.

    /// Crash backstop for active markers whose owning pid we can't verify and
    /// for active-without-tool thinking gaps. A live tool's pid is alive and
    /// exempt; stale active markers age out so leaked files cannot pin the Mac
    /// awake forever. Matches the contract's staleness ceiling.
    private static let STALE_CEILING: TimeInterval = 15 * 60

    /// Re-evaluation cadence: a plain 1s poll, deliberately NOT file events.
    /// Heartbeats are silent mtime bumps, and tool/state changes touch a subdir
    /// or rewrite file contents — none of which a directory vnode reports, so a
    /// watcher would miss most transitions. The scan is tiny and the timer is
    /// suspended while the Mac sleeps, so 1Hz costs nothing at rest. (Adaptive
    /// fast/idle cadence was tried and reverted: it regressed cold-engage for a
    /// gain that doesn't exist once you account for the sleep-suspended timer.)
    private static let POLL_SECS: TimeInterval = 1

    private let sourcesDir: URL
    private let queue = DispatchQueue(label: "app.getstayup.sourcemonitor")

    private var pollTimer: DispatchSourceTimer?
    private var running = false

    /// `directory` override exists for tests; production reads
    /// `~/.stayup/sources/*/active`.
    init(directory: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sourcesDir = directory ?? home.appendingPathComponent(".stayup/sources", isDirectory: true)
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.ensureDirExists()
            self.armPollTimer()
            self.evaluate()   // eager: pick up a session already in flight at launch
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.pollTimer?.cancel()
            self.pollTimer = nil
        }
    }

    // MARK: - Watch setup

    private func ensureDirExists() {
        try? FileManager.default.createDirectory(
            at: sourcesDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    private func armPollTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.POLL_SECS, repeating: Self.POLL_SECS)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.ensureDirExists()
            self.evaluate()
        }
        pollTimer = t
        t.resume()
    }

    // MARK: - Marker classification (single source of truth)

    /// One marker file, read and parsed once per evaluation. Every policy
    /// question — keep-awake, menu visibility, pruning — goes through
    /// `classify(_:now:)` so the call sites can never drift apart.
    private struct Marker {
        let url: URL
        let mtime: Date
        let state: String?             // "active" | "waiting" | nil (invalid token)
        let pid: Int32?
        let toolCount: Int
        let fields: [String: String]   // cwd/term/tx/signal/detail (untrusted)
        var isExternal: Bool {
            url.lastPathComponent.hasPrefix("ext-") || fields["signal"] != nil
        }
    }

    private enum MarkerClass {
        case working   // keeps the Mac awake
        case idle      // visible in the menu, does not keep awake
        case dead      // pruned
    }

    /// nil when the URL is not a regular file (directories, vanished entries).
    /// Unreadable/empty content fails toward `active` (keep awake on a torn read).
    private func readMarker(_ url: URL) -> Marker? {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard vals?.isRegularFile == true, let mtime = vals?.contentModificationDate else { return nil }

        var state: String? = "active"
        var fields: [String: String] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            let first = (lines.first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            if first.isEmpty || first == "active" { state = "active" }
            else if first == "waiting" { state = "waiting" }
            else { state = nil }
            for line in lines.dropFirst() {
                let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
        }
        let pid = fields["pid"].flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        return Marker(url: url, mtime: mtime, state: state, pid: pid,
                      toolCount: toolCount(url), fields: fields)
    }

    /// The policy truth table (see the contract's reader-semantics section):
    ///   • invalid state token → dead (junk in active/ is removed, not aged out)
    ///   • waiting → idle while its owner is around, never working
    ///   • external (observed) → working while fresh
    ///   • tool in flight → working while the owning pid lives; NO time cap,
    ///     so a real build runs as long as it takes
    ///   • active, no tool (thinking gap) → working while fresh AND the owner
    ///     lives; a dead owner is dead even when fresh
    ///   • no verifiable pid anywhere → the 15-min staleness ceiling decides
    private func classify(_ m: Marker, now: Date) -> MarkerClass {
        let fresh = now.timeIntervalSince(m.mtime) < Self.STALE_CEILING
        guard let state = m.state else { return .dead }
        if state == "waiting" {
            if let pid = m.pid, pid > 0 { return Self.pidAlive(pid) ? .idle : .dead }
            return fresh ? .idle : .dead
        }
        if m.isExternal { return fresh ? .working : .dead }
        if m.toolCount > 0 {
            if let pid = m.pid, pid > 0 { return Self.pidAlive(pid) ? .working : .dead }
            return fresh ? .working : .dead
        }
        if let pid = m.pid, pid > 0 {
            return (Self.pidAlive(pid) && fresh) ? .working : .dead
        }
        return fresh ? .working : .dead
    }

    private func makeSession(_ m: Marker, working: Bool) -> ActivitySourceSession {
        let state = m.state == "waiting" ? "waiting" : "active"
        let visibleToolCount = working && state != "waiting" ? m.toolCount : 0
        return ActivitySourceSession(
            id: m.url.lastPathComponent, state: state,
            cwd: m.fields["cwd"], terminal: m.fields["term"],
            transcriptPath: m.fields["tx"],
            signal: m.fields["signal"], detail: m.fields["detail"],
            mtime: m.mtime, working: working,
            toolsInFlight: visibleToolCount, isExternal: m.isExternal)
    }

    // MARK: - Evaluation

    /// Recompute the aggregate state and fire `onChange` (on main) if it flipped.
    /// Runs on `queue`.
    private func evaluate() {
        pruneStaleMarkers(now: Date())
        let working = computeAnyWorking()
        DispatchQueue.main.async { [weak self] in self?.onEvaluate?() }   // every tick, for live status
        guard working != anySourceWorking else { return }
        anySourceWorking = working
        DispatchQueue.main.async { [weak self] in self?.onChange?(working) }
    }

    private func computeAnyWorking() -> Bool {
        let now = Date()
        for url in markerURLs() {
            guard sourceEnabled(url), let m = readMarker(url),
                  classify(m, now: now) == .working else { continue }
            return true
        }
        return false
    }

    private func markerURLs() -> [URL] {
        guard let sourceFolders = try? FileManager.default.contentsOfDirectory(
            at: sourcesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // One physical marker per (source, session-id) already — the path is the
        // identity, so no dedupe needed. (A name+id "dedupe" only ever risked
        // hiding a second real session; removed.)
        return sourceFolders.flatMap {
            markerURLs(in: $0.appendingPathComponent("active", isDirectory: true))
        }
    }

    private func markerURLs(in activeDir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: activeDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// Keep `active/` folders as small as the contract implies: live receipts
    /// stay, dead/stale receipts and their sibling `.tools/` dirs are removed.
    private func pruneStaleMarkers(now: Date) {
        guard let sourceDirs = try? FileManager.default.contentsOfDirectory(
            at: sourcesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for sourceDir in sourceDirs {
            let activeDir = sourceDir.appendingPathComponent("active", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: activeDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey],
                options: []
            ) else { continue }

            for entry in entries {
                if entry.lastPathComponent == ".DS_Store" {
                    try? FileManager.default.removeItem(at: entry)
                    continue
                }

                let vals = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if vals?.isDirectory == true && entry.lastPathComponent.hasSuffix(".tools") {
                    let markerPath = String(entry.path.dropLast(".tools".count))
                    let markerURL = URL(fileURLWithPath: markerPath)
                    pruneToolMarkers(in: entry)
                    if !FileManager.default.fileExists(atPath: markerURL.path)
                        || shouldPruneMarker(markerURL, now: now) {
                        try? FileManager.default.removeItem(at: entry)
                    } else if isDirectoryEmpty(entry) {
                        try? FileManager.default.removeItem(at: entry)
                    }
                    continue
                }

                guard vals?.isRegularFile == true else { continue }
                if shouldPruneMarker(entry, now: now) {
                    try? FileManager.default.removeItem(at: entry)
                    try? FileManager.default.removeItem(
                        at: URL(fileURLWithPath: entry.path + ".tools", isDirectory: true))
                }
            }
        }
    }

    private func pruneToolMarkers(in toolsDir: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: toolsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return }

        // Tool markers themselves are cleaned by tool-end/turn-start/marker
        // pruning; this only clears foreign non-file entries.
        for entry in entries {
            let vals = try? entry.resourceValues(forKeys: [.isRegularFileKey])
            if vals?.isRegularFile != true {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    private func isDirectoryEmpty(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty) ?? true
    }

    /// Prune-worthy ⟺ the classifier says dead. Non-regular entries return
    /// false here; the directory walk in `pruneStaleMarkers` handles them.
    private func shouldPruneMarker(_ url: URL, now: Date) -> Bool {
        guard let m = readMarker(url) else { return false }
        return classify(m, now: now) == .dead
    }

    /// Honour the per-source toggle from Settings. Prefer the source's own
    /// `source.json` name so custom reported writers participate without being
    /// mistaken for a bundled source; fall back to the bundled hook heuristic only for
    /// hand-written markers that have no source file yet.
    private func sourceEnabled(_ url: URL) -> Bool {
        Settings.isSourceEnabled(sourceName(for: url))
    }

    private func sourceName(for markerURL: URL) -> String {
        let sourceDir = markerURL
            .deletingLastPathComponent()   // active/
            .deletingLastPathComponent()   // <source>/
        let sourceURL = sourceDir.appendingPathComponent("source.json")
        if let data = try? Data(contentsOf: sourceURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = dict["name"] as? String,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        return sourceDir.lastPathComponent
    }

    /// Number of tools currently in flight for a session — files in the sibling
    /// `<marker>.tools/` directory (PreToolUse adds, PostToolUse removes).
    private func toolCount(_ markerURL: URL) -> Int {
        let toolsURL = URL(fileURLWithPath: markerURL.path + ".tools", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: toolsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return entries.filter { url in
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
            return vals.isRegularFile == true
        }.count
    }

    /// Is the process still alive? `kill(pid, 0)` succeeds for a live process we
    /// own; `EPERM` means it's alive but not ours (still counts as alive).
    private static func pidAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: - Rich snapshot (for the menu)

    /// Synchronous snapshot of *live* sessions for the menu — which terminal,
    /// how many, where, and whether each is running (a tool in flight) vs merely
    /// waiting/idle. Looser than the keep-awake test: a waiting session shows
    /// here (its `working` flag is false) but doesn't keep the Mac awake. Reads
    /// the dir on the calling thread (cheap); call it on menu-open, not in a loop.
    func snapshotSessions() -> [ActivitySourceSession] {
        let now = Date()
        return markerURLs()
            .compactMap { url -> ActivitySourceSession? in
                guard sourceEnabled(url), let m = readMarker(url) else { return nil }
                let cls = classify(m, now: now)
                guard cls != .dead else { return nil }
                return makeSession(m, working: cls == .working)
            }
            .sorted { a, b in a.working != b.working ? a.working : a.mtime > b.mtime }  // running first
    }

    /// Total tokens **used** in a session, summed from its transcript JSONL
    /// (input + output + cache_creation + cache_read across all `usage`
    /// records). This is consumption, NOT remaining quota — quota isn't exposed
    /// locally. Cached by (path, size, mtime) so the menu doesn't re-parse a
    /// large transcript on every open. nil if the transcript can't be read.
    static func tokensUsed(transcriptPath: String) -> Int? {
        let url = URL(fileURLWithPath: transcriptPath).standardizedFileURL
        // `tx=` is untrusted marker content. Only ever read known transcript
        // roots, so a crafted marker can't point us at an arbitrary file. Keep
        // this allow-list explicit per integration.
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .standardizedFileURL.path
        guard url.path.hasPrefix(root + "/") else { return nil }
        guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = vals.fileSize, let mtime = vals.contentModificationDate,
              size <= Self.MAX_TRANSCRIPT_BYTES else { return nil }   // cap: no UI hang on a huge file
        let key = "\(transcriptPath)|\(size)|\(mtime.timeIntervalSince1970)"
        if let cached = tokenCache[key] { return cached }
        guard let data = try? Data(contentsOf: url) else { return nil }
        var total = 0
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
                     ?? obj["usage"] as? [String: Any]
            guard let u = usage else { continue }
            for field in ["input_tokens", "output_tokens",
                          "cache_creation_input_tokens", "cache_read_input_tokens"] {
                if let n = u[field] as? Int { total += n }
            }
        }
        if tokenCache.count > 64 { tokenCache.removeAll() }   // crude cap
        tokenCache[key] = total
        return total
    }
    private static var tokenCache: [String: Int] = [:]
    /// Ceiling on a transcript read (menu-open, main thread). A marker's `tx=`
    /// is untrusted; without this a crafted path to a huge file would hang the UI.
    private static let MAX_TRANSCRIPT_BYTES = 64 * 1024 * 1024
}
