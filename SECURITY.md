# Security policy

## Reporting a vulnerability

StayUp ships a **root LaunchDaemon** (`app.getstayup.helper`) that
runs `pmset disablesleep` on behalf of the menu-bar app over a Unix
socket at `/var/run/app.getstayup.helper.sock`. The daemon's plist
and binary live inside the app bundle (`Contents/Library/LaunchDaemons/`
+ `Contents/MacOS/`) and register via Apple's `SMAppService` API,
which requires the daemon and the parent app to share a Developer ID
team and validates the signature on every load. There is no sudo
installer.

If you find a way to abuse that path, such as privilege escalation, unsigned
binary substitution, or socket spoofing, please report it privately.

**Don't open a public issue.** Email instead:

> security@getstayup.app  *(routes to the maintainer)*

Or use [GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on the repo if you'd rather use the GitHub UI.

Reports are acknowledged as quickly as possible. Valid security issues are
prioritized for a signed and notarized release.

## Threat model — what's in scope

| Area | In scope |
|---|---|
| Helper daemon socket — anyone on the system can hit `/var/run/app.getstayup.helper.sock` (perms `0o777`). The daemon only accepts the strings `enable` and `disable`, but anything else here is fair game. | ✅ Yes |
| The Swift app reading the SPU accelerometer via raw IOKit | ✅ Yes |
| Codesigning gaps that would let an unsigned `app.getstayup.helper` get bootstrapped in place of the signed one | ✅ Yes |
| The notarization pipeline / DMG distribution | ✅ Yes |

## Threat model — what's NOT in scope

- **Anyone with admin/root on your Mac is already trusted.** If an
  attacker can already run `sudo`, they can install whatever daemon
  they want; this isn't a StayUp problem.
- **Apple sandbox bypasses.** StayUp deliberately runs unsandboxed
  (direct distribution, not Mac App Store) because battery + closed-lid
  coverage uses `CGVirtualDisplay` (private API) and a root daemon —
  both forbidden in App Store sandbox.
- **The CGVirtualDisplay private API.** Apple may break it in a future
  macOS release. Not a security issue; an availability one.
- **Third-party menu-bar shells / tooling that introspect StayUp's
  status item.** Out of scope.

## Privacy posture

For completeness — StayUp does not call this a "security feature" but
it's relevant context:

- **No network calls** during normal operation. Two exceptions:
  - Opening `getstayup.app/tip` in the user's browser when they click
    "Feed Duck" in Settings → About.
  - Signed update checks — opt-in only from Welcome, Settings, or
    Sparkle's second-launch prompt; users can also manually check for
    updates. Enabling automatic checks from StayUp starts one immediate
    background check so an available signed update can surface right away.
    Update payloads are EdDSA-signed so a compromised CDN can't ship a
    backdoored DMG.
- **Auto mode** reads local Activity Source files only: it watches
  `~/.stayup/sources/<source>/source.json` recipes and
  `~/.stayup/sources/<source>/active/` receipts, optionally parses
  known local transcripts for token counts, and edits supported local
  tool hook configs to register StayUp hooks. No network, no reading of
  other users' files. The hooks it installs run a local script
  (`~/.stayup/bin/stayup-source-hook.sh`) that only writes small
  heartbeat receipts under `~/.stayup/sources/`.
- **No telemetry, no analytics, no crash reporting, no accounts.**
- **Accelerometer data** is sampled locally only when StayUp is
  engaged, used for the walking Duck animation, and discarded after
  each sample. It never leaves the device.
- **UserDefaults** under `app.getstayup` stores user prefs locally
  (skin choice, Don't Die threshold, Resume on Launch flag, last walk
  count). Never transmitted.
