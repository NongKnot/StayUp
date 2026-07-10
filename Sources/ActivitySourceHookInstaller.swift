import Foundation

/// Installs / removes StayUp's bundled reported-source hooks in supported local
/// tool configs and deploys the hook script to a stable location. This is the
/// writer half of the Activity Source feature; see
/// `tools/stayup-source-hook.sh`.
///
/// Table-driven: every bundled reported source lives in `BundledSources.swift`,
/// and one of three install adapters handles it — `mergeGrouped`/`mergeFlat`
/// (merge our hook groups into a shared JSON config the tool owns), `ownFile`
/// (StayUp owns the whole hook JSON), or `ownPlugin` (StayUp owns a JS plugin).
///
/// Safety is the whole point — we're editing global tool config:
///   • **Merge, never clobber.** For merge adapters, existing hooks (and any
///     other settings) are preserved. We only touch hook groups whose command is
///     *ours* (matched by the `stayup-source-hook` marker in the path), so
///     re-install replaces only our entries and uninstall removes only ours.
///   • **Refuse to corrupt.** If a config exists but doesn't parse as a JSON
///     object, we throw rather than overwrite it.
///   • **Atomic + backed up.** Merge writes snapshot to `…stayup.bak` and write
///     atomically. Owned files are written atomically (no backup — the file is
///     entirely ours).
///   • **Bundle-independent script path.** The hook script is copied to
///     `~/.stayup/bin/` so moving or renaming `StayUp.app` never breaks hooks.
enum ActivitySourceHookInstaller {

    enum InstallError: Error, CustomStringConvertible, LocalizedError {
        case settingsNotObject
        case scriptSourceMissing
        case sourceFailures([String])
        var description: String {
            switch self {
            case .settingsNotObject:
                return "Hook config exists but is not a JSON object; refusing to modify it."
            case .scriptSourceMissing:
                return "Could not locate the bundled stayup-source-hook.sh to install."
            case .sourceFailures(let failures):
                return failures.joined(separator: "\n")
            }
        }

        var errorDescription: String? { description }
    }

    /// Marker that identifies a hook command as ours, for idempotent merge and
    /// clean removal. It's part of the deployed script path, so any group whose
    /// command contains it is a StayUp entry.
    static let marker = "stayup-source-hook"

    // The three original bundled sources still have named test entry points.
    private static let claude = BundledSources.source(forKey: "Claude")!
    private static let codex = BundledSources.source(forKey: "Codex")!
    private static let cursor = BundledSources.source(forKey: "Cursor")!

    // MARK: - Default locations (production)

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var scriptDestURL: URL { home.appendingPathComponent(".stayup/bin/stayup-source-hook.sh") }

    /// Home-relative config/plugin file for a reported source.
    static func configURL(for s: BundledSource) -> URL {
        home.appendingPathComponent(s.configPath ?? "")
    }

    /// The bundled source script copied in at build time (see build.sh).
    static var bundledScriptURL: URL? {
        Bundle.main.url(forResource: "stayup-source-hook", withExtension: "sh")
    }

    // MARK: - Status queries

    /// True when our hooks are registered with the **current** command for every
    /// event we manage on every wanted source. Checks the exact command (not just
    /// presence) so a stale mapping from an older app version self-heals via
    /// `repairIfNeeded`.
    static func isInstalled(onlyEnabled: Bool = false) -> Bool {
        BundledSources.reported
            .filter { wants($0, onlyEnabled: onlyEnabled) }
            .allSatisfy { isSourceInstalled($0, scriptDest: scriptDestURL, configFile: configURL(for: $0)) }
    }

    static func missingHookDisplayNames(onlyEnabled: Bool = false) -> [String] {
        BundledSources.reported
            .filter { wants($0, onlyEnabled: onlyEnabled) }
            .filter { !isSourceInstalled($0, scriptDest: scriptDestURL, configFile: configURL(for: $0)) }
            .map(\.displayName)
    }

    static func isHookInstalled(for sourceKey: String) -> Bool {
        guard let s = reportedSource(named: sourceKey) else { return false }
        return isSourceInstalled(s, scriptDest: scriptDestURL, configFile: configURL(for: s))
    }

