# StayUp

> Duck's up. Mac stays awake. Work keeps going.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Open Source](https://img.shields.io/badge/open%20source-%E2%9D%A4-ff9b3d.svg)](./LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Architecture: Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-black.svg)](https://en.wikipedia.org/wiki/Apple_silicon)
[![Built with Swift](https://img.shields.io/badge/Swift-5%2B-orange.svg?logo=swift&logoColor=white)](https://swift.org)
[![Duck Mode](https://img.shields.io/badge/Duck%20mode-up-ff9b3d.svg)](https://getstayup.app)

StayUp is a free Apple Silicon Mac menu-bar app that keeps local work alive:
AI agents, model servers, renders, downloads, and long jobs that should not die
just because the lid closed.

No account. No telemetry. No analytics. Just a Duck.

<table>
  <tr>
    <td width="33%" align="center">
      <img src="./assets/use-case-walk.png" alt="Duck walking with a closed MacBook" width="180">
      <br>
      <sub>Close lid. Walk.</sub>
    </td>
    <td width="33%" align="center">
      <img src="./assets/use-case-desk.png" alt="Duck beside a docked MacBook" width="180">
      <br>
      <sub>Docked work.</sub>
    </td>
    <td width="33%" align="center">
      <img src="./assets/use-case-auto.png" alt="Duck watching local work run at night" width="180">
      <br>
      <sub>Auto mode.</sub>
    </td>
  </tr>
</table>

## What It Does

- **Keeps the Mac awake.** Manual mode is direct: turn Duck on, Mac stays up.
- **Protects closed-lid work.** The optional Helper covers battery plus lid
  closed, where normal menu-bar apps cannot promise enough.
- **Detects local work.** Auto mode watches selected Activity Sources and keeps
  Duck up while trusted local work is running.
- **Stands down after work stops.** Choose a grace period: 5, 15, 30, 60, or
  180 minutes.
- **Avoids fake protection.** Idle apps, waiting agents, and stale receipts
  should not keep the Mac awake forever.
- **Adds a little Duck.** Optional walking animation when you carry a MacBook.

<p align="center">
  <img src="./assets/readme-walk.gif" alt="The StayUp Duck walking" width="160">
</p>

## Download

Download the latest notarized build from:

**[getstayup.app/download](https://getstayup.app/download)**

First launch can ask for:

- **Launch at Login** if you want Duck available after restart.
- **Helper setup** if you want stronger closed-lid protection on battery.
- **Automatic updates** if you want StayUp to check quietly for signed updates.

You can change these later in StayUp Settings.

## Auto Mode

Auto mode is for the moment when you want the Mac awake only while local work is
real.

```text
work starts -> Duck up
work stops  -> grace timer
quiet again -> Duck down
```

Bundled starter sources:

- Claude
- Codex
- Cursor
- LM Studio
- Ollama

Sources are local and opt-in. Cloud work somewhere else does not keep this Mac
awake unless a local tool writes a StayUp activity receipt.

## Privacy

StayUp is local-first:

- No telemetry
- No analytics
- No crash reporting
- No accounts
- No remote activity tracking

Auto mode reads local Activity Source receipts under `~/.stayup/`. Some sources
can show local session details, such as whether a tool is running or waiting.
Update checks happen only when enabled or manually requested.

Security notes live in [SECURITY.md](./SECURITY.md).

## Build From Source

For local development:

```bash
git clone https://github.com/NongKnot/StayUp.git
cd StayUp
bash build.sh

cp -R StayUp.app /Applications/
open /Applications/StayUp.app
```

Local builds are for development. The public download is signed and notarized.

## Uninstall

Polite path:

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

## Credits

- [BetterDummy](https://github.com/waydabber/BetterDummy) by Istvan T.
- [apple-silicon-accelerometer](https://github.com/olvvier/apple-silicon-accelerometer) by Olivier Bourbonnais
- [OxWearables stepcount](https://github.com/OxWearables/stepcount)
- [Sparkle](https://sparkle-project.org/) for signed updates
- `/usr/bin/caffeinate`, Apple's built-in sleep-prevention tool

The code is MIT. Forks should use their own name and artwork so this Duck keeps
his pond.

## License

MIT. See [LICENSE](./LICENSE).
