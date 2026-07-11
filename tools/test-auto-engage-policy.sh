#!/bin/sh
# Regression-test AutoEngagePolicy — the pure decision core for Auto mode.
# No timers, no engines, no Settings; just asserts on decide() output for the
# three decision paths (source edge, grace fire, mode changes).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-auto-engage-policy.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-auto-engage-policy"

cat > "$TEST_MAIN" <<'SWIFT'
import Foundation

typealias Facts  = AutoEngagePolicy.Facts
typealias Action = AutoEngagePolicy.Action

func decide(_ e: AutoEngagePolicy.Event, _ f: Facts) -> [Action] {
    AutoEngagePolicy.decide(e, f)
}

func check(_ label: String, _ got: [Action], _ want: [Action]) {
    if got != want {
        fputs("FAIL: \(label)\n  got:  \(got)\n  want: \(want)\n", stderr)
        exit(1)
    }
}

/// Baseline: Auto on, source idle, stack down, battery fine, 5-min grace.
func facts(autoEnabled: Bool = true, working: Bool = false, engaged: Bool = false,
           engagedByAuto: Bool = false, dontDieTriggered: Bool = false,
           graceSecs: Int = 300) -> Facts {
    Facts(autoEnabled: autoEnabled, working: working, engaged: engaged,
          engagedByAuto: engagedByAuto, dontDieTriggered: dontDieTriggered,
          graceSecs: graceSecs)
}

// MARK: - sourceChanged (the activity edge)

// 1. Source gets busy while idle: raise the stack (and drop any pending
//    stand-down first — compound moves stay explicit).
check("busy while idle → engage",
      decide(.sourceChanged, facts(working: true)),
      [.cancelStandDown, .engage])

// 2. Source busy while already engaged (either reason): just cancel a pending
//    stand-down; never double-engage.
check("busy while engaged → cancel only",
      decide(.sourceChanged, facts(working: true, engaged: true, engagedByAuto: true)),
      [.cancelStandDown])
check("busy while manually engaged → cancel only",
      decide(.sourceChanged, facts(working: true, engaged: true)),
      [.cancelStandDown])

// 3. Don't Die wins on battery: after the low-battery cutout fired, auto must
//    not re-engage (it would drain the battery to zero).
check("busy but Don't Die fired → cancel only",
      decide(.sourceChanged, facts(working: true, dontDieTriggered: true)),
      [.cancelStandDown])

// 4. Source goes idle while auto-engaged: start the grace countdown.
check("idle while auto-engaged → stand down after grace",
      decide(.sourceChanged, facts(engaged: true, engagedByAuto: true)),
      [.standDown(after: 300)])

// 5. Grace 0 is policy, not a zero-length timer: disengage now.
check("idle, grace 0 → disengage now",
      decide(.sourceChanged, facts(engaged: true, engagedByAuto: true, graceSecs: 0)),
      [.disengage])

// 6. Manual mode wins: auto only releases what auto raised.
check("idle while manually engaged → nothing",
      decide(.sourceChanged, facts(engaged: true)),
      [])

// 7. Idle while already idle: nothing to do.
check("idle while idle → nothing",
      decide(.sourceChanged, facts()),
      [])

// 8. Defensive: a late signal outside Auto must never move the stack.
check("signal outside Auto → nothing",
      decide(.sourceChanged, facts(autoEnabled: false, working: true)),
      [])

// MARK: - graceFired (the stand-down timer's re-check)

// 9. Still auto-engaged and still idle at fire time: stand down.
check("grace fired, still idle → disengage",
      decide(.graceFired, facts(engaged: true, engagedByAuto: true)),
      [.disengage])

// 10. Source got busy again before the timer fired: leave the stack up.
check("grace fired but busy again → nothing",
      decide(.graceFired, facts(working: true, engaged: true, engagedByAuto: true)),
      [])

// 11. Auto no longer owns the engagement (user chose On meanwhile): hands off.
check("grace fired, manual owns → nothing",
      decide(.graceFired, facts(engaged: true)),
      [])
check("grace fired, already idle → nothing",
      decide(.graceFired, facts()),
      [])

// MARK: - autoToggled (Settings flips Auto on/off)

// 12. Auto turned on while a source is busy: engage immediately.
check("auto on, source busy → engage",
      decide(.autoToggled, facts(working: true)),
      [.cancelStandDown, .engage])

// 13. Auto turned on while idle: nothing until an edge arrives.
check("auto on, idle → nothing",
      decide(.autoToggled, facts()),
      [])

// 14. Auto turned off while auto-engaged: drop the pending stand-down and
//     release the stack.
check("auto off while auto-engaged → cancel + disengage",
      decide(.autoToggled, facts(autoEnabled: false, engaged: true, engagedByAuto: true)),
      [.cancelStandDown, .disengage])

// 15. Auto turned off while manually engaged: a manual engage is left alone.
check("auto off while manual → cancel only",
      decide(.autoToggled, facts(autoEnabled: false, engaged: true)),
      [.cancelStandDown])

// MARK: - adoptedFromManual (setMode(.auto) while manually engaged)

// 16. Entering Auto with a manual engage and a busy source: auto adopts the
//     engagement (no teardown + re-engage flicker).
check("adopt, source busy → adopt as auto",
      decide(.adoptedFromManual, facts(working: true, engaged: true)),
      [.adoptAsAuto])

// 17. Entering Auto with a manual engage and no work: release the stack —
//     Auto only holds while sources prove work.
check("adopt, idle → disengage",
      decide(.adoptedFromManual, facts(engaged: true)),
      [.disengage])

// 18. Defensive: adoption only applies to a live manual engagement.
check("adopt but not engaged → nothing",
      decide(.adoptedFromManual, facts(working: true)),
      [])
check("adopt but auto already owns → nothing",
      decide(.adoptedFromManual, facts(working: true, engaged: true, engagedByAuto: true)),
      [])

print("auto engage policy: ok")
SWIFT

swiftc "$ROOT/Sources/AutoEngagePolicy.swift" "$TEST_MAIN" -o "$BIN"
"$BIN"
