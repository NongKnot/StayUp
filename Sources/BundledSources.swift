import Foundation

/// Single source of truth for every Activity Source StayUp ships knowledge of.
/// Both the reported-source hook installer (`ActivitySourceHookInstaller`) and
/// the observed-source watcher (`ExternalSourceWatcher`) read this one table, so
/// slugs, display names, event→action mappings, transcript prefixes, and
/// observed recipes all live in exactly one place. Adding a bundled source is a
/// new entry here plus a recipe doc — no scattered switch statements.
///
/// The frozen wire contract is `docs/activity-source-contract.md`; per-source
/// research + doc URLs live in `docs/activity-source-recipes/<slug>.md`.

enum BundledSourceKind {
    case reported   // the tool runs our hook/plugin and writes its own heartbeat
    case observed   // the tool can't report; the watcher infers work from a clue
}

/// How StayUp writes a reported source's hook config.
enum HookAdapter: Equatable {
    /// Merge our hook groups into a shared JSON config the tool owns, grouped
    /// dialect `{ "matcher": "", "hooks": [{ "type": "command", "command": … }] }`
    /// (Claude, Codex, Gemini, Qwen).
    case mergeGrouped
    /// Merge into a shared JSON config, flat dialect `[{ "command": … }]` per
    /// event (Cursor).
    case mergeFlat
    /// StayUp owns the whole JSON hook file — write it whole, delete on cleanup
    /// (GitHub Copilot CLI: `~/.copilot/hooks/stayup.json`).
    case ownFile
    /// StayUp owns a small dependency-free JS plugin file that `exec`s our
    /// per-source wrapper (OpenCode: `~/.config/opencode/plugins/stayup.js`).
    case ownPlugin

    var isMerge: Bool { self == .mergeGrouped || self == .mergeFlat }
}

/// Observed-source recipe fields (only the v1 contract types are legal).
struct ObservedRecipe {
    let type: String            // "file" | "logPattern" | "process" | "socket"
    var path: String? = nil
    var match: String? = nil
    var activePattern: String? = nil
    var idlePattern: String? = nil
    var minCpu: Double = 0
    var freshSecs: Double = 45
}

struct BundledSource {
    let key: String             // Settings toggle key + source.json "name" + STAYUP_SOURCE_NAME
    let slug: String            // folder under ~/.stayup/sources/<slug>
    let displayName: String
    let kind: BundledSourceKind

    // reported-only
    var adapter: HookAdapter? = nil
    var configPath: String? = nil          // home-relative hook config / plugin file
    var events: [(event: String, state: String)] = []
    var retiredEvents: [String] = []       // grouped events we used to manage; strip on install/uninstall
    var transcriptFolders: [String] = []   // home-relative dirs for STAYUP_SOURCE_TRANSCRIPT_PREFIXES

    // observed-only
    var recipe: ObservedRecipe? = nil
}

enum BundledSources {

