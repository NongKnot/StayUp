#!/bin/sh
# Regression-test HelperWatchdog — the pure decision core for the layer-5
# re-arm loop. No timers, no ioreg, no helper socket; just asserts on tick()
# output: when to re-send "enable", how strikes accumulate, and when the
# degraded warning shows. Born from the 2026-07-18 incident: `pmset
# disablesleep` stripped system-wide behind an engaged app, lid close slept
# the Mac on battery, every agent connection died.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-helper-watchdog.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-helper-watchdog"

cat > "$TEST_MAIN" <<'SWIFT'
import Foundation

typealias Verdict = HelperWatchdog.Verdict

func check(_ label: String, _ got: Verdict, _ want: Verdict) {
    if got != want {
        fputs("FAIL: \(label)\n  got:  \(got)\n  want: \(want)\n", stderr)
        exit(1)
    }
}

// 1. Disengaged: nothing to guard — no re-arm, strikes reset. The flag being
//    off while idle is the CORRECT state, not a strip.
check("disengaged → idle, reset",
      HelperWatchdog.tick(engaged: false, sleepDisabled: false, strikes: 3),
      Verdict(rearm: false, strikes: 0))

// 2. Healthy: engaged and the kernel flag is up — no action, strikes reset.
check("engaged + flag on → healthy, reset",
      HelperWatchdog.tick(engaged: true, sleepDisabled: true, strikes: 2),
      Verdict(rearm: false, strikes: 0))

// 3. Stripped: engaged but the flag is down (second instance's launch
//    self-heal, daemon restart rescue, stray pmset) — re-arm, count a strike.
check("engaged + flag off → re-arm, strike 1",
      HelperWatchdog.tick(engaged: true, sleepDisabled: false, strikes: 0),
      Verdict(rearm: true, strikes: 1))

// 4. Still stripped on the next tick (the re-arm didn't stick): keep
//    re-arming, keep counting.
check("still stripped → re-arm, strike 2",
      HelperWatchdog.tick(engaged: true, sleepDisabled: false, strikes: 1),
      Verdict(rearm: true, strikes: 2))

// 5. Unreadable (ioreg failed / key absent on this macOS): don't thrash the
//    helper and don't accuse it — hold the strike count as-is.
check("engaged + unreadable → hold",
      HelperWatchdog.tick(engaged: true, sleepDisabled: nil, strikes: 1),
      Verdict(rearm: false, strikes: 1))

// 6. Recovery clears the slate: one healthy read forgives all strikes, so the
//    warning heals itself with no user action.
check("recovery after strikes → reset",
      HelperWatchdog.tick(engaged: true, sleepDisabled: true, strikes: 5),
      Verdict(rearm: false, strikes: 0))

// 7. The warning boundary is policy, not caller arithmetic: one failed
//    re-arm is a blip; two consecutive means it won't stick — warn.
if HelperWatchdog.degraded(strikes: 1) {
    fputs("FAIL: degraded at 1 strike — a single blip must not warn\n", stderr)
    exit(1)
}
if !HelperWatchdog.degraded(strikes: 2) {
    fputs("FAIL: not degraded at 2 strikes — persistent strip must warn\n", stderr)
    exit(1)
}

print("test-helper-watchdog: all checks passed")
SWIFT

xcrun swiftc "$ROOT/Sources/HelperWatchdog.swift" "$TEST_MAIN" -o "$BIN"
"$BIN"
