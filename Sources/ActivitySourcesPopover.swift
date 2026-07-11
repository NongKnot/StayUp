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

        let header = NSTextField(labelWithString: sessions.isEmpty ? "No Activity Sources detected" : "Activity Sources")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        stack.addArrangedSubview(header)

        for s in sessions { stack.addArrangedSubview(card(for: s)) }

        // Countdown to nap (the auto-grace timer) — only while it's ticking.
        if let secs = napIn, secs > 0 {
            let foot = NSTextField(labelWithString: "Mac naps in \(SessionPresenter.mmss(Int(secs)))")
            foot.font = .systemFont(ofSize: 11, weight: .medium)
            foot.textColor = .secondaryLabelColor
            stack.addArrangedSubview(foot)
        }
        view.layoutSubtreeIfNeeded()
    }

    private func card(for s: ActivitySourceSession) -> NSView {
        // Title row:  ● Source surface · project
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: SessionPresenter.dotColor(s), .font: NSFont.systemFont(ofSize: 11)]))
        title.append(NSAttributedString(string: s.terminalLabel, attributes: [
            .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 13, weight: .medium)]))
        let titleField = NSTextField(labelWithAttributedString: title)
        titleField.lineBreakMode = .byTruncatingTail

        // Detail row:  running · heartbeat 8s ago · 2 tools · 1.2M tok
        let detail = NSTextField(labelWithString: SessionPresenter.detailBits(s).joined(separator: "  ·  "))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let card = NSStackView(views: [titleField, detail])
        card.orientation = .vertical
        card.alignment   = .leading
        card.spacing     = 2
        return card
    }
}
