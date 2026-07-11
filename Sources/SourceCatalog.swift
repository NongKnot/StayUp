import Foundation

/// One configured Activity Source as read from disk. The five common fields
/// every caller needs, plus the full parsed dict for fields beyond them
/// (observed detection recipes, transcript prefixes, …).
struct SourceRecord {
    let name: String          // the source key (Settings toggles key on this)
    let displayName: String?
    let type: String          // "" when the file omits it — callers keep their own strictness
    let method: String        // falls back to type, then ""
    let folderSlug: String
    let raw: [String: Any]

    var isReported: Bool { SourceCatalog.isReported(method: method, type: type) }
}

/// The one reader for the `~/.stayup/sources/<slug>/source.json` layout —
/// folder walk, JSON parse, and reported/observed classification live here and
/// nowhere else (see CONTEXT.md "SourceCatalog + SourceProvisioner").
/// Directory-injectable for tests, `Settings`-free, and it never writes:
/// enabled/deleted filtering stays at callers, provisioning is
/// `SourceProvisioner`'s job.
enum SourceCatalog {

    /// Canonical sources folder — the single definition point for the path.
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stayup/sources", isDirectory: true)
    }

    /// The one statement of the reported/observed rule.
    static func isReported(method: String, type: String) -> Bool {
        method == "reported" || type == "reported"
    }

    static func records(in dir: URL = defaultDirectory) -> [SourceRecord] {
        guard let sourceDirs = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return sourceDirs.compactMap(record(sourceDir:))
    }

    /// Parse one `<slug>/source.json`. Only `name` is required — a nameless
    /// file (or a bare marker folder with no source.json) yields nil and the
    /// caller decides its own fallback.
    static func record(sourceDir: URL) -> SourceRecord? {
        let sourceURL = sourceDir.appendingPathComponent("source.json")
        guard let data = try? Data(contentsOf: sourceURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = dict["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let type = (dict["type"] as? String) ?? ""
        return SourceRecord(
            name: name,
            displayName: dict["displayName"] as? String,
            type: type,
            method: (dict["method"] as? String) ?? type,
            folderSlug: sourceDir.lastPathComponent,
            raw: dict)
    }
}
