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
final class SparkleUpdater {
    static let shared = SparkleUpdater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
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
    /// checkbox; reading reflects the current state, writing flips it.
    var automaticChecksEnabled: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
