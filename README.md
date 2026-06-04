# StayUp 🦆

> Duck's up. Mac stays awake. Work does not faceplant.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Open Source](https://img.shields.io/badge/open%20source-%E2%9D%A4-ff9b3d.svg)](./LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Architecture: Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-black.svg)](https://en.wikipedia.org/wiki/Apple_silicon)
[![Built with Swift](https://img.shields.io/badge/Swift-5%2B-orange.svg?logo=swift&logoColor=white)](https://swift.org)
[![Duck Mode](https://img.shields.io/badge/Duck%20mode-up-ff9b3d.svg)](https://getstayup.app)

Free Apple Silicon Mac menu-bar Duck that keeps local work alive when macOS
really wants a nap. No account. No telemetry. No weird cloud leash.

Close the lid. LLM still running. Render still rendering. Download still
downloading. Good Duck.

<p align="center">
  <img src="./assets/readme-walk.gif" alt="The StayUp Duck walking" width="200">
</p>

## 🦆 What The Duck Does

- **Off / On / Auto.** Manual sleep control, or Auto mode that protects only
  while trusted local Activity Sources prove real work.
- **Lid-closed work.** Battery plus lid closed is the boss fight. The Helper is
  how Duck handles it.
- **MacBook as Mac mini.** Dock it, close it, run Ollama, a worker, a tiny
  server, or the overnight thing that should not die.
- **Don't Die.** Duck cuts itself off before the Mac faceplants. BJ help.
  Bryan Johnson obviously.
- **Good Duck.** Local-first, opt-in sources, polite uninstall.

## 🚀 Getting A Duck

### Normies Way ✨

Download StayUp from [getstayup.app](https://getstayup.app).

First setup has a few macOS prompts:

- **Welcome window:** Launch at Login, Helper setup, update preference.
- **Helper setup:** macOS approval plus one password prompt. This is the
  lid-closed-on-battery part.
- **Sparkle updates:** optional signed updates from `getstayup.app/appcast.xml`.

No Helper, no hard-case promise. Duck is bold, not fake.

### Respectable Way 🛠

StayUp is a small AppKit app built with `swiftc`. No Xcode project. No SPM.
Sparkle is vendored so a fresh clone can build without dependency setup.

```bash
git clone https://github.com/NongKnot/StayUp.git
cd StayUp
bash build.sh

cp -R StayUp.app /Applications/
open /Applications/StayUp.app
```

For the real StayUp setup:

```text
StayUp menu -> Settings -> Helper -> Set up
```

For a notarized local build:

```bash
bash build.sh notarize
```

That needs a Developer ID certificate and a configured `notarytool` keychain
profile.

## ⚡ Auto Mode

Auto mode is Duck with timing:

```text
work starts -> Duck up
work stops  -> grace timer
quiet again -> Duck down
```

Supported starter sources include Claude Code CLI, Codex CLI, LM Studio, and
Ollama. Sources are local and opt-in. Cloud/web work somewhere else does not
keep this Mac awake unless a local thing writes a heartbeat.

Docs:

- Activity Source contract: [docs/activity-source-contract.md](./docs/activity-source-contract.md)
- Setup prompt and examples: [docs/activity-sources.md](./docs/activity-sources.md)
- Contributor recipes: [docs/activity-source-recipes](./docs/activity-source-recipes/)
- Launch kit: [docs/LAUNCH.md](./docs/LAUNCH.md)

## 🔒 Privacy

No telemetry. No analytics. No crash reporting. No accounts.

StayUp reads local Activity Source receipts, optional local session details for
the menu, and accelerometer samples only while engaged. Sparkle checks for
updates only if enabled or manually requested.

Security notes live in [SECURITY.md](./SECURITY.md).

## 🧹 Uninstall

Polite path. Good Duck:

1. Open StayUp -> Settings -> Helper -> Uninstall Helper.
2. Quit StayUp.
3. Drag `/Applications/StayUp.app` to the Trash.

Fast path:

```bash
pkill -x StayUp
sudo launchctl bootout system/app.getstayup.helper 2>/dev/null || true
rm -rf /Applications/StayUp.app
defaults delete app.getstayup 2>/dev/null || true
```

If System Settings still shows a background item afterward, remove it from:

```text
System Settings -> General -> Login Items & Extensions
```

## 🙏 Credits

- [BetterDummy](https://github.com/waydabber/BetterDummy) by Istvan T.
- [apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer) by Olivier Bourbonnais
- [OxWearables stepcount](https://github.com/OxWearables/stepcount)
- [Sparkle](https://sparkle-project.org/) for signed updates
- `/usr/bin/caffeinate`, Apple's built-in sleep-prevention tool

## 🤝 Contributors

- <img src="./assets/codex-mark.svg" alt="" width="18"> Codex - coding
  collaborator for public repo cleanup, release docs, and launch polish.
- Claude Code - early coding collaborator for the original StayUp build and
  Auto mode exploration.

See [AUTHORS.md](./AUTHORS.md) for the public credit roll.

## 🌱 Contributing

Issues and PRs welcome. Bring proof, keep it local, do not impersonate Duck.

For Auto mode sources, start with proof: exact local surface, idle proof,
active proof, stop proof, false positives, and false negatives.

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the full Duck manners.

The code is MIT. Forks should use their own name and artwork so this Duck keeps
his pond.

## 📜 License

MIT. See [LICENSE](./LICENSE).
