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
    /// Dims the built-in panel to backlight-0 under a closed lid when "Keep
    /// screen on" holds a remote session on it — see BuiltinBacklight.swift.
    private let builtinBacklight   = BuiltinBacklight()

    // MARK: - State

    /// Laptop mirror-phantom state (see reconcileMirror). `mirrorVetoed` sticks
    /// for the rest of the engage once mirroring changed the built-in's
    /// resolution or ran out of retries — the planner then drops the phantom
    /// and lid-close falls back to backlight-0 (shipped 1.3.6 behavior).
    private var mirrorVetoed = false
    private var mirrorRetries = 0
    private static let MIRROR_MAX_RETRIES = 5
    /// The built-in's CURRENT mode as last seen while it was online —
    /// refreshed every screen-policy pass (a mirror-time-only capture proved
    /// unreliable: macOS auto-restores mirrors, bypassing the establishment
    /// path — HITL 2026-07-27). The clamshell-off pin reads this. Cleared on
    /// disengage.
    private var lastBuiltinMode: VirtualDisplay.Mode?
    /// One-shot READ-ONLY yank watch armed at OUR topology transitions —
    /// phantom spawn, phantom teardown, lid-open re-pairing. macOS keeps one
    /// remembered display config per topology ({built-in} solo vs
    /// {built-in + phantom} pair) and re-applies it wholesale at every such
    /// transition, including the built-in's stored mode (root-caused
    /// 2026-07-27, WindowServer log — this is the entire "resolution yank"
    /// family; StayUp's own mirror call never moved the built-in). StayUp
    /// never writes the built-in's config (operator decision 2026-07-27:
    /// a buggy auto-undo can cement the wrong mode into macOS's store
    /// permanently; a notification can't). While armed, a built-in mode
    /// differing from the reference is that stale memory being re-applied —
    /// surface it in one notification and stand down. The user's picker is
    /// the built-in's ONLY writer.
    private var topologyYankWatch: (reference: VirtualDisplay.Mode, event: String, until: Date)?
    private static let TOPOLOGY_YANK_WINDOW_SECS: TimeInterval = 8
    /// Built-in online-list state of the previous reapply pass — detects the
    /// lid-open (offline→online) re-pairing transition for the watch above.
    private var builtinWasOnline: Bool?
    /// Which lid-closed mechanism is live: "clamshell-off" (panel genuinely
    /// off) or "backlight-fallback" (panel driven dark). nil lid-open/idle.
    private var lidClosedMode: String?

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
    /// Cached result of `ActivitySourceHookInstaller.unhealthyDisplayNames`,
    /// refreshed only by `refreshHookHealthCache()` — see that method for why.
    private var unhealthySourceNames: [String] = []
    private var settings:          SettingsWindow?
    private var appearanceObserver: NSKeyValueObservation?
    private var welcome:           WelcomeWindow?

    private var active           = false
    private var batteryTimer:    Timer?
    private var helperWatchdogTimer: Timer?
    private var helperStrikes    = 0
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
        let sessions = sourceMonitor.snapshotSessions().map { s -> [String: Any] in
            let now = Date()
            var d: [String: Any] = ["label": s.terminalLabel, "state": SessionPresenter.word(s),
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
        if helperStrikes > 0 { status["helperStrikes"] = helperStrikes }
        if let pct = powerSource.batteryPercent() { status["batteryPct"] = pct }
        if let lid = lidMonitor.isClosed { status["lidClosed"] = lid }
        if let m = lidClosedMode { status["lidClosedMode"] = m }
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

    /// Settle delay before a lid flip or display reshuffle may move the
    /// virtual display. Spawning/destroying a CGVirtualDisplay *while* macOS
    /// is still reconfiguring displays for the same event (built-in going
    /// on/offline at a clamshell flip) crashed the Dock — 25 identical
    /// SIGABRTs on 2026-07-04, zero the prior week, reproduced by lid
    /// cycling. Every trigger reschedules, so the apply runs once, this long
    /// after the *last* topology event, when the display list is quiet.
    private static let SCREEN_SETTLE_SECS: TimeInterval = 1.5
    private var screenPolicyReapply: DispatchWorkItem?

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
        SourceProvisioner.ensureProvisioned()

        // Defensive: clear any leftover sleep-prevention state (esp. the helper's
        // system-wide `pmset disablesleep 1`) from a prior session that crashed
        // or was force-killed while engaged. A built-in dimmed to backlight-0 by
        // a prior run needs no such self-heal — the hardware brightness keys and
        // lid-open wake bring it back with the app dead (BuiltinBacklight.swift).
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

        // Lid watcher — a lid flip re-runs the screen policy: mirror upkeep,
        // the clamshell verdict, and backlight-0 fallback all live in
        // reapplyScreenPolicy. No-op on Macs without a lid.
        // Deferred, never synchronous: the flip races macOS's own clamshell
        // display reconfiguration (see SCREEN_SETTLE_SECS).
        lidMonitor.start()
        lidMonitor.onChange = { [weak self] _ in
            guard let self else { return }
            self.scheduleScreenPolicyReapply()
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
        builtinBacklight.apply(dim: false)   // undim the built-in before teardown
        let hadPhantom = stack.snapshot().virtualDisplay
        // Reference priority: an armed in-window watch first (a store yank
        // may still be unreported — the LIVE mode is then the yank, not the
        // user's pick), then the live mode, then the pre-close mode
        // (clamshell-off: the built-in is offline, builtinNativeMode is nil).
        let armedReference = topologyYankWatch.flatMap { Date() < $0.until ? $0.reference : nil }
        let quitReference = armedReference ?? builtinNativeMode ?? lastBuiltinMode
        stack.shutdown()
        // Quit tears the phantom down with no surviving check pass — macOS
        // re-applies the remembered solo config within milliseconds of the
        // display leaving. One bounded synchronous READ before exit surfaces
        // it (read-only: notify, never write). Runs for a pending in-window
        // watch too, even when the phantom already went down (disengage
        // moments before quit — the scheduled checks die with us).
        if hadPhantom || armedReference != nil, let want = quitReference, !hasRealExternalDisplay {
            Thread.sleep(forTimeInterval: 0.8)
            if let cur = builtinNativeMode, cur != want {
                FileHandle.standardError.write(Data(
                    "[StayUp] topology-memory yank at quit: built-in \(want.pointsWide)x\(want.pointsHigh) -> \(cur.pointsWide)x\(cur.pointsHigh) (read-only: notified, not undone)\n".utf8))
                notifyResolutionYank(from: want, to: cur)
                Thread.sleep(forTimeInterval: 0.3)   // let the notification XPC land before exit
            }
        }
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
        reconnectMenuItem.target    = self
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
        // Also darkens a laptop's built-in under a shut lid (BuiltinBacklight).
        keepScreenItem = NSMenuItem(title: "Keep screen on when lid closed", action: #selector(toggleKeepScreen), keyEquivalent: "")
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
        refreshHookHealthCache()
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
            SourceProvisioner.ensureProvisioned()   // explicit mutation point — reads never scaffold
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
        refreshHookHealthCache()
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

    /// Menu-warning action: force a reconnect of every enabled reported source.
    @objc private func reconnectSourcesNow() {
        do {
            try ActivitySourceHookInstaller.install(onlyEnabled: true)
            reconnectNotice = "Reconnected — sources are hooked up again"
        } catch {
            presentHookWarning(error)
        }
        refreshHookHealthCache()
        updateUI()
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
    enum Mode: Int { case off = 0, on = 1, auto = 2 }

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
                runAutoActions(AutoEngagePolicy.decide(
                    .adoptedFromManual, autoFacts(working: sourceMonitor.isAnySourceWorking)))
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
        applyScreenPolicyNow()
        updateUI()
        publishStatus()
    }

    // MARK: - Engage / disengage

    private func engage(reason: EngageReason = .manual) {
        guard !active else { return }
        engageReason = reason
        cancelAutoGrace()
        // Every engage earns a fresh mirror attempt — except the HITL drill:
        // STAYUP_NO_MIRROR pre-vetoes so the planner suppresses the phantom
        // outright, exercising the true shipped-1.3.6 backlight-fallback shape
        // (single definition point — reconcileMirror no longer re-checks this).
        mirrorVetoed = ProcessInfo.processInfo.environment["STAYUP_NO_MIRROR"] != nil
        mirrorRetries = 0
        applyStack(engaged: true)
        active = true
        Settings.wasActive = (reason == .manual)
        playClick()
        startBatteryMonitor()    // poll battery only while engaged
        startHelperWatchdog()    // verify layer 5 only while engaged
        if Settings.walkEnabled {
            walkDetector.start()  // accelerometer only while engaged + opted in
        }
        // OFF→ON tween, then blink loop. Zzz stops here; the transition
        // tick clears the zzz icon naturally.
        stopZzzAnimation()
        startTransition(toActive: true)
        updateUI()
        publishStatus()
        // Converge the screen policy once the display list is quiet. Engaging
        // under an already-closed lid (launch resume, or auto re-engage after a
        // grace cycle) fires no lid flip or topology event, so without this the
        // built-in never gets dimmed — the feature would silently do nothing for
        // the rest of the session. The planner diffs, so the inner applyStack is
        // a no-op; this exists to reach the builtinBacklight dim in reapply.
        scheduleScreenPolicyReapply()
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
        builtinBacklight.apply(dim: false)   // undim the built-in before the stack drops
        lidClosedMode = nil
        lastBuiltinMode = nil
        applyStack(engaged: false)
        stopBatteryMonitor()
        stopHelperWatchdog()
        // Powering off the accelerometer also fires onWalkStop if we were
        // mid-walk, which clears `isWalkingNow` and the icon animation.
        walkDetector.stop()
        // ON→OFF tween, then Zzz loop.
        stopBlinkAnimation()
        startTransition(toActive: false)
        updateUI()
        publishStatus()
    }

    /// The one place live facts become a stack `apply(...)`. When the user opts
    /// to let the screen lock, we still hold the *system* awake for background
    /// work but drop the display-keep-awake layers — display-sleep assertion,
    /// caffeinate -d, and the virtual display — so macOS can lock and show the
    /// login screen. See Settings → General.
    /// `suppressVirtualDisplay`: a laptop whose mirror was vetoed this engage
    /// runs the shipped 1.3.6 shape (no phantom, backlight-0 at lid-close).
    /// Desktops (no built-in active) never suppress — the phantom is their
    /// only surface.
    private func applyStack(engaged: Bool) {
        // C1: never remove the last online display under a closed lid — the
        // user's screen-lock toggle is deferred until the lid opens (a topology
        // event then re-applies it naturally). If the lid is strictly closed,
        // no built-in is in the active list, and the stack's phantom is the
        // live display, honoring a keepScreenOn=false here would drop it and
        // leave the Mac with zero online displays.
        let soleDisplayUnderClosedLid = lidMonitor.isClosed == true
            && !hasBuiltinDisplayOnline
            && stack.snapshot().virtualDisplay
        let effectiveKeepScreenOn = soleDisplayUnderClosedLid || Settings.virtualDisplayEnabled
        // M2: a built-in Mac with no lid sensor (iMac) has no clamshell to
        // trigger, so the phantom would be pure cost — suppress it there too,
        // same as a genuine mirror veto. Desktops without a built-in keep the
        // phantom regardless (it's their only surface).
        let suppressPhantom = hasBuiltinDisplayOnline && (mirrorVetoed || lidMonitor.isClosed == nil)
        // Capture the built-in's mode BEFORE the stack can flip the phantom:
        // if this apply spawns or drops it, macOS re-applies the remembered
        // config for the new topology right behind the flip, and this
        // pre-transition mode is the reference the yank watch compares against.
        let phantomBefore = stack.snapshot().virtualDisplay
        let modeBefore = builtinNativeMode
        let phantomCycled = stack.apply(engaged: engaged,
                    keepScreenOn: effectiveKeepScreenOn,
                    hasExternalDisplay: hasRealExternalDisplay,
                    suppressVirtualDisplay: suppressPhantom,
                    virtualDisplayModes: builtinModeTable)
        if stack.snapshot().virtualDisplay != phantomBefore {
            armTopologyYankWatch(reference: modeBefore,
                                 event: phantomBefore ? "phantom teardown" : "phantom arrival")
        } else if phantomCycled {
            // The table-upgrade respawn is teardown+arrival with an unchanged
            // snapshot. Its one real occurrence is the first pass after an
            // engage-under-closed-lid lid-open, where the live mode may ALREADY
            // be the store's pair imposition — so arm from lastBuiltinMode
            // (never adopts a disputed mode), not modeBefore. nil (built-in
            // never seen this engage) arms nothing: with no trusted reference,
            // a notification would just be a guess.
            armTopologyYankWatch(reference: lastBuiltinMode,
                                 event: "phantom respawn (mode-table upgrade)")
        }
    }

    /// Arm the yank watch for one of OUR topology transitions and schedule
    /// follow-up checks. The scheduled checks exist because the settle-
    /// deferred reapply path only runs while engaged — the teardown
    /// transition (disengage, veto) needs the check to fire while idle too.
    private func armTopologyYankWatch(reference: VirtualDisplay.Mode?, event: String) {
        // A real external display in the mix → stand down: its arrival/removal
        // legitimately re-applies the user's own remembered config for THAT
        // display set — not a yank, nothing to report.
        guard !hasRealExternalDisplay else { topologyYankWatch = nil; return }
        // No reference (built-in offline: closed lid, or a desktop) → nothing
        // to arm — but a pending in-window watch from an earlier transition
        // stays armed (a teardown flip under a closed lid must not wipe the
        // arrival flip's pending check). Expired watches are dropped here so
        // they can't linger and block lid-open arming / mode adoption.
        guard var reference else {
            if let g = topologyYankWatch, Date() >= g.until { topologyYankWatch = nil }
            return
        }
        // Unresolved dispute: an in-window watch whose reference differs means
        // the CURRENT mode may itself be the store's imposition (veto teardown,
        // rapid engage→disengage) — keep the older capture (the user's mode)
        // instead of adopting the disputed one as the new reference.
        if let g = topologyYankWatch, Date() < g.until, g.reference != reference {
            reference = g.reference
        }
        topologyYankWatch = (reference, event,
                             Date().addingTimeInterval(Self.TOPOLOGY_YANK_WINDOW_SECS))
        for delay: TimeInterval in [2.5, 6.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.runTopologyYankCheck()
            }
        }
    }

    /// Compare the built-in against the armed reference; a deviation inside
    /// the window is macOS's per-topology memory being re-applied. READ-ONLY:
    /// tell the user and stand down — StayUp never writes the mode back.
    private func runTopologyYankCheck() {
        guard let g = topologyYankWatch else { return }
        if Date() >= g.until || hasRealExternalDisplay { topologyYankWatch = nil; return }
        // Built-in offline (mid-clamshell churn): keep armed; a later pass
        // re-checks once the panel is back.
        guard let cur = builtinNativeMode else { return }
        guard cur != g.reference else { return }
        // A deviation while System Settings is frontmost is far more likely
        // the user's own pick than the store's imposition (impositions land
        // at transitions, with no picker in front) — no yank, nothing to say.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" {
            topologyYankWatch = nil
            return
        }
        topologyYankWatch = nil   // one notice per transition, not one per pass
        FileHandle.standardError.write(Data(
            "[StayUp] topology-memory yank after \(g.event): built-in \(g.reference.pointsWide)x\(g.reference.pointsHigh) -> \(cur.pointsWide)x\(cur.pointsHigh) (read-only: notified, not undone)\n".utf8))
        notifyResolutionYank(from: g.reference, to: cur)
    }

    /// macOS's per-topology display memory changed the built-in's resolution
    /// around one of our transitions. StayUp is read-only about the built-in
    /// (operator decision 2026-07-27) — tell the user instead of writing.
    private func notifyResolutionYank(from: VirtualDisplay.Mode, to: VirtualDisplay.Mode) {
        if Self.isTestMode { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Your resolution was changed"
            content.body = "macOS switched the built-in display to \(to.pointsWide)×\(to.pointsHigh) (you had \(from.pointsWide)×\(from.pointsHigh)). Pick it again in System Settings → Displays if you didn't want that."
            center.add(UNNotificationRequest(
                identifier: "stayup.resolutionYank", content: content, trigger: nil))
        }
    }

    /// The built-in panel's display ID if it is currently in the ACTIVE display
    /// list, else nil. Live on purpose: backlight-0 leaves the built-in ONLINE
    /// (just dark); a built-in that actually leaves the list (clamshell-off —
    /// now the *goal* at lid-close) reads nil, so the phantom is the surface.
    private var builtinDisplayID: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    private var hasBuiltinDisplayOnline: Bool { builtinDisplayID != nil }

    /// The built-in's CURRENT mode as a phantom spec — nil when no built-in is
    /// active (desktop, or mid-clamshell; the executor then keeps its last
    /// mode). Refresh 0 (some panels report it) falls back to 60.
    private var builtinNativeMode: VirtualDisplay.Mode? {
        guard let id = builtinDisplayID, let m = CGDisplayCopyDisplayMode(id) else { return nil }
        return VirtualDisplay.Mode(pixelsWide: m.pixelWidth, pixelsHigh: m.pixelHeight,
                                   pointsWide: m.width, pointsHigh: m.height,
                                   refreshRate: m.refreshRate > 0 ? m.refreshRate : 60)
    }

    /// The built-in's full usable mode TABLE as a phantom spec — a constant
    /// hardware property, so the phantom advertising it never needs a respawn
    /// to follow the user's resolution picks (the single-mode chase produced
    /// respawn churn, sticky vetoes, and a settings revert loop — HITL
    /// 2026-07-27). Deduped by logical size + refresh (the 1x/2x variants of
    /// one logical size collapse to one advertised mode; hiDPI handles the
    /// rest), keeping the largest framebuffer per entry. nil when no built-in
    /// is active. Sorted for stable Equatable comparison in the executor.
    private var builtinModeTable: [VirtualDisplay.Mode]? {
        guard let id = builtinDisplayID else { return nil }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let all = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return nil }
        var best: [String: VirtualDisplay.Mode] = [:]
        for m in all where m.isUsableForDesktopGUI() {
            let hz = m.refreshRate > 0 ? m.refreshRate : 60
            let key = "\(m.width)x\(m.height)@\(Int(hz))"
            if let seen = best[key], seen.pixelsWide >= m.pixelWidth { continue }
            best[key] = VirtualDisplay.Mode(pixelsWide: m.pixelWidth, pixelsHigh: m.pixelHeight,
                                            pointsWide: m.width, pointsHigh: m.height,
                                            refreshRate: hz)
        }
        guard !best.isEmpty else { return nil }
        return best.values.sorted {
            ($0.pointsWide, $0.pointsHigh, $0.refreshRate) < ($1.pointsWide, $1.pointsHigh, $1.refreshRate)
        }
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
            if screen.localizedName == VirtualDisplay.displayName { continue }
            guard let id = screen.deviceDescription[displayKey] as? CGDirectDisplayID else { continue }
            if CGDisplayIsBuiltin(id) == 0 { return true }
        }
        return false
    }

    private func handleDisplayChange() {
        guard active else { return }
        guard Settings.virtualDisplayEnabled else { return }  // screen-lock mode: no virtual display
        // Coalesced settle-debounce: the screen list churns during reshuffles,
        // and a lid flip fires this too (built-in going on/offline). Re-apply
        // the desired state only once the topology has been quiet — the planner
        // adds/drops only the virtual display as lid / real-external change.
        scheduleScreenPolicyReapply()
    }

    /// Coalesced, settle-delayed `reapplyScreenPolicy()`. Each trigger (lid
    /// flip, display-parameters change) cancels the pending one and
    /// reschedules, so the stack moves once, SCREEN_SETTLE_SECS after the
    /// last topology event — never concurrently with macOS's own clamshell
    /// reconfiguration (that concurrency crashed the Dock, 2026-07-04). A
    /// rapid open/close/open lid cycle coalesces into a single no-op apply.
    /// The planner diffs against live state, so a fired apply is idempotent.
    private func scheduleScreenPolicyReapply() {
        screenPolicyReapply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.screenPolicyReapply = nil
            self.reapplyScreenPolicy()
        }
        screenPolicyReapply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.SCREEN_SETTLE_SECS, execute: work)
    }

    /// A USER-initiated policy change (keep-screen toggle, Settings edit) takes
    /// effect immediately — deferring it behind the settle delay can miss a
    /// lid close inside the window (toggle off → close lid → the late apply
    /// then sees the phantom as sole display and keeps the Mac awake all
    /// night). The settle rule exists to avoid mutating displays concurrently
    /// with macOS's own reconfiguration, so only when a topology event is
    /// already settling does the change ride the pending pass instead.
    private func applyScreenPolicyNow() {
        guard screenPolicyReapply == nil else { return }   // pending pass picks it up
        reapplyScreenPolicy()
    }

    // MARK: - Power source

    private func handlePowerSourceChange(_ source: PowerSourceMonitor.Source) {
        if source == .ac { dontDieTriggered = false }
        updateUI()
    }

    // MARK: - Auto mode (Activity Sources)
    //
    // When `Settings.autoSourceEnabled`, `ActivitySourceMonitor` drives engage/
    // disengage off the `~/.stayup/sources/*/active` contract folders. All
    // decisions live in `AutoEngagePolicy` (pure, shell-tested); this section
    // only gathers facts, runs the returned actions, and owns the grace timer.

    private func handleActivitySourceChange(_ working: Bool) {
        runAutoActions(AutoEngagePolicy.decide(.sourceChanged, autoFacts(working: working)))
        updateUI()
    }

    private func autoFacts(working: Bool) -> AutoEngagePolicy.Facts {
        .init(autoEnabled: Settings.autoSourceEnabled,
              working: working,
              engaged: active,
              engagedByAuto: engageReason == .auto,
              dontDieTriggered: dontDieTriggered,
              graceSecs: Settings.autoGraceSecs)
    }

    private func runAutoActions(_ actions: [AutoEngagePolicy.Action]) {
        for action in actions {
            switch action {
            case .engage:                 engage(reason: .auto)
            case .adoptAsAuto:            engageReason = .auto
            case .standDown(let grace):   scheduleAutoStandDown(after: grace)
            case .disengage:              disengage()
            case .cancelStandDown:        cancelAutoGrace()
            }
        }
    }

    /// Timer mechanics only — whether and when to stand down is the policy's
    /// call (`.standDown(after:)` always carries a positive grace; grace 0
    /// comes back as `.disengage` instead).
    private func scheduleAutoStandDown(after grace: Int) {
        cancelAutoGrace()
        autoStandDownAt = Date(timeIntervalSinceNow: TimeInterval(grace))   // for the popover countdown
        let t = Timer(timeInterval: TimeInterval(grace), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.autoGraceTimer = nil
            self.autoStandDownAt = nil
            // Re-check at fire time: the world may have changed while we slept.
            self.runAutoActions(AutoEngagePolicy.decide(
                .graceFired, self.autoFacts(working: self.sourceMonitor.isAnySourceWorking)))
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
        guard active else { lidClosedMode = nil; return }
        // The planner diffs against the live state, so an unchanged policy is a
        // no-op and a keepScreenOn or lid flip re-arms exactly the display layers.
        applyStack(engaged: true)
        reconcileMirror()
        // Clamshell verdict — verify, don't assume (consult 2026-07-11): after
        // the settle delay, the ONLINE list says whether macOS powered the
        // built-in off. Gone → genuinely off, nothing to dim. Still online →
        // the phantom didn't count for clamshell (or engage happened under an
        // already-closed lid, where JIT spawn can't trigger it — bench 0/200)
        // → backlight-0, exactly the shipped 1.3.6 behavior.
        let builtinOnline = DisplayMirror.builtinIsInOnlineList()
        if Settings.virtualDisplayEnabled && lidMonitor.isClosed == true {
            lidClosedMode = builtinOnline ? "backlight-fallback" : "clamshell-off"
        } else {
            lidClosedMode = nil
        }
        // Lid-open returns the built-in into the {built-in, phantom} pair —
        // macOS re-applies that topology's remembered config on the way in
        // (the same per-topology store that yanks at spawn/teardown). Arm the
        // yank watch with the pre-close mode so a stale pair memory gets
        // surfaced; a watch already armed by this pass's applyStack wins.
        if builtinOnline, builtinWasOnline == false, stack.snapshot().virtualDisplay,
           topologyYankWatch == nil {
            armTopologyYankWatch(reference: lastBuiltinMode, event: "lid-open re-pairing")
        }
        builtinWasOnline = builtinOnline
        runTopologyYankCheck()
        // Keep the pre-close desktop spec fresh while the built-in is online —
        // but never adopt a mode the armed watch still disputes, or the
        // reference would drift onto the store's imposed mode.
        if let m = builtinNativeMode,
           topologyYankWatch == nil || m == topologyYankWatch!.reference {
            lastBuiltinMode = m
        }
        // Standalone phantom defaults to its raw 1x framebuffer mode, doubling
        // the logical desktop and reflowing windows on reopen (HITL
        // 2026-07-27). When clamshell has taken the built-in offline, pin the
        // phantom to the 2x mode whose logical size matches the pre-close
        // desktop. The set fires a displays-changed event whose reapply finds
        // the mode already correct — no loop.
        if lidClosedMode == "clamshell-off", let want = lastBuiltinMode,
           let phantom = DisplayMirror.phantomDisplayID() {
            let pinned = DisplayMirror.setLogicalMode(phantom,
                                                      pointsWide: want.pointsWide, pointsHigh: want.pointsHigh,
                                                      pixelsWide: want.pixelsWide, pixelsHigh: want.pixelsHigh)
            FileHandle.standardError.write(Data(
                "[StayUp] phantom pin \(want.pointsWide)x\(want.pointsHigh)@2x: \(pinned ? "ok" : "FAILED")\n".utf8))
        }
        // Dim the built-in to backlight-0 only when the lid is *strictly* closed
        // (desktops report nil and never dim), Keep screen on is held, and the
        // panel is still online (clamshell-off left nothing to dim). Lid-open
        // restores brightness; hardware keys are the ultimate safety net.
        builtinBacklight.apply(dim: active
                          && Settings.virtualDisplayEnabled
                          && lidMonitor.isClosed == true
                          && builtinOnline)
        publishStatus()
    }

    /// True when two display modes match on pixel W/H and refresh rate. Refresh
    /// tolerates the 0→60 fallback normalization (some panels briefly report a
    /// 0 refresh) — equal if either side is 0 or they differ by less than 1.
    private static func modesMatch(width w1: Int, height h1: Int, refresh r1: Double,
                                    width w2: Int, height h2: Int, refresh r2: Double) -> Bool {
        w1 == w2 && h1 == h2 && (r1 == 0 || r2 == 0 || abs(r1 - r2) < 1)
    }

    /// Converge the laptop mirror: phantom active + built-in active → phantom
    /// mirrors the built-in. Runs ONLY from reapplyScreenPolicy (settle-
    /// deferred). Accepted design cost: from spawn until this converges
    /// (~1.5–3s, up to ~9s across retries) the phantom is a visible extended
    /// display — pre-existing the lid close is the whole feature, and
    /// mirroring closer to arrival would re-enter the settle window the
    /// 2026-07-04 Dock crash forbids. Verifies the built-in's pixel mode survived mirroring — the
    /// 2026-07-08 rejection (2056→1728) must never silently return; any drop
    /// vetoes the mirror for the rest of this engage and stands the phantom
    /// down. `mirrorVetoed`'s only writer besides this is `engage()`'s
    /// STAYUP_NO_MIRROR init (HITL fallback drill) — this guard just reads it.
    private func reconcileMirror() {
        guard active, Settings.virtualDisplayEnabled, !mirrorVetoed, !hasRealExternalDisplay else { return }
        // Establish the mirror only while the lid is open. Its whole purpose
        // is to pre-exist the close; attempting it under a closed lid is
        // pointless (clamshell already missed) and fails in the mid-clamshell
        // churn, tripping a sticky veto that then blocks the next open→close
        // cycle from upgrading to clamshell-off (HITL 2026-07-27, item 6).
        // Lid-open's own reapply establishes it as soon as the panel returns.
        guard lidMonitor.isClosed != true else { return }
        guard let builtin = builtinDisplayID else { return }   // desktop, or mid-clamshell
        guard let phantom = DisplayMirror.phantomDisplayID() else {
            // The phantom spawned this very apply may not be in the display
            // list yet (async arrival). Retry via the coalesced settle path;
            // give up into the veto after MIRROR_MAX_RETRIES.
            if stack.snapshot().virtualDisplay {
                if mirrorRetries < Self.MIRROR_MAX_RETRIES {
                    mirrorRetries += 1
                    scheduleScreenPolicyReapply()
                } else {
                    vetoMirror(reason: "phantom never appeared in display list")
                }
            }
            return
        }
        if DisplayMirror.isMirrored(phantom) {
            mirrorRetries = 0
            // Converged. NO mode-change policing here: the phantom advertises
            // the built-in's whole mode table, so a user's resolution pick is
            // just the mirror renegotiating onto a mode both sides already
            // offer — nothing to chase, nothing to veto. (A single-mode
            // phantom chased the current mode with respawns; the respawn
            // churn produced sticky vetoes and a revert loop that overrode
            // the user's choice every ~3s — HITL 2026-07-27.) The immediate
            // before/after verify below still guards establishment.
            return
        }
        let before = CGDisplayCopyDisplayMode(builtin)
        let ok = DisplayMirror.mirror(phantom, to: builtin)
        let after = CGDisplayCopyDisplayMode(builtin)
        if !ok {
            // A failed mirror CALL is usually transient topology churn (the
            // lid-open reshuffle vetoed here twice on 2026-07-27's HITL) —
            // retry like the phantom-arrival path; veto only at the cap. Only
            // a held mirror with a changed resolution is a permanent condition.
            if mirrorRetries < Self.MIRROR_MAX_RETRIES {
                mirrorRetries += 1
                scheduleScreenPolicyReapply()
            } else {
                vetoMirror(reason: "mirror call kept failing")
            }
        } else if let before, let after {
            if Self.modesMatch(
                width: before.pixelWidth, height: before.pixelHeight, refresh: before.refreshRate,
                width: after.pixelWidth, height: after.pixelHeight, refresh: after.refreshRate) {
                mirrorRetries = 0
            } else {
                _ = DisplayMirror.unmirror(phantom)
                vetoMirror(reason: "mirroring changed the built-in's resolution")
            }
        } else {
            // The call succeeded but the built-in's mode was unreadable (mid-
            // churn transience) — the resolution verify couldn't complete, so
            // don't trust the mirror AND don't burn the permanent veto on it:
            // unmirror and retry, so the next establishment is fully verified.
            _ = DisplayMirror.unmirror(phantom)
            if mirrorRetries < Self.MIRROR_MAX_RETRIES {
                mirrorRetries += 1
                scheduleScreenPolicyReapply()
            } else {
                vetoMirror(reason: "built-in mode unreadable at establishment")
            }
        }
    }

    /// Stand the mirror experiment down for the rest of this engage: the
    /// planner drops the phantom and the laptop runs the shipped 1.3.6 shape.
    private func vetoMirror(reason: String) {
        mirrorVetoed = true
        FileHandle.standardError.write(Data(
            "[StayUp] DisplayMirror: vetoed — \(reason); falling back to backlight-0\n".utf8))
        applyStack(engaged: true)   // planner sees the veto and drops the phantom
    }

    /// Called from Settings `onChange` when the auto-mode toggle or
    /// grace value may have changed. Brings the live state in line immediately
    /// instead of waiting for the next source-activity edge.
    private func reconcileAutoMode() {
        runAutoActions(AutoEngagePolicy.decide(
            .autoToggled, autoFacts(working: sourceMonitor.isAnySourceWorking)))
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

    // MARK: - Helper watchdog (layer 5)

    // `pmset disablesleep` is system-wide state anyone root can flip — a second
    // app instance's launch self-heal, the daemon's restart rescue, a stray
    // pmset. When it's stripped behind an engaged app, everything still LOOKS
    // safe (assertions held, duck active) but battery+lid-close sleeps the Mac
    // (2026-07-18: killed every running agent). Policy in HelperWatchdog.swift;
    // this owns the timer, the live ioreg read, and the strike counter.

    private func startHelperWatchdog() {
        helperWatchdogTimer?.invalidate()
        let t = Timer(timeInterval: HelperWatchdog.intervalSecs, repeats: true) { [weak self] _ in
            self?.helperWatchdogTick()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        helperWatchdogTimer = t
    }

    private func stopHelperWatchdog() {
        helperWatchdogTimer?.invalidate()
        helperWatchdogTimer = nil
        helperStrikes = 0
    }

    private func helperWatchdogTick() {
        // No registered+approved helper means layer 5 was never promised —
        // that gap has its own surface (updateCoverageItem's set-up line),
        // so the watchdog has nothing to guard or accuse.
        guard StayUpHelper.shared.isEnabled else { helperStrikes = 0; return }
        let live = StayUpHelper.shared.sleepDisabledLiveState(forceRefresh: true)
        let verdict = HelperWatchdog.tick(engaged: active, sleepDisabled: live,
                                          strikes: helperStrikes)
        if verdict.rearm { StayUpHelper.shared.enable() }
        let wasDegraded = HelperWatchdog.degraded(strikes: helperStrikes)
        helperStrikes = verdict.strikes
        if HelperWatchdog.degraded(strikes: helperStrikes) != wasDegraded {
            publishStatus()   // menu picks it up on open via updateCoverageItem
        }
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
                self?.applyScreenPolicyNow()
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
            s.setMode = { [weak self] idx in self?.setMode(Mode(rawValue: idx) ?? .off) }
            s.currentModeIndex = { [weak self] in self?.currentMode.rawValue ?? 0 }
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
            statusMenuItem.attributedTitle = dotTitle("●", "STAYUP · ON · naps in \(SessionPresenter.mmss(secs))", on: true, color: .systemOrange)
        } else if let at = manualNapAt, at.timeIntervalSinceNow > 0 {
            let secs = max(0, Int(at.timeIntervalSinceNow))
            statusMenuItem.attributedTitle = dotTitle("●", "STAYUP · ON · naps in \(SessionPresenter.mmss(secs))", on: true, color: .systemGreen)
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
        let noHelper = active
            && powerSource.current == .battery
            && StayUpHelper.shared.status != .enabled
        // Helper is set up but the kernel flag keeps getting stripped and the
        // watchdog's re-arms aren't sticking — same broken promise, same line.
        let wontStick = active && HelperWatchdog.degraded(strikes: helperStrikes)
        coverageItem.isHidden = !(noHelper || wontStick)
        if noHelper {
            coverageItem.title = "⚠︎ Lid-closed not covered on battery — set up Helper"
        } else if wontStick {
            coverageItem.title = "⚠︎ Lid-closed protection keeps switching off — click to check Helper"
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
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.attributedTitle = dotTitle("●", session.terminalLabel,
                                         on: session.working,
                                         color: SessionPresenter.dotColor(session))
        title.isEnabled = false
        menu.addItem(title)

        let detail = NSMenuItem(title: "   " + SessionPresenter.detailBits(session).joined(separator: " · "),
                                action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
    }

    private func updateWalkStatsItem() {
        if isWalkingNow, let started = walkDetector.walkStartedAt {
            let secs  = Int(Date().timeIntervalSince(started))
            let steps = walkDetector.sessionSteps
            walkStatsMenuItem.title    = "🚶  \(SessionPresenter.mmss(secs))  ·  \(steps) step\(steps == 1 ? "" : "s")"
            walkStatsMenuItem.isHidden = false
            walkStatsSeparator.isHidden = false
        } else if let dur = lastWalkDuration {
            let secs = Int(dur)
            walkStatsMenuItem.title    = "Last walk: \(SessionPresenter.mmss(secs)) · \(lastWalkSteps) step\(lastWalkSteps == 1 ? "" : "s")"
            walkStatsMenuItem.isHidden = false
            walkStatsSeparator.isHidden = false
        } else {
            walkStatsMenuItem.isHidden = true
            walkStatsSeparator.isHidden = true
        }
    }

    /// Recompute hook health (file I/O — a read per source config + wrapper).
    /// Called only from menu-open and the reconnect action, never from the
    /// updateUI() hot path: animation timers tick updateUI() at up to 4 Hz,
    /// and health polling there would burn disk + battery for nothing.
    private func refreshHookHealthCache() {
        unhealthySourceNames = Settings.autoSourceEnabled
            ? ActivitySourceHookInstaller.unhealthyDisplayNames(onlyEnabled: true) : []
    }

    private func updateReconnectItem() {
        // Active failure beats passive notice: Auto is on but a source is
        // still unhealthy after self-heal ran — repair is failing (unwritable
        // config, deploy error), so give the user a handle instead of a log.
        let broken = unhealthySourceNames
        if !broken.isEmpty {
            reconnectMenuItem.title    = "⚠︎  Auto can't see \(broken.joined(separator: ", ")) — click to reconnect"
            reconnectMenuItem.action   = #selector(reconnectSourcesNow)
            reconnectMenuItem.isEnabled = true
            reconnectMenuItem.isHidden = false
            reconnectSeparator.isHidden = false
        } else if let notice = reconnectNotice {
            reconnectMenuItem.title    = "⚠︎  \(notice)"
            reconnectMenuItem.action   = nil
            reconnectMenuItem.isEnabled = false
            reconnectMenuItem.isHidden = false
            reconnectSeparator.isHidden = false
        } else {
            reconnectMenuItem.isHidden = true
            reconnectSeparator.isHidden = true
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
