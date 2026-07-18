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

// Engaged, screen kept on, no real external, NO built-in panel — the headless
// desktop (Mac mini/Studio) baseline. The virtual display is the only surface a
// remote session can land on, so it spawns; the display-sleep flag stays held or
// the virtual idle-sleeps (~4 min) and remote GUI sessions go black (CRD
// regression, 2026-07-04). Laptops never take this path — they keep their
// built-in as the surface (dimmed to backlight-0 on lid-close, outside the
// planner). Default hasBuiltinDisplay:false = the desktop case.
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

// 8. Laptop engage (a built-in panel is present): everything but the virtual
//    display — the built-in is the surface, lid open or shut. On lid-close it's
//    dimmed to backlight-0 (handled in MenuController, not the planner), so no
//    fake display is ever spawned. This is the case that used to spawn a virtual
//    on lid-close; it no longer does.
let laptopKeepOn = Desired(engaged: true, keepScreenOn: true,
                           hasExternalDisplay: false, hasBuiltinDisplay: true)
check("engage laptop (built-in present)",
      plan(from: nil, to: laptopKeepOn),
      [.enable(.caffeinate, preventDisplaySleep: true),
       .enable(.sleepPreventer, preventDisplaySleep: true),
       .enable(.closedLid, preventDisplaySleep: false),
       .enable(.helper, preventDisplaySleep: false)])

// 9. keepScreenOn flips off on a laptop: only caffeinate/sleepPreventer re-arm.
//    Contrast test 4 (desktop) which also drops the virtual — a laptop never had
//    one to drop.
check("laptop keepScreenOn flip",
      plan(from: laptopKeepOn, to: Desired(engaged: true, keepScreenOn: false,
                                           hasExternalDisplay: false, hasBuiltinDisplay: true)),
      [.rearm(.caffeinate, preventDisplaySleep: false),
       .rearm(.sleepPreventer, preventDisplaySleep: false)])

print("sleep stack planner policy: ok")
SWIFT

swiftc "$ROOT/Sources/SleepStackPlanner.swift" "$TEST_MAIN" -o "$BIN"
"$BIN"
