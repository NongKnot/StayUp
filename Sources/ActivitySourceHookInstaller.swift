import Foundation

/// Installs / removes StayUp's bundled reported-source hooks in supported local
/// tool configs and deploys the hook script to a stable location. This is the
/// writer half of the Activity Source feature; see
/// `tools/stayup-source-hook.sh`.
///
/// Safety is the whole point — we're editing global tool config:
///   • **Merge, never clobber.** Existing hooks (and any other settings) are
///     preserved. We only touch hook groups whose command is *ours* (matched by
///     the `stayup-source-hook` marker in the path), so re-install replaces only
///     our entries and uninstall removes only our entries.
///   • **Refuse to corrupt.** If `settings.json` exists but doesn't parse as a
///     JSON object, we throw rather than overwrite it.
///   • **Atomic + backed up.** We snapshot to `settings.json.stayup.bak` and
///     write the new file atomically (temp + rename).
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

    private struct BuiltInSource {
        let name: String
        let slug: String
        let displayName: String
        let sourceKey: String
        let transcriptFolders: [String]
    }

    private static let claudeSource = BuiltInSource(
        name: "Claude",
        slug: "claude-code-cli",
        displayName: "Claude",
        sourceKey: "Claude",
        transcriptFolders: [".claude"]
    )

    private static let codexSource = BuiltInSource(
        name: "Codex",
        slug: "codex-cli",
        displayName: "Codex",
        sourceKey: "Codex",
        transcriptFolders: [".codex"]
    )

    private static let cursorSource = BuiltInSource(
        name: "Cursor",
        slug: "cursor",
        displayName: "Cursor",
        sourceKey: "Cursor",
        transcriptFolders: [".cursor"]
    )

    private static let managedSources = [claudeSource, codexSource, cursorSource]

    /// Claude event → state argument passed to the script. See the contract.
    static let eventStates: [(event: String, state: String)] = [
        ("UserPromptSubmit", "turn-start"),   // resets the tool-in-flight counter
        ("PreToolUse",       "tool-begin"),   // +1 tool in flight
        ("PostToolUse",      "tool-end"),     // -1 tool in flight
        ("SessionStart",     "waiting"),   // visible, but startup/recap is not real work
        ("Notification",     "waiting"),
        ("Stop",             "waiting"),   // turn done → "waiting on you" (stays visible), NOT removed
        ("SessionEnd",       "stop"),      // session actually over → remove the marker
    ]
    /// Events StayUp used to manage for Claude but no longer trusts. Keep this
    /// list so reconnect/repair removes stale StayUp entries without touching
    /// unrelated user hooks on those events.
    private static let retiredClaudeEvents = ["SubagentStop"]

    /// Codex event → state argument passed to the script. Tool events are
    /// mapped to real in-flight markers so a long shell command/build cannot
    /// age past the active-heartbeat ceiling; `Stop` removes the turn receipt.
    static let codexEventStates: [(event: String, state: String)] = [
        ("SessionStart",      "waiting"),     // visible but not protecting
        ("UserPromptSubmit",  "turn-start"),  // fresh turn + clear leaked tools
        ("PreToolUse",        "tool-begin"),  // long tools stay protected until they finish
        ("PostToolUse",       "tool-end"),    // remove the matching in-flight marker
        ("SubagentStart",     "active"),
        ("SubagentStop",      "active"),
        ("Stop",              "stop"),        // turn done → remove; Codex has no SessionEnd cleanup
    ]

    /// Cursor event → state argument passed to the script. Cursor's public hook
    /// schema uses lower-camel event names and a flat hook array in
    /// `~/.cursor/hooks.json`, so install/uninstall uses a separate merge path.
    static let cursorEventStates: [(event: String, state: String)] = [
        ("sessionStart",       "waiting"),
        ("beforeSubmitPrompt", "turn-start"),
        ("preToolUse",         "tool-begin"),
        ("postToolUse",        "tool-end"),
        ("postToolUseFailure", "tool-end"),
        ("subagentStart",      "active"),
        ("subagentStop",       "active"),
        ("stop",               "stop"),
        ("sessionEnd",         "stop"),
    ]

    // MARK: - Default locations (production)

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
    static var codexHooksURL: URL { home.appendingPathComponent(".codex/hooks.json") }
    static var cursorHooksURL: URL { home.appendingPathComponent(".cursor/hooks.json") }
    static var scriptDestURL: URL { home.appendingPathComponent(".stayup/bin/stayup-source-hook.sh") }

    /// The bundled source script copied in at build time (see build.sh).
    static var bundledScriptURL: URL? {
        Bundle.main.url(forResource: "stayup-source-hook", withExtension: "sh")
    }

    /// True when our hooks are registered with the **current** command for every
    /// event we manage. Checks the exact command (not just presence) so a stale
    /// action mapping from an older app version self-heals via `repairIfNeeded`.
    static func isInstalled(onlyEnabled: Bool = false) -> Bool {
        let claudeOK = wants(claudeSource, onlyEnabled: onlyEnabled) ? isClaudeInstalled() : true
        let codexOK = wants(codexSource, onlyEnabled: onlyEnabled) ? isCodexInstalled() : true
        let cursorOK = wants(cursorSource, onlyEnabled: onlyEnabled) ? isCursorInstalled() : true
        return claudeOK && codexOK && cursorOK
    }

    static func missingHookDisplayNames(onlyEnabled: Bool = false) -> [String] {
        var missing: [String] = []
        if wants(claudeSource, onlyEnabled: onlyEnabled), !isClaudeInstalled() {
            missing.append(claudeSource.displayName)
        }
        if wants(codexSource, onlyEnabled: onlyEnabled), !isCodexInstalled() {
            missing.append(codexSource.displayName)
        }
        if wants(cursorSource, onlyEnabled: onlyEnabled), !isCursorInstalled() {
            missing.append(cursorSource.displayName)
        }
        return missing
    }

    static func isHookInstalled(for sourceKey: String) -> Bool {
        guard let source = builtInSource(named: sourceKey) else { return false }
        switch source.sourceKey {
        case claudeSource.sourceKey:
            return isClaudeInstalled()
        case codexSource.sourceKey:
            return isCodexInstalled()
        case cursorSource.sourceKey:
            return isCursorInstalled()
        default:
            return false
        }
    }

    static func canManageHooks(for sourceKey: String) -> Bool {
        builtInSource(named: sourceKey) != nil
    }

    static func deployReusableHookScript() throws {
        guard let src = bundledScriptURL else { throw InstallError.scriptSourceMissing }
        try deployScript(from: src, to: scriptDestURL)
    }

    // MARK: - Public API (production wrappers)

    static func install(onlyEnabled: Bool = false) throws {
        guard let src = bundledScriptURL else { throw InstallError.scriptSourceMissing }
        if managedSources.contains(where: { wants($0, onlyEnabled: onlyEnabled) }) {
            try deployScript(from: src, to: scriptDestURL)
        }
        var failures: [String] = []
        if wants(claudeSource, onlyEnabled: onlyEnabled) {
            do {
                try install(scriptSource: src, scriptDest: scriptDestURL, settings: settingsURL)
            } catch {
                failures.append("\(claudeSource.displayName): \(error)")
            }
        }
        if wants(codexSource, onlyEnabled: onlyEnabled) {
            do {
                try installCodex(scriptDest: scriptDestURL, hooksFile: codexHooksURL)
            } catch {
                failures.append("\(codexSource.displayName): \(error)")
            }
        }
        if wants(cursorSource, onlyEnabled: onlyEnabled) {
            do {
                try installCursor(scriptDest: scriptDestURL, hooksFile: cursorHooksURL)
            } catch {
                failures.append("\(cursorSource.displayName): \(error)")
            }
        }
        if !failures.isEmpty {
            throw InstallError.sourceFailures(failures)
        }
    }

    static func installHooks(for sourceKey: String) throws {
        guard let source = builtInSource(named: sourceKey) else { return }
        guard let src = bundledScriptURL else { throw InstallError.scriptSourceMissing }
        try deployScript(from: src, to: scriptDestURL)
        switch source.sourceKey {
        case claudeSource.sourceKey:
            try install(scriptSource: src, scriptDest: scriptDestURL, settings: settingsURL)
        case codexSource.sourceKey:
            try installCodex(scriptDest: scriptDestURL, hooksFile: codexHooksURL)
        case cursorSource.sourceKey:
            try installCursor(scriptDest: scriptDestURL, hooksFile: cursorHooksURL)
        default:
            return
        }
    }

    static func uninstall() throws {
        try uninstall(settings: settingsURL)
        try uninstallCodex(hooksFile: codexHooksURL)
        try uninstallCursor(hooksFile: cursorHooksURL)
    }

    static func disableSource(named sourceKey: String, folderSlug: String) throws {
        try disableSource(named: sourceKey, folderSlug: folderSlug, scriptDest: scriptDestURL)
    }

    static func disableSource(named sourceKey: String, folderSlug: String, scriptDest: URL) throws {
        if let source = builtInSource(named: sourceKey) {
            try deployNoopWrapper(for: source, scriptDest: scriptDest)
            try deployLegacyNoopWrapperIfNeeded(for: source, scriptDest: scriptDest)
            return
        }
        try deployNoopWrapper(named: wrapperName(for: folderSlug), scriptDest: scriptDest)
    }

    static func cleanupHooks(for sourceKey: String) throws {
        guard let source = builtInSource(named: sourceKey) else { return }
        try disableSource(named: source.sourceKey, folderSlug: source.slug)
        switch source.sourceKey {
        case claudeSource.sourceKey:
            try uninstall(settings: settingsURL)
        case codexSource.sourceKey:
            try uninstallCodex(hooksFile: codexHooksURL)
        case cursorSource.sourceKey:
            try uninstallCursor(hooksFile: cursorHooksURL)
        default:
            return
        }
    }

    /// Self-heal. A supported tool can clobber our `hooks` block by re-saving
    /// config from a stale in-memory copy. When Auto is on but our hooks have
    /// gone missing, silently re-assert them. No-op when Auto is off or the
    /// hooks are already present. Safe to call often (e.g. on launch + a
    /// periodic timer). Best-effort — never throws.
    static func repairIfNeeded() {
        guard Settings.autoSourceEnabled else { return }
        guard managedSources.contains(where: { wants($0, onlyEnabled: true) }) else { return }
        guard Settings.reportedHookConnectionAllowed || isInstalled(onlyEnabled: true) else { return }
        // Reinstall when our hooks are missing OR the deployed script itself was
        // deleted — isInstalled() only inspects settings.json, not the file on
        // disk, so without the second check a deleted script never self-heals
        // until the next launch (every hook meanwhile runs a missing script).
        let scriptMissing = !FileManager.default.fileExists(atPath: scriptDestURL.path)
        let wrapperMissing =
            (wants(claudeSource, onlyEnabled: true) && !FileManager.default.fileExists(atPath: wrapperURL(for: claudeSource, scriptDest: scriptDestURL).path)) ||
            (wants(codexSource, onlyEnabled: true) && !FileManager.default.fileExists(atPath: wrapperURL(for: codexSource, scriptDest: scriptDestURL).path)) ||
            (wants(cursorSource, onlyEnabled: true) && !FileManager.default.fileExists(atPath: wrapperURL(for: cursorSource, scriptDest: scriptDestURL).path))
        guard !isInstalled(onlyEnabled: true) || scriptMissing || wrapperMissing else { return }
        try? install(onlyEnabled: true)
    }

    /// Overwrite the deployed hook script with the bundled one. Lets a new app
    /// version ship an updated script (new heartbeat fields, fixes) without the
    /// user re-toggling Auto. Cheap (a ~2 KB copy); call on launch when Auto is
    /// on. No-op otherwise. Best-effort — never throws.
    static func redeployScriptIfNeeded() {
        guard Settings.autoSourceEnabled, let src = bundledScriptURL else { return }
        guard Settings.reportedHookConnectionAllowed
            || isInstalled(onlyEnabled: true)
            || hasEnabledReportedSource()
        else { return }
        try? deployScript(from: src, to: scriptDestURL)
        if wants(claudeSource, onlyEnabled: true) { try? deployWrapper(for: claudeSource, scriptDest: scriptDestURL) }
        if wants(codexSource, onlyEnabled: true) { try? deployWrapper(for: codexSource, scriptDest: scriptDestURL) }
        if wants(cursorSource, onlyEnabled: true) { try? deployWrapper(for: cursorSource, scriptDest: scriptDestURL) }
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

    // MARK: - Core (path-injectable for tests)

    /// Deploy the script and merge our hook entries into `settings`.
    static func install(scriptSource: URL, scriptDest: URL, settings: URL) throws {
        try deployScript(from: scriptSource, to: scriptDest)
        try deployWrapper(for: claudeSource, scriptDest: scriptDest)

        var root = try readSettings(at: settings)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        let command = hookCommandBase(for: claudeSource, scriptDest: scriptDest)
        for event in retiredClaudeEvents {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = removingOurHooks(from: groups)
            if groups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = groups }
        }
        for es in eventStates {
            var groups = (hooks[es.event] as? [[String: Any]]) ?? []
            groups = removingOurHooks(from: groups)               // drop any prior StayUp entry
            groups.append(ourGroup(command: "\(command) \(es.state)"))
            hooks[es.event] = groups
        }
        root["hooks"] = hooks
        try writeSettings(root, to: settings)
    }

    static func installCodex(scriptDest: URL, hooksFile: URL) throws {
        try deployWrapper(for: codexSource, scriptDest: scriptDest)

        var root = try readSettings(at: hooksFile)
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        let commandBase = hookCommandBase(for: codexSource, scriptDest: scriptDest)
        for es in codexEventStates {
            var groups = (hooks[es.event] as? [[String: Any]]) ?? []
            groups = removingOurHooks(from: groups)
            groups.append(ourGroup(command: "\(commandBase) \(es.state)"))
            hooks[es.event] = groups
        }
        root["hooks"] = hooks
        try writeSettings(root, to: hooksFile)
    }

    static func installCursor(scriptDest: URL, hooksFile: URL) throws {
        try deployWrapper(for: cursorSource, scriptDest: scriptDest)

        var root = try readSettings(at: hooksFile)
        if root["version"] == nil { root["version"] = 1 }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        let commandBase = hookCommandBase(for: cursorSource, scriptDest: scriptDest)
        for es in cursorEventStates {
            var items = (hooks[es.event] as? [[String: Any]]) ?? []
            items = removingOurFlatHooks(from: items)
            items.append(["command": "\(commandBase) \(es.state)"])
            hooks[es.event] = items
        }
        root["hooks"] = hooks
        try writeSettings(root, to: hooksFile)
    }

    /// Remove only our hook entries; leave everything else (and the script) intact.
    static func uninstall(settings: URL) throws {
        var root = try readSettings(at: settings)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for event in eventStates.map(\.event) + retiredClaudeEvents {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups = removingOurHooks(from: groups)
            if groups.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeSettings(root, to: settings)
    }

    static func uninstallCodex(hooksFile: URL) throws {
        var root = try readSettings(at: hooksFile)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for es in codexEventStates {
            guard var groups = hooks[es.event] as? [[String: Any]] else { continue }
            groups = removingOurHooks(from: groups)
            if groups.isEmpty { hooks.removeValue(forKey: es.event) }
            else { hooks[es.event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeSettings(root, to: hooksFile)
    }

    static func uninstallCursor(hooksFile: URL) throws {
        var root = try readSettings(at: hooksFile)
        guard var hooks = root["hooks"] as? [String: Any] else { return }
        for es in cursorEventStates {
            guard var items = hooks[es.event] as? [[String: Any]] else { continue }
            items = removingOurFlatHooks(from: items)
            if items.isEmpty { hooks.removeValue(forKey: es.event) }
            else { hooks[es.event] = items }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try writeSettings(root, to: hooksFile)
    }

    // MARK: - Helpers

    private static func ourGroup(command: String) -> [String: Any] {
        ["matcher": "", "hooks": [["type": "command", "command": command]]]
    }

    private static func isClaudeInstalled() -> Bool {
        guard let root = try? readSettings(at: settingsURL),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let commandBase = hookCommandBase(for: claudeSource, scriptDest: scriptDestURL)
        let currentHooksInstalled = eventStates.allSatisfy { es in
            guard let groups = hooks[es.event] as? [[String: Any]] else { return false }
            let want = "\(commandBase) \(es.state)"
            return groups.contains { g in
                (g["hooks"] as? [[String: Any]])?
                    .contains { ($0["command"] as? String) == want } == true
            }
        }
        let retiredHooksGone = retiredClaudeEvents.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return true }
            return !groupsContainOurHooks(groups)
        }
        return currentHooksInstalled && retiredHooksGone
    }

    private static func isCodexInstalled() -> Bool {
        guard let root = try? readSettings(at: codexHooksURL),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let commandBase = hookCommandBase(for: codexSource, scriptDest: scriptDestURL)
        return codexEventStates.allSatisfy { es in
            guard let groups = hooks[es.event] as? [[String: Any]] else { return false }
            let want = "\(commandBase) \(es.state)"
            return groups.contains { g in
                (g["hooks"] as? [[String: Any]])?
                    .contains { ($0["command"] as? String) == want } == true
            }
        }
    }

    private static func isCursorInstalled() -> Bool {
        guard let root = try? readSettings(at: cursorHooksURL),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let commandBase = hookCommandBase(for: cursorSource, scriptDest: scriptDestURL)
        return cursorEventStates.allSatisfy { es in
            guard let items = hooks[es.event] as? [[String: Any]] else { return false }
            let want = "\(commandBase) \(es.state)"
            return items.contains { ($0["command"] as? String) == want }
        }
    }

    private static func wants(_ source: BuiltInSource, onlyEnabled: Bool = false) -> Bool {
        let present = !Settings.isSourceDeleted(source.sourceKey) || sourceFileExists(for: source)
        return present && (!onlyEnabled || Settings.isSourceEnabled(source.sourceKey))
    }

    private static func sourceFileExists(for source: BuiltInSource) -> Bool {
        FileManager.default.fileExists(
            atPath: home
                .appendingPathComponent(".stayup/sources", isDirectory: true)
                .appendingPathComponent(source.slug, isDirectory: true)
                .appendingPathComponent("source.json")
                .path
        )
    }

    private static func hookCommandBase(for source: BuiltInSource, scriptDest: URL) -> String {
        shellQuote(wrapperURL(for: source, scriptDest: scriptDest).path)
    }

    private static func wrapperURL(for source: BuiltInSource, scriptDest: URL) -> URL {
        scriptDest.deletingLastPathComponent().appendingPathComponent(wrapperName(for: source.slug))
    }

    private static func wrapperURL(named wrapperName: String, scriptDest: URL) -> URL {
        scriptDest.deletingLastPathComponent().appendingPathComponent(wrapperName)
    }

    private static func wrapperName(for slug: String) -> String {
        "stayup-source-hook-\(slug).sh"
    }

    private static func wrapperContents(for source: BuiltInSource, scriptDest: URL) -> String {
        let transcriptPrefixes = source.transcriptFolders
            .map(transcriptPrefix(for:))
            .joined(separator: ":")
        var lines = [
            shellAssignment("STAYUP_SOURCE_NAME", source.name),
            shellAssignment("STAYUP_SOURCE_SLUG", source.slug),
            shellAssignment("STAYUP_SOURCE_DISPLAY", source.displayName),
            shellAssignment("STAYUP_SOURCE_KEY", source.sourceKey),
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

    /// Read settings.json into a dictionary. Missing file → empty object.
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

    private static func deployWrapper(for source: BuiltInSource, scriptDest: URL) throws {
        let wrapper = wrapperURL(for: source, scriptDest: scriptDest)
        let fm = FileManager.default
        try fm.createDirectory(at: wrapper.deletingLastPathComponent(),
                               withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let data = Data(("#!/bin/sh\n" + wrapperContents(for: source, scriptDest: scriptDest)).utf8)
        try data.write(to: wrapper, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    private static func deployNoopWrapper(for source: BuiltInSource, scriptDest: URL) throws {
        try deployNoopWrapper(named: wrapperName(for: source.slug), scriptDest: scriptDest)
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

    private static func deployLegacyNoopWrapperIfNeeded(for source: BuiltInSource, scriptDest: URL) throws {
        let legacyName: String
        switch source.sourceKey {
        case claudeSource.sourceKey:
            legacyName = "stayup-source-hook-claude.sh"
        case codexSource.sourceKey:
            legacyName = "stayup-source-hook-codex.sh"
        case cursorSource.sourceKey:
            legacyName = "stayup-source-hook-cursor-agent.sh"
        default:
            return
        }
        let legacyURL = wrapperURL(named: legacyName, scriptDest: scriptDest)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try deployNoopWrapper(named: legacyName, scriptDest: scriptDest)
        }
    }

    private static func builtInSource(named sourceKey: String) -> BuiltInSource? {
        let key = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return managedSources.first {
            key == $0.sourceKey.lowercased() || key == $0.name.lowercased()
        }
    }
}
