# StayUp Agent Guide

This repo is a small macOS AppKit app. Keep changes narrow, honest, and easy to
review.

## Product Shape

StayUp is a menu-bar Duck that keeps local Mac work alive.

Core promises:

- Manual On/Off is direct user intent.
- Auto mode only acts while selected local Activity Sources report or prove
  work.
- Battery plus lid closed depends on the Helper path.
- Virtual display is for remote GUI/screen availability, not the hard sleep
  guarantee by itself.
- No telemetry, accounts, analytics, or crash reporting.

## Build And Test

Use the existing scripts:

```bash
bash build.sh
bash tools/test-hook-installer.sh
bash tools/test-source-hook.sh
```

For release work:

```bash
bash tools/release.sh
```

Do not replace the `swiftc` build with an Xcode project, SPM package, or new
dependency system unless the maintainer explicitly asks.

## Activity Sources

Read these before changing Auto mode behavior:

- `docs/activity-source-contract.md`
- `docs/activity-sources.md`
- `docs/activity-source-recipes/_template.md`

Rules:

- Name exact surfaces, not broad brands.
- Prefer reported sources when a tool has hooks or lifecycle events.
- Observed sources may use only v1 types: `file`, `logPattern`, `socket`, or
  `process`.
- App-open behavior is valid only when the user explicitly wants a presence
  source.
- Delete should safe-disable first. Clean Up Hooks should remove only
  StayUp-owned hook entries.

## Public Repo Hygiene

Do not commit unpublished operating plans, business notes, local credentials,
private Claude/Codex scratch files, generated app bundles, or site/deploy
artifacts.

Good public docs are welcome. Private operating notes are not.

## Brand

Duck is capital D. Keep public copy short, useful, and honest. Duck can be
funny, but claims still need proof.

Do not commit unpublished notes or strategy docs.
