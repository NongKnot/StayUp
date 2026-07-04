import AppKit
import ServiceManagement
import UserNotifications

/// One button: Stay Up.
/// Engages a five-layer sleep prevention stack:
///   1. caffeinate (-dis -w $PID)
///   2. SleepPreventer (IOKit idle/display assertions + ProcessInfo activity)
///   3. ClosedLidPreventer (IOKit PreventSystemSleep)
///   4. VirtualDisplay (private CGVirtualDisplay)
///   5. StayUpHelper (root daemon → pmset disablesleep)
class MenuController: NSObject, NSMenuDelegate {

    // MARK: - Engines

    private let stack              = SleepStack()
    private let powerSource        = PowerSourceMonitor()
    private let lidMonitor         = LidMonitor()
    private let walkDetector       = WalkDetector()
    private let sourceMonitor       = ActivitySourceMonitor()
    private let externalWatcher    = ExternalSourceWatcher()

    // MARK: - State

    private var statusItem:        NSStatusItem!
    private var menu:              NSMenu!
    private var statusMenuItem:    NSMenuItem!
    private var coverageItem:      NSMenuItem!
    private var offItem:           NSMenuItem!
    private var onItem:            NSMenuItem!
    private var autoItem:          NSMenuItem!
    private var keepScreenItem:    NSMenuItem!
    private var sourcesItem:        NSMenuItem!
    private var sourcesSeparator:   NSMenuItem!
    private var walkStatsMenuItem: NSMenuItem!
    private var walkStatsSeparator: NSMenuItem!
    private var reconnectMenuItem: NSMenuItem!
    private var reconnectSeparator: NSMenuItem!
    /// Set when a launch hook check found an agent's config had drifted and we
    /// re-added our entries. Drives the passive menu-bar reminder. Session-scoped
    /// — clears on the next launch where nothing drifted.
    private var reconnectNotice: String?
    private var settings:          SettingsWindow?
    private var appearanceObserver: NSKeyValueObservation?
    private var welcome:           WelcomeWindow?

    private var active           = false
    private var batteryTimer:    Timer?
    private var dontDieTriggered = false
    private var menuRefreshTimer: Timer?

    /// Why the stack is currently engaged. `.manual` = the user clicked the
    /// Duck (auto mode must never tear that down). `.auto` = the
    /// `ActivitySourceMonitor` raised it (auto may release it when the source
    /// goes idle). Meaningless while `!active`.
    private enum EngageReason { case manual, auto }
    private var engageReason: EngageReason = .manual

    /// Pending auto stand-down. When a source goes idle, auto-mode waits
    /// `Settings.autoGraceSecs` before disengaging (so back-to-back turns don't
    /// sleep/wake-flap). Cancelled if a source gets busy again, or on any
    /// manual engage/disengage.
    private var autoGraceTimer: Timer?
    /// When the auto-grace timer will fire (the Mac naps) — drives the popover
    /// countdown, and is published to `~/.stayup/nap-at` so external tools (the
    /// looker) can show the same countdown.
    private var autoStandDownAt: Date? { didSet { publishStatus() } }

    /// Manual timed-On ("On → For 2 hours"). Duck naps (mode → Off) when it
    /// fires. Cleared by any mode change, disengage, or a plain "On".
    private var manualNapTimer: Timer?
    private var manualNapAt: Date?

    /// Publish the *entire* live state to ~/.stayup/status.json so one external
    /// renderer (tools/stayup.sh, also the About left-eye tester) can show
    /// everything without re-implementing any logic — the app does it all here.
    /// Called on every state change (updateUI), every monitor evaluate, and when
    /// the nap deadline changes.
    func publishStatus() {
        func enabledSourceDisplayNames() -> [String] {
            let namesByKey = Dictionary(
                uniqueKeysWithValues: ExternalSourceWatcher.configuredSourceInfo().map { ($0.key, $0.displayName) }
            )
            return Settings.enabledSources
                .map { namesByKey[$0] ?? "Activity Source" }
                .sorted()
        }
        func word(_ s: ActivitySourceSession) -> String {
            if s.isExternal { return s.working ? "activity seen" : "idle" }
            if s.working    { return s.toolsInFlight > 0 ? "running" : "active" }
            return s.state == "waiting" ? "waiting" : "idle"
        }
        let sessions = sourceMonitor.snapshotSessions().map { s -> [String: Any] in
            let now = Date()
            var d: [String: Any] = ["label": s.terminalLabel, "state": word(s),
                                    "working": s.working, "external": s.isExternal,
                                    "tools": s.toolsInFlight,
                                    "proof": s.proofLabel(now: now),
                                    "lastSeenSecs": max(0, Int(now.timeIntervalSince(s.mtime)))]
            if let signal = s.signal { d["signal"] = signal }
            if let detail = s.detail { d["detail"] = detail }
            if !s.isExternal, let tx = s.transcriptPath,
               let t = ActivitySourceMonitor.tokensUsed(transcriptPath: tx) { d["tokens"] = t }
            return d
        }
        let power: String
        switch powerSource.current { case .ac: power = "ac"; case .battery: power = "battery"; default: power = "unknown" }
        let stackState = stack.snapshot()
        var status: [String: Any] = [
            "ts": Int(Date().timeIntervalSince1970),
            "active": active,
            "mode": ["off", "on", "auto"][currentMode.rawValue],
            "keepScreenOn": Settings.virtualDisplayEnabled,
            "caffeinate": stackState.caffeinate,
            "sleep": stackState.sleepPreventer,
            "lid": stackState.closedLid,
            "virtualDisplay": stackState.virtualDisplay,
            "helper": stackState.helper,
            "power": power,
            "dontDieTriggered": dontDieTriggered,
            "dontDieEnabled": Settings.dontDieEnabled,
            "dontDiePct": Settings.dontDiePct,
            "walking": isWalkingNow,
            "graceSecs": Settings.autoGraceSecs,
            "enabledSources": enabledSourceDisplayNames(),
            "anySourceWorking": sourceMonitor.isAnySourceWorking,
            "sources": sessions,
        ]
        if let sleepDisabled = StayUpHelper.shared.sleepDisabledLiveState() {
            status["sleepDisabled"] = sleepDisabled
        }
        if let pct = powerSource.batteryPercent() { status["batteryPct"] = pct }
        if let lid = lidMonitor.isClosed { status["lidClosed"] = lid }
        if let at = autoStandDownAt ?? manualNapAt { status["napAt"] = Int(at.timeIntervalSince1970) }
        if isWalkingNow, let started = walkDetector.walkStartedAt {
            status["walkSecs"] = Int(Date().timeIntervalSince(started))
            status["walkSteps"] = walkDetector.sessionSteps
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".stayup/status.json")
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
        lastTickPublishAt = Date()
    }

    /// status.json is read only by the external tester (tools/stayup.sh); the
    /// on-screen popover countdown has its own visibility-gated 1s timer and does
    /// not touch this file. So the per-tick monitor evaluate (POLL_SECS=1) doesn't
    /// need to rewrite the file + spawn `ioreg` every second for a tester that's
    /// usually not open. Real state changes call publishStatus() directly and stay
    /// instant; this only throttles the idle per-tick refresh.
    // ponytail: 5s tick floor; drop it if a watcher ever needs sub-5s liveness from the file.
    private var lastTickPublishAt = Date.distantPast
    private func publishStatusThrottled() {
        guard Date().timeIntervalSince(lastTickPublishAt) >= 5 else { return }
        publishStatus()
    }

    /// Periodic self-heal for bundled reported-source hooks. Some tools can
    /// clobber hook entries when they re-save config from stale in-memory state;
    /// this re-asserts them in Auto so the feature can't silently die.
    private var hookHealTimer: Timer?
    private static let HOOK_HEAL_SECS: TimeInterval = 60