    /// Per-source hook health for UI. `off` = Auto is off (disconnected is the
    /// normal state, not a failure); `needsRepair` = wrapper stubbed/drifted/
    /// missing or config entries gone while Auto is on.
    enum HookHealth { case connected, needsRepair, off }

    static func hookHealth(for sourceKey: String) -> HookHealth {
        guard Settings.autoSourceEnabled else { return .off }
        guard let s = reportedSource(named: sourceKey) else { return .off }
        return isSourceHealthy(s, scriptDest: scriptDestURL, configFile: configURL(for: s))
            ? .connected : .needsRepair
    }

    static func isHookHealthy(for sourceKey: String) -> Bool {
        guard let s = reportedSource(named: sourceKey) else { return false }
        return isSourceHealthy(s, scriptDest: scriptDestURL, configFile: configURL(for: s))
    }

    /// Installed AND the deployed wrapper's bytes match what we'd generate.
    /// The content check is what catches a safe-disable stub (`exit 0`) left
    /// behind by delete/re-add — it exists on disk, so a bare existence check
    /// calls it fine while every hook silently no-ops.
    static func isSourceHealthy(_ s: BundledSource, scriptDest: URL, configFile: URL) -> Bool {
        isSourceInstalled(s, scriptDest: scriptDest, configFile: configFile)
            && wrapperHealthy(for: s, scriptDest: scriptDest)
    }

    static func unhealthyDisplayNames(onlyEnabled: Bool) -> [String] {
        BundledSources.reported
            .filter { wants($0, onlyEnabled: onlyEnabled) }
            .filter { !isSourceHealthy($0, scriptDest: scriptDestURL, configFile: configURL(for: $0)) }
            .map(\.displayName)
    }

    private static func wrapperHealthy(for s: BundledSource, scriptDest: URL) -> Bool {
        fileMatches(wrapperURL(for: s, scriptDest: scriptDest),
                    expected: "#!/bin/sh\n" + wrapperContents(for: s, scriptDest: scriptDest))
    }

    static func canManageHooks(for sourceKey: String) -> Bool {
        reportedSource(named: sourceKey) != nil
    }

    static func deployReusableHookScript() throws {
        guard let src = bundledScriptURL else { throw InstallError.scriptSourceMissing }
        try deployScript(from: src, to: scriptDestURL)
    }

    // MARK: - Public API (production)

    static func install(onlyEnabled: Bool = false) throws {
        guard let src = bundledScriptURL else { throw InstallError.scriptSourceMissing }
        let active = BundledSources.reported.filter { wants($0, onlyEnabled: onlyEnabled) }
        if !active.isEmpty { try deployScript(from: src, to: scriptDestURL) }
        var failures: [String] = []
        for s in active {
            do {
                try installSource(s, scriptDest: scriptDestURL, configFile: configURL(for: s))
            } catch {
                failures.append("\(s.displayName): \(error)")
            }
        }
        if !failures.isEmpty { throw InstallError.sourceFailures(failures) }
    }

    static func installHooks(for sourceKey: String) throws {
        guard let s = reportedSource(named: sourceKey) else { return }
        guard let src = bundledScriptURL else { throw InstallError.scriptSourceMissing }
        try deployScript(from: src, to: scriptDestURL)
        try installSource(s, scriptDest: scriptDestURL, configFile: configURL(for: s))
    }

    static func uninstall() throws {
        for s in BundledSources.reported {
            try uninstallSource(s, configFile: configURL(for: s))
        }
    }

    static func disableSource(named sourceKey: String, folderSlug: String) throws {
        try disableSource(named: sourceKey, folderSlug: folderSlug, scriptDest: scriptDestURL)
    }

    static func disableSource(named sourceKey: String, folderSlug: String, scriptDest: URL) throws {
        if let s = reportedSource(named: sourceKey) {
            try deployNoopWrapper(named: wrapperName(for: s.slug), scriptDest: scriptDest)
            try deployLegacyNoopWrapperIfNeeded(for: s, scriptDest: scriptDest)
            return
        }
        try deployNoopWrapper(named: wrapperName(for: folderSlug), scriptDest: scriptDest)
    }

