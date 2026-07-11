import AppKit
import ServiceManagement

/// Settings panel built on the classic macOS preferences pattern:
/// NSToolbar tabs across the top, content pane below, window
/// auto-resizes vertically as you switch tabs.
///
/// Why toolbar tabs and not the sidebar I tried first: 5 sections is
/// the sweet spot for top-tab navigation (3–10 items). Sidebar nav
/// pays a fixed chrome cost (~150pt of permanent width) that only
/// amortizes past ~10 sections. For us it's pure tax — every section
/// already fits in a top icon strip, every section is visible at once,
/// no hidden state behind a sidebar selection.
///
/// Structural changes that shipped with this rebuild (kept the
/// commentary inline so the structural decisions remain obvious):
/// * Dropped "Resume on launch" as a user-facing toggle. Always-on is
///   what 99% of users want; the persisted state still lives in
///   `Settings.resumeOnLaunch` for the engine but no longer earns its
///   real estate in the UI.
/// * Don't Die's stepper + numeric field + % suffix collapsed into a
///   3-option dropdown (5% / 10% / 20%). Stepper precision was an
///   engineer's mental model.
/// * Status banner at the top of General: live "5 of 5 layers ready"
///   readout that nudges the user to Helper when it's amber. Surfaces
///   the battery+lid coverage gate without nagging.
/// * Skin picker shows a colored swatch per skin (Mono renders as a
///   light/dark split to convey "adapts to menu bar").
/// * Tip CTA softened — borderless text link, not a primary button.
/// * Helper paragraph trimmed to a single sentence.
final class SettingsWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {

    // Picker options — one definition each; the builders and sync() both read
    // these so the menu items and the stale-value normalisation can't drift.
    private static let dontDiePctOptions = [5, 10, 20]
    private static let autoGraceOptions: [(title: String, secs: Int)] = [
        ("5 min", 300), ("15 min", 900), ("30 min", 1800),
        ("1 hour", 3600), ("3 hours", 10800),
    ]

    private var window: NSWindow?

    /// Tab identifiers. Kept in this order — affects the toolbar layout.
    private let tabIDs: [NSToolbarItem.Identifier] = [
        .stayupGeneral, .stayupAdvanced, .stayupWalk, .stayupLook, .stayupAbout,
    ]
    private var sectionViews: [NSToolbarItem.Identifier: NSView] = [:]

    // Controls — populated by the section builders.
    private var dontDieCheck:    NSButton!
    private var dontDiePopup:    NSPopUpButton!
    private var roastCheck:      NSButton!
    private var loginCheck:      NSButton!
    private var skinPopUp:       NSPopUpButton!
    private var helperStatus:    NSTextField!
    private var helperButton:    NSButton!
    private var autoUpdateCheck: NSButton!
    private var walkCheck:       NSButton!
    private var walkHardwareNote: NSTextField!
    private var modeControl:     NSSegmentedControl!
    private var layersBanner:    NSTextField!
    private var autoGracePopup:  NSPopUpButton!
    private var screenLockCheck: NSButton!
    private var sourceSummary: NSTextField!
    private var sourceListStack: NSStackView!
    private var sourceActionNote: NSTextField!
    private var sourceDeleteTargets: [String: ExternalSourceWatcher.ConfiguredSourceInfo] = [:]

    /// Width of every section's content. Window resizes height per
    /// section but keeps a uniform width so toolbar items don't
    /// shimmy around on tab switches.
    private let contentWidth: CGFloat = 520

    /// Called whenever a setting changes so MenuController can refresh
    /// the menu bar.
    var onChange: (() -> Void)?

    /// Caller-provided action for the "Launch at Login" toggle. The
    /// `SMAppService.mainApp` plumbing lives in MenuController.
    var loginToggle: ((Bool) -> Void)?
    var loginIsEnabled: (() -> Bool)?

    /// Re-opens the WelcomeWindow from the low-key footer link in About.
    var openWelcome: (() -> Void)?

    /// Mode control, routed to `MenuController` so the menu and this panel
    /// share one path. `setMode` takes the segment index (0=Off,1=On,2=Auto);
    /// `currentModeIndex` reads it back for `sync()`.
    var setMode: ((Int) -> Void)?
    var currentModeIndex: (() -> Int)?

