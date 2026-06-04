import AppKit

/// Small live panel listing the Activity Sources StayUp can see — RunCat /
/// OpenUsage in spirit, but smaller: one card per session with a status dot
/// (running / waiting / idle), which surface + project, and the signals that
/// actually mean local work (heartbeat freshness, tools in flight, or observed
/// clues). No generic RAM/CPU summary — source-specific proof is what matters.
///
/// Only used in Auto mode. Refreshes itself every couple of seconds while shown,
/// so unlike the old static dropdown you actually see state change live.
final class ActivitySourcesPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let content = ActivitySourcesContentVC()
    private var refreshTimer: Timer?

    /// Pulls the current live sessions on each refresh (= monitor.snapshotSessions).
    var sessionsProvider: (() -> [ActivitySourceSession])?
    /// Seconds until the Mac naps (auto-grace countdown), or nil if not counting down.
    var napCountdownProvider: (() -> TimeInterval?)?

    override init() {
        super.init()
        popover.behavior = .transient          // closes when you click away
        popover.animates  = true
        popover.contentViewController = content
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo button: NSStatusBarButton) {
        refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() { popover.performClose(nil) }

    private func refresh() {
        content.render(sessionsProvider?() ?? [], napIn: napCountdownProvider?() ?? nil)
        popover.contentSize = content.view.fittingSize
    }

    // Live refresh only while visible — no work when closed. 1s for a smooth countdown.
    func popoverDidShow(_ notification: Notification) {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func popoverDidClose(_ notification: Notification) {
        refreshTimer?.invalidate(); refreshTimer = nil
    }
}

/// The popover's content: a vertical stack of source cards, rebuilt on each refresh.
private final class ActivitySourcesContentVC: NSViewController {
    private let stack = NSStackView()
    private static let width: CGFloat = 256

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 12
        stack.edgeInsets  = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        view = host
    }

    func render(_ sessions: [ActivitySourceSession], napIn: TimeInterval?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let header = NSTextField(labelWithString: sessions.isEmpty ? "No activity sources detected" : "Local Activity Sources")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        stack.addArrangedSubview(header)

        for s in sessions { stack.addArrangedSubview(card(for: s)) }

        // Countdown to nap (the auto-grace timer) — only while it's ticking.
        if let secs = napIn, secs > 0 {
            let foot = NSTextField(labelWithString: "Mac naps in \(Self.mmss(secs))")
            foot.font = .systemFont(ofSize: 11, weight: .medium)
            foot.textColor = .secondaryLabelColor
            stack.addArrangedSubview(foot)
        }
        view.layoutSubtreeIfNeeded()
    }

    private func card(for s: ActivitySourceSession) -> NSView {
        // Some sources report activity directly. Observed sources are estimates
        // from file/socket/CPU activity, so describe the signal plainly.
        let dot: NSColor
        let stateWord: String
        if s.isExternal {
            dot = s.working ? .systemGreen : .systemGray
            stateWord = s.working ? "activity seen" : "idle"
        } else if s.working {
            dot = .systemGreen
            stateWord = s.toolsInFlight > 0 ? "running" : "active"   // tool vs thinking
        } else if s.state == "waiting" {
            dot = .systemOrange
            stateWord = "waiting"
        } else {
            dot = .systemGray
            stateWord = "idle"
        }

        // Title row:  ● Source surface · project
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: dot, .font: NSFont.systemFont(ofSize: 11)]))
        title.append(NSAttributedString(string: s.terminalLabel, attributes: [
            .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 13, weight: .medium)]))
        let titleField = NSTextField(labelWithAttributedString: title)
        titleField.lineBreakMode = .byTruncatingTail

        // Detail row:  running · heartbeat 8s ago · 2 tools · 1.2M tok
        // External sources use the same proof label, e.g. socket/log/file.
        var bits = [stateWord]
        if s.isExternal {
            bits = [stateWord]
            bits.append(s.proofLabel())
            bits.append("estimate")
        } else {
            bits.append(s.proofLabel())
            if s.working, s.toolsInFlight > 0 {
                bits.append("\(s.toolsInFlight) tool\(s.toolsInFlight == 1 ? "" : "s")")
            }
            if let tx = s.transcriptPath, let toks = ActivitySourceMonitor.tokensUsed(transcriptPath: tx) {
                bits.append("\(Self.abbrev(toks)) tok")
            }
        }
        let detail = NSTextField(labelWithString: bits.joined(separator: "  ·  "))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let card = NSStackView(views: [titleField, detail])
        card.orientation = .vertical
        card.alignment   = .leading
        card.spacing     = 2
        return card
    }

    /// Seconds → "M:SS" (or "H:MM:SS" past an hour).
    private static func mmss(_ secs: TimeInterval) -> String {
        let t = max(0, Int(secs))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 1234 → "1.2K", 1_200_000 → "1.2M".
    private static func abbrev(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }
}