    static func cleanupHooks(for sourceKey: String) throws {
        guard let s = reportedSource(named: sourceKey) else { return }
        try disableSource(named: s.key, folderSlug: s.slug)
        try uninstallSource(s, configFile: configURL(for: s))
    }

    /// Self-heal. A supported tool can clobber our hooks by re-saving config from
    /// a stale in-memory copy. When Auto is on but our hooks have gone missing,
    /// silently re-assert them. No-op when Auto is off or the hooks are already
    /// present. Safe to call often. Best-effort — never throws.
    ///
    /// Returns the display names whose *config* hook entries had drifted away
    /// (i.e. the agent dropped them) and were re-added — so a caller can remind
    /// the user. Empty when nothing drifted, or when the only repair was to our
    /// own deployed script/wrapper (an app-upgrade concern, not the user's).
    @discardableResult
    static func repairIfNeeded() -> [String] {
        guard Settings.autoSourceEnabled else { return [] }
        let wanted = BundledSources.reported.filter { wants($0, onlyEnabled: true) }
        guard !wanted.isEmpty else { return [] }
        guard Settings.reportedHookConnectionAllowed || isInstalled(onlyEnabled: true) else { return [] }
        // Reinstall when our hooks are missing OR the deployed script itself was
        // deleted — isInstalled() only inspects configs, not the file on disk, so
        // without the second check a deleted script never self-heals until the
        // next launch (every hook meanwhile runs a missing script).
        let scriptMissing = !FileManager.default.fileExists(atPath: scriptDestURL.path)
        // Content mismatch, not just existence: a safe-disable stub or a
        // drifted wrapper exists on disk but no-ops every hook. Missing is a
        // special case of mismatched, so one check covers both.
        let wrapperUnhealthy = wanted.contains { !wrapperHealthy(for: $0, scriptDest: scriptDestURL) }
        // Drift = our hook entries gone from the agent's own config (vs. our
        // script/wrapper on disk). Capture before reinstalling so we can report it.
        let drifted = missingHookDisplayNames(onlyEnabled: true)
        guard !isInstalled(onlyEnabled: true) || scriptMissing || wrapperUnhealthy else { return [] }
        try? install(onlyEnabled: true)
        return drifted
    }

    /// Overwrite the deployed hook script + wrappers with the bundled ones. Lets
    /// a new app version ship an updated script/wrapper (new heartbeat fields,
    /// fixes) without the user re-toggling Auto. Cheap; call on launch when Auto
    /// is on. No-op otherwise. Best-effort — never throws. Config-file drift
    /// (owned-file event mappings) is handled by `repairIfNeeded`.
    static func redeployScriptIfNeeded() {
        guard Settings.autoSourceEnabled, let src = bundledScriptURL else { return }
        guard Settings.reportedHookConnectionAllowed
            || isInstalled(onlyEnabled: true)
            || hasEnabledReportedSource()
        else { return }
        try? deployScript(from: src, to: scriptDestURL)
        for s in BundledSources.reported where wants(s, onlyEnabled: true) {
            try? deployWrapper(for: s, scriptDest: scriptDestURL)
        }
    }

