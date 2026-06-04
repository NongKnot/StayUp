# Changelog

All notable changes to StayUp. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning
follows [SemVer](https://semver.org/).

## [1.0] — 2026-06-04

First public release. This is the launch entry; later patches will
land below it.

### Added

- **Five-layer sleep prevention stack.** `caffeinate` subprocess +
  IOKit idle/display/system-sleep assertions + `CGVirtualDisplay`
  private API + optional root LaunchDaemon (`pmset disablesleep`).
- **Battery + closed-lid coverage.** The only consumer Mac sleep
  blocker that handles this scenario today, via the virtual-display
  trick + the helper daemon. Other apps fail because Apple Silicon
  firmware overrides their IOKit assertions.
- **Walking Duck mascot.** `WalkDetector` reads the M-series
  accelerometer (`AppleSPUHIDDevice`) at ~14 Hz and animates the
  menu-bar icon between two stride frames when sustained motion is
  detected. `StepCounter` counts steps via classical peak detection.
  Live walk timer + post-walk roast text in the menu.
- **Left-click engage, right-click menu.** Click menu-bar Duck
  to toggle Stay Up directly. Right-click (or Ctrl+click) opens the
  menu for Settings / Quit / walk stats. Keyboard activation still
  routes to the menu so VoiceOver / Tab navigation keeps working.
- **Idle animations.** ON eye blink every 4–6s, OFF chibi Duck with
  drifting Z's, smooth tween between ON↔OFF on toggle.
- **Don't Die.** Auto-disengages everything if battery drops below
  the configured threshold (default 5%). Engage-gated polling so
  it costs zero CPU at idle.
- **Resume on Launch.** Re-arms the prevention stack on next launch
  if you quit while engaged.
- **Four free starter skins.** Classic (default), Rubber, Charcoal,
  Mono (`isTemplate=true`, adapts to dark/light menu bar). Classic +
  Rubber + Charcoal use their base palette on both menu-bar
  appearances — the white/yellow/dark-grey bodies read fine against
  either background without an explicit dark-mode palette.
- **Starter skins only.** Public v1 ships Classic, Rubber, Charcoal,
  and Mono. Unfinished character/pack experiments stay out of the
  picker until the site and unlock story are ready.
- **Walk mode controls.** Accelerometer
  detection can be turned off explicitly; toggle is auto-grayed on
  Macs without an Apple SPU accelerometer (Mac mini / Studio / Pro /
  Intel-era). Walk-related controls (Walk mode, Roast me) live under
  Settings → Advanced.
- **First-launch welcome window.** Surfaces Launch at Login, Helper
  setup, and automatic-update opt-in in a single window so new users
  don't have to hunt for the battery+lid coverage path in Settings.
  Defaults are off — encourage, don't presume. Re-openable from
  Settings → About → "Replay welcome."
- **Settings panel** organized as preference tabs (General · Advanced ·
  Look · About). General holds Mode, Launch at Login, Don't Die, and
  Helper setup; Advanced holds screen-lock policy, Activity Sources, and
  Walk mode. Don't Die uses a 5%/10%/20% dropdown; the Duck skin picker
  shows a colored swatch next to each option (Mono renders as a
  light/dark split to indicate "adapts to menu bar").
- **Auto mode Activity Sources.** Bundled starter sources cover Claude Code
  CLI, Codex CLI, LM Studio, and Ollama. Sources are local, opt-in, and must
  prove active work instead of merely proving that an app is open.
- **Safe Activity Source setup and cleanup.** The copied setup prompt asks the
  agent to test idle, active, and stopped states before writing anything.
  Normal Delete safe-disables a reported source with a no-op wrapper; Clean Up
  Hooks removes only StayUp-owned hook entries.
- **Launch at Login** registers via `SMAppService.mainApp`, so the
  entry shows up in System Settings → Login Items & Extensions →
  "Open at Login" labeled "StayUp" with the app icon. Earlier
  pre-public 1.0 builds used a hand-written LaunchAgent that
  classified as a legacy login item; a one-shot migration in
  `MenuController` claims those installs onto the modern API
  transparently.
- **Helper Uninstall** lives in Settings → General. Sends `disable`
  to the daemon first (so `pmset disablesleep 0` runs cleanly),
  waits for the drain, then unregisters the `SMAppService.daemon`
  entry. A confirmation alert spells out that Duck loses its
  lid-closed-on-battery powers until you set it up again.
- **Defensive `pmset disablesleep 0`** on every helper daemon launch.
  Self-heals any stuck system-wide sleep-prevention state from a
  prior leak — SIGKILL, crash, or any bug that killed the daemon
  before it could clean up. Trade-off documented inline:
  `Helper/main.swift`.
- **Tip jar link.** "Feed Duck" in Settings → About opens
  `getstayup.app/tip` in the browser.
- **Sparkle auto-updater.** Future versions land via the standard
  Sparkle update flow. No network calls on first launch — Sparkle
  prompts once ("Should StayUp automatically check for updates?")
  on second launch; user opts in or out. Updates verified end-to-end
  with EdDSA signatures so a compromised CDN can't ship a backdoored
  DMG. Settings → About exposes the toggle + manual "Check Now."
- **One-command release pipeline.** `bash tools/release.sh` builds,
  codesigns, notarizes, staples, DMGs the app, signs the appcast
  with EdDSA, and writes `site/appcast.xml`. Output:
  `dist/StayUp-<version>.dmg`.
- **Open source under MIT.** Code is free; the StayUp name and Duck
  artwork are reserved (see `LICENSE` + README Contributing section).

### Notes

- Bundle ID is `app.getstayup` (matches the owned domain). Helper
  daemon is `app.getstayup.helper`.
- Settings storage migrates one-shot from the old `com.stayup.app`
  domain on first launch (relevant only to dev builds; new users
  start fresh under `app.getstayup`).
- App is direct-distribution only. Battery + closed-lid coverage
  uses Apple private APIs (`CGVirtualDisplay`) and a root LaunchDaemon
  — both forbidden in App Store sandbox — so the Mac App Store
  path stays closed.
- DMG installer background renders at 2× device scale on Retina
  displays (`assets/dmg-bg.png` is 1080×760 @ 144 DPI).