    func show() {
        if window == nil { window = build() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sync()
    }

    // MARK: - Build

    private func build() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "StayUp Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.toolbarStyle = .preference

        let toolbar = NSToolbar(identifier: "app.getstayup.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.sizeMode = .regular
        w.toolbar = toolbar
        toolbar.selectedItemIdentifier = .stayupGeneral

        // Pre-build all section views so tab switches are instant. Each
        // view is given an explicit width constraint so its fittingSize
        // returns a predictable (width, height) and the window can
        // resize on switch without re-measuring multiple times.
        for id in tabIDs {
            let v: NSView
            switch id {
            case .stayupGeneral:  v = buildGeneralView()
            case .stayupAdvanced: v = buildAdvancedView()
            case .stayupWalk:     v = buildWalkView()
            case .stayupLook:     v = buildLookView()
            case .stayupAbout:    v = buildAboutView()
            default:             v = NSView()
            }
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            sectionViews[id] = v
        }

        if let general = sectionViews[.stayupGeneral] {
            w.contentView = general
            general.layoutSubtreeIfNeeded()
            resizeWindow(toFit: general)
        }
        return w
    }

    /// Resize the window's content area to match a section view's
    /// fitting size. Top-anchored so the title bar feels stable.
    private func resizeWindow(toFit view: NSView) {
        guard let w = window else { return }
        view.layoutSubtreeIfNeeded()
        let h = view.fittingSize.height
        let contentRect = NSRect(x: 0, y: 0, width: contentWidth, height: h)
        var frame = w.frameRect(forContentRect: contentRect)
        // Keep the top of the window in place across height changes.
        frame.origin = NSPoint(x: w.frame.origin.x,
                               y: w.frame.origin.y + (w.frame.height - frame.height))
        w.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Toolbar

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case .stayupGeneral:
            item.label = "General"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        case .stayupAdvanced:
            // Identifier stays `stayupAdvanced`; user-facing name is "Auto" —
            // the flagship feature shouldn't hide behind the word "Advanced".
            item.label = "Auto"
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Auto")
        case .stayupWalk:
            item.label = "Walk"
            item.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "Walk")
        case .stayupLook:
            item.label = "Look"
            item.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Look")
        case .stayupAbout:
            item.label = "About"
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "About")
        default:
            return nil
        }
        item.target = self
        item.action = #selector(tabSelected(_:))
        return item
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { tabIDs }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { tabIDs }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { tabIDs }

    @objc private func tabSelected(_ sender: NSToolbarItem) {
        showTab(sender.itemIdentifier)
    }

    private func showTab(_ id: NSToolbarItem.Identifier) {
        guard let view = sectionViews[id] else { return }
        window?.contentView = view
        resizeWindow(toFit: view)
    }

    // MARK: - Section builders

    private func buildGeneralView() -> NSView {
        let (container, stack) = sectionContainer()

        // Coverage banner — honest layer count. Green when the Helper is in
        // (lid-closed battery covered), orange when it's the missing layer.
        layersBanner = NSTextField(labelWithString: "")
        layersBanner.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        layersBanner.maximumNumberOfLines = 0
        layersBanner.lineBreakMode = .byWordWrapping
        layersBanner.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(layersBanner)
        layersBanner.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addGap(in: stack)

        // Mode — the one switch (mirrored in the menu-bar dropdown).
        let modeLabel = NSTextField(labelWithString: "Mode")
        modeLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(modeLabel)
        modeControl = NSSegmentedControl(
            labels: ["Off", "On", "Auto"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged))
        modeControl.segmentStyle = .rounded
        stack.addArrangedSubview(modeControl)
        addDesc("Off: idle. On: stay awake now. Auto: only while trusted sources work.", in: stack)

        addGap(in: stack)

        // Keep screen on (vs let the Mac lock). Mirrors the menu toggle.
        screenLockCheck = NSButton(checkboxWithTitle: "Keep screen on",
                                   target: self, action: #selector(screenLockToggled))
        stack.addArrangedSubview(screenLockCheck)
        addDesc("Off lets the Mac lock while work continues.", in: stack)

        addGap(in: stack)

        loginCheck = NSButton(checkboxWithTitle: "Launch at Login",
                              target: self, action: #selector(loginToggled))
        stack.addArrangedSubview(loginCheck)
        addDesc("Start Duck when you log in.", in: stack)

        addGap(in: stack)

        dontDieCheck = NSButton(checkboxWithTitle: "Don't Die",
                                target: self, action: #selector(dontDieToggled))
        stack.addArrangedSubview(dontDieCheck)

        // Inline sub-row: "Nap at: ▾ 10%"
        let dontDieRow = NSStackView()
        dontDieRow.orientation = .horizontal
        dontDieRow.spacing     = 8
        dontDieRow.alignment   = .centerY
        let dontDieLabel = NSTextField(labelWithString: "Nap at:")
        dontDieLabel.font = NSFont.systemFont(ofSize: 11)
        dontDieLabel.textColor = .secondaryLabelColor
        dontDiePopup = NSPopUpButton()
        dontDiePopup.target = self
        dontDiePopup.action = #selector(dontDiePopupChanged)
        for pct in Self.dontDiePctOptions {
            let item = NSMenuItem(title: "\(pct)%", action: nil, keyEquivalent: "")
            item.tag = pct
            dontDiePopup.menu?.addItem(item)
        }
        dontDieRow.addArrangedSubview(dontDieLabel)
        dontDieRow.addArrangedSubview(dontDiePopup)

        let ddIndent = NSView()
        ddIndent.translatesAutoresizingMaskIntoConstraints = false
        ddIndent.addSubview(dontDieRow)
        dontDieRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dontDieRow.leadingAnchor.constraint(equalTo: ddIndent.leadingAnchor, constant: 20),
            dontDieRow.trailingAnchor.constraint(lessThanOrEqualTo: ddIndent.trailingAnchor),
            dontDieRow.topAnchor.constraint(equalTo: ddIndent.topAnchor),
            dontDieRow.bottomAnchor.constraint(equalTo: ddIndent.bottomAnchor),
        ])
        stack.addArrangedSubview(ddIndent)
        ddIndent.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addDesc("Duck naps before the battery dies.", in: stack)

        // Helper — the one layer that truly survives battery + lid-closed on
        // Apple Silicon (root daemon → pmset disablesleep).
        addGap(in: stack, height: 18)
        let helperHeader = NSTextField(labelWithString: "Helper")
        helperHeader.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(helperHeader)
        addDesc("Required for lid-closed battery mode.", in: stack)
        helperStatus = NSTextField(labelWithString: "—")
        helperStatus.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(helperStatus)
        helperButton = NSButton(title: "Set up", target: self, action: #selector(helperAction))
        helperButton.bezelStyle = .rounded
        stack.addArrangedSubview(helperButton)

        return container
    }

    /// Auto tab — Activity Source tuning. (Mode switch + keep-screen-on live
    /// in General.)
    private func buildAdvancedView() -> NSView {
        let (container, stack) = sectionContainer()

        // Activity Sources — one user-facing workflow. Some tools report their
        // own activity; others are observed by local file/log/socket/CPU clues.
        let aiHeader = NSTextField(labelWithString: "Activity Sources")
        aiHeader.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(aiHeader)
        addDesc("Auto trusts selected local work signals.", in: stack)

        sourceSummary = NSTextField(labelWithString: "")
        sourceSummary.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        sourceSummary.textColor = .secondaryLabelColor
        sourceSummary.maximumNumberOfLines = 1
        sourceSummary.lineBreakMode = .byTruncatingTail
        sourceSummary.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sourceSummary)
        sourceSummary.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Inline sub-row: "Nap after: ▾ 5 min"
        let graceRow = NSStackView()
        graceRow.orientation = .horizontal
        graceRow.spacing     = 8
        graceRow.alignment   = .centerY
        let graceLabel = NSTextField(labelWithString: "Nap after:")
        graceLabel.font = NSFont.systemFont(ofSize: 11)
        graceLabel.textColor = .secondaryLabelColor
        autoGracePopup = NSPopUpButton()
        autoGracePopup.target = self
        autoGracePopup.action = #selector(autoGraceChanged)
        for (title, secs) in Self.autoGraceOptions {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = secs
            autoGracePopup.menu?.addItem(item)
        }
        graceRow.addArrangedSubview(graceLabel)
        graceRow.addArrangedSubview(autoGracePopup)

        let graceIndent = NSView()
        graceIndent.translatesAutoresizingMaskIntoConstraints = false
        graceIndent.addSubview(graceRow)
        graceRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            graceRow.leadingAnchor.constraint(equalTo: graceIndent.leadingAnchor, constant: 20),
            graceRow.trailingAnchor.constraint(lessThanOrEqualTo: graceIndent.trailingAnchor),
            graceRow.topAnchor.constraint(equalTo: graceIndent.topAnchor),
            graceRow.bottomAnchor.constraint(equalTo: graceIndent.bottomAnchor),
        ])
        stack.addArrangedSubview(graceIndent)
        graceIndent.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addDesc("Duck waits this long after work stops before napping.", in: stack)

        // Which sources to trust — a scrollable list that scales as users add
        // more sources. Nothing's on until the user ticks it.
        addGap(in: stack, height: 10)
        let detectLabel = NSTextField(labelWithString: "Sources")
        detectLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        detectLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(detectLabel)

        sourceListStack = NSStackView()
        sourceListStack.orientation = .vertical
        sourceListStack.alignment   = .leading
        sourceListStack.spacing     = 0
        sourceListStack.translatesAutoresizingMaskIntoConstraints = false
        rebuildSourceList()

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(sourceListStack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            sourceListStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 8),
            sourceListStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 10),
            sourceListStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -10),
            sourceListStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), // no horizontal scroll
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 206),
        ])
        addDesc("Tick sources you trust. Disabled sources cannot wake Duck.", in: stack)

        let sourceButtonRow = NSStackView()
        sourceButtonRow.orientation = .horizontal
        sourceButtonRow.spacing     = 8
        sourceButtonRow.alignment   = .centerY
        for button in [
            NSButton(title: "Add Source", target: self, action: #selector(addTrustedSource)),
            NSButton(title: "Refresh", target: self, action: #selector(refreshSourceList)),
            NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaultSources)),
        ] {
            button.bezelStyle = .rounded
            sourceButtonRow.addArrangedSubview(button)
        }
        stack.addArrangedSubview(sourceButtonRow)

        sourceActionNote = NSTextField(labelWithString: "")
        sourceActionNote.font = NSFont.systemFont(ofSize: 10)
        sourceActionNote.textColor = .secondaryLabelColor
        sourceActionNote.maximumNumberOfLines = 2
        sourceActionNote.lineBreakMode = .byTruncatingTail
        sourceActionNote.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sourceActionNote)
        sourceActionNote.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return container
    }

    private func buildWalkView() -> NSView {
        let (container, stack) = sectionContainer()

        let walkHeader = NSTextField(labelWithString: "Walk")
        walkHeader.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(walkHeader)

        walkCheck = NSButton(checkboxWithTitle: "Walk mode",
                             target: self, action: #selector(walkToggled))
        stack.addArrangedSubview(walkCheck)
        addDesc("Duck walks with your MacBook. Accelerometer stays local.", in: stack)

        walkHardwareNote = NSTextField(labelWithString: "No accelerometer on this Mac. Duck stays put.")
        walkHardwareNote.font = NSFont.systemFont(ofSize: 11)
        walkHardwareNote.textColor = .tertiaryLabelColor
        walkHardwareNote.maximumNumberOfLines = 0
        walkHardwareNote.lineBreakMode = .byWordWrapping
        walkHardwareNote.translatesAutoresizingMaskIntoConstraints = false
        walkHardwareNote.isHidden = true
        stack.addArrangedSubview(walkHardwareNote)
        walkHardwareNote.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        addGap(in: stack)

        roastCheck = NSButton(checkboxWithTitle: "Roast me",
                              target: self, action: #selector(roastChanged))
        stack.addArrangedSubview(roastCheck)
        addDesc("Duck heckles the step count.", in: stack)

        addGap(in: stack, height: 14)
        let statsHeader = NSTextField(labelWithString: "Walk log")
        statsHeader.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(statsHeader)
        addDesc("Coming later. Duck is still learning to keep a diary.", in: stack)

        return container
    }

    private func buildLookView() -> NSView {
        let (container, stack) = sectionContainer()

        // Duck skin row with colored swatches in the popup menu. Public v1
        // shows only the shipped starter Ducks; pack/code surfaces can come
        // back when the site + unlock story are ready.
        let skinRow = NSStackView()
        skinRow.orientation = .horizontal
        skinRow.spacing     = 10
        skinRow.alignment   = .centerY
        let skinLabel = NSTextField(labelWithString: "Duck:")
        skinPopUp = NSPopUpButton()
        skinPopUp.target = self
        skinPopUp.action = #selector(skinChanged)
        skinPopUp.menu?.autoenablesItems = false
        skinRow.addArrangedSubview(skinLabel)
        skinRow.addArrangedSubview(skinPopUp)
        stack.addArrangedSubview(skinRow)

        addDesc("Pick a Duck. Mono adapts to dark mode.", in: stack)

        rebuildSkinPicker()

        return container
    }

    /// Repopulate the skin picker with the public v1 starter Ducks.
    private func rebuildSkinPicker() {
        guard let popup = skinPopUp else { return }
        popup.removeAllItems()

        let availableSkins = DuckPack.starter.skins

        for skin in availableSkins {
            let item = NSMenuItem(title: skin.displayName,
                                  action: nil, keyEquivalent: "")
            item.image = skinSwatch(skin, size: 16)
            item.representedObject = skin.id
            popup.menu?.addItem(item)
        }

        // Restore the user's selection if it is one of the public v1 skins;
        // otherwise fall back to Classic. This cleans up old local states
        // that may have selected a hidden work-in-progress skin.
        let activeId = Settings.skinId
        if let idx = availableSkins.firstIndex(where: { $0.id == activeId }) {
            popup.selectItem(at: idx)
        } else {
            let fallbackId = DuckSkin.classic.id
            popup.selectItem(at: availableSkins.firstIndex(where: { $0.id == fallbackId }) ?? 0)
            Settings.skinId = fallbackId
            IconRenderer.invalidateCache()
            onChange?()
        }
    }

    /// Repopulate the Activity Sources checklist from ~/.stayup/sources/*.
    /// This lets a user add a source folder, save, then hit Refresh without
    /// closing Settings.
    private func rebuildSourceList() {
        guard let stack = sourceListStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        sourceDeleteTargets.removeAll()

        let sources = ExternalSourceWatcher.configuredSourceInfo()
        guard !sources.isEmpty else {
            let empty = NSTextField(labelWithString: "No sources yet. Click Add Source for the setup prompt, then Refresh.")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.maximumNumberOfLines = 0
            empty.lineBreakMode = .byWordWrapping
            empty.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            updateSourceSummary(sources: sources)
            return
        }

        for source in sources {
            let enabled = Settings.isSourceEnabled(source.key)
            let cb = NSButton(checkboxWithTitle: "", target: self, action: #selector(sourceToggled(_:)))
            cb.identifier = NSUserInterfaceItemIdentifier(source.key)
            cb.state = enabled ? .on : .off
            cb.toolTip = source.key == source.displayName ? nil : "Source key: \(source.key)"
            cb.setContentHuggingPriority(.required, for: .horizontal)

            // Hook-health badge — managed reported sources only (observed
            // sources have no hooks to break).
            var badge: NSTextField?
            if source.isReported,
               ActivitySourceHookInstaller.canManageHooks(for: source.key) {
                let dot = NSTextField(labelWithString: "●")
                dot.font = NSFont.systemFont(ofSize: 9)
                if !enabled {
                    dot.textColor = .tertiaryLabelColor
                    dot.toolTip = "Source not selected for Auto"
                } else {
                    switch ActivitySourceHookInstaller.hookHealth(for: source.key) {
                    case .connected:
                        dot.textColor = .systemGreen
                        dot.toolTip = "Hooks connected"
                    case .needsRepair:
                        dot.textColor = .systemOrange
                        dot.toolTip = "Hooks need repair — use Connect"
                    case .off:
                        dot.textColor = .tertiaryLabelColor
                        dot.toolTip = "Disconnected while Auto is off"
                    }
                }
                dot.setContentHuggingPriority(.required, for: .horizontal)
                badge = dot
            }

            let name = NSTextField(labelWithString: source.displayName)
            name.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            name.maximumNumberOfLines = 1
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let note = NSTextField(labelWithString: Self.sourceStatus(for: source, enabled: enabled))
            note.font = NSFont.systemFont(ofSize: 10)
            note.textColor = .secondaryLabelColor
            note.maximumNumberOfLines = 1
            note.lineBreakMode = .byTruncatingTail
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let text = NSStackView(views: [name, note])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 0
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            sourceDeleteTargets[source.folderSlug] = source
            var actions: [NSView] = []
            // Outside Auto, hooks are uninstalled by design and reinstall
            // automatically when Auto turns on — a Connect button there is
            // just noise that implies missing user work.
            if Settings.autoSourceEnabled, Self.sourceNeedsManagedConnection(source) {
                let connect = NSButton(title: "Connect", target: self, action: #selector(connectSourceHooks(_:)))
                connect.bezelStyle = .rounded
                connect.controlSize = .small
                connect.font = NSFont.systemFont(ofSize: 11)
                connect.identifier = NSUserInterfaceItemIdentifier(source.folderSlug)
                connect.toolTip = "Add StayUp hook entries for \(source.displayName)"
                connect.widthAnchor.constraint(equalToConstant: 72).isActive = true
                actions.append(connect)
            }

            let delete = NSButton(title: "Delete", target: self, action: #selector(deleteSource(_:)))
            delete.bezelStyle = .rounded
            delete.controlSize = .small
            delete.font = NSFont.systemFont(ofSize: 11)
            delete.identifier = NSUserInterfaceItemIdentifier(source.folderSlug)
            delete.toolTip = "Remove \(source.displayName) from StayUp"
            delete.widthAnchor.constraint(equalToConstant: 72).isActive = true
            actions.append(delete)

            let row = NSStackView(views: [cb] + (badge.map { [$0] } ?? []) + [text, spacer] + actions)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        updateSourceSummary(sources: sources)
    }

    private static func sourceStatus(for source: ExternalSourceWatcher.ConfiguredSourceInfo, enabled: Bool) -> String {
        if enabled {
            if sourceNeedsManagedConnection(source) && !Settings.autoSourceEnabled {
                return "Trusted — connects when Auto is on"
            }
            return "Trusted for Auto"
        }
        if sourceNeedsManagedConnection(source) && Settings.autoSourceEnabled {
            return "Needs connection"
        }
        return "Available"
    }

    private static func sourceNeedsManagedConnection(_ source: ExternalSourceWatcher.ConfiguredSourceInfo) -> Bool {
        source.isReported &&
            ActivitySourceHookInstaller.canManageHooks(for: source.key) &&
            !ActivitySourceHookInstaller.isHookHealthy(for: source.key)
    }

    private func updateSourceSummary(sources: [ExternalSourceWatcher.ConfiguredSourceInfo]? = nil) {
        guard sourceSummary != nil else { return }
        let visibleSources = sources ?? ExternalSourceWatcher.configuredSourceInfo()
        let total = visibleSources.count
        let enabled = visibleSources.filter { Settings.isSourceEnabled($0.key) }.count
        let mode = Settings.autoSourceEnabled
            ? "Auto on"
            : "Auto off — sources reconnect when Auto turns on"
        let trusted = enabled == 1 ? "1 trusted" : "\(enabled) trusted"
        let found = total == 1 ? "1 found" : "\(total) found"
        sourceSummary.stringValue = "\(mode) · \(trusted) · \(found)"
        sourceSummary.textColor = Settings.autoSourceEnabled ? .systemBlue : .secondaryLabelColor
    }

    /// About tab — app identity, welcome replay, and the Updates controls
    /// (auto-check + Check Now), which used to be their own tab.
    private func buildAboutView() -> NSView {
        let (container, stack) = sectionContainer()

        let aboutRow = NSStackView()
        aboutRow.orientation = .horizontal
        aboutRow.spacing     = 14
        aboutRow.alignment   = .top
        let icon = NSImageView(image: IconRenderer.aboutIcon(size: 72))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        // Easter-egg: Duck's LEFT EYE is a transparent button that launches
        // the live "everything" tester (bundled tools/stayup.sh). Invisible but
        // clickable; positioned over the eye (~ (138,175) in the 400×500 art).
        let eye = NSButton(title: "", target: self, action: #selector(launchTester))
        eye.isBordered = false
        eye.isTransparent = true
        eye.toolTip = "🔧 StayUp live tester"
        eye.setAccessibilityLabel("Duck's left eye — opens the live tester")
        eye.translatesAutoresizingMaskIntoConstraints = false
        icon.addSubview(eye)
        NSLayoutConstraint.activate([
            eye.leadingAnchor.constraint(equalTo: icon.leadingAnchor, constant: 14),
            eye.topAnchor.constraint(equalTo: icon.topAnchor, constant: 16),
            eye.widthAnchor.constraint(equalToConstant: 20),
            eye.heightAnchor.constraint(equalToConstant: 20),
        ])

        let aboutText = NSStackView()
        aboutText.orientation = .vertical
        aboutText.alignment   = .leading
        aboutText.spacing     = 2
        let appName = NSTextField(labelWithString: "StayUp")
        appName.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        let motto = NSTextField(labelWithString: "Duck's up, all night baby.")
        motto.font = NSFont.systemFont(ofSize: 12)
        motto.textColor = .secondaryLabelColor
        let version = NSTextField(labelWithString: "Version \(Self.appVersion) · getstayup.app")
        version.font = NSFont.systemFont(ofSize: 11)
        version.textColor = .tertiaryLabelColor
        aboutText.addArrangedSubview(appName)
        aboutText.addArrangedSubview(motto)
        aboutText.addArrangedSubview(version)

        aboutRow.addArrangedSubview(icon)
        aboutRow.addArrangedSubview(aboutText)
        stack.addArrangedSubview(aboutRow)

        addGap(in: stack, height: 18)
        addDesc("Free. Open source. Duck has rent.", in: stack)

        // Tip + welcome as visible buttons side-by-side. Tip opens the site;
        // pack/code surfaces stay held back for public v1.
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing     = 10
        buttonRow.alignment   = .centerY

        let tipButton = NSButton(title: "Feed Duck",
                                 target: self, action: #selector(openTipPage))
        tipButton.bezelStyle = .rounded

        let welcomeButton = NSButton(title: "Replay welcome",
                                     target: self, action: #selector(reopenWelcome))
        welcomeButton.bezelStyle = .rounded

        buttonRow.addArrangedSubview(tipButton)
        buttonRow.addArrangedSubview(welcomeButton)
        stack.addArrangedSubview(buttonRow)

        // ---- Updates (was its own tab) ----
        addGap(in: stack, height: 18)
        let updatesHeader = NSTextField(labelWithString: "Updates")
        updatesHeader.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        stack.addArrangedSubview(updatesHeader)
        autoUpdateCheck = NSButton(checkboxWithTitle: "Automatic updates",
                                   target: self, action: #selector(autoUpdateToggled))
        stack.addArrangedSubview(autoUpdateCheck)
        addDesc("Only checks for signed updates. No analytics.", in: stack)
        let updateNowButton = NSButton(title: "Check for Updates Now",
                                       target: self, action: #selector(checkUpdatesNow))
        updateNowButton.bezelStyle = .rounded
        stack.addArrangedSubview(updateNowButton)

        return container
    }

    // MARK: - Section helpers

    private func sectionContainer() -> (NSView, NSStackView) {
        let v = NSView()
        let s = NSStackView()
        s.orientation = .vertical
        s.alignment   = .leading
        s.spacing     = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            s.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            s.topAnchor.constraint(equalTo: v.topAnchor, constant: 22),
            s.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -22),
        ])
        return (v, s)
    }

    /// Description text with a hard width binding so wrapping happens at
    /// the actual visible width — the bug the old single-column layout
    /// kept tripping over with `preferredMaxLayoutWidth` being a hint.
    private func addDesc(_ text: String, in stack: NSStackView) {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.maximumNumberOfLines = 0
        l.lineBreakMode = .byWordWrapping
        l.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(l)
        l.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addGap(in stack: NSStackView, height: CGFloat = 8) {
        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.heightAnchor.constraint(equalToConstant: height).isActive = true
        stack.addArrangedSubview(gap)
    }

    /// Top-left origin so a scroll view's content fills from the top, not bottom.
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    /// A full-width hairline that visually separates sections within a tab.
    private func addSeparator(in stack: NSStackView) {
        addGap(in: stack, height: 10)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        addGap(in: stack, height: 10)
    }

    /// Renders a small swatch for the skin picker popup. Filled rounded
    /// rect using the skin's body + outline colors. Mono is a special-case
    /// half-light / half-dark split since its body/outline are both white
    /// (the actual mono Duck adapts to menu-bar appearance — the swatch
    /// has to communicate that with its own bitmap rather than relying on
    /// macOS template behavior, since menu-item images don't get template
    /// treatment the same way menu-bar icons do).
    private func skinSwatch(_ skin: DuckSkin, size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        defer { img.unlockFocus() }
        let rect = NSRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        if skin.id == "mono" {
            NSColor(white: 0.15, alpha: 1).setFill()
            path.fill()
            path.addClip()
            NSColor.white.setFill()
            NSRect(x: size / 2, y: 0, width: size / 2, height: size).fill()
            path.lineWidth = 1
            NSColor.separatorColor.setStroke()
            path.stroke()
        } else {
            skin.body.setFill()
            path.fill()
            skin.outline.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        return img
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private static func trustNote(for source: ExternalSourceWatcher.ConfiguredSourceInfo) -> String {
        "Connected \(source.displayName). Close any open session for that source, reopen it, then trust the StayUp hooks if it asks. The hook path should live under ~/.stayup/bin/."
    }

    private static func connectHookMessage(for source: ExternalSourceWatcher.ConfiguredSourceInfo) -> String {
        var text = "StayUp needs to add its own hook entries before Auto can trust this source. Existing config is preserved, and cleanup removes only StayUp entries."
        if ActivitySourceHookInstaller.canManageHooks(for: source.key) {
            text += "\n\nAfter connecting, close any open session for \(source.displayName), reopen it, then trust the StayUp hooks if it asks. Several hook events can point to one StayUp wrapper; that is expected."
        }
        return text
    }

    private static func connectedHookNote(for source: ExternalSourceWatcher.ConfiguredSourceInfo) -> String {
        ActivitySourceHookInstaller.canManageHooks(for: source.key)
            ? trustNote(for: source)
            : "Connected \(source.displayName). Tick it to trust it for Auto."
    }

    private static let sourceSetupPrompt = """
You are setting up one StayUp Activity Source for one local tool or app surface on this Mac.

StayUp is simple: Manual On/Off is direct user control. Auto protects the Mac while a selected local Activity Source is true, then turns off after StayUp's grace period. Best sources prove "working now." If the user explicitly wants "keep awake while this app is open," that is also allowed as a deliberate presence source.

Target one exact surface: CLI, desktop app, IDE extension, browser automation surface, local model runner, daemon, or other. Do not treat a brand as one source; different surfaces from the same product can expose different local signals.

If the user has not named the exact surface in the current conversation, ask one short question: "Which local app or tool should I connect, and should I use Easy, Normal, or Developer mode?" Do not search or inspect broadly until they answer. If they name a surface but do not choose a style, use Normal mode.

Talking style:
- Easy mode: plain user steps, almost no implementation detail.
- Normal mode: short explanations with the concrete checks and files you are using.
- Developer mode: include commands, paths, config details, and tradeoffs.

User-guided setup protocol:
- First clarify the user's intent: should Duck stay up only during real work, or whenever the app/tool is open? If they ask for app-open behavior, accept that choice and call it a presence source.
- For real-work sources, ask the user to put the target surface in an idle / not-working state. The app or daemon may stay open; idle means no generation, build, download, tool call, or local job is running.
- For app-open presence sources, prove open-vs-closed instead of idle-vs-active. Ask the user to open the exact app/tool, verify the local process/surface exists, then ask them to quit it and verify the signal goes quiet. Do not run a tiny job unless the user wants real-work detection.
- After the exact surface is named, do a quick online search for official documentation or primary sources for that exact surface before local probing. Look specifically for hooks, log files, sockets, task-state APIs, lifecycle events, and local inference/job status. If online search is unavailable, say so and continue with local evidence. Treat web results as a map, not proof. The Activity Source is valid only after local idle-vs-active evidence on this Mac.
- Inspect idle evidence and record what is quiet.
- Then ask the user to start one tiny local job in that exact surface. Name the smallest safe action you need. If a model is required, ask them to choose or load the smallest local model available.
- Inspect active evidence while the tiny job is running.
- Ask the user to let the job finish or stop it. The user's "stopped" answer is a cue, not proof: inspect once right away, then re-check after about 10 seconds. If the signal still looks active, keep re-checking for about 1 to 3 minutes before deciding it failed to return idle. Some tools flush logs, release sockets, or update task state late.
- Only install hooks or write source.json after the idle and active evidence support the source. If you cannot prove the difference, return needs_user_test or no_source.
- If the user asks to delete or undo a setup, prefer safe disable first: remove the StayUp source folder for that exact source under ~/.stayup/sources/<source-slug>/, disable that source if needed, and replace any StayUp source-specific wrapper with a harmless no-op that exits 0. Do not edit the target tool's hook/config file unless the user explicitly asks to clean up hooks. Do not delete the target app, model files, user projects, logs, or unrelated config.

StayUp source model:
- Source recipe: ~/.stayup/sources/<source-slug>/source.json
- Live receipts: ~/.stayup/sources/<source-slug>/active/
- Preferred: the tool reports activity by writing heartbeat receipts under active/.
- Generic reported CLIs can call ~/.stayup/bin/stayup-source-hook.sh working, not-working, or stop with STAYUP_SOURCE_NAME, STAYUP_SOURCE_SLUG, STAYUP_SOURCE_DISPLAY, STAYUP_SOURCE_KEY, optional STAYUP_SESSION_ID, optional STAYUP_SOURCE_PID, and optional STAYUP_SOURCE_TRANSCRIPT_PREFIXES.
- Custom reported sources do not require StayUp app-code changes. Prefer a short source-specific wrapper under ~/.stayup/bin/stayup-source-hook-<source-slug>.sh that sets STAYUP_SOURCE_NAME, STAYUP_SOURCE_SLUG, STAYUP_SOURCE_DISPLAY, and STAYUP_SOURCE_KEY, exports them, then execs ~/.stayup/bin/stayup-source-hook.sh "$@". If the hook payload includes a transcript_path or similar local receipt path, set STAYUP_SOURCE_TRANSCRIPT_PREFIXES to a colon-separated list of absolute source-owned roots so compatible hosts cannot cross-report as this source. Install the target tool's hooks so local work calls working, idle/waiting calls not-working, and session end calls stop. The script creates the reported source.json automatically on first heartbeat.
- For reported sources, create or update ~/.stayup/sources/<source-slug>/source.json immediately after the wrapper/hook mapping is ready, even before the first live heartbeat. This lets StayUp Settings show the source after Refresh. Do not create an active receipt by hand except for a deliberate test heartbeat.
- If reinstalling or restoring a reported source and its source-specific wrapper already exists as a harmless no-op, overwrite that wrapper with the real source wrapper. If the target tool's hooks already call that wrapper with the right actions, reuse them instead of adding duplicates.
- Create ~/.stayup/bin and refresh ~/.stayup/bin/stayup-source-hook.sh from /Applications/StayUp.app/Contents/Resources/stayup-source-hook.sh when that file exists, then chmod 755 it. Do this even if a previous hook script already exists, so the connector uses the newly installed StayUp writer. If the installed app resource is unavailable, ask the user to open StayUp or return needs_user_test. Do not edit the StayUp source repo.
- Reported CLI trust step: after installing CLI hooks, tell the user to close any open session for that CLI, reopen it, then trust the StayUp hooks if the CLI asks. The trusted path should live under ~/.stayup/bin/. Several hook events may call one StayUp wrapper; that is expected.
- Fallback observed types are exactly: file, logPattern, socket, process.
- Do not invent other type values.

Codex CLI / IDE special case:
- Use Codex's user-level hook config at ~/.codex/hooks.json for hook-capable Codex CLI/IDE surfaces.
- Use StayUp's canonical source identity so Settings, Delete, Restore Defaults, and built-in hook repair all agree: STAYUP_SOURCE_NAME="Codex", STAYUP_SOURCE_SLUG="codex-cli", STAYUP_SOURCE_DISPLAY="Codex", STAYUP_SOURCE_KEY="Codex".
- Use a wrapper at ~/.stayup/bin/stayup-source-hook-codex-cli.sh that exports those values plus STAYUP_SOURCE_TRANSCRIPT_PREFIXES="$HOME/.codex/" and execs ~/.stayup/bin/stayup-source-hook.sh "$@".
- Map Codex events: SessionStart -> waiting, UserPromptSubmit -> turn-start, PreToolUse -> tool-begin, PostToolUse -> tool-end, SubagentStart -> active, SubagentStop -> active, PreCompact -> active, PostCompact -> active, PermissionRequest -> waiting, Stop -> stop.
- Write ~/.stayup/sources/codex-cli/source.json with name Codex, displayName Codex, type reported, method reported.
- After editing ~/.codex/hooks.json, tell the user to close/reopen Codex CLI/IDE and trust the StayUp hooks via /hooks if Codex asks. Do not create a separate "Codex App" source key.

Cursor special case:
- Use Cursor's user-level hook config at ~/.cursor/hooks.json. Current Cursor docs say hooks can live in ~/.cursor/hooks.json and expose events including sessionStart, beforeSubmitPrompt, preToolUse, postToolUse, postToolUseFailure, subagentStart, subagentStop, afterAgentThought, afterAgentResponse, stop, and sessionEnd.
- Use StayUp's canonical source identity so Settings, Delete, Restore Defaults, and built-in hook repair all agree: STAYUP_SOURCE_NAME="Cursor", STAYUP_SOURCE_SLUG="cursor", STAYUP_SOURCE_DISPLAY="Cursor", STAYUP_SOURCE_KEY="Cursor".
- Use a wrapper at ~/.stayup/bin/stayup-source-hook-cursor.sh that exports those values plus STAYUP_SOURCE_TRANSCRIPT_PREFIXES="$HOME/.cursor/" and execs ~/.stayup/bin/stayup-source-hook.sh "$@".
- Map Cursor events: sessionStart -> waiting, beforeSubmitPrompt -> turn-start, preToolUse -> tool-begin, postToolUse -> tool-end, postToolUseFailure -> tool-end, subagentStart -> active, subagentStop -> active, afterAgentThought -> active, afterAgentResponse -> waiting, stop -> stop, sessionEnd -> stop.
- Write ~/.stayup/sources/cursor/source.json with name Cursor, displayName Cursor, type reported, method reported.
- After editing ~/.cursor/hooks.json, tell the user to close/reopen Cursor and trust the StayUp hooks if Cursor asks. Do not create a separate "Cursor App" source key.

Good signals mean active local work:
- heartbeat from tool events
- task/log file mtime changing during work and quiet while idle
- logPattern with clear active and idle/done markers
- ESTABLISHED socket that appears during work and is absent while idle
- CPU only when it clearly separates active work from idle
- process exists with minCpu 0 only when the user explicitly asked for app-open / presence behavior

Bad signals:
- app is installed, authenticated, or configured
- local model is loaded in RAM, VRAM, memory, or ready state
- generic process exists, unless the user explicitly asked for app-open / presence behavior
- browser tab or chat text exists
- cloud/web-only work with no local receipt

Local model rule: loaded model, server alive, or model ready is idle unless tokens are being generated, embeddings are running, a download is active, or another local inference/job is actually working.

Workflow:
1. If the exact surface is unclear, ask which local app or tool to connect and whether Duck should watch real work or app-open presence.
2. For real-work sources, inspect idle state first.
3. For app-open presence sources, inspect closed/absent state and open/present state. A process source with minCpu 0 is acceptable if it cleanly tracks the requested app/tool.
4. For real-work sources, inspect active state from a tiny local job; ask the user before running anything expensive, killing processes, installing software, or editing config.
5. Prefer reported heartbeat if the tool has hooks/events for working, waiting/idle, or stop. Install that mapping in the tool's own hook/config file, not in ~/.stayup/sources by hand.
6. Use the simple states first: working means protect the Mac, not-working means do not protect and let StayUp's grace timer run, stop removes the receipt. Only use advanced tool-begin/tool-end if those hooks are reliable paired lifecycle events.
7. Otherwise choose the smallest observed signal that matches the user's intent.
8. If the evidence is weak, return needs_user_test or no_source. Do not guess.

If you are asked to install a ready source, do not edit StayUp app code. For reported, install hooks in the target tool's own hook/config file so each event calls the source-specific wrapper under ~/.stayup/bin/stayup-source-hook-<source-slug>.sh. For file, logPattern, socket, or process, create exactly one source.json under ~/.stayup/sources/<source-slug>/source.json.

Return exactly this structure and no extra prose:
STAYUP_ACTIVITY_SOURCE_RESULT
status: ready | needs_user_test | no_source
source_method: reported | file | logPattern | socket | process | needs_user_test | no_source
surface:
reported_activity_plan:
- tool_hook_config_path:
- tool_events:
- stayup_actions:
- hook_commands:
- notes:
candidate_tests:
- file:
- logPattern:
- socket:
- process:
observed_source:
```json
{
  "schema": "app.getstayup.activity-source.v1",
  "name": "Tool Name",
  "displayName": "Tool Name",
  "type": "file",
  "path": "~/path/to/file-or-glob",
  "freshSecs": 45
}
```
evidence:
- idle:
- active:
why_this_means_local_work:
false_positives:
false_negatives:
user_instruction:
If source_method is reported, add hooks to the tool's own hook/config file. Prefer a short source-specific wrapper under ~/.stayup/bin/stayup-source-hook-<source-slug>.sh; each hook should call that wrapper with one simple action: working, not-working, or stop. Advanced mappings may use turn-start, active, waiting, tool-begin, and tool-end only when the tool exposes reliable paired lifecycle events. The wrapper should set and export STAYUP_SOURCE_NAME, STAYUP_SOURCE_SLUG, STAYUP_SOURCE_DISPLAY, STAYUP_SOURCE_KEY, optional STAYUP_SESSION_ID, optional STAYUP_SOURCE_PID if the tool exposes its long-lived process id, and optional STAYUP_SOURCE_TRANSCRIPT_PREFIXES if the hook payload includes a source-owned transcript_path or similar receipt root, then exec ~/.stayup/bin/stayup-source-hook.sh "$@". Also create ~/.stayup/sources/<source-slug>/source.json with schema app.getstayup.activity-source.v1, type reported, method reported, name STAYUP_SOURCE_KEY, and displayName STAYUP_SOURCE_DISPLAY so StayUp can show the source before the first hook fires. If source_method is file, logPattern, socket, or process, save observed_source as ~/.stayup/sources/<source-slug>/source.json. Then open StayUp Settings -> Auto, click Refresh, tick the source, set Mode to Auto, and choose the Nap after grace period.
For Codex CLI / IDE, use the canonical source identity and hook mapping above instead of creating a separate Codex App source.
If no supported source is strong enough, say what support would make it detectable, such as a native heartbeat hook, task-state API, lifecycle log, active-work socket, or parent-scoped child-process tracking.
"""

    // MARK: - Sync

    private func sync() {
        dontDieCheck.state    = Settings.dontDieEnabled ? .on : .off
        let pct = Settings.dontDiePct
        let opts = Self.dontDiePctOptions
        let closest = opts.min(by: { abs($0 - pct) < abs($1 - pct) }) ?? 10
        dontDiePopup.selectItem(withTag: closest)
        if closest != pct { Settings.dontDiePct = closest }   // normalize stale values
        dontDiePopup.isEnabled = Settings.dontDieEnabled

        roastCheck.state      = Settings.roastEnabled ? .on : .off
        loginCheck.state      = (loginIsEnabled?() ?? false) ? .on : .off
        screenLockCheck.state = Settings.virtualDisplayEnabled ? .on : .off
        autoUpdateCheck.state = SparkleUpdater.shared.automaticChecksEnabled ? .on : .off

        // Walk-mode toggle reflects user pref AND hardware probe. On Macs
        // without the SPU accelerometer (Intel, Mac mini, Studio, Pro) we
        // force the checkbox visually OFF and disable interaction — the
        // persisted preference is left untouched so it Just Works if the
        // user later moves their settings to a MacBook.
        let walkHW = WalkDetector.isHardwareAvailable
        walkCheck.isEnabled = walkHW
        walkCheck.state = (walkHW && Settings.walkEnabled) ? .on : .off
        walkHardwareNote.isHidden = walkHW
        roastCheck.isEnabled = walkHW    // roast only fires during a walk → meaningless without hardware

        let activeId = Settings.skinId
        for (i, item) in skinPopUp.itemArray.enumerated() {
            if (item.representedObject as? String) == activeId {
                skinPopUp.selectItem(at: i); break
            }
        }
        syncSources()
        syncHelper()
    }

    /// Reflect auto-mode prefs. The mode segmented control reflects
    /// `autoSourceEnabled`; the grace popup is only live when Auto is selected.
    private func syncSources() {
        guard modeControl != nil else { return }
        modeControl.selectedSegment = currentModeIndex?() ?? (Settings.autoSourceEnabled ? 2 : 0)
        rebuildSourceList()

        let opts = Self.autoGraceOptions.map(\.secs)
        let g = Settings.autoGraceSecs
        let closest = opts.min(by: { abs($0 - g) < abs($1 - g) }) ?? 300
        autoGracePopup.selectItem(withTag: closest)
        if closest != g { Settings.autoGraceSecs = closest }   // normalize stale values
        autoGracePopup.isEnabled = Settings.autoSourceEnabled    // grace only matters in Auto
    }

    private func syncHelper() {
        let sleepDisabled = StayUpHelper.shared.sleepDisabledLiveState()
        switch StayUpHelper.shared.status {
        case .enabled:
            if sleepDisabled == true {
                helperStatus.stringValue = "Ready — holding sleep off right now."
            } else {
                helperStatus.stringValue = "Ready for lid-closed battery mode."
            }
            helperStatus.textColor   = .systemGreen
            helperButton.title       = "Uninstall Helper"
        case .requiresApproval:
            helperStatus.stringValue = "Approve in Login Items."
            helperStatus.textColor   = .systemOrange
            helperButton.title       = "Open System Settings"
        case .notRegistered, .notFound:
            helperStatus.stringValue = "Not set up."
            helperStatus.textColor   = .secondaryLabelColor
            helperButton.title       = "Set up"
        @unknown default:
            helperStatus.stringValue = "Unknown"
            helperStatus.textColor   = .secondaryLabelColor
            helperButton.title       = "Set up"
        }
        syncLayersBanner()
    }

    /// Honest layer count at the top of General. The four in-app layers are
    /// always available; the Helper is the one that can be missing — and it's
    /// the one that owns the lid-closed-on-battery promise.
    private func syncLayersBanner() {
        guard layersBanner != nil else { return }
        if StayUpHelper.shared.status == .enabled {
            layersBanner.stringValue = "● All 5 layers ready — lid-closed battery covered."
            layersBanner.textColor   = .systemGreen
        } else {
            layersBanner.stringValue = "● 4 of 5 layers — set up the Helper below for the lid-closed battery case."
            layersBanner.textColor   = .systemOrange
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard helperStatus != nil else { return }
        syncSources()
        syncHelper()
    }

    // MARK: - Actions

    @objc private func dontDieToggled() {
        Settings.dontDieEnabled = (dontDieCheck.state == .on)
        sync()
        onChange?()
    }
    @objc private func dontDiePopupChanged() {
        let tag = dontDiePopup.selectedItem?.tag ?? 10
        Settings.dontDiePct = tag
        onChange?()
    }
    @objc private func roastChanged() {
        Settings.roastEnabled = (roastCheck.state == .on)
        onChange?()
    }
    @objc private func screenLockToggled() {
        // Checked = keep screen on (no lock). MenuController.reapplyScreenPolicy
        // applies the change live if currently engaged.
        Settings.virtualDisplayEnabled = (screenLockCheck.state == .on)
        onChange?()
    }
    @objc private func walkToggled() {
        Settings.walkEnabled = (walkCheck.state == .on)
        onChange?()
    }
    @objc private func modeChanged() {
        // setMode does the engage/disengage/install + reconcile + warning
        // path shared with the menu.
        setMode?(modeControl.selectedSegment)
        syncSources()
    }
    @objc private func autoGraceChanged() {
        Settings.autoGraceSecs = autoGracePopup.selectedItem?.tag ?? 300
        onChange?()
    }
    @objc private func sourceToggled(_ sender: NSButton) {
        let key = sender.identifier?.rawValue ?? sender.title
        let enabling = sender.state == .on
        if enabling, Settings.autoSourceEnabled,
           let source = ExternalSourceWatcher.configuredSourceInfo().first(where: { $0.key == key }),
           Self.sourceNeedsManagedConnection(source) {
            guard confirmConnectSourceHooks(source) else {
                sender.state = .off
                Settings.setSource(key, enabled: false)
                rebuildSourceList()
                return
            }
            do {
                Settings.setReportedHookConnectionAllowed(true)
                try ActivitySourceHookInstaller.installHooks(for: source.key)
            } catch {
                sender.state = .off
                Settings.setSource(key, enabled: false)
                sourceActionNote.stringValue = "Could not connect \(source.displayName): \(error.localizedDescription) Try Connect again."
                rebuildSourceList()
                return
            }
        }

        Settings.setSource(key, enabled: enabling)
        rebuildSourceList()
        if enabling,
           let source = ExternalSourceWatcher.configuredSourceInfo().first(where: { $0.key == key }),
           ActivitySourceHookInstaller.canManageHooks(for: source.key),
           ActivitySourceHookInstaller.isHookInstalled(for: source.key) {
            sourceActionNote.stringValue = Self.trustNote(for: source)
        }
        onChange?()
    }

    private func confirmConnectSourceHooks(_ source: ExternalSourceWatcher.ConfiguredSourceInfo) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Connect \(source.displayName)?"
        alert.informativeText = Self.connectHookMessage(for: source)
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @objc private func addTrustedSource() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Add Trusted Source"
        alert.informativeText = """
Use this when Auto should watch a local app or tool.

1. Copy the setup prompt.
2. Open a fresh AI assistant session (Claude, ChatGPT, or a coding agent).
3. Paste the prompt and follow its steps.
4. Come back here, click Refresh, tick the new source, then set Mode to Auto.

Duck tip: best sources prove real work. App-open sources are okay if that is what you want.
"""
        alert.addButton(withTitle: "Copy Prompt")
        alert.addButton(withTitle: "Open Folder")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            copySourcePrompt()
        case .alertSecondButtonReturn:
            openSourcesFolder()
        default:
            break
        }
    }

    private func copySourcePrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.sourceSetupPrompt, forType: .string)
        do {
            try ActivitySourceHookInstaller.deployReusableHookScript()
            sourceActionNote.stringValue = "Setup prompt copied. Hook writer is ready."
        } catch {
            sourceActionNote.stringValue = "Setup prompt copied. Could not refresh hook writer: \(error.localizedDescription)"
        }
    }
    @objc private func openSourcesFolder() {
        let url = SourceProvisioner.ensureProvisioned()
        NSWorkspace.shared.open(url)
        sourceActionNote.stringValue = "Opened ~/.stayup."
    }
    @objc private func refreshSourceList() {
        SourceProvisioner.ensureProvisioned()   // Refresh is an explicit re-scaffold point
        rebuildSourceList()
        sourceActionNote.stringValue = "Activity Sources refreshed."
        onChange?()
    }
    @objc private func restoreDefaultSources() {
        SourceProvisioner.restoreBundledDefaults()
        rebuildSourceList()
        sourceActionNote.stringValue = "Default sources restored."
        onChange?()
    }
    @objc private func deleteSource(_ sender: NSButton) {
        guard let slug = sender.identifier?.rawValue,
              let source = sourceDeleteTargets[slug] else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(source.displayName)?"
        var cleanupHooks = false
        if source.isReported {
            let canManageHooks = ActivitySourceHookInstaller.canManageHooks(for: source.key)
            if canManageHooks {
                alert.informativeText = "Disable removes the StayUp source and leaves tool config alone. Clean Up Hooks also removes StayUp entries from the tool config. Neither deletes apps, models, projects, logs, or unrelated config."
                alert.addButton(withTitle: "Disable")
                alert.addButton(withTitle: "Clean Up Hooks")
                alert.addButton(withTitle: "Cancel")
                let response = alert.runModal()
                guard response != .alertThirdButtonReturn else { return }
                cleanupHooks = (response == .alertSecondButtonReturn)
            } else {
                alert.informativeText = "Disable removes the StayUp source and replaces the standard StayUp wrapper with a no-op when possible. It will not edit the tool's own config, apps, models, projects, logs, or unrelated settings."
                alert.addButton(withTitle: "Disable")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        } else {
            alert.informativeText = "This removes its StayUp setup and disables it. It will not delete the app or tool itself."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            try ExternalSourceWatcher.deleteConfiguredSource(source, cleanupHooks: cleanupHooks)
            rebuildSourceList()
            sourceActionNote.stringValue = cleanupHooks
                ? "Deleted \(source.displayName) and cleaned up StayUp hook entries."
                : "Disabled \(source.displayName) in Activity Sources."
            onChange?()
        } catch {
            sourceActionNote.stringValue = "Could not delete \(source.displayName): \(error.localizedDescription)"
        }
    }
    @objc private func connectSourceHooks(_ sender: NSButton) {
        guard let slug = sender.identifier?.rawValue,
              let source = sourceDeleteTargets[slug],
              ActivitySourceHookInstaller.canManageHooks(for: source.key) else { return }

        do {
            Settings.setReportedHookConnectionAllowed(true)
            try ActivitySourceHookInstaller.installHooks(for: source.key)
            rebuildSourceList()
            sourceActionNote.stringValue = Self.connectedHookNote(for: source)
            onChange?()
        } catch {
            sourceActionNote.stringValue = "Could not connect \(source.displayName): \(error.localizedDescription) Try Connect again."
        }
    }
    /// Launch the bundled live tester (tools/stayup.sh) in Terminal. `open -a`
    /// avoids the AppleScript Automation prompt.
    @objc private func launchTester() {
        let url = Bundle.main.url(forResource: "stayup", withExtension: "sh")
            ?? URL(fileURLWithPath: "/Applications/StayUp.app/Contents/Resources/stayup.sh")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Terminal", url.path]
        try? p.run()
    }
    @objc private func loginToggled() {
        loginToggle?(loginCheck.state == .on)
    }
    @objc private func skinChanged() {
        guard let id = skinPopUp.selectedItem?.representedObject as? String else { return }
        Settings.skinId = id
        IconRenderer.invalidateCache()
        onChange?()
    }
    @objc private func reopenWelcome() {
        openWelcome?()
    }
    @objc private func openTipPage() {
        if let url = URL(string: "https://getstayup.app/tip") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func autoUpdateToggled() {
        SparkleUpdater.shared.setAutomaticChecksEnabledFromUserAction(autoUpdateCheck.state == .on)
    }
    @objc private func checkUpdatesNow() {
        SparkleUpdater.shared.checkForUpdatesNow()
    }
    @objc private func helperAction() {
        let helper = StayUpHelper.shared
        switch helper.status {
        case .enabled:
            // Uninstall is destructive — removes the SMAppService.daemon
            // registration entirely. Battery + lid closed coverage stops
            // until the user clicks Set up again. Confirm before doing it.
            let alert = NSAlert()
            alert.messageText     = "Uninstall the Helper?"
            alert.informativeText = "Duck loses its lid-closed-on-battery powers until you set it up again. macOS will ask for approval again on next setup."
            alert.alertStyle      = .warning
            alert.addButton(withTitle: "Uninstall")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            // CRITICAL: restore macOS sleep before unregistering.
            // SMAppService.unregister() stops the daemon; if we kill it
            // before `pmset disablesleep 0` finishes, the system-wide flag
            // can stay stuck on.
            do {
                try helper.prepareForUnregister()
            } catch {
                presentHelperError("Couldn't uninstall the Helper", error)
                return
            }

            do { try helper.unregister() }
            catch { presentHelperError("Couldn't uninstall the Helper", error) }
        case .requiresApproval:
            helper.openLoginItemsPane()
        case .notRegistered, .notFound:
            do { try helper.register() }
            catch { presentHelperError("Couldn't set up the Helper", error) }
            if helper.status == .requiresApproval {
                helper.openLoginItemsPane()
            }
        @unknown default:
            break
        }
        syncHelper()
    }

    private func presentHelperError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle      = .warning
        alert.runModal()
    }
}

private extension NSToolbarItem.Identifier {
    static let stayupGeneral  = NSToolbarItem.Identifier("stayup.settings.general")
    static let stayupAdvanced = NSToolbarItem.Identifier("stayup.settings.advanced")
    static let stayupWalk     = NSToolbarItem.Identifier("stayup.settings.walk")
    static let stayupLook     = NSToolbarItem.Identifier("stayup.settings.look")
    static let stayupAbout    = NSToolbarItem.Identifier("stayup.settings.about")
}