    private static func hasEnabledReportedSource() -> Bool {
        let sourcesDir = home.appendingPathComponent(".stayup/sources", isDirectory: true)
        guard let sourceDirs = try? FileManager.default.contentsOfDirectory(
            at: sourcesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for dir in sourceDirs {
            let sourceURL = dir.appendingPathComponent("source.json")
            guard let data = try? Data(contentsOf: sourceURL),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = dict["name"] as? String
            else { continue }
            let method = (dict["method"] as? String) ?? (dict["type"] as? String) ?? ""
            if method == "reported" && Settings.isSourceEnabled(name) { return true }
        }
        return false
    }

    // MARK: - Named test entry points (path-injectable)

    /// Deploy the script and merge our hook entries into Claude's `settings`.
    static func install(scriptSource: URL, scriptDest: URL, settings: URL) throws {
        try deployScript(from: scriptSource, to: scriptDest)
        try installSource(claude, scriptDest: scriptDest, configFile: settings)
    }

    static func uninstall(settings: URL) throws {
        try uninstallSource(claude, configFile: settings)
    }

    static func installCodex(scriptDest: URL, hooksFile: URL) throws {
        try installSource(codex, scriptDest: scriptDest, configFile: hooksFile)
    }

    static func uninstallCodex(hooksFile: URL) throws {
        try uninstallSource(codex, configFile: hooksFile)
    }

    static func installCursor(scriptDest: URL, hooksFile: URL) throws {
        try installSource(cursor, scriptDest: scriptDest, configFile: hooksFile)
    }

    static func uninstallCursor(hooksFile: URL) throws {
        try uninstallSource(cursor, configFile: hooksFile)
    }

    // MARK: - Generic adapters

    /// Install one reported source into its config file. Always (re)deploys the
    /// source-specific wrapper, then dispatches by adapter.
    static func installSource(_ s: BundledSource, scriptDest: URL, configFile: URL) throws {
        try deployWrapper(for: s, scriptDest: scriptDest)
        guard let adapter = s.adapter else { return }
        switch adapter {
        case .mergeGrouped:
            try mergeInstall(s, grouped: true, scriptDest: scriptDest, configFile: configFile)
        case .mergeFlat:
            try mergeInstall(s, grouped: false, scriptDest: scriptDest, configFile: configFile)
        case .ownFile:
            try writeOwnedFile(ownFileContents(s, scriptDest: scriptDest), to: configFile)
        case .ownPlugin:
            try writeOwnedFile(pluginContents(s, scriptDest: scriptDest), to: configFile)
        }
    }

    static func uninstallSource(_ s: BundledSource, configFile: URL) throws {
        guard let adapter = s.adapter else { return }
        switch adapter {
        case .ownFile, .ownPlugin:
            try? FileManager.default.removeItem(at: configFile)
        case .mergeGrouped, .mergeFlat:
            let grouped = adapter == .mergeGrouped
            var root = try readSettings(at: configFile)
            guard var hooks = root["hooks"] as? [String: Any] else { return }
            for event in s.events.map(\.event) + s.retiredEvents {
                if grouped {
                    guard var groups = hooks[event] as? [[String: Any]] else { continue }
                    groups = removingOurHooks(from: groups)
                    if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
                } else {
                    guard var items = hooks[event] as? [[String: Any]] else { continue }
                    items = removingOurFlatHooks(from: items)
                    if items.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = items }
                }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
            try writeSettings(root, to: configFile)
        }
    }

    // MARK: - Legacy v0 purge

    /// Marker for pre-contract v0 hook entries (`stayup-agent-hook.sh`, wrote
    /// markers to ~/.stayup/active/ that nothing reads since the v1 Activity
    /// Source contract). Distinct from `marker` — v1 entries must survive.
    static let legacyAgentMarker = "stayup-agent-hook.sh"

    /// Remove StayUp-owned v0 entries from a Claude-style grouped hooks file.
    /// Returns true when the file was modified. Foreign entries and v1
    /// (`stayup-source-hook`) entries are untouched. No-op (and no rewrite,
    /// no .bak churn) when nothing matches.
    @discardableResult
    static func purgeLegacyAgentHooks(settings: URL) throws -> Bool {
        var root = try readSettings(at: settings)
        guard var hooks = root["hooks"] as? [String: Any] else { return false }
        var changed = false
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let hookItems = group["hooks"] as? [[String: Any]] else { return group }
                let keptItems = hookItems.filter {
                    guard let command = $0["command"] as? String else { return true }
                    return !command.contains(legacyAgentMarker)
                }
                if keptItems.count != hookItems.count { changed = true }
                if keptItems.isEmpty { return nil }
                var keptGroup = group
                keptGroup["hooks"] = keptItems
                return keptGroup
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        guard changed else { return false }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeSettings(root, to: settings)
        return true
    }

    /// One-time launch migration: clear every v0 artifact — the hook entries in
    /// Claude's settings plus the dead script, marker dir, and watch-list under
    /// ~/.stayup/. Idempotent; each piece is independent and best-effort.
    static func purgeLegacyAgentArtifactsIfNeeded() {
        _ = try? purgeLegacyAgentHooks(settings: home.appendingPathComponent(".claude/settings.json"))
        let fm = FileManager.default
        for path in [".stayup/bin/stayup-agent-hook.sh", ".stayup/active", ".stayup/watch.json"] {
            try? fm.removeItem(at: home.appendingPathComponent(path))
        }
    }

    static func isSourceInstalled(_ s: BundledSource, scriptDest: URL, configFile: URL) -> Bool {
        guard let adapter = s.adapter else { return false }
        switch adapter {
        case .ownFile:
            return fileMatches(configFile, expected: ownFileContents(s, scriptDest: scriptDest))
        case .ownPlugin:
            return fileMatches(configFile, expected: pluginContents(s, scriptDest: scriptDest))
        case .mergeGrouped:
            guard let root = try? readSettings(at: configFile),
                  let hooks = root["hooks"] as? [String: Any] else { return false }
            let command = hookCommandBase(for: s, scriptDest: scriptDest)
            let present = s.events.allSatisfy { es in
                guard let groups = hooks[es.event] as? [[String: Any]] else { return false }
                let want = "\(command) \(es.state)"
                return groups.contains { g in
                    (g["hooks"] as? [[String: Any]])?
                        .contains { ($0["command"] as? String) == want } == true
                }
            }
            let retiredGone = s.retiredEvents.allSatisfy { event in
                guard let groups = hooks[event] as? [[String: Any]] else { return true }
                return !groupsContainOurHooks(groups)
            }
            return present && retiredGone
        case .mergeFlat:
            guard let root = try? readSettings(at: configFile),
                  let hooks = root["hooks"] as? [String: Any] else { return false }
            let command = hookCommandBase(for: s, scriptDest: scriptDest)
            return s.events.allSatisfy { es in
                guard let items = hooks[es.event] as? [[String: Any]] else { return false }
                let want = "\(command) \(es.state)"
                return items.contains { ($0["command"] as? String) == want }
            }
        }
    }

    private static func mergeInstall(_ s: BundledSource, grouped: Bool, scriptDest: URL, configFile: URL) throws {
        var root = try readSettings(at: configFile)
        // Cursor's flat schema declares a top-level version.
        if !grouped, root["version"] == nil { root["version"] = 1 }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        let command = hookCommandBase(for: s, scriptDest: scriptDest)

        for event in s.retiredEvents {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = removingOurHooks(from: groups)
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        for es in s.events {
            if grouped {
                var groups = (hooks[es.event] as? [[String: Any]]) ?? []
                groups = removingOurHooks(from: groups)               // drop any prior StayUp entry
                groups.append(ourGroup(command: "\(command) \(es.state)"))
                hooks[es.event] = groups
            } else {
                var items = (hooks[es.event] as? [[String: Any]]) ?? []
                items = removingOurFlatHooks(from: items)
                items.append(["command": "\(command) \(es.state)"])
                hooks[es.event] = items
            }
        }
        root["hooks"] = hooks
        try writeSettings(root, to: configFile)
    }

    // MARK: - Owned-file content

    /// GitHub Copilot CLI hook file: `{version, hooks:{event:[{type,command}]}}`.
    static func ownFileContents(_ s: BundledSource, scriptDest: URL) -> String {
        let command = hookCommandBase(for: s, scriptDest: scriptDest)
        var hooks: [String: Any] = [:]
        for es in s.events {
            hooks[es.event] = [["type": "command", "command": "\(command) \(es.state)"]]
        }
        let root: [String: Any] = ["version": 1, "hooks": hooks]
        let data = (try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// OpenCode JS plugin: dependency-free, `exec`s our per-source wrapper via
    /// `node:child_process`, tagging each call with the session id (when the
    /// event carries one) and our own pid for the reader's liveness prune.
    static func pluginContents(_ s: BundledSource, scriptDest: URL) -> String {
        let wrapper = jsStringLiteral(wrapperURL(for: s, scriptDest: scriptDest).path)
        return """
        // StayUp OpenCode plugin — auto-generated, do not edit.
        // Reports local work to StayUp's Activity Source heartbeat so Auto mode
        // keeps the Mac awake while a turn runs. Dependency-free.
        import { execFile } from "node:child_process"

        const WRAPPER = \(wrapper)

        function report(action, sessionID, directory) {
          try {
            const env = Object.assign({}, process.env, { STAYUP_SOURCE_PID: String(process.pid) })
            if (sessionID) env.STAYUP_SESSION_ID = String(sessionID)
            const child = execFile(WRAPPER, [action], { env }, () => {})
            if (child.stdin) child.stdin.end(JSON.stringify({ cwd: directory || "" }))
          } catch (e) { /* a hook must never break the turn */ }
        }

        // Streaming message events fire per token — throttle the "active"
        // heartbeat so a chat-only turn (no tools) still protects the Mac
        // without spawning a shell every few ms.
        let lastActiveAt = 0
        function reportActiveThrottled(sessionID, directory) {
          const now = Date.now()
          if (now - lastActiveAt < 15000) return
          lastActiveAt = now
          report("active", sessionID, directory)
        }

        export const StayUp = async ({ directory }) => {
          return {
            event: async ({ event }) => {
              const type = event && event.type
              const props = (event && event.properties) || {}
              const sid = props.sessionID || props.sessionId || (props.info && props.info.id) || ""
              if (type === "session.idle") report("waiting", sid, directory)
              else if (type === "session.created") report("waiting", sid, directory)
              else if (type === "session.deleted") report("stop", sid, directory)
              else if (type === "message.updated" || type === "message.part.updated")
                reportActiveThrottled(sid || (props.info && props.info.sessionID) || "", directory)
            },
            "tool.execute.before": async (input) => report("tool-begin", input && input.sessionID, directory),
            "tool.execute.after": async (input) => report("tool-end", input && input.sessionID, directory),
          }
        }

        """
    }

    private static func jsStringLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func fileMatches(_ url: URL, expected: String) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return String(decoding: data, as: UTF8.self) == expected
    }

    private static func writeOwnedFile(_ contents: String, to url: URL) throws {
        let fm = FileManager.default
        // The tool owns this directory (~/.copilot, ~/.config/opencode) — don't
        // force 0700; use default perms so we don't fight the tool's expectations.
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    private static func ourGroup(command: String) -> [String: Any] {
        ["matcher": "", "hooks": [["type": "command", "command": command]]]
    }

    private static func wants(_ s: BundledSource, onlyEnabled: Bool = false) -> Bool {
        let present = !Settings.isSourceDeleted(s.key) || sourceFileExists(for: s)
        return present && (!onlyEnabled || Settings.isSourceEnabled(s.key))
    }

    private static func sourceFileExists(for s: BundledSource) -> Bool {
        FileManager.default.fileExists(
            atPath: home
                .appendingPathComponent(".stayup/sources", isDirectory: true)
                .appendingPathComponent(s.slug, isDirectory: true)
                .appendingPathComponent("source.json")
                .path
        )
    }

    private static func hookCommandBase(for s: BundledSource, scriptDest: URL) -> String {
        shellQuote(wrapperURL(for: s, scriptDest: scriptDest).path)
    }

    private static func wrapperURL(for s: BundledSource, scriptDest: URL) -> URL {
        scriptDest.deletingLastPathComponent().appendingPathComponent(wrapperName(for: s.slug))
    }

    private static func wrapperURL(named wrapperName: String, scriptDest: URL) -> URL {
        scriptDest.deletingLastPathComponent().appendingPathComponent(wrapperName)
    }

    private static func wrapperName(for slug: String) -> String {
        "stayup-source-hook-\(slug).sh"
    }

    private static func wrapperContents(for s: BundledSource, scriptDest: URL) -> String {
        let transcriptPrefixes = s.transcriptFolders
            .map(transcriptPrefix(for:))
            .joined(separator: ":")
        var lines = [
            shellAssignment("STAYUP_SOURCE_NAME", s.key),
            shellAssignment("STAYUP_SOURCE_SLUG", s.slug),
            shellAssignment("STAYUP_SOURCE_DISPLAY", s.displayName),
            shellAssignment("STAYUP_SOURCE_KEY", s.key),
        ]
        var exported = [
            "STAYUP_SOURCE_NAME",
            "STAYUP_SOURCE_SLUG",
            "STAYUP_SOURCE_DISPLAY",
            "STAYUP_SOURCE_KEY",
        ]
        if !transcriptPrefixes.isEmpty {
            lines.append(shellAssignment("STAYUP_SOURCE_TRANSCRIPT_PREFIXES", transcriptPrefixes))
            exported.append("STAYUP_SOURCE_TRANSCRIPT_PREFIXES")
        }
        lines.append(contentsOf: [
            "export \(exported.joined(separator: " "))",
            "exec \(shellQuote(scriptDest.path)) \"$@\"",
            ""
        ])
        return lines.joined(separator: "\n")
    }

    private static func transcriptPrefix(for folder: String) -> String {
        let path = home
            .appendingPathComponent(folder, isDirectory: true)
            .standardizedFileURL
            .path
        return path.hasSuffix("/") ? path : "\(path)/"
    }

    private static func shellAssignment(_ key: String, _ value: String) -> String {
        "\(key)=\(shellQuote(value))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func removingOurHooks(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            guard let hookItems = group["hooks"] as? [[String: Any]] else { return group }
            let keptHookItems = hookItems.filter {
                guard let command = $0["command"] as? String else { return true }
                return !command.contains(marker)
            }
            if keptHookItems.isEmpty { return nil }
            var keptGroup = group
            keptGroup["hooks"] = keptHookItems
            return keptGroup
        }
    }

    private static func groupsContainOurHooks(_ groups: [[String: Any]]) -> Bool {
        groups.contains { group in
            guard let hookItems = group["hooks"] as? [[String: Any]] else { return false }
            return hookItems.contains {
                guard let command = $0["command"] as? String else { return false }
                return command.contains(marker)
            }
        }
    }

    private static func removingOurFlatHooks(from items: [[String: Any]]) -> [[String: Any]] {
        items.filter {
            guard let command = $0["command"] as? String else { return true }
            return !command.contains(marker)
        }
    }

    /// Read a JSON config into a dictionary. Missing file → empty object.
    /// Present-but-not-an-object → throw (so we never overwrite a file we don't
    /// understand).
    private static func readSettings(at url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else { throw InstallError.settingsNotObject }
        return dict
    }

    /// Back up the existing file, then write the new JSON atomically.
    private static func writeSettings(_ root: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("stayup.bak")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private static func deployScript(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        // 0700: ~/.stayup/bin holds a script local tools execute on every hook — keep
        // it owner-only so another local user can't tamper with or pre-plant it.
        try fm.createDirectory(at: dest.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = try Data(contentsOf: src)
        try data.write(to: dest, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    private static func deployWrapper(for s: BundledSource, scriptDest: URL) throws {
        let wrapper = wrapperURL(for: s, scriptDest: scriptDest)
        let fm = FileManager.default
        try fm.createDirectory(at: wrapper.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = Data(("#!/bin/sh\n" + wrapperContents(for: s, scriptDest: scriptDest)).utf8)
        try data.write(to: wrapper, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    private static func deployNoopWrapper(named wrapperName: String, scriptDest: URL) throws {
        let wrapper = wrapperURL(named: wrapperName, scriptDest: scriptDest)
        let fm = FileManager.default
        try fm.createDirectory(at: wrapper.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wrapper, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    private static func deployLegacyNoopWrapperIfNeeded(for s: BundledSource, scriptDest: URL) throws {
        let legacyName: String
        switch s.key {
        case "Claude": legacyName = "stayup-source-hook-claude.sh"
        case "Codex":  legacyName = "stayup-source-hook-codex.sh"
        case "Cursor": legacyName = "stayup-source-hook-cursor-agent.sh"
        default: return
        }
        let legacyURL = wrapperURL(named: legacyName, scriptDest: scriptDest)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try deployNoopWrapper(named: legacyName, scriptDest: scriptDest)
        }
    }

    private static func reportedSource(named sourceKey: String) -> BundledSource? {
        guard let s = BundledSources.source(named: sourceKey), s.kind == .reported else { return nil }
        return s
    }
}
