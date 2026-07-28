#!/bin/sh
# StayUp — the one live tester. Shows EVERYTHING about StayUp, live, by rendering
# the state the app publishes to ~/.stayup/status.json. The app computes it all
# (engage, the 5 layers, power, Don't Die, walk, mode, sources, nap countdown), so
# this is a pure renderer — no logic here to drift out of sync.
#
#   bash tools/stayup.sh             # live dashboard (Ctrl-C to quit)
#   bash tools/stayup.sh once        # one snapshot and exit
#   bash tools/stayup.sh fake work   # fake a running source (also: wait | done)
#
# Also launchable from StayUp → Settings → About: click Duck's LEFT EYE.
# (Replaces the old looker / devbench / source-tester scripts.)

FAKE_ROOT="$HOME/.stayup/sources/fake-tester"
FAKE_ACTIVE="$FAKE_ROOT/active"
FAKE_SOURCE="$FAKE_ROOT/source.json"

if [ "${1:-}" = "fake" ]; then
    mkdir -m 700 -p "$FAKE_ACTIVE"
    if [ ! -f "$FAKE_SOURCE" ]; then
        cat > "$FAKE_SOURCE" <<'JSON'
{
  "displayName": "Fake Tester",
  "method": "file",
  "name": "Fake Tester",
  "schema": "app.getstayup.activity-source.v1",
  "type": "file",
  "path": "~/.stayup/sources/fake-tester/active/state",
  "freshSecs": 45
}
JSON
    fi
    file="$FAKE_ACTIVE/state"
    case "${2:-work}" in
        work) printf 'active\nterm=FakeTester\npid=0\nsignal=file\ndetail=fake fresh marker\n' > "$file"
              rm -rf "$file.tools"
              echo "faked a RUNNING estimated local source";;
        wait) printf 'waiting\nterm=FakeTester\npid=0\nsignal=file\ndetail=fake waiting marker\n' > "$file"
              rm -rf "$file.tools"; echo "faked a WAITING source";;
        done|stop|clear) rm -rf "$file" "$file.tools"; echo "cleared fake source";;
        *) echo "usage: fake work|wait|done";;
    esac
    exit 0
fi

exec /usr/bin/python3 - "${1:-}" <<'PY'
import json, os, sys, time

ONCE = (len(sys.argv) > 1 and sys.argv[1] == "once")
STATUS = os.path.expanduser("~/.stayup/status.json")
SOURCE_LABELS = {
    "Claude Code CLI": "Claude",
    "Codex CLI": "Codex",
}

def source_label(name):
    return SOURCE_LABELS.get(name, name)

def adot(a):
    if a.get("external"): return "🟢" if a.get("working") else "○"
    if a.get("working"):  return "🟢"
    return "🟡" if a.get("state") == "waiting" else "⚪️"

def toks(n):
    return f"{n/1e6:.1f}M" if n >= 1e6 else (f"{n/1e3:.1f}K" if n >= 1e3 else str(n))

def render():
    if not ONCE: sys.stdout.write("\033[2J\033[H")
    try:
        with open(STATUS) as f: s = json.load(f)
    except Exception:
        print("StayUp — no status yet. Is the app running?"); return
    age = int(time.time()) - s.get("ts", 0)
    print(f"StayUp — live{'' if ONCE else '   (Ctrl-C to quit)'}   · updated {age}s ago")
    print("═" * 52)
    protected = "🟢 ON" if s.get("active") else "⚪️ IDLE"
    print(f"Mode: {s.get('mode','?').upper():<5} StayUp: {protected}   Keep screen: {'on' if s.get('keepScreenOn') else 'off'}")
    nap = s.get("napAt")
    if nap:
        r = nap - int(time.time())
        if r > 0:
            h, m, sec = r//3600, (r%3600)//60, r%60
            print(f"💤 Mac naps in " + (f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}"))
    bat = s.get("batteryPct"); bats = f" {bat}%" if bat is not None else ""
    dd = "TRIGGERED" if s.get("dontDieTriggered") else (f"armed ({s.get('dontDiePct')}%)" if s.get("dontDieEnabled") else "off")
    print(f"Power: {s.get('power','?')}{bats}    Don't Die: {dd}")
    L = lambda k: "●" if s.get(k) else "○"
    pmset = L("sleepDisabled") if "sleepDisabled" in s else "?"
    print(f"Layers: caffeinate {L('caffeinate')} · sleep {L('sleep')} · lid {L('lid')} · vdisplay {L('virtualDisplay')} · helper {L('helper')} · pmset {pmset}")
    lcm = s.get("lidClosedMode")
    if lcm:
        print("Lid closed: " + ("🛑 panel OFF (clamshell)" if lcm == "clamshell-off" else "🌙 backlight-0 fallback"))
    if s.get("walking"):
        w = s.get("walkSecs", 0); print(f"Walk: 🚶 {w//60}:{w%60:02d} · {s.get('walkSteps',0)} steps")
    print("─" * 52)
    sources = s.get("sources", [])
    any_source = s.get("anySourceWorking")
    print(f"Activity Sources (keeping Mac up: {'YES' if any_source else 'no'}):")
    if not sources:
        print("  (none — tick a source in Settings → Auto, and use Auto mode)")
    for a in sources:
        line = f"  {adot(a)} {a.get('label','?'):<26} {a.get('state','?')}"
        if a.get("tools", 0) > 0: line += f" · {a['tools']} tool" + ("" if a['tools'] == 1 else "s")
        if "tokens" in a: line += f" · {toks(a['tokens'])} tok"
        if a.get("proof"): line += f" · {a['proof']}"
        print(line)
    enabled = [source_label(x) for x in s.get("enabledSources", [])]
    print("Sources on: " + (", ".join(enabled) or "none"))
    print("─" * 52)
    sys.stdout.flush()

if ONCE: render()
else:
    while True:
        render(); time.sleep(1)
PY
