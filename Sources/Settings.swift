import Foundation

/// Typed, defaulted access to StayUp user preferences.
/// All keys live under the `stayup.` namespace.
enum Settings {
    static var d: UserDefaults = .standard

    /// One-shot migration from the old `com.stayup.app` UserDefaults domain
    /// to the current bundle ID. Idempotent — safe to call repeatedly. Run
    /// once at app startup before anything reads Settings.
    static func migrateLegacyDefaultsIfNeeded() {
        guard !d.bool(forKey: "stayup.legacyMigrated") else { return }
        let legacy = UserDefaults(suiteName: "com.stayup.app")
        let keys = [
            "stayup.dontDiePct", "stayup.dontDieEnabled",
            "stayup.roastEnabled", "stayup.resumeOnLaunch",
            "stayup.wasActive", "stayup.skinId",
        ]
        if let legacy {
            for k in keys {
                if let v = legacy.object(forKey: k) {
                    d.set(v, forKey: k)
                    legacy.removeObject(forKey: k)
                }
            }
        }
        d.set(true, forKey: "stayup.legacyMigrated")
    }

    // MARK: - Don't Die

    /// Battery percentage at which Don't Die fires and disables sleep prevention.
    static var dontDiePct: Int {
        get { d.object(forKey: "stayup.dontDiePct") as? Int ?? 5 }
        set { d.set(newValue, forKey: "stayup.dontDiePct") }
    }

