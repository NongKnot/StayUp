import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater controller. Owns the
/// updater object's lifetime — it must be retained for the duration of the
/// app, otherwise Sparkle silently stops working.
///
/// On first invocation Sparkle reads `SUFeedURL` and `SUPublicEDKey` from
/// `Info.plist`. Because `SUEnableAutomaticChecks` is intentionally absent,
/// Sparkle prompts the user once on the *second* app launch:
/// *"Should StayUp automatically check for updates?"* Whatever the user
/// picks is stored in `NSUserDefaults` under `SUEnableAutomaticChecks`
/// and respected forever after — no further prompts, no network calls
/// before they opt in.
///
/// The "no network calls during normal operation" promise in CLAUDE.md
/// stands: update checks only fire when the user explicitly opts in
/// (auto-mode) or clicks "Check for Updates Now" in Settings.
///
/// When a user flips automatic checks from off to on inside StayUp, start one
/// immediate background check. Sparkle suppresses "already up to date" UI for
/// background checks, but will present its standard update alert if a signed
/// update is available. This makes opt-in visibly useful without polling before
/// consent or nagging when there is no release.

/// Brings StayUp to the front the moment Sparkle finds a valid update. StayUp is
/// a menu-bar agent (`LSUIElement`, no Dock icon), so a *scheduled* background
/// update alert otherwise opens behind the user's other windows and goes
/// unnoticed (user-initiated "Check for Updates" already activates the app, so
/// only the background path needs this nudge). Activating here — before Sparkle
/// puts up its alert — makes the prompt land in front on launch/restart.
private final class UpdaterEventDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        // macOS blocks a background/menu-bar app (`.accessory`) from stealing
        // focus, so `activate()` alone leaves the alert behind the foreground
        // app. Temporarily promote to `.regular` (which gets a Dock icon and is
        // allowed to come forward), then activate so the update prompt lands in
        // front on launch. Restored to `.accessory` when the update cycle ends.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        // Drop the temporary Dock icon once the check/prompt is done (user
        // dismissed, or no update). If they chose Install, the relaunched app
        // starts fresh as `.accessory` anyway.
        NSApp.setActivationPolicy(.accessory)
    }
}

final class SparkleUpdater {
    static let shared = SparkleUpdater()

    private let eventDelegate = UpdaterEventDelegate()
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: eventDelegate,
            userDriverDelegate: nil
        )
    }

    /// Kick one background check shortly after launch — but only once the user
    /// has *explicitly* opted in (the `SUEnableAutomaticChecks` key exists and is
    /// true). So an available update surfaces on app start and, via
    /// `UpdaterEventDelegate`, pops to the front, instead of waiting for
    /// Sparkle's daily scheduled interval. The explicit-key guard preserves the
    /// "no network before consent" promise: nothing fires before the user has
    /// answered the second-launch prompt.
    func checkOnLaunchIfEnabled() {
        guard UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") != nil,
              controller.updater.automaticallyChecksForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    /// User-triggered "Check for Updates" — bypasses opt-in (the user just
    /// asked for it explicitly). Opens Sparkle's standard update UI.
    func checkForUpdatesNow() {
        controller.checkForUpdates(nil)
    }

    /// Apply a user-driven automatic-check preference change. Enabling kicks
    /// Sparkle once so an available update can surface right away; future checks
    /// continue on Sparkle's normal scheduled interval.
    func setAutomaticChecksEnabledFromUserAction(_ enabled: Bool) {
        let wasEnabled = controller.updater.automaticallyChecksForUpdates
        controller.updater.automaticallyChecksForUpdates = enabled

        if enabled && !wasEnabled {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// Mirrors the user's auto-check preference. Wired to the Settings
    /// checkbox; reading reflects the current state.
    var automaticChecksEnabled: Bool {
        controller.updater.automaticallyChecksForUpdates
    }
}
