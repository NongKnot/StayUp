import AppKit

/// First-launch onboarding window. Surfaces the three decisions a fresh
/// install actually wants from the user before menu-bar Duck blends
/// into background noise:
///   1. Launch at Login (SMAppService.mainApp via MenuController)
///   2. Helper setup (SMAppService.daemon — the only layer that keeps the
///      Mac awake on battery + lid closed)
///   3. Sparkle automatic updates
///
/// Without this surface those decisions only happen if the user goes
/// hunting in Settings — and the helper-approval friction kills
/// activation for the feature people actually came for.
///
/// Lifecycle: shown once when `Settings.didOnboard == false`, sets it
/// `true` on close. `defaults delete app.getstayup` resets the flag for
/// clean-room testing.
final class WelcomeWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var loginCheck:       NSButton!
    private var updateCheck:      NSButton!
    private var helperButton:     NSButton!
    private var helperStatusLabel: NSTextField!
    private var tryButton:        NSButton!
    private var tryStatusLabel:   NSTextField!

    /// Caller-provided action that flips the SMAppService.mainApp
    /// registration. Bound by MenuController so all login-item plumbing
    /// stays in one place (mirrors how SettingsWindow.loginToggle works).
    var loginToggle: ((Bool) -> Void)?
    /// Read the live "Launch at Login" state from `SMAppService.mainApp`.
    /// Used by the checkbox to reflect reality when the welcome is replayed
    /// from Settings → About after the user already toggled login elsewhere.
    var loginIsEnabled: (() -> Bool)?

    /// Called after the window closes. MenuController uses this to refresh
    /// the menu in case the welcome flipped Launch-at-Login or Helper state.
    var onDismiss: (() -> Void)?

    /// "Turn Duck on" — engage before asking for any permission, so a fresh
    /// install feels the product before the trust decisions. Bound by
    /// MenuController to `setMode(.on)`; `isEngaged` reads the live state so
    /// a replayed welcome reflects reality.
    var turnOn: (() -> Void)?
    var isEngaged: (() -> Bool)?

    func show() {
        if window == nil { window = build() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncHelperStatus()
        syncTryState()
    }

    // MARK: - Build

    private func build() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Welcome to StayUp"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 14
        stack.edgeInsets  = NSEdgeInsets(top: 26, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // ── Intro card: big Duck + cheeky welcome ──
        let introRow = NSStackView()
        introRow.orientation = .horizontal
        introRow.spacing = 16
        introRow.alignment = .centerY

        let icon = NSImageView(image: IconRenderer.aboutIcon(size: 72))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let introText = NSStackView()
        introText.orientation = .vertical
        introText.alignment   = .leading
        introText.spacing     = 2

        let quack = NSTextField(labelWithString: "Quack.")
        quack.font = NSFont.systemFont(ofSize: 26, weight: .bold)
        let welcome = NSTextField(labelWithString: "Welcome to StayUp.")
        welcome.font = NSFont.systemFont(ofSize: 14)
        welcome.textColor = .secondaryLabelColor
        let motto = NSTextField(labelWithString: "Duck's up, all night baby.")
        motto.font = NSFont.systemFont(ofSize: 11)
        motto.textColor = .tertiaryLabelColor

        introText.addArrangedSubview(quack)
        introText.addArrangedSubview(welcome)
        introText.addArrangedSubview(motto)
        introRow.addArrangedSubview(icon)
        introRow.addArrangedSubview(introText)
        stack.addArrangedSubview(introRow)
        stack.addArrangedSubview(divider())

        // ── 0. Try it — value before permissions ──
        let tryRow = NSStackView()
        tryRow.orientation = .horizontal
        tryRow.spacing     = 10
        tryRow.alignment   = .centerY
        tryButton = NSButton(title: "Turn Duck on",
                             target: self, action: #selector(tryPressed))
        tryButton.bezelStyle = .rounded
        tryStatusLabel = NSTextField(labelWithString: "")
        tryStatusLabel.font = NSFont.systemFont(ofSize: 11)
        tryStatusLabel.textColor = .systemGreen
        tryRow.addArrangedSubview(tryButton)
        tryRow.addArrangedSubview(tryStatusLabel)
        stack.addArrangedSubview(tryRow)
        stack.addArrangedSubview(desc("One click. Duck holds the Mac awake until you say Off."))
        stack.addArrangedSubview(divider())

        // ── 1. Launch at Login ──
        // Default OFF on first-launch onboarding, but the "Replay welcome"
        // path in Settings → About can re-open this window AFTER the user
        // already toggled the setting elsewhere — read the live state so
        // the checkbox reflects reality (was hardcoded .off, drifted vs
        // Settings → General).
        loginCheck = NSButton(checkboxWithTitle: "Launch StayUp at login",
                              target: self, action: #selector(loginToggled))
        loginCheck.state = (loginIsEnabled?() ?? false) ? .on : .off
        stack.addArrangedSubview(loginCheck)
        stack.addArrangedSubview(desc("Tick this and Duck shows up when you do."))

        // ── 2. Helper (battery+lid coverage) ──
        let helperHeader = NSTextField(labelWithString: "Battery + lid closed mode")
        helperHeader.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(helperHeader)
        stack.addArrangedSubview(desc("Set this up. Battery plus lid closed is the hard case, and the Helper is how Duck handles it. macOS asks once, then one password prompt."))

        let helperRow = NSStackView()
        helperRow.orientation = .horizontal
        helperRow.spacing     = 10
        helperRow.alignment   = .centerY
        helperButton = NSButton(title: "Set up Helper",
                                target: self, action: #selector(helperPressed))
        helperButton.bezelStyle = .rounded
        helperStatusLabel = NSTextField(labelWithString: "")
        helperStatusLabel.font = NSFont.systemFont(ofSize: 11)
        helperRow.addArrangedSubview(helperButton)
        helperRow.addArrangedSubview(helperStatusLabel)
        stack.addArrangedSubview(helperRow)

        stack.addArrangedSubview(divider())

        // ── 3. Auto-update (last per request) ──
        // Default OFF — Sparkle still prompts the user on second launch
        // (`SUEnableAutomaticChecks` is absent from Info.plist), so opting
        // in here is purely an encouragement, not the only path. Leaving
        // it unchecked means zero network calls until the user explicitly
        // says yes either here or to Sparkle's second-launch dialog.
        updateCheck = NSButton(checkboxWithTitle: "Automatically check for updates",
                               target: self, action: #selector(updateToggled))
        // Read live Sparkle preference — same drift bug as the login checkbox.
        // If the user already opted in via Sparkle's second-launch prompt or
        // Settings → About, this checkbox should reflect that.
        updateCheck.state = SparkleUpdater.shared.automaticChecksEnabled ? .on : .off
        stack.addArrangedSubview(updateCheck)
        stack.addArrangedSubview(desc("Tick this for quiet update checks. No ads, no telemetry — just Duck staying fresh."))

        // ── Footer ──
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(footerSpacer)

        let go = NSButton(title: "Let's go",
                          target: self, action: #selector(getStarted))
        go.bezelStyle = .rounded
        go.keyEquivalent = "\r"
        let footerRow = NSStackView()
        footerRow.orientation = .horizontal
        let leftSpacer = NSView()
        leftSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerRow.addArrangedSubview(leftSpacer)
        footerRow.addArrangedSubview(go)
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(footerRow)
        NSLayoutConstraint.activate([
            footerRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 28),
            footerRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -28),
        ])

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content
        return w
    }

    private func desc(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.maximumNumberOfLines = 0
        l.preferredMaxLayoutWidth = 380
        return l
    }

    private func divider() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    // MARK: - Helper status sync

    private func syncHelperStatus() {
        guard helperButton != nil else { return }
        switch StayUpHelper.shared.status {
        case .enabled:
            helperStatusLabel.stringValue = "Ready. Real Duck mode."
            helperStatusLabel.textColor   = .systemGreen
            helperButton.title            = "Done"
            helperButton.isEnabled        = false
        case .requiresApproval:
            helperStatusLabel.stringValue = "Approve in System Settings"
            helperStatusLabel.textColor   = .systemOrange
            helperButton.title            = "Open System Settings"
            helperButton.isEnabled        = true
        case .notRegistered, .notFound:
            helperStatusLabel.stringValue = ""
            helperButton.title            = "Set up Helper"
            helperButton.isEnabled        = true
        @unknown default:
            helperStatusLabel.stringValue = ""
            helperButton.isEnabled        = true
        }
    }

    private func syncTryState() {
        guard tryButton != nil else { return }
        if isEngaged?() ?? false {
            tryButton.title = "Duck's up"
            tryButton.isEnabled = false
            tryStatusLabel.stringValue = "Check the menu bar."
        } else {
            tryButton.title = "Turn Duck on"
            tryButton.isEnabled = true
            tryStatusLabel.stringValue = ""
        }
    }

    /// Re-sync helper status when the welcome window comes back to focus
    /// after the user approved in System Settings → Login Items.
    func windowDidBecomeKey(_ notification: Notification) {
        syncHelperStatus()
        syncTryState()
    }

    // MARK: - Actions

    @objc private func tryPressed() {
        turnOn?()
        syncTryState()
    }

    @objc private func loginToggled() {
        // Apply immediately so the user sees System Settings → Login Items
        // reflect their choice in real time if they look while we're here.
        loginToggle?(loginCheck.state == .on)
    }

    @objc private func updateToggled() {
        // Only write the Sparkle preference when the user *actively* toggles
        // the checkbox. Closing the welcome without touching this leaves
        // `SUEnableAutomaticChecks` absent in UserDefaults, so Sparkle's
        // own second-launch opt-in prompt still fires — that's the
        // intentional fallback path documented in `SparkleUpdater.swift`.
        SparkleUpdater.shared.setAutomaticChecksEnabledFromUserAction(updateCheck.state == .on)
    }

    @objc private func helperPressed() {
        let helper = StayUpHelper.shared
        switch helper.status {
        case .enabled:
            return
        case .requiresApproval:
            helper.openLoginItemsPane()
        case .notRegistered, .notFound:
            do { try helper.register() }
            catch {
                // Silent failure kills the feature people came for — say it.
                helperStatusLabel.stringValue = "Couldn't set up — try again from Settings."
                helperStatusLabel.textColor   = .systemRed
                return
            }
            if helper.status == .requiresApproval {
                helper.openLoginItemsPane()
            }
        @unknown default:
            break
        }
        syncHelperStatus()
    }

    @objc private func getStarted() {
        // Defers the actual "apply preferences" pass to windowWillClose so
        // both routes (button + ✕) land at the same place.
        window?.close()
    }

    /// Toggles apply immediately when clicked, so on close we just record
    /// that onboarding ran and let the menu refresh. A user who closes
    /// without touching anything ends up with Launch at Login OFF (no
    /// mainApp registration written) and `SUEnableAutomaticChecks` absent
    /// from UserDefaults — preserving Sparkle's own second-launch prompt
    /// as the fallback opt-in path.
    func windowWillClose(_ notification: Notification) {
        Settings.didOnboard = true
        onDismiss?()
    }
}