    /// Activity Source detection (monitor + watcher + hook heal) runs only in Auto mode.
    private var sourceDetectionOn = false
    /// Live Activity Sources panel, opened from the menu's source row (Auto mode only).
    private lazy var sourcesPopover = ActivitySourcesPopover()

    /// Walk-animation state. When the accelerometer says we're walking the
    /// Duck icon swaps between two stride frames at a fixed cadence; the
    /// `isWalkingNow` flag overrides the on/off icon in `updateUI`.
    private var isWalkingNow:    Bool   = false
    private var walkPhase:       WalkPhase = .leftForward
    private var walkAnimTimer:   Timer?

    /// Stats from the most recently completed walk. Captured on walkStop so
    /// the menu can show "Last: 0:23 · 18 steps" until the next walk.
    private var lastWalkDuration: TimeInterval?
    private var lastWalkSteps:    Int = 0
    private var lastWalkEndedAt:  Date?

    /// One-shot timer that clears the post-walk roast line after the window
    /// elapses. Roast is walk-only now, not a cycling idle/on-state timer.
    private var roastTimer:       Timer?

    // MARK: - Animation state

    /// OFF↔ON tween animation. While running, the icon ignores the
    /// cached on/off variant and renders an interpolated warp each tick.
    private var transitionTimer:    Timer?
    private var transitionStartedAt: Date?
    private var transitionToActive:  Bool = false
    private static let TRANSITION_SECS: TimeInterval = 0.40

    /// ON-state eye blink — shows the blink frame for ~120ms every few
    /// seconds (with a small random jitter so it doesn't feel robotic).
    private var blinkTimer: Timer?
    private var blinkActive = false

    /// OFF-state Zzz drift — cycles through 4 phases (3 Z positions + a
    /// rest/no-Z) so Duck looks like it's slowly snoring.
    private var zzzTimer: Timer?
    private var zzzPhase: Int? = nil   // 0..2 = visible Z, nil = rest beat

    private static let BATTERY_POLL_SECS: TimeInterval = 30.0
    private static let WALK_ANIM_INTERVAL: TimeInterval = 0.25  // 4 fps stride cadence

    /// Set by the test harness via the `STAYUP_TEST=1` env var. When set,
    /// Don't Die logs to stderr instead of opening a modal alert (so signal-
    /// driven tests don't deadlock waiting for a user to click "Got it").
    private static let isTestMode: Bool = {
        ProcessInfo.processInfo.environment["STAYUP_TEST"] != nil
    }()

    // MARK: - Lifecycle

    func setup() {
        // One-shot UserDefaults migration from the old `com.stayup.app`
        // bundle ID. Must run before anything reads Settings.
        Settings.migrateLegacyDefaultsIfNeeded()
        _ = ExternalSourceWatcher.ensureStayUpFolder()

        // Defensive: clear any leftover sleep-prevention state (esp. the helper's
        // system-wide `pmset disablesleep 1`) from a prior session that crashed
        // or was force-killed while engaged.
        stack.shutdown()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.image = IconRenderer.icon(active: false)
        statusItem.button?.toolTip = "StayUp — click for menu"

        buildMenu()

        // Both clicks open the menu (the conventional menu-bar behavior).
        // Assigning `statusItem.menu` lets macOS handle left- and right-clicks
        // uniformly; mode + on/off + keep-screen-on all live in the dropdown.
        statusItem.menu = menu

        powerSource.start()
        powerSource.onChange = { [weak self] src in self?.handlePowerSourceChange(src) }

        // Lid watcher — the virtual display is lid-gated (spawns when the lid
        // shuts, stands down when it opens). No-op on Macs without a lid.
        lidMonitor.start()
        lidMonitor.onChange = { [weak self] _ in
            guard let self else { return }
            self.reapplyScreenPolicy()
            self.publishStatus()
        }

        // Walk detector wiring — but don't start the accelerometer yet.
        // The hardware only powers on when the user engages Stay Up. No
        // point burning ~14 Hz of HID callbacks while StayUp is idle.
        walkDetector.onWalkStart = { [weak self] in self?.startWalkAnimation() }
        walkDetector.onWalkStop  = { [weak self] in self?.stopWalkAnimation() }

        // Activity Source wiring. Detection (monitor + external watcher + hook
        // self-heal) runs ONLY in Auto mode — there's nothing to act on in Off/
        // On, so we don't poll the filesystem or watch hooks there. start/stop
        // follow the Auto toggle (setAutoMode); kick it off now if already on.
        sourceMonitor.onChange = { [weak self] working in
            self?.handleActivitySourceChange(working)
        }
        sourceMonitor.onEvaluate = { [weak self] in self?.publishStatusThrottled() }   // live status file
        if Settings.autoSourceEnabled { startSourceDetection() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.stack.refresh()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.handleDisplayChange() }

        // KVO on the app's effective appearance so Duck redraws when the
        // user flips light↔dark mode (or schedules an automatic transition
        // at sunset). The IconRenderer caches render output by state, so we
        // invalidate the cache before re-drawing. NSApp.effectiveAppearance
        // is the documented KVO-compliant source for this signal.
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            IconRenderer.invalidateCache()
            DispatchQueue.main.async { self?.updateUI() }
        }

        updateUI()