    /// Don't Die armed. Default ON.
    static var dontDieEnabled: Bool {
        get { d.object(forKey: "stayup.dontDieEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "stayup.dontDieEnabled") }
    }

    /// Show Duck's roast text next to the menu-bar icon.
    /// Default ON.
    static var roastEnabled: Bool {
        get { d.object(forKey: "stayup.roastEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "stayup.roastEnabled") }
    }

    /// Walk mode — accelerometer-driven walking Duck animation + step counter.
    /// Default ON. Set to false to suppress the
    /// HID hookup entirely on engage; useful for Macs without an Apple SPU
    /// accelerometer (Intel-era, Mac mini/Studio/Pro) or users who'd just
    /// rather have a stationary Duck.
    static var walkEnabled: Bool {
        get { d.object(forKey: "stayup.walkEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "stayup.walkEnabled") }
    }

    /// Auto mode — engage the sleep-prevention stack automatically while a
    /// selected Activity Source is working, and stand down when it goes idle. Driven by
    /// `ActivitySourceMonitor` watching the `~/.stayup/sources/*/active/`
    /// contract folders.
    /// Default OFF: it's opt-in. A source can only wake Auto after the user
    /// enables it in Settings, whether the signal comes from bundled CLI hooks
    /// or an observed local clue.
    static var autoSourceEnabled: Bool {
        get { d.object(forKey: "stayup.autoSourceEnabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "stayup.autoSourceEnabled") }
    }

    /// Consent for editing bundled reported-source hook configs. Auto can
    /// still watch observed sources without it.
    static var reportedHookConsentKnown: Bool {
        d.object(forKey: "stayup.reportedHookConsentKnown") as? Bool ?? false
    }
    static var reportedHookConnectionAllowed: Bool {
        d.object(forKey: "stayup.reportedHookConnectionAllowed") as? Bool ?? false
    }
    static func setReportedHookConnectionAllowed(_ allowed: Bool) {
        d.set(true, forKey: "stayup.reportedHookConsentKnown")
        d.set(allowed, forKey: "stayup.reportedHookConnectionAllowed")
    }

    /// Grace period (seconds) to keep holding the Mac awake after activity
    /// stops running a tool (it finished, paused to ask you something, or went
    /// idle) before auto-mode lets the Mac sleep. This is the single "sleep
    /// after" knob — running keeps the Mac awake with no timer; everything else
    /// runs out this grace. Floor 5 min so a long thinking pause mid-turn can't
    /// drop the connection. Default 5 min.
    static var autoGraceSecs: Int {
        // Floor at 5 min: clamps legacy values from the old picker (Right away=0,
        // 30s, 1m, 2m) up to the new minimum so an upgrade can't leave a sub-5-min
        // grace that sleeps mid-turn before the user ever opens Settings.
        get { max(300, d.object(forKey: "stayup.autoGraceSecs") as? Int ?? 300) }
        set { d.set(newValue, forKey: "stayup.autoGraceSecs") }
    }

    /// Which Activity Sources are enabled by source name.
    /// Default **none**: nothing can wake Auto until you pick at least one in
    /// Settings → Advanced.
    static var enabledSources: Set<String> {
        get { Set((d.array(forKey: "stayup.enabledSources") as? [String]) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "stayup.enabledSources") }
    }
    static func isSourceEnabled(_ name: String) -> Bool { enabledSources.contains(name) }
    static func setSource(_ name: String, enabled: Bool) {
        var s = enabledSources
        if enabled { s.insert(name) } else { s.remove(name) }
        enabledSources = s
    }

    /// Activity Sources the user explicitly removed from Settings. This lets
    /// bundled defaults stay deleted instead of being recreated on Refresh.
    static var deletedSources: Set<String> {
        get { Set((d.array(forKey: "stayup.deletedSources") as? [String]) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "stayup.deletedSources") }
    }
    static func isSourceDeleted(_ name: String) -> Bool { deletedSources.contains(name) }
    static func setSourceDeleted(_ name: String, deleted: Bool) {
        var s = deletedSources
        if deleted { s.insert(name) } else { s.remove(name) }
        deletedSources = s
    }

    /// Keep the *screen* awake too, not just the system. Default ON (the v1
    /// behavior: display-sleep assertion + optional virtual display, so remote
    /// GUI tools have a screen-shaped target while engaged). Turn OFF for a
    /// security-friendlier mode: the system stays awake for background work,
    /// but the display is allowed to sleep so macOS can lock and show the login
    /// screen. Gates `VirtualDisplay` + the display-sleep layers in
    /// `MenuController.engage()`.
    static var virtualDisplayEnabled: Bool {
        get { d.object(forKey: "stayup.virtualDisplayEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "stayup.virtualDisplayEnabled") }
    }

    /// Re-engage Stay Up automatically if it was on when the app last quit.
    /// Default ON — "remember my choice".
    static var resumeOnLaunch: Bool {
        get { d.object(forKey: "stayup.resumeOnLaunch") as? Bool ?? true }
        set { d.set(newValue, forKey: "stayup.resumeOnLaunch") }
    }

    /// Set on engage/disengage. Read at launch (when `resumeOnLaunch` is on)
    /// to decide whether to re-arm the stack.
    static var wasActive: Bool {
        get { d.bool(forKey: "stayup.wasActive") }
        set { d.set(newValue, forKey: "stayup.wasActive") }
    }

    /// Selected Duck skin. Persists across launches.
    static var skinId: String {
        get { d.string(forKey: "stayup.skinId") ?? DuckSkin.classic.id }
        set { d.set(newValue, forKey: "stayup.skinId") }
    }
    static var currentSkin: DuckSkin { DuckSkin.byId(skinId) }

    /// Pack-scoped ownership. Persisted as an array of pack IDs the user
    /// has unlocked via `PackUnlocker`. The `starter` pack is *always*
    /// implicitly unlocked (the free 4-skin set that ships with v1.0) —
    /// it's union'd in at read time so a stale `defaults delete app.getstayup`
    /// can never lock the user out of the free skins.
    static var unlockedPackIds: Set<String> {
        get {
            let stored = (d.array(forKey: "stayup.unlockedPackIds") as? [String]) ?? []
            return Set(stored).union([DuckPack.starter.id])
        }
        set {
            // Strip the implicit starter ID before persisting so we don't
            // bloat the on-disk array with redundant state.
            let persisted = newValue.subtracting([DuckPack.starter.id])
            d.set(Array(persisted).sorted(), forKey: "stayup.unlockedPackIds")
        }
    }

    static func isPackUnlocked(_ packId: String) -> Bool {
        unlockedPackIds.contains(packId)
    }

    /// First-launch onboarding completed. Set to true the first time the
    /// `WelcomeWindow` closes (either via "Let's go" or the window's close
    /// button) so the welcome doesn't reappear on every launch. Default
    /// `false` — fresh installs and `defaults delete app.getstayup` both
    /// reset it and re-trigger the onboarding flow.
    static var didOnboard: Bool {
        get { d.bool(forKey: "stayup.didOnboard") }
        set { d.set(newValue, forKey: "stayup.didOnboard") }
    }

}
