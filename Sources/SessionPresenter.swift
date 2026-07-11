import AppKit

/// The one session→presentation mapping. The menu rows, the popover cards,
/// and status.json all speak through here, so the state words, dot colors,
/// detail rows, and formatters cannot drift apart (they used to exist as
/// three hand-kept copies). Pure — shell-tested by
/// `tools/test-session-presenter.sh`; see CONTEXT.md "SessionPresenter".
enum SessionPresenter {

    /// The state word: reported sources are "running" (tool in flight),
    /// "active" (thinking), "waiting", or "idle"; observed sources are
    /// best-effort, so just "activity seen" / "idle".
    static func word(_ s: ActivitySourceSession) -> String {
        if s.isExternal { return s.working ? "activity seen" : "idle" }
        if s.working    { return s.toolsInFlight > 0 ? "running" : "active" }
        return s.state == "waiting" ? "waiting" : "idle"
    }

    /// Status-dot color for the word: green = keeping the Mac awake,
    /// orange = waiting on the user, gray = idle.
    static func dotColor(_ s: ActivitySourceSession) -> NSColor {
        if s.working { return .systemGreen }
        if !s.isExternal, s.state == "waiting" { return .systemOrange }
        return .systemGray
    }

    /// The detail row under a session title:
    /// `running · heartbeat 8s ago · 2 tools · 1.2M tok` — observed sources
    /// swap the tail for "estimate" since their signal is a best-effort clue.
    static func detailBits(_ s: ActivitySourceSession, now: Date = Date()) -> [String] {
        var bits = [word(s), s.proofLabel(now: now)]
        if s.isExternal {
            bits.append("estimate")
            return bits
        }
        if s.working, s.toolsInFlight > 0 {
            bits.append("\(s.toolsInFlight) tool\(s.toolsInFlight == 1 ? "" : "s")")
        }
        if let tx = s.transcriptPath, let toks = ActivitySourceMonitor.tokensUsed(transcriptPath: tx) {
            bits.append("\(abbrevTokens(toks)) tok")
        }
        return bits
    }

    /// Seconds → "M:SS" (or "H:MM:SS" past an hour).
    static func mmss(_ totalSeconds: Int) -> String {
        let t = max(0, totalSeconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// 1234 → "1.2K", 1_200_000 → "1.2M".
    static func abbrevTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
}