        // Restore prior engaged state if the user was on when they last quit.
        // The defensive `helper.disable()` at the top of setup() already
        // cleared stale daemon state, so engage() here re-arms cleanly.
        if Settings.resumeOnLaunch && Settings.wasActive && !Settings.autoSourceEnabled {
            engage()
        } else {
            // Idle OFF — start the Zzz animation so Duck looks asleep.
            startZzzAnimation()
        }
    }

    func cleanup() {
        stopSourceDetection()
        cancelAutoGrace()
        batteryTimer?.invalidate()
        batteryTimer = nil
        stopMenuRefreshTimer()
        walkAnimTimer?.invalidate()
        walkAnimTimer = nil
        roastTimer?.invalidate()
        roastTimer = nil
        transitionTimer?.invalidate()
        transitionTimer = nil
        blinkTimer?.invalidate()
        blinkTimer = nil
        zzzTimer?.invalidate()
        zzzTimer = nil
        stack.shutdown()
        walkDetector.stop()
        powerSource.stop()
        lidMonitor.stop()
        active = false
        isWalkingNow = false
    }

    // MARK: - Menu

    private func buildMenu() {
        menu = NSMenu()
        menu.delegate = self
        // We manage isEnabled ourselves. Auto-enable would disable any item
        // without a click action — including the "Working in N places" parent,
        // which must stay enabled or macOS won't open its submenu on hover.
        menu.autoenablesItems = false

        statusMenuItem = NSMenuItem(title: "STAYUP · IDLE", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Honesty line: engaged on battery without the Helper means the
        // lid-closed promise does NOT hold. Say so instead of looking safe.
        // Click-through opens Settings → General (where Helper setup lives).
        coverageItem = NSMenuItem(title: "", action: #selector(showSettings), keyEquivalent: "")
        coverageItem.target = self
        coverageItem.isHidden = true
        menu.addItem(coverageItem)
        menu.addItem(.separator())

        // Hook-reconnect reminder — hidden until a launch check finds an agent's
        // config dropped our activity hook and we re-added it. Passive backstop
        // (paired with a one-shot notification) so the user still sees it later.
        reconnectMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        reconnectMenuItem.isEnabled = false
        reconnectMenuItem.isHidden  = true
        menu.addItem(reconnectMenuItem)
        reconnectSeparator = .separator()
        reconnectSeparator.isHidden = true
        menu.addItem(reconnectSeparator)

        // Mode — Off / On / Auto tri-state. Exactly one is checked (set in
        // updateUI from currentMode); each routes through setMode.
        //   Off  = let the Mac sleep.   On = stay awake now (manual).
        //   Auto = stay awake only while selected Activity Sources work.
        offItem  = NSMenuItem(title: "Off",  action: #selector(selectOff),  keyEquivalent: "")
        onItem   = NSMenuItem(title: "On",   action: #selector(selectOn),   keyEquivalent: "")
        autoItem = NSMenuItem(title: "Auto", action: #selector(selectAuto), keyEquivalent: "")
        for it in [offItem, onItem, autoItem] { it?.target = self; menu.addItem(it!) }

        // Optional timer submenu on On. macOS doesn't fire a parent item's
        // action once it has a submenu, so "Until you turn it off" is the
        // plain-On entry.
        let onSub = NSMenu()
        onSub.autoenablesItems = false
        let untilOff = NSMenuItem(title: "Until you turn it off", action: #selector(selectOn), keyEquivalent: "")
        untilOff.target = self
        onSub.addItem(untilOff)
        onSub.addItem(.separator())
        for (title, secs) in [("For 1 hour", 3600), ("For 2 hours", 7200),
                              ("For 4 hours", 14400), ("For 8 hours", 28800)] {
            let it = NSMenuItem(title: title, action: #selector(selectOnTimed(_:)), keyEquivalent: "")
            it.target = self
            it.tag = secs
            onSub.addItem(it)
        }
        onItem.submenu = onSub
        menu.addItem(.separator())

        // Keep screen on (vs let the Mac lock). Mirrors Settings → General.
        keepScreenItem = NSMenuItem(title: "Keep screen on", action: #selector(toggleKeepScreen), keyEquivalent: "")
        keepScreenItem.target = self
        menu.addItem(keepScreenItem)
        menu.addItem(.separator())

        // Activity Sources — visible in Auto mode as a compact submenu. It shows
        // which local sources are protecting the Mac, waiting, or merely
        // visible, plus the grace countdown when Auto is about to release.
        sourcesItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sourcesItem.isEnabled = false
        sourcesItem.isHidden  = true
        menu.addItem(sourcesItem)
        sourcesSeparator = .separator()
        sourcesSeparator.isHidden = true
        menu.addItem(sourcesSeparator)

        // Walk stats — hidden until the user has walked at least once,
        // then shows live "🚶 0:23 · 18 steps" while walking and
        // "Last: 0:23 · 18 steps" once they stop.
        walkStatsMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        walkStatsMenuItem.isEnabled = false
        walkStatsMenuItem.isHidden  = true
        menu.addItem(walkStatsMenuItem)
        walkStatsSeparator = .separator()
        walkStatsSeparator.isHidden = true
        menu.addItem(walkStatsSeparator)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: "Quit StayUp", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateUI()
        startMenuRefreshTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopMenuRefreshTimer()
    }

    private func startMenuRefreshTimer() {
        stopMenuRefreshTimer()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.autoStandDownAt != nil || self.manualNapAt != nil || self.isWalkingNow else { return }
            self.updateMenuLiveText()
        }
        RunLoop.main.add(t, forMode: .common)
        menuRefreshTimer = t
    }

    private func stopMenuRefreshTimer() {
        menuRefreshTimer?.invalidate()
        menuRefreshTimer = nil
    }

    /// While the dropdown is open, update only text that naturally counts down.
    /// Rebuilding the whole menu each second also rebuilds submenus, which makes
    /// hover state and countdown text feel jittery.
    private func updateMenuLiveText() {
        updateStatusLine()
        updateWalkStatsItem()
        updateSourcesItem(rebuildSubmenu: false)
        publishStatus()
    }

    // MARK: - Mode + toggle

    /// Switch Auto on/off from anywhere (menu or Settings). Starts/stops the
    /// Activity Source machinery, persists the flag, and reconciles the stack.
    func setAutoMode(_ enabled: Bool) {
        if enabled {
            let hookInstallError = connectReportedHooksForAutoIfAllowed()
            Settings.autoSourceEnabled = true
            startSourceDetection()
            if let hookInstallError {
                presentHookWarning(hookInstallError)
            }
        } else {
            Settings.autoSourceEnabled = false
            stopSourceDetection()
            try? ActivitySourceHookInstaller.uninstall()
        }
        reconcileAutoMode()
        updateUI()
        publishStatus()
    }

    private func connectReportedHooksForAutoIfAllowed() -> Error? {
        let missing = ActivitySourceHookInstaller.missingHookDisplayNames(onlyEnabled: true)
        if missing.isEmpty {
            Settings.setReportedHookConnectionAllowed(true)
            return nil
        }

        if !Settings.reportedHookConsentKnown {
            guard confirmReportedHookConnection(for: missing) else {
                Settings.setReportedHookConnectionAllowed(false)
                return nil
            }
            Settings.setReportedHookConnectionAllowed(true)
        }

        guard Settings.reportedHookConnectionAllowed else { return nil }

        do {
            try ActivitySourceHookInstaller.install(onlyEnabled: true)
            return nil
        } catch {
            return error
        }
    }

    private func confirmReportedHookConnection(for names: [String]) -> Bool {
        if Self.isTestMode { return false }
        let a = NSAlert()
        a.messageText = names.count == 1
            ? "Connect \(names[0])?"
            : "Connect trusted sources?"
        a.informativeText =
            "StayUp can add its own hook entries so Auto knows when these tools are working. Existing config is preserved, a .stayup.bak backup is made before edits, and cleanup removes only StayUp entries."
        a.alertStyle = .informational
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Start Activity Source detection — only run in Auto mode. Idempotent.
    /// Off/On do zero filesystem polling / hook watching, so the source monitor
    /// costs nothing when you're not using Auto.
    private func startSourceDetection() {
        guard !sourceDetectionOn else { return }
        sourceDetectionOn = true
        sourceMonitor.start()
        externalWatcher.start()
        if ActivitySourceHookInstaller.isInstalled(onlyEnabled: true) {
            Settings.setReportedHookConnectionAllowed(true)
        }
        ActivitySourceHookInstaller.redeployScriptIfNeeded()   // ship script updates from app upgrades
        let reconnected = ActivitySourceHookInstaller.repairIfNeeded()
        if !reconnected.isEmpty { reportHookReconnect(reconnected) }
        // Periodic self-heal stays silent — the reminder is a launch-time check;
        // mid-session drift gets re-asserted here and surfaced on the next launch.
        let t = Timer(timeInterval: Self.HOOK_HEAL_SECS, repeats: true) { _ in
            ActivitySourceHookInstaller.repairIfNeeded()
        }
        RunLoop.main.add(t, forMode: .common)
        hookHealTimer = t
    }

    private func stopSourceDetection() {
        guard sourceDetectionOn else { return }
        sourceDetectionOn = false
        sourceMonitor.stop()
        externalWatcher.stop()
        hookHealTimer?.invalidate(); hookHealTimer = nil
        if sourcesPopover.isShown { sourcesPopover.close() }
    }

    /// A launch check found these agents had dropped StayUp's activity hook (config
    /// drift) and we re-added it. Remind the user: a one-shot notification (in case
    /// the menu is closed) plus a passive menu line that lingers for the session.
    private func reportHookReconnect(_ names: [String]) {
        let joined = names.joined(separator: ", ")
        reconnectNotice = names.count == 1
            ? "Reconnected \(joined) — config had changed"
            : "Reconnected \(joined) — configs had changed"
        updateUI()
        notifyHookReconnect(names)
    }

    private func notifyHookReconnect(_ names: [String]) {
        if Self.isTestMode { return }
        let joined = names.joined(separator: ", ")
        let center = UNUserNotificationCenter.current()
        // Authorization is requested lazily — only the first time an agent actually
        // drifts, so most users never see the prompt. Cached after the first ask.
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }   // declined → the menu line still carries it
            let content = UNMutableNotificationContent()
            content.title = names.count == 1 ? "Reconnected \(joined)" : "Reconnected your AI sources"
            content.body = names.count == 1
                ? "\(joined)’s config had changed and dropped StayUp’s activity hook. Duck re-added it so Auto keeps working."
                : "\(joined) changed their configs and dropped StayUp’s activity hooks. Duck re-added them so Auto keeps working."
            let req = UNNotificationRequest(
                identifier: "stayup.hookReconnect", content: content, trigger: nil)
            center.add(req)
        }
    }

    @objc private func showActivitySourcesPopover() {
        guard let button = statusItem.button else { return }
        sourcesPopover.sessionsProvider = { [weak self] in self?.sourceMonitor.snapshotSessions() ?? [] }
        sourcesPopover.napCountdownProvider = { [weak self] in
            guard let at = self?.autoStandDownAt else { return nil }
            let secs = at.timeIntervalSinceNow
            return secs > 0 ? secs : nil
        }
        sourcesPopover.show(relativeTo: button)
    }

    private func presentHookWarning(_ error: Error) {
        if Self.isTestMode { return }
        let a = NSAlert()
        a.messageText     = "Auto is on, but source connection failed"
        a.informativeText = "StayUp is still watching observed Activity Sources like model servers and app workflow signals. Reported CLI sources may not report activity until the hook connection succeeds.\n\nTry again from Settings → Auto → Connect.\n\n\(error.localizedDescription)"
        a.alertStyle      = .warning
        a.addButton(withTitle: "Got it")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// The one user-facing control. `index` maps to the Settings segmented control.
    enum Mode: Int { case off = 0, on = 1, auto = 2
        init(index: Int) { self = Mode(rawValue: index) ?? .off }
        var index: Int { rawValue }
    }

    /// Derived from live state. In Auto+idle this is `.auto` even though the
    /// stack is down (the icon shows the real engagement; this is the intent).
    var currentMode: Mode { Settings.autoSourceEnabled ? .auto : (active ? .on : .off) }

    /// Apply a mode (from the menu radios or the Settings segmented control).
    /// Built on the existing engage/disengage/setAutoMode seam.
    func setMode(_ mode: Mode) {
        cancelManualNap()   // any explicit mode choice resets a pending timed-On
        switch mode {
        case .off:
            setAutoMode(false)              // manual Off exits Auto
            if active { disengage() }
            Settings.wasActive = false
        case .on:
            setAutoMode(false)              // manual On exits Auto
            if !active { engage(reason: .manual) }
        case .auto:
            let wasManualActive = active && engageReason == .manual
            setAutoMode(true)               // install hooks + reconcile (engages if busy)
            if wasManualActive {
                Settings.wasActive = false
                if sourceMonitor.isAnySourceWorking {
                    engageReason = .auto
                    reconcileAutoMode()
                } else {
                    disengage()
                }
            }
        }
        updateUI()
    }

    @objc private func selectOff()  { setMode(.off) }
    @objc private func selectOn()   { setMode(.on) }
    @objc private func selectAuto() { setMode(.auto) }

    /// "On → For N hours". Plain On, plus a one-shot nap timer.
    @objc private func selectOnTimed(_ sender: NSMenuItem) {
        setMode(.on)
        scheduleManualNap(TimeInterval(sender.tag))
        updateUI()
    }

    private func scheduleManualNap(_ secs: TimeInterval) {
        cancelManualNap()
        manualNapAt = Date(timeIntervalSinceNow: secs)
        let t = Timer(timeInterval: secs, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.manualNapTimer = nil
            self.manualNapAt = nil
            guard self.active, self.engageReason == .manual else { return }
            self.setMode(.off)
        }
        RunLoop.main.add(t, forMode: .common)
        manualNapTimer = t
        publishStatus()
    }

    private func cancelManualNap() {
        manualNapTimer?.invalidate()
        manualNapTimer = nil
        manualNapAt = nil
    }

    @objc private func toggleKeepScreen() {
        Settings.virtualDisplayEnabled.toggle()
        reapplyScreenPolicy()
        updateUI()
        publishStatus()
    }

    // MARK: - Engage / disengage

    private func engage(reason: EngageReason = .manual) {
        guard !active else { return }
        engageReason = reason
        cancelAutoGrace()
        // When the user opts to let the screen lock, we still hold the *system*
        // awake for background work but drop the display-keep-awake layers
        // — display-sleep assertion, caffeinate -d, and the virtual display —
        // so macOS can lock and show the login screen. See Settings → General.
        stack.apply(engaged: true,
                    keepScreenOn: Settings.virtualDisplayEnabled,
                    hasExternalDisplay: hasRealExternalDisplay,
                    lidClosed: lidMonitor.isClosed ?? true)
        active = true
        Settings.wasActive = (reason == .manual)
        playClick()
        startBatteryMonitor()    // poll battery only while engaged
        if Settings.walkEnabled {
            walkDetector.start()  // accelerometer only while engaged + opted in
        }
        // OFF→ON tween, then blink loop. Zzz stops here; the transition
        // tick clears the zzz icon naturally.
        stopZzzAnimation()
        startTransition(toActive: true)
        updateUI()
        publishStatus()
    }

    /// Bring the WalkDetector state in line with `Settings.walkEnabled`
    /// while the app is already engaged. Called when the Walk-mode toggle
    /// flips in the Settings panel so users see the change immediately
    /// instead of having to disengage+engage StayUp. No-op when StayUp is
    /// idle (the detector only runs while engaged anyway) or when the
    /// state is already correct.
    private func reconcileWalkDetector() {
        guard active else { return }
        if Settings.walkEnabled {
            walkDetector.start()
        } else {
            walkDetector.stop()
        }
    }

    private func disengage() {
        guard active else { return }
        cancelAutoGrace()
        cancelManualNap()
        active = false
        Settings.wasActive = false
        stack.apply(engaged: false, keepScreenOn: false, hasExternalDisplay: false,
                    lidClosed: lidMonitor.isClosed ?? true)
        stopBatteryMonitor()
        // Powering off the accelerometer also fires onWalkStop if we were
        // mid-walk, which clears `isWalkingNow` and the icon animation.
        walkDetector.stop()
        // ON→OFF tween, then Zzz loop.
        stopBlinkAnimation()
        startTransition(toActive: false)
        updateUI()
        publishStatus()
    }

    private func playClick() {
        let s = NSSound(named: "Tink")
        s?.volume = 0.35
        s?.play()
    }

    // MARK: - Display change

    /// True when a non-virtual, non-built-in display is attached. The virtual
    /// display only exists to mimic an external; if a real one is present it
    /// can stand down.
    private var hasRealExternalDisplay: Bool {
        let displayKey = NSDeviceDescriptionKey("NSScreenNumber")
        for screen in NSScreen.screens {
            if screen.localizedName == "StayUp Display" { continue }
            guard let id = screen.deviceDescription[displayKey] as? CGDirectDisplayID else { continue }
            if CGDisplayIsBuiltin(id) == 0 { return true }
        }
        return false
    }

    private func handleDisplayChange() {
        guard active else { return }
        guard Settings.virtualDisplayEnabled else { return }  // screen-lock mode: no virtual display
        // Debounce: the screen list churns during transient reshuffles. Re-apply
        // the current desired state — the planner adds/drops only the virtual
        // display as the real-external presence changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.active else { return }
            self.stack.apply(engaged: true,
                             keepScreenOn: Settings.virtualDisplayEnabled,
                             hasExternalDisplay: self.hasRealExternalDisplay,
                             lidClosed: self.lidMonitor.isClosed ?? true)
        }
    }

    // MARK: - Power source

    private func handlePowerSourceChange(_ source: PowerSourceMonitor.Source) {
        if source == .ac { dontDieTriggered = false }
        updateUI()
    }

    // MARK: - Auto mode (Activity Sources)
    //
    // When `Settings.autoSourceEnabled`, `ActivitySourceMonitor` drives engage/
    // disengage off the `~/.stayup/sources/*/active` contract folders. The callback always runs; the policy
    // below decides how the signal interacts with manual intent and Don't Die.

    private func handleActivitySourceChange(_ working: Bool) {
        guard Settings.autoSourceEnabled else {
            // Defensive: detection is normally stopped outside Auto, and any
            // late signal must never move the stack.
            updateUI()
            return
        }
        reconcileAutoEngage(working: working)
        updateUI()
    }

    /// Auto-mode reconciliation policy.
    ///
    ///   • **Manual mode wins.** Choosing Off or On exits Auto entirely; Auto
    ///     only moves the stack while the selected mode is Auto.
    ///   • **Don't Die wins on battery.** If the low-battery cutout has already
    ///     fired, auto must not re-engage, or it would defeat the cutout and
    ///     drain the battery to zero. The flag resets on return to AC.
    private func reconcileAutoEngage(working: Bool) {
        if working {
            cancelAutoGrace()                               // source is busy again — don't stand down
            guard !active else { return }                   // already up — leave it
            guard !dontDieTriggered else { return }         // low-battery cutout active
            engage(reason: .auto)
        } else {
            guard active, engageReason == .auto else { return }  // only release what auto raised
            scheduleAutoStandDown()
        }
    }

    /// Stand down after the user-configured grace period, unless a source gets
    /// busy again (which cancels the timer) or the conditions change by the
    /// time it fires. A grace of 0 stands down immediately.
    private func scheduleAutoStandDown() {
        cancelAutoGrace()
        let grace = max(0, Settings.autoGraceSecs)
        guard grace > 0 else { disengage(); return }
        autoStandDownAt = Date(timeIntervalSinceNow: TimeInterval(grace))   // for the popover countdown
        let t = Timer(timeInterval: TimeInterval(grace), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.autoGraceTimer = nil
            self.autoStandDownAt = nil
            // Re-check at fire time: only stand down if still auto-engaged and
            // the source is still idle.
            guard self.active, self.engageReason == .auto,
                  !self.sourceMonitor.isAnySourceWorking else { return }
            self.disengage()
        }
        RunLoop.main.add(t, forMode: .common)
        autoGraceTimer = t
    }

    private func cancelAutoGrace() {
        autoGraceTimer?.invalidate()
        autoGraceTimer = nil
        autoStandDownAt = nil
    }

    /// Apply a mid-engage change to the screen-lock / virtual-display policy
    /// without a full teardown + animation. Re-arms only the display-related
    /// layers (caffeinate flags, the display-sleep assertion, the virtual
    /// display); the system-sleep + closed-lid + helper layers keep holding.
    /// No-op when idle or when the policy hasn't actually changed.
    private func reapplyScreenPolicy() {
        guard active else { return }
        // The planner diffs against the live state, so an unchanged policy is a
        // no-op and a keepScreenOn or lid flip re-arms exactly the display layers.
        stack.apply(engaged: true,
                    keepScreenOn: Settings.virtualDisplayEnabled,
                    hasExternalDisplay: hasRealExternalDisplay,
                    lidClosed: lidMonitor.isClosed ?? true)
    }

    /// Called from Settings `onChange` when the auto-mode toggle or
    /// grace value may have changed. Brings the live state in line immediately
    /// instead of waiting for the next source-activity edge.
    private func reconcileAutoMode() {
        if Settings.autoSourceEnabled {
            reconcileAutoEngage(working: sourceMonitor.isAnySourceWorking)
        } else {
            // Auto mode turned off: drop any pending stand-down and release the
            // stack if auto is what raised it. A manual engage is left alone.
            cancelAutoGrace()
            if active, engageReason == .auto { disengage() }
        }
    }

    // MARK: - Don't Die
    //
    // Polled only while engaged. When StayUp isn't holding any sleep
    // prevention, there's nothing for Don't Die to undo, and macOS already
    // shows its own low-battery alert.

    private func startBatteryMonitor() {
        batteryTimer?.invalidate()
        // Eager check so a launch-while-already-low-on-battery fires
        // immediately instead of waiting up to one poll interval.
        checkBattery()
        let t = Timer(timeInterval: Self.BATTERY_POLL_SECS, repeats: true) { [weak self] _ in
            self?.checkBattery()
        }
        RunLoop.main.add(t, forMode: .common)
        batteryTimer = t
    }

    private func stopBatteryMonitor() {
        batteryTimer?.invalidate()
        batteryTimer = nil
    }

    private func checkBattery() {
        guard active, Settings.dontDieEnabled else { return }
        let onBattery = (powerSource.current == .battery)
        if !onBattery { dontDieTriggered = false; return }
        guard !dontDieTriggered else { return }
        let pct = powerSource.batteryPercent() ?? 100
        guard pct <= Settings.dontDiePct else { return }

        dontDieTriggered = true
        disengage()
        updateUI()
        showDontDieAlert(pct: pct)
    }

    private func showDontDieAlert(pct: Int) {
        if Self.isTestMode {
            // Self-tests skip the modal; signal handlers run on the main queue
            // and a runModal() would block them.
            FileHandle.standardError.write(Data(
                "[StayUp][TEST] Don't Die fired at \(pct)%; disengaged.\n".utf8))
            return
        }
        let alert = NSAlert()
        alert.messageText     = "Don't Die"
        alert.informativeText = "Battery at \(pct)%. StayUp turned itself off — plug in your charger."
        alert.alertStyle      = .critical
        alert.addButton(withTitle: "Got it")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// First-launch onboarding. Surfaces Launch-at-Login, Helper setup,
    /// and Sparkle auto-update in a single window so users actually see
    /// the battery+lid coverage path (Helper) instead of hunting for it
    /// in Settings. No-op if the user has already onboarded.
    /// Called from `AppDelegate.applicationDidFinishLaunching` after
    /// `setup()` and `migrateLegacyLaunchAgentIfNeeded()`.
    func showWelcomeIfNeeded() {
        guard !Settings.didOnboard else { return }
        showWelcome()
    }

    /// Force-open the welcome window. Wired to the low-key "Show welcome
    /// screen" entry at the bottom of Settings → About so users who
    /// dismissed onboarding can re-open it without resetting state.
    func showWelcome() {
        let w = WelcomeWindow()
        w.loginToggle = { [weak self] (desired: Bool) in
            guard let self else { return }
            let currently = self.isLaunchAtLoginEnabled()
            if desired && !currently { self.enableLaunchAtLogin() }
            else if !desired && currently { self.disableLaunchAtLogin() }
        }
        w.loginIsEnabled = { [weak self] in self?.isLaunchAtLoginEnabled() ?? false }
        w.turnOn    = { [weak self] in self?.setMode(.on) }
        w.isEngaged = { [weak self] in self?.active ?? false }
        w.onDismiss = { [weak self] in self?.updateUI() }
        welcome = w
        w.show()
    }

    @objc private func showSettings() {
        if settings == nil {
            let s = SettingsWindow()
            s.onChange = { [weak self] in
                self?.reconcileWalkDetector()
                self?.reconcileAutoMode()
                self?.reapplyScreenPolicy()
                self?.updateUI()
            }
            s.loginIsEnabled = { [weak self] in self?.isLaunchAtLoginEnabled() ?? false }
            s.loginToggle = { [weak self] desired in
                guard let self else { return }
                let currently = self.isLaunchAtLoginEnabled()
                if desired && !currently { self.enableLaunchAtLogin() }
                else if !desired && currently { self.disableLaunchAtLogin() }
                self.updateUI()
            }
            s.openWelcome = { [weak self] in self?.showWelcome() }
            s.setMode = { [weak self] idx in self?.setMode(Mode(index: idx)) }
            s.currentModeIndex = { [weak self] in self?.currentMode.index ?? 0 }
            settings = s
        }
        settings?.show()
    }

    // MARK: - Roast text
    //
    // Duck commentary next to the menu-bar icon. Walk-only: live commentary
    // while you're moving, a parting line for a few seconds after you stop,
    // otherwise silent. Idle/on roasts felt like noise during normal desk work.

    private static let postWalkRoastWindow: TimeInterval = 5

    private func currentRoast() -> String? {
        guard Settings.roastEnabled else { return nil }

        if isWalkingNow, let started = walkDetector.walkStartedAt {
            let secs  = Int(Date().timeIntervalSince(started))
            let steps = walkDetector.sessionSteps
            if steps == 0 && secs < 3      { return "..." }
            if steps == 0                  { return "you faking?" }
            if steps < 5                   { return "barely a step" }
            if steps < 20                  { return "look at you go" }
            if steps < 60                  { return "moving moving" }
            return "real walk huh"
        }

        if let endedAt = lastWalkEndedAt,
           Date().timeIntervalSince(endedAt) < Self.postWalkRoastWindow {
            if lastWalkSteps == 0          { return "that wasn't a walk" }
            if lastWalkSteps < 5           { return "lol \(lastWalkSteps) steps" }
            if lastWalkSteps < 20          { return "okay champ" }
            if lastWalkSteps < 60          { return "decent walk" }
            return "respectable"
        }

        return nil
    }

    /// One-shot timer that hides the post-walk roast once the 5s window
    /// elapses. Without this the line would linger in the bar until the
    /// next walk event since nothing else triggers a UI refresh.
    private func schedulePostWalkRoastClear() {
        roastTimer?.invalidate()
        let t = Timer(timeInterval: Self.postWalkRoastWindow + 1, repeats: false) { [weak self] _ in
            self?.updateUI()
        }
        RunLoop.main.add(t, forMode: .common)
        roastTimer = t
    }

    // MARK: - Launch at Login
    //
    // Registered via `SMAppService.mainApp` so macOS surfaces the entry in
    // System Settings → General → Login Items & Extensions under the
    // "Open at Login" section, labeled with the app name + icon. The earlier
    // path (hand-written `~/Library/LaunchAgents/app.getstayup.plist` +
    // `launchctl bootstrap`) registered as a legacy launch agent, which macOS
    // groups under the code-signing developer name in the Background Activity
    // section — surfacing the cert holder's personal name to every user.
    // `mainApp` shares a parent record with the `SMAppService.daemon` helper,
    // so all StayUp registrations group under a single "StayUp" identity.

    private let loginItemService = SMAppService.mainApp

    /// True when StayUp will (or already does) launch at login through any
    /// of the three state sources we trust: the modern SMAppService.mainApp
    /// registration in either `.enabled` or `.requiresApproval` state, or
    /// the legacy LaunchAgent plist if a pre-public install still has it. The
    /// `.requiresApproval` case is rare for mainApp (Developer-ID apps
    /// typically land at `.enabled` directly) but reachable if the user
    /// manually removed the entry from Settings → Background Activity, so
    /// reflect intent rather than effective state. The legacy fallback
    /// matters during migration-failure windows: if `register()` throws
    /// during migration, the legacy plist stays in place and is the actual
    /// source of truth until the next retry — without this check the
    /// Settings UI would lie ("OFF" while the app launches at login).
    private func isLaunchAtLoginEnabled() -> Bool {
        switch loginItemService.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            let legacy = "\(NSHomeDirectory())/Library/LaunchAgents/app.getstayup.plist"
            return FileManager.default.fileExists(atPath: legacy)
        @unknown default:
            return false
        }
    }

    /// Register first so a `register()` failure doesn't leave the user
    /// with no Launch at Login at all (mirrors the migration ordering).
    /// On success, tear down any leftover legacy registration.
    private func enableLaunchAtLogin() {
        do {
            try loginItemService.register()
        } catch {
            FileHandle.standardError.write(Data(
                "[StayUp] enableLaunchAtLogin register() failed: \(error)\n".utf8))
            return
        }
        removeLegacyLaunchAgent()
    }

    /// Order is intentional: tear down the modern registration first, then
    /// the legacy artifacts. `unregister()` throws `.notRegistered` benignly
    /// when mainApp wasn't registered (e.g. user upgraded from a legacy build and the
    /// migration register failed, so legacy is the live registration). Log
    /// real failures to stderr; cleanup runs unconditionally so the legacy
    /// plist also goes away.
    private func disableLaunchAtLogin() {
        do {
            try loginItemService.unregister()
        } catch {
            FileHandle.standardError.write(Data(
                "[StayUp] disableLaunchAtLogin unregister() failed: \(error)\n".utf8))
        }
        removeLegacyLaunchAgent()
    }

    /// Idempotent cleanup of the pre-migration LaunchAgent + the very-old
    /// `com.stayup.app` label from before the `app.getstayup` bundle rename.
    /// `bootout` returns non-zero if the service isn't loaded; `removeItem`
    /// no-ops on missing files — both safe to call on already-clean systems.
    private func removeLegacyLaunchAgent() {
        runLaunchctl(["bootout", "gui/\(getuid())/app.getstayup"])
        runLaunchctl(["bootout", "gui/\(getuid())/com.stayup.app"])
        let home = NSHomeDirectory()
        try? FileManager.default.removeItem(
            atPath: "\(home)/Library/LaunchAgents/app.getstayup.plist")
        try? FileManager.default.removeItem(
            atPath: "\(home)/Library/LaunchAgents/com.stayup.app.plist")
    }

    /// One-shot migration for installs that registered Launch at Login via
    /// the pre-public LaunchAgent path. Presence of the legacy plist means the
    /// user previously had Launch at Login ON (the old install path was the
    /// only writer), so register the modern `mainApp` service first to
    /// preserve that preference, and only then tear down the legacy
    /// artifacts. If register fails, keep the legacy plist in place so the
    /// user doesn't silently lose Launch at Login — we'll retry next launch.
    /// Called once from `AppDelegate.applicationDidFinishLaunching`.
    func migrateLegacyLaunchAgentIfNeeded() {
        let legacyPath = "\(NSHomeDirectory())/Library/LaunchAgents/app.getstayup.plist"
        guard FileManager.default.fileExists(atPath: legacyPath) else { return }
        do {
            try loginItemService.register()
        } catch {
            FileHandle.standardError.write(Data(
                "[StayUp] LaunchAtLogin migration register() failed: \(error)\n".utf8))
            return
        }
        removeLegacyLaunchAgent()
    }

    private func runLaunchctl(_ args: [String]) {
        let task = Process()
        task.executableURL  = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments      = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Walk animation
    //
    // The accelerometer-driven animation. WalkDetector calls `startWalkAnimation`
    // when it detects sustained motion and `stopWalkAnimation` when motion
    // ceases. While running, the menu-bar icon swaps between two stride
    // frames every WALK_ANIM_INTERVAL. `isWalkingNow` lets `updateUI` tell
    // the icon path apart from a normal active/inactive update.

    private func startWalkAnimation() {
        isWalkingNow = true
        walkPhase = .leftForward
        updateUI()
        walkAnimTimer?.invalidate()
        let t = Timer(timeInterval: Self.WALK_ANIM_INTERVAL, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.walkPhase = (self.walkPhase == .leftForward) ? .rightForward : .leftForward
            self.updateUI()
        }
        RunLoop.main.add(t, forMode: .common)
        walkAnimTimer = t
    }

    // MARK: - OFF↔ON transition

    private func startTransition(toActive: Bool) {
        transitionTimer?.invalidate()
        transitionStartedAt = Date()
        transitionToActive  = toActive
        let t = Timer(timeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            self?.tickTransition()
        }
        RunLoop.main.add(t, forMode: .common)
        transitionTimer = t
    }

    private func tickTransition() {
        guard let started = transitionStartedAt else { return }
        let raw = Date().timeIntervalSince(started) / Self.TRANSITION_SECS
        let p   = max(0.0, min(1.0, raw))
        // Ease-out cubic so the tween settles instead of snapping.
        let eased = 1 - pow(1 - p, 3)

        let from: (CGFloat, CGFloat) = transitionToActive ? (IconRenderer.offDx, IconRenderer.offDy) : (1.0, 1.0)
        let to:   (CGFloat, CGFloat) = transitionToActive ? (1.0, 1.0) : (IconRenderer.offDx, IconRenderer.offDy)
        let dx = from.0 + (to.0 - from.0) * CGFloat(eased)
        let dy = from.1 + (to.1 - from.1) * CGFloat(eased)
        // Eyes flip at the midpoint so the snap is hidden inside motion.
        let eyes: DuckEyes = (transitionToActive ? p > 0.5 : p < 0.5) ? .open : .closed

        statusItem.button?.image = IconRenderer.iconWarped(dx: dx, dy: dy, eyes: eyes)
        statusItem.button?.imagePosition = .imageOnly

        if p >= 1.0 {
            transitionTimer?.invalidate()
            transitionTimer = nil
            transitionStartedAt = nil
            // Hand off to the appropriate idle animation now that the
            // tween has landed.
            if transitionToActive { startBlinkAnimation() }
            else                   { startZzzAnimation()   }
            updateUI()
        }
    }

    // MARK: - ON eye blink

    private func startBlinkAnimation() {
        blinkTimer?.invalidate()
        scheduleNextBlink()
    }

    private func stopBlinkAnimation() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkActive = false
    }

    private func scheduleNextBlink() {
        // Blink every 4–6 seconds so it doesn't feel mechanical.
        let delay = TimeInterval.random(in: 4.0...6.0)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.fireBlink()
        }
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    private func fireBlink() {
        // Blink only matters while ON and not in the middle of another
        // animation (walking/transition take priority).
        guard active, !isWalkingNow, transitionTimer == nil else {
            scheduleNextBlink()
            return
        }
        blinkActive = true
        updateUI()
        // Open the eyes back up after 120ms.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            self.blinkActive = false
            self.updateUI()
            self.scheduleNextBlink()
        }
    }

    // MARK: - OFF Zzz drift

    private func startZzzAnimation() {
        zzzTimer?.invalidate()
        zzzPhase = 0
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.tickZzz()
        }
        RunLoop.main.add(t, forMode: .common)
        zzzTimer = t
    }

    private func stopZzzAnimation() {
        zzzTimer?.invalidate()
        zzzTimer = nil
        zzzPhase = nil
    }

    private func tickZzz() {
        guard !active, !isWalkingNow, transitionTimer == nil else { return }
        // 4-phase cycle: Z grows + rises through 0,1,2 then a rest beat (nil).
        switch zzzPhase {
        case .none:    zzzPhase = 0
        case .some(0): zzzPhase = 1
        case .some(1): zzzPhase = 2
        default:       zzzPhase = nil
        }
        updateUI()
    }

    private func stopWalkAnimation() {
        walkAnimTimer?.invalidate()
        walkAnimTimer = nil
        isWalkingNow = false
        // Snapshot the just-finished walk for the menu's "Last:" line and
        // for the post-walk roast window.
        if let started = walkDetector.walkStartedAt {
            lastWalkDuration = Date().timeIntervalSince(started)
            lastWalkSteps    = walkDetector.sessionSteps
            lastWalkEndedAt  = Date()
            schedulePostWalkRoastClear()
        }
        updateUI()
    }

    // MARK: - UI

    private func updateUI() {
        // While the OFF↔ON tween is animating, tickTransition writes the
        // image directly each frame — leave it alone.
        if transitionTimer != nil {
            // Still update the menu items below so the dropdown reflects
            // the new state if the user happens to have the menu open.
        } else {
            let img: NSImage
            if isWalkingNow {
                img = IconRenderer.walkIcon(phase: walkPhase)
            } else if active {
                img = blinkActive ? IconRenderer.iconBlink() : IconRenderer.icon(active: true)
            } else {
                img = (zzzPhase != nil) ? IconRenderer.iconOffZ(phase: zzzPhase) : IconRenderer.icon(active: false)
            }
            statusItem.button?.image = img
        }

        // Roast text on the LEFT of the icon. `.imageRight` puts Duck
        // after the title, which renders as `<title> [icon]` in the menu bar.
        if let line = currentRoast() {
            statusItem.button?.title = line + " "
            statusItem.button?.imagePosition = .imageRight
        } else {
            statusItem.button?.title = ""
            statusItem.button?.imagePosition = .imageOnly
        }

        updateStatusLine()

        // Walk stats: live count while walking, last-walk snapshot afterward,
        // hidden if the user has never walked since launch.
        updateWalkStatsItem()

        // Hook-reconnect reminder: shown when a launch check re-added a dropped hook.
        updateReconnectItem()

        // Mode radios + Keep-screen — dots instead of system checkmarks, coloured
        // by meaning (Off gray, On green, Auto blue; selected = filled).
        let mode = currentMode
        offItem.attributedTitle  = dotTitle(mode == .off  ? "●" : "○", "Off",  on: mode == .off,  color: .systemGray)
        onItem.attributedTitle   = dotTitle(mode == .on   ? "●" : "○", "On",   on: mode == .on,   color: .systemGreen)
        autoItem.attributedTitle = dotTitle(mode == .auto ? "●" : "○", "Auto", on: mode == .auto, color: .systemBlue)
        for it in [offItem, onItem, autoItem] { it?.state = .off }   // dot replaces the checkmark
        let kso = Settings.virtualDisplayEnabled
        keepScreenItem.attributedTitle = dotTitle(kso ? "●" : "○", "Keep screen on", on: kso, color: .systemGreen)
        keepScreenItem.state = .off

        updateSourcesItem()
        publishStatusThrottled()   // tester file refreshes on the 5s throttle from animation ticks; real state changes publish directly
    }

    /// Status line — staged + colour-coded, dot leading, BRAND.md words
    /// (ON / IDLE, naps — never "protected"). Auto countdown > timed-On
    /// countdown > source-running > plain ON > IDLE.
    private func updateStatusLine() {
        if !active {
            statusMenuItem.attributedTitle = dotTitle("○", "STAYUP · IDLE", on: false)
        } else if let at = autoStandDownAt, at.timeIntervalSinceNow > 0 {
            let secs = max(0, Int(at.timeIntervalSinceNow))
            statusMenuItem.attributedTitle = dotTitle("●", "STAYUP · ON · naps in \(formatMMSS(secs))", on: true, color: .systemOrange)
        } else if let at = manualNapAt, at.timeIntervalSinceNow > 0 {
            let secs = max(0, Int(at.timeIntervalSinceNow))
            statusMenuItem.attributedTitle = dotTitle("●", "STAYUP · ON · naps in \(formatMMSS(secs))", on: true, color: .systemGreen)
        } else if engageReason == .auto && sourceMonitor.isAnySourceWorking {
            statusMenuItem.attributedTitle = dotTitle("●", "STAYUP · ON · sources working", on: true, color: .systemGreen)
        } else {
            statusMenuItem.attributedTitle = dotTitle("●", "STAYUP · ON", on: true, color: .systemGreen)
        }
        updateCoverageItem()
    }

    /// The lid-closed promise on battery needs the Helper. When the user is
    /// engaged, on battery, and the Helper isn't enabled, the "safe" look
    /// would be a lie — show the gap and route the click to Settings.
    private func updateCoverageItem() {
        let uncovered = active
            && powerSource.current == .battery
            && StayUpHelper.shared.status != .enabled
        coverageItem.isHidden = !uncovered
        if uncovered {
            coverageItem.title = "⚠︎ Lid-closed not covered on battery — set up Helper"
        }
    }

    /// The menu's Activity Sources row — a summary submenu for Auto mode.
    /// Running sources keep the Mac awake; waiting/idle ones are context.
    private func updateSourcesItem(rebuildSubmenu: Bool = true) {
        guard Settings.autoSourceEnabled else {        // no detection outside Auto
            sourcesItem.isHidden = true; sourcesSeparator.isHidden = true
            sourcesItem.submenu = nil
            return
        }
        let sessions = sourceMonitor.snapshotSessions()
        sourcesItem.isHidden = false
        sourcesItem.isEnabled = true
        sourcesSeparator.isHidden = false
        sourcesItem.image = nil   // dot replaces the terminal icon

        let anyRun = sessions.contains { $0.working }
        let anyWait = sessions.contains { !$0.working && $0.state == "waiting" }
        let running = sessions.filter { $0.working }.count
        let releaseIn = autoStandDownAt?.timeIntervalSinceNow ?? 0
        let dotColor: NSColor = anyRun ? .systemGreen : (releaseIn > 0 ? .systemOrange : (anyWait ? .systemOrange : .systemGray))
        let label: String = {
            if running > 0 {
                return running == 1 ? "Activity Sources: 1 working" : "Activity Sources: \(running) working"
            }
            if releaseIn > 0 {
                return "Activity Sources: napping soon"
            }
            if anyWait { return "Activity Sources: waiting" }
            return "Activity Sources: watching"
        }()

        sourcesItem.attributedTitle = dotTitle("●", label, on: true, color: dotColor)
        sourcesItem.target = nil
        sourcesItem.action = nil
        if rebuildSubmenu || sourcesItem.submenu == nil {
            sourcesItem.submenu = makeSourcesSubmenu(sessions: sessions)
        }
    }

    private func makeSourcesSubmenu(sessions: [ActivitySourceSession]) -> NSMenu {
        let sub = NSMenu()
        sub.autoenablesItems = false

        let title: String
        if sessions.contains(where: { $0.working }) {
            title = "Duck's up — local work running"
        } else if let at = autoStandDownAt, at.timeIntervalSinceNow > 0 {
            title = "Napping soon — no work right now"
        } else {
            title = "Watching for local work"
        }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        sub.addItem(header)

        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No local activity right now", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            sub.addItem(.separator())
            for session in sessions.prefix(8) {
                addActivitySourceSession(session, to: sub)
            }
            if sessions.count > 8 {
                let more = NSMenuItem(title: "\(sessions.count - 8) more sources…", action: nil, keyEquivalent: "")
                more.isEnabled = false
                sub.addItem(more)
            }
        }

        sub.addItem(.separator())
        let panel = NSMenuItem(title: "Open Activity Panel", action: #selector(showActivitySourcesPopover), keyEquivalent: "")
        panel.target = self
        panel.isEnabled = !sessions.isEmpty
        sub.addItem(panel)

        let settings = NSMenuItem(title: "Activity Source Settings…", action: #selector(showSettings), keyEquivalent: "")
        settings.target = self
        sub.addItem(settings)
        return sub
    }

    private func addActivitySourceSession(_ session: ActivitySourceSession, to menu: NSMenu) {
        let dot: NSColor
        let state: String
        if session.isExternal {
            dot = session.working ? .systemGreen : .systemGray
            state = session.working ? "activity seen" : "idle"
        } else if session.working {
            dot = .systemGreen
            state = session.toolsInFlight > 0 ? "running" : "active"
        } else if session.state == "waiting" {
            dot = .systemOrange
            state = "waiting"
        } else {
            dot = .systemGray
            state = "idle"
        }

        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.attributedTitle = dotTitle("●", session.terminalLabel, on: session.working, color: dot)
        title.isEnabled = false
        menu.addItem(title)

        var detailBits = [state, session.proofLabel()]
        if session.isExternal {
            detailBits.append("estimate")
        } else {
            if session.working, session.toolsInFlight > 0 {
                detailBits.append("\(session.toolsInFlight) tool\(session.toolsInFlight == 1 ? "" : "s")")
            }
            if let tx = session.transcriptPath, let toks = ActivitySourceMonitor.tokensUsed(transcriptPath: tx) {
                detailBits.append("\(abbrevTokens(toks)) tok")
            }
        }
        let detail = NSMenuItem(title: "   " + detailBits.joined(separator: " · "), action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
    }

    private func updateWalkStatsItem() {
        if isWalkingNow, let started = walkDetector.walkStartedAt {
            let secs  = Int(Date().timeIntervalSince(started))
            let steps = walkDetector.sessionSteps
            walkStatsMenuItem.title    = "🚶  \(formatMMSS(secs))  ·  \(steps) step\(steps == 1 ? "" : "s")"
            walkStatsMenuItem.isHidden = false
            walkStatsSeparator.isHidden = false
        } else if let dur = lastWalkDuration {
            let secs = Int(dur)
            walkStatsMenuItem.title    = "Last walk: \(formatMMSS(secs)) · \(lastWalkSteps) step\(lastWalkSteps == 1 ? "" : "s")"
            walkStatsMenuItem.isHidden = false
            walkStatsSeparator.isHidden = false
        } else {
            walkStatsMenuItem.isHidden = true
            walkStatsSeparator.isHidden = true
        }
    }

    private func updateReconnectItem() {
        if let notice = reconnectNotice {
            reconnectMenuItem.title    = "⚠︎  \(notice)"
            reconnectMenuItem.isHidden = false
            reconnectSeparator.isHidden = false
        } else {
            reconnectMenuItem.isHidden = true
            reconnectSeparator.isHidden = true
        }
    }

    private func formatMMSS(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    private func abbrevTokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    /// "● text" / "○ text" — the dot carries the colour; the text stays readable
    /// (normal when on, dimmed when off). One style for the whole menu: mode
    /// radios, Keep-screen, the status line, and the source row.
    private func dotTitle(_ dot: String, _ text: String, on: Bool, color: NSColor? = nil) -> NSAttributedString {
        let font     = NSFont.menuFont(ofSize: 0)
        let dotColor = on ? (color ?? NSColor.systemGreen) : NSColor.tertiaryLabelColor
        let txtColor = on ? NSColor.labelColor : NSColor.secondaryLabelColor
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: dot + "  ", attributes: [.font: font, .foregroundColor: dotColor]))
        s.append(NSAttributedString(string: text,       attributes: [.font: font, .foregroundColor: txtColor]))
        return s
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    // MARK: - Test harness (signal-driven)

    func signalEngage()    { if !active { engage() } }
    func signalDisengage() { if  active { disengage() } }

    func signalDumpState() {
        let st = stack.snapshot()
        let s = """
        === StayUp State ===
        active:                       \(active)
        dontDieTriggered:             \(dontDieTriggered)
        powerSource.current:          \(powerSource.current)
        batteryPct:                   \(powerSource.batteryPercent().map(String.init) ?? "nil")
        Settings.dontDieEnabled:      \(Settings.dontDieEnabled)
        Settings.dontDiePct:          \(Settings.dontDiePct)
        caffeinate.isActive:          \(st.caffeinate)
        sleepPreventer.isActive:      \(st.sleepPreventer)
        closedLidPreventer.isEnabled: \(st.closedLid)
        virtualDisplay.isActive:      \(st.virtualDisplay)
        StayUpHelper.status:          \(StayUpHelper.shared.status)
        StayUpHelper.isEnabled:       \(st.helper)
        SleepDisabled.live:           \(StayUpHelper.shared.sleepDisabledLiveState().map(String.init) ?? "unknown")
        ====================

        """
        FileHandle.standardError.write(Data(s.utf8))
    }
}
