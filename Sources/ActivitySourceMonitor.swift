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

    /// Poll cadence for re-evaluation. Auto should notice a new reported
    /// connector heartbeat quickly after the user has already turned Auto on,
    /// and no filesystem event fires when a present marker merely crosses a
    /// TTL. The scan is tiny and runs only in Auto mode.
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
            guard sourceEnabled(url), isWorking(url, now: now) else { continue }
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

        let urls = sourceFolders.flatMap {
            markerURLs(in: $0.appendingPathComponent("active", isDirectory: true))
        }
        return dedupeMarkerURLs(urls)
    }

    private func dedupeMarkerURLs(_ urls: [URL]) -> [URL] {
        var best: [String: (url: URL, mtime: Date)] = [:]
        for url in urls {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let key = "\(sourceName(for: url))\u{0}\(url.lastPathComponent)"
            if best[key]?.mtime ?? .distantPast < mtime {
                best[key] = (url, mtime)
            }
        }
        return best.values.map(\.url)
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

        for entry in entries {
            guard let vals = try? entry.resourceValues(forKeys: [.isRegularFileKey]),
                  vals.isRegularFile == true else {
                try? FileManager.default.removeItem(at: entry)
                continue
            }
        }
    }

    private func isDirectoryEmpty(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty) ?? true
    }

    private func shouldPruneMarker(_ url: URL, now: Date) -> Bool {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard vals?.isRegularFile == true, let mtime = vals?.contentModificationDate else { return false }
        let age = now.timeIntervalSince(mtime)

        guard let state = workingState(url) else { return age > Self.STALE_CEILING }
        if state == "waiting" {
            if let pid = pidOf(url), pid > 0 { return !Self.pidAlive(pid) }
            return age > Self.STALE_CEILING
        }
        if toolCount(url) > 0, let pid = pidOf(url), pid > 0 {
            return !Self.pidAlive(pid)
        }
        return age > Self.STALE_CEILING
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

    private func isExternalMarker(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("ext-") || markerValue("signal", in: url) != nil
    }

    /// A session marker qualifies as working while it is active and live:
    /// tool-in-flight turns stay awake as long as the owning process lives,
    /// and active model-thinking / between-tool gaps stay awake while fresh.
    /// When the pid can't be verified, the staleness ceiling caps it so an
    /// unreadable/leaked marker can't pin the Mac awake forever. Everything
    /// else — waiting on you, stopped, idle — is *not working*; the post-idle
    /// grace in MenuController decides how long to linger before the Mac may
    /// sleep.
    ///
    /// Tool markers are not capped by mtime: a long build can run quietly for
    /// longer than the staleness ceiling. Leaks are cleaned by `waiting`,
    /// `stop`, `turn-start`, or by pruning the owning marker when its pid dies.
    private func isWorking(_ url: URL, now: Date) -> Bool {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard vals?.isRegularFile == true, let mtime = vals?.contentModificationDate else { return false }
        guard let state = workingState(url) else { return false }   // "active" | "waiting"
        let age = now.timeIntervalSince(mtime)

        // Waiting on the human → not working; the grace decides the linger.
        // Applies to exact and synthetic markers alike, so test/custom writers
        // can model an idle-but-visible source.
        if state == "waiting" { return false }

        // Observed source: fresh active presence = busy.
        if isExternalMarker(url) { return age < Self.STALE_CEILING }

        // An ACTIVE turn keeps the Mac awake — whether a tool is running OR the
        // model is just thinking (the long "spinner"). That's the whole point:
        // the source is working, so don't nap mid-turn.
        //   • tool in flight → held while the owning process lives (a long build's
        //     marker goes stale, but the live pid keeps it up; no time cap).
        //   • no tool (thinking) → held while the process is alive AND the marker
        //     is fresh; a stale active marker (an Esc'd turn that fired no Stop)
        //     ages out on the staleness ceiling so it can't pin the Mac forever.
        if toolCount(url) > 0 {
            if let pid = pidOf(url), pid > 0 { return Self.pidAlive(pid) }
            return age < Self.STALE_CEILING
        }
        if let pid = pidOf(url), pid > 0 { return Self.pidAlive(pid) && age < Self.STALE_CEILING }
        return age < Self.STALE_CEILING
    }

    /// The `pid=` line from a marker (the source process that owns the session).
    private func pidOf(_ url: URL) -> Int32? {
        guard let raw = markerValue("pid", in: url) else { return nil }
        return Int32(raw.trimmingCharacters(in: .whitespaces))
    }

    private func markerValue(_ key: String, in url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let prefix = key + "="
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    /// Is the process still alive? `kill(pid, 0)` succeeds for a live process we
    /// own; `EPERM` means it's alive but not ours (still counts as alive).
    private static func pidAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// First line of the marker: `active`/`waiting` → that state. Empty/torn →
    /// `active` (fail toward keeping awake on a transient read). Other → nil.
    private func workingState(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "active" }
        let first = (String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        if first.isEmpty || first == "active" { return "active" }
        return first == "waiting" ? "waiting" : nil
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

    // MARK: - Rich snapshot (for the menu)

    /// Synchronous snapshot of *live* sessions for the menu — which terminal,
    /// how many, where, and whether each is running (a tool in flight) vs merely
    /// waiting/idle. Looser than the keep-awake test: a waiting session shows
    /// here (its `working` flag is false) but doesn't keep the Mac awake. Reads
    /// the dir on the calling thread (cheap); call it on menu-open, not in a loop.
    func snapshotSessions() -> [ActivitySourceSession] {
        let now = Date()
        return markerURLs()
            .filter { sourceEnabled($0) && isLive($0, now: now) }
            .map { parseSession($0, working: isWorking($0, now: now), now: now) }
            .sorted { a, b in a.working != b.working ? a.working : a.mtime > b.mtime }  // running first
    }

    /// A marker worth *showing* in the menu — looser than `isWorking`: any valid
    /// active/waiting marker whose owner is still around (pid alive if known,
    /// else fresh within the staleness ceiling for pid-less external markers).
    /// A crashed session (dead pid) drops out; a long-waiting session stays.
    private func isLive(_ url: URL, now: Date) -> Bool {
        let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard vals?.isRegularFile == true, let mtime = vals?.contentModificationDate else { return false }
        guard let state = workingState(url) else { return false }
        let age = now.timeIntervalSince(mtime)
        if state == "waiting" {
            if let pid = pidOf(url), pid > 0 { return Self.pidAlive(pid) }
            return age < Self.STALE_CEILING
        }
        if isExternalMarker(url) { return age < Self.STALE_CEILING }
        if toolCount(url) > 0 {
            if let pid = pidOf(url), pid > 0 { return Self.pidAlive(pid) }
            return age < Self.STALE_CEILING
        }
        if let pid = pidOf(url), pid > 0 { return Self.pidAlive(pid) && age < Self.STALE_CEILING }
        return age < Self.STALE_CEILING
    }

    private func parseSession(_ url: URL, working: Bool, now: Date) -> ActivitySourceSession {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        var state = "active"
        var cwd: String?, term: String?, tx: String?, signal: String?, detail: String?
        if let data = try? Data(contentsOf: url) {
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
            if let first = lines.first,
               first.trimmingCharacters(in: .whitespaces).lowercased() == "waiting" {
                state = "waiting"
            }
            for line in lines.dropFirst() {
                let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                switch kv[0] {
                case "cwd":    cwd    = kv[1]
                case "term":   term   = kv[1]
                case "tx":     tx     = kv[1]
                case "signal": signal = kv[1]
                case "detail": detail = kv[1]
                default:       break
                }
            }
        }
        let visibleToolCount = working && state != "waiting" ? toolCount(url) : 0
        return ActivitySourceSession(id: url.lastPathComponent, state: state,
                            cwd: cwd, terminal: term, transcriptPath: tx,
                            signal: signal, detail: detail, mtime: mtime,
                            working: working, toolsInFlight: visibleToolCount,
                            isExternal: isExternalMarker(url))
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
