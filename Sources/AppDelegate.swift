import AppKit
import Dispatch

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: MenuController?
    private var signalSources:  [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let mc = MenuController()
        menuController = mc
        mc.setup()
        // Migrate pre-public installs off the hand-written LaunchAgent path
        // onto SMAppService.mainApp so the entry shows under "Open at Login"
        // labeled "StayUp" instead of in Background Activity grouped under
        // the developer-name from the code-signing cert. Idempotent on clean
        // systems.
        mc.migrateLegacyLaunchAgentIfNeeded()
        // First-launch onboarding. Sets Settings.didOnboard=true on close
        // so the welcome never re-appears for the same install. Delayed
        // by one runloop tick so the menu-bar icon paints first — the
        // welcome window centers feel intentional with Duck already
        // present in the menu bar.
        DispatchQueue.main.async { mc.showWelcomeIfNeeded() }
        installSignalHandlers(mc)
        installTerminationHandlers()
        // Start Sparkle. No network calls happen before the user opts in
        // (Sparkle prompts on second launch when SUEnableAutomaticChecks
        // is absent from Info.plist).
        _ = SparkleUpdater.shared
        // Surface an available update on launch for opted-in users: kick one
        // background check after the menu bar is up. StayUp is a menu-bar agent,
        // so the updater delegate brings the alert to the front (a scheduled
        // check would otherwise open behind other windows). No-op + no network
        // until the user has opted in, so the consent promise holds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            SparkleUpdater.shared.checkOnLaunchIfEnabled()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuController?.cleanup()
    }

    /// Entry point for `getstayup://` URLs. The parked route is
    /// `getstayup://unlock-pro/<packId>`. Called by macOS *before*
    /// `applicationDidFinishLaunching` in the cold-launch case, so this
    /// routes through `PackUnlocker` directly rather than depending on
    /// MenuController being set up — PackUnlocker only touches
    /// UserDefaults, which is always available.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "getstayup" else { return }
        let host = url.host ?? ""
        let path = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "unlock-pro":
            guard let packId = path.first, !packId.isEmpty else {
                logURL("missing pack ID in \(url)")
                return
            }
            let result = PackUnlocker.unlock(packId: packId)
            logURL("unlock-pro \(packId) → \(result)")
            // Public v1 does not register unlockable packs, so this mostly
            // future-proofs the URL scheme without creating a visible surface.
        default:
            logURL("unknown host '\(host)' in \(url)")
        }
    }

    private func logURL(_ msg: String) {
        FileHandle.standardError.write(Data("[URLHandler] \(msg)\n".utf8))
    }

    /// Debug interface (off-the-record):
    ///   kill -USR1 <pid>  → engage
    ///   kill -USR2 <pid>  → disengage
    ///   kill -INFO <pid>  → dump state to stderr
    /// Used to drive the app from a test harness without clicking the menu.
    /// Production users never touch these — they're harmless if triggered
    /// because they map to the same engage/disengage paths the menu uses.
    private func installSignalHandlers(_ mc: MenuController) {
        let map: [(Int32, () -> Void)] = [
            (SIGUSR1, { [weak mc] in mc?.signalEngage() }),
            (SIGUSR2, { [weak mc] in mc?.signalDisengage() }),
            (SIGINFO, { [weak mc] in mc?.signalDumpState() }),
        ]
        for (sig, handler) in map {
            // DispatchSourceSignal requires the default action be ignored
            // so the signal isn't handled twice.
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler(handler: handler)
            src.resume()
            signalSources.append(src)
        }
    }

    /// `SIGTERM` and `SIGINT` are the standard ways for `launchctl bootout`,
    /// Activity Monitor's "Quit" button, and `kill <pid>` to ask us to exit.
    /// The default action is immediate termination, which bypasses
    /// `applicationWillTerminate` and leaks `pmset disablesleep 1`.
    /// Route them through `NSApp.terminate(nil)` so cleanup runs.
    private func installTerminationHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }
}
