#!/bin/sh
# Regression-test the SleepStack planner — the pure policy for the five-layer
# sleep-prevention stack. No engines, no IOKit; just asserts on plan() output.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-sleep-stack-planner.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-sleep-stack-planner"

cat > "$TEST_MAIN" <<'SWIFT'
import Foundation

typealias Desired = SleepPlanner.Desired
typealias LayerAction = SleepPlanner.LayerAction
func plan(from old: Desired?, to new: Desired) -> [LayerAction] { SleepPlanner.plan(from: old, to: new) }

func check(_ label: String, _ got: [LayerAction], _ want: [LayerAction]) {
    if got != want {
        fputs("FAIL: \(label)\n  got:  \(got)\n  want: \(want)\n", stderr)
        exit(1)
    }
}

// Engaged, screen kept on, no real external, lid shut — the baseline closed-lid
// "on" state. The virtual display is the surface and the display-sleep flag
// stays held: without it the virtual display idle-sleeps (~4 min) and remote
// GUI sessions go black (CRD regression, 2026-07-04). Clamshell firmware keeps
// the shut built-in panel dark regardless.
let engagedKeepOn = Desired(engaged: true, keepScreenOn: true, hasExternalDisplay: false)

// 1. Engage from idle (lid shut): all five layers come up, virtual display
//    included, display-sleep prevention held so the virtual display never
//    idle-sleeps out from under a remote session.
check("engage keepScreenOn",
      plan(from: nil, to: engagedKeepOn),
      [.enable(.caffeinate, preventDisplaySleep: true),
       .enable(.sleepPreventer, preventDisplaySleep: true),
       .enable(.closedLid, preventDisplaySleep: false),
       .enable(.virtualDisplay, preventDisplaySleep: false),
       .enable(.helper, preventDisplaySleep: false)])

// 2. Engage in screen-lock mode: system layers only (display free to sleep),
//    no virtual display, caffeinate/sleepPreventer drop the display-sleep flag.
check("engage screen-lock",
      plan(from: nil, to: Desired(engaged: true, keepScreenOn: false, hasExternalDisplay: false)),
      [.enable(.caffeinate, preventDisplaySleep: false),
       .enable(.sleepPreventer, preventDisplaySleep: false),
       .enable(.closedLid, preventDisplaySleep: false),
       .enable(.helper, preventDisplaySleep: false)])

// 3. Engage with a real external attached: the virtual display stands down.
check("engage external present",
      plan(from: nil, to: Desired(engaged: true, keepScreenOn: true, hasExternalDisplay: true)),
      [.enable(.caffeinate, preventDisplaySleep: true),
       .enable(.sleepPreventer, preventDisplaySleep: true),
       .enable(.closedLid, preventDisplaySleep: false),
       .enable(.helper, preventDisplaySleep: false)])

// 4. keepScreenOn flips off mid-engage (still lid-shut): display prevention
//    re-arms off and the virtual display goes away.
check("keepScreenOn flip",
      plan(from: engagedKeepOn, to: Desired(engaged: true, keepScreenOn: false, hasExternalDisplay: false)),
      [.rearm(.caffeinate, preventDisplaySleep: false),
       .rearm(.sleepPreventer, preventDisplaySleep: false),
       .disable(.virtualDisplay)])

// 5. A real external arrives mid-engage (lid still shut): only the virtual
//    display drops — display prevention was already held and stays held.
check("external arrives",
      plan(from: engagedKeepOn, to: Desired(engaged: true, keepScreenOn: true, hasExternalDisplay: true)),
      [.disable(.virtualDisplay)])

// 6. Disengage: disable exactly what was on, in layer order.
check("disengage",
      plan(from: engagedKeepOn, to: Desired(engaged: false, keepScreenOn: false, hasExternalDisplay: false)),
      [.disable(.caffeinate),
       .disable(.sleepPreventer),
       .disable(.closedLid),
       .disable(.virtualDisplay),
       .disable(.helper)])

// 7. Re-applying an unchanged state is a no-op (the diff replaces the old guard).
check("no-op reapply",
      plan(from: engagedKeepOn, to: engagedKeepOn),
      [])

// 8. Lid open (MacBook in normal use): everything but the virtual display —
//    the built-in screen is right there, no fake display needed.
let engagedLidOpen = Desired(engaged: true, keepScreenOn: true,
                             hasExternalDisplay: false, lidClosed: false)
check("engage lid open",
      plan(from: nil, to: engagedLidOpen),
      [.enable(.caffeinate, preventDisplaySleep: true),
       .enable(.sleepPreventer, preventDisplaySleep: true),
       .enable(.closedLid, preventDisplaySleep: false),
       .enable(.helper, preventDisplaySleep: false)])

// 9. Lid shuts mid-engage: only the virtual display comes up — display
//    prevention stays held so the virtual display can't idle-sleep out from
//    under a remote session.
check("lid closes",
      plan(from: engagedLidOpen, to: engagedKeepOn),
      [.enable(.virtualDisplay, preventDisplaySleep: false)])

// 10. Lid reopens: only the virtual display drops.
check("lid opens",
      plan(from: engagedKeepOn, to: engagedLidOpen),
      [.disable(.virtualDisplay)])

print("sleep stack planner policy: ok")
SWIFT

swiftc "$ROOT/Sources/SleepStackPlanner.swift" "$TEST_MAIN" -o "$BIN"
"$BIN"