    /// Every bundled source. Order is the Settings display order.
    static let all: [BundledSource] = [

        // ── Reported: shared-config merge (grouped dialect) ──────────────────
        BundledSource(
            key: "Claude", slug: "claude-code-cli", displayName: "Claude",
            kind: .reported, adapter: .mergeGrouped, configPath: ".claude/settings.json",
            events: [
                ("UserPromptSubmit",   "turn-start"),
                ("PreToolUse",         "tool-begin"),
                ("PostToolUse",        "tool-end"),
                ("PostToolUseFailure", "tool-end"),
                ("PermissionRequest",  "waiting"),
                ("PermissionDenied",   "waiting"),
                ("StopFailure",        "waiting"),
                ("SessionStart",       "waiting"),
                ("Notification",       "waiting"),
                ("Stop",               "waiting"),
                ("SessionEnd",         "stop"),
            ],
            // Claude can fire SubagentStop for internal recap/compaction while
            // idle; we no longer manage it — keep it here so repair/uninstall
            // strips any stale StayUp entry.
            retiredEvents: ["SubagentStop"],
            transcriptFolders: [".claude"]),

        BundledSource(
            key: "Codex", slug: "codex-cli", displayName: "Codex",
            kind: .reported, adapter: .mergeGrouped, configPath: ".codex/hooks.json",
            events: [
                ("SessionStart",      "waiting"),
                ("UserPromptSubmit",  "turn-start"),
                ("PreToolUse",        "tool-begin"),
                ("PostToolUse",       "tool-end"),
                ("SubagentStart",     "active"),
                ("SubagentStop",      "active"),
                ("PreCompact",        "active"),
                ("PostCompact",       "active"),
                ("PermissionRequest", "waiting"),
                // Codex has no SessionEnd; Stop → waiting (was stop) so an idle
                // Codex session stays visible like Claude and the reader's
                // pid-liveness prune removes the marker when Codex exits. The old
                // Stop→stop command is stripped on install because removingOurHooks
                // drops every StayUp entry on the Stop event before re-adding.
                ("Stop",              "waiting"),
            ],
            transcriptFolders: [".codex"]),

        // Gemini CLI uses its own Before/After hook vocabulary (NOT Claude's) —
        // verified against the official reference. See gemini-cli.md.
        BundledSource(
            key: "Gemini", slug: "gemini-cli", displayName: "Gemini",
            kind: .reported, adapter: .mergeGrouped, configPath: ".gemini/settings.json",
            events: [
                ("SessionStart", "waiting"),
                ("BeforeAgent",  "turn-start"),
                ("BeforeTool",   "tool-begin"),
                ("AfterTool",    "tool-end"),
                ("AfterAgent",   "waiting"),
                ("Notification", "waiting"),
                ("SessionEnd",   "stop"),
            ],
            transcriptFolders: [".gemini"]),

        // Qwen Code is a Gemini-CLI fork but its hooks use Claude-style event
        // names (verified independently). See qwen-code.md.
        BundledSource(
            key: "Qwen", slug: "qwen-code", displayName: "Qwen",
            kind: .reported, adapter: .mergeGrouped, configPath: ".qwen/settings.json",
            events: [
                ("SessionStart",       "waiting"),
                ("UserPromptSubmit",   "turn-start"),
                ("PreToolUse",         "tool-begin"),
                ("PostToolUse",        "tool-end"),
                ("PostToolUseFailure", "tool-end"),
                ("SubagentStart",      "active"),
                ("SubagentStop",       "active"),
                ("Notification",       "waiting"),
                ("PermissionRequest",  "waiting"),
                ("Stop",               "waiting"),
                ("StopFailure",        "waiting"),
                ("SessionEnd",         "stop"),
            ],
            transcriptFolders: [".qwen"]),

        // ── Reported: flat-dialect merge ─────────────────────────────────────
        BundledSource(
            key: "Cursor", slug: "cursor", displayName: "Cursor",
            kind: .reported, adapter: .mergeFlat, configPath: ".cursor/hooks.json",
            events: [
                ("sessionStart",       "waiting"),
                ("beforeSubmitPrompt", "turn-start"),
                ("preToolUse",         "tool-begin"),
                ("postToolUse",        "tool-end"),
                ("postToolUseFailure", "tool-end"),
                ("subagentStart",      "active"),
                ("subagentStop",       "active"),
                ("afterAgentThought",  "active"),
                ("afterAgentResponse", "waiting"),
                ("stop",               "stop"),
                ("sessionEnd",         "stop"),
            ],
            transcriptFolders: [".cursor"]),

        // ── Reported: StayUp owns the whole file ─────────────────────────────
        // GitHub Copilot CLI user-level hooks use camelCase event names and a
        // flat command array. See copilot-cli.md.
        BundledSource(
            key: "Copilot", slug: "copilot-cli", displayName: "Copilot",
            kind: .reported, adapter: .ownFile, configPath: ".copilot/hooks/stayup.json",
            events: [
                ("sessionStart",       "waiting"),
                ("userPromptSubmitted", "turn-start"),
                ("preToolUse",         "tool-begin"),
                ("postToolUse",        "tool-end"),
                ("postToolUseFailure", "tool-end"),
                ("subagentStart",      "active"),
                ("subagentStop",       "active"),
                ("agentStop",          "waiting"),
                ("errorOccurred",      "waiting"),
                ("permissionRequest",  "waiting"),
                ("notification",       "waiting"),
                ("sessionEnd",         "stop"),
            ],
            transcriptFolders: [".copilot"]),

        // ── Reported: StayUp owns a JS plugin ────────────────────────────────
        // OpenCode plugins are loaded from ~/.config/opencode/plugins/. The
        // plugin execs our wrapper via node:child_process. See opencode.md.
        BundledSource(
            key: "OpenCode", slug: "opencode", displayName: "OpenCode",
            kind: .reported, adapter: .ownPlugin, configPath: ".config/opencode/plugins/stayup.js",
            events: [
                ("session.created",      "waiting"),
                ("session.idle",         "waiting"),
                ("session.deleted",      "stop"),
                ("tool.execute.before",  "tool-begin"),
                ("tool.execute.after",   "tool-end"),
            ],
            transcriptFolders: []),

        // ── Observed ─────────────────────────────────────────────────────────
        // Ollama: generation always burns runner CPU; an idle loaded model and
        // the idle server sit at ~0%, and an idle-but-ESTABLISHED client socket
        // (the old socket false positive) no longer counts. minCpu 8 clears
        // typing/background noise without missing real generation. See ollama.md.
        BundledSource(
            key: "Ollama", slug: "ollama", displayName: "Ollama",
            kind: .observed,
            recipe: ObservedRecipe(type: "process", match: "ollama", minCpu: 8, freshSecs: 0)),

        BundledSource(
            key: "LM Studio", slug: "lm-studio", displayName: "LM Studio",
            kind: .observed,
            recipe: ObservedRecipe(
                type: "logPattern", path: "~/.lmstudio/server-logs/*/*.log",
                activePattern: "processing task|n_decoded|print_timing",
                idlePattern: "all slots are idle", freshSecs: 45)),
    ]

    static let reported = all.filter { $0.kind == .reported }
    static let observed = all.filter { $0.kind == .observed }

    static func source(forKey key: String) -> BundledSource? {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.key.lowercased() == k }
    }

    /// Case-insensitive lookup by the source's `name`/`key` (used by the writer
    /// slug/displayName resolvers).
    static func source(named name: String) -> BundledSource? { source(forKey: name) }
}
