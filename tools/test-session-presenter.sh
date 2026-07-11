#!/bin/sh
# Regression-test SessionPresenter — the one session→presentation mapping
# shared by the menu rows, the popover cards, and status.json. Pins the
# state-word / dot-color truth table and the formatters so the three surfaces
# can't drift.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-session-presenter.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-session-presenter"

cat > "$TEST_MAIN" <<'SWIFT'
import AppKit

// ActivitySourceMonitor.swift compiles alongside; give it its Settings seam.
enum Settings {
    static var enabledSources: Set<String> = []
    static func isSourceEnabled(_ name: String) -> Bool { enabledSources.contains(name) }
}

func fail(_ msg: String) -> Never {
    fputs("FAIL: \(msg)\n", stderr)
    exit(1)
}

func session(state: String = "active", working: Bool = false, tools: Int = 0,
             external: Bool = false) -> ActivitySourceSession {
    ActivitySourceSession(id: "s", state: state, cwd: nil, terminal: "Claude",
                          transcriptPath: nil, signal: external ? "file" : nil,
                          detail: nil, mtime: Date(), working: working,
                          toolsInFlight: tools, isExternal: external)
}

// The truth table: word + dot, all five rows.
let rows: [(ActivitySourceSession, String, NSColor, String)] = [
    (session(working: true, tools: 2),            "running",       .systemGreen,  "reported busy with tools"),
    (session(working: true),                      "active",        .systemGreen,  "reported busy, thinking"),
    (session(state: "waiting"),                   "waiting",       .systemOrange, "reported waiting"),
    (session(state: "active"),                    "idle",          .systemGray,   "reported gone idle"),
    (session(working: true, external: true),      "activity seen", .systemGreen,  "observed busy"),
    (session(external: true),                     "idle",          .systemGray,   "observed idle"),
]
for (s, word, color, label) in rows {
    if SessionPresenter.word(s) != word { fail("\(label): want word \(word), got \(SessionPresenter.word(s))") }
    if SessionPresenter.dotColor(s) != color { fail("\(label): wrong dot color") }
}

// Detail rows: state word first, proof second; observed adds "estimate",
// reported adds a tool count while running.
let obs = SessionPresenter.detailBits(session(working: true, external: true))
if obs.first != "activity seen" || obs.last != "estimate" { fail("observed detail bits: \(obs)") }
let rep = SessionPresenter.detailBits(session(working: true, tools: 2))
if rep.first != "running" || !rep.contains("2 tools") { fail("reported detail bits: \(rep)") }
let one = SessionPresenter.detailBits(session(working: true, tools: 1))
if !one.contains("1 tool") { fail("singular tool count: \(one)") }

// Formatters.
if SessionPresenter.mmss(65) != "1:05" { fail("mmss minutes") }
if SessionPresenter.mmss(3_725) != "1:02:05" { fail("mmss hours") }
if SessionPresenter.abbrevTokens(950) != "950" { fail("abbrev plain") }
if SessionPresenter.abbrevTokens(1_234) != "1.2K" { fail("abbrev K") }
if SessionPresenter.abbrevTokens(1_200_000) != "1.2M" { fail("abbrev M") }

print("session presenter: ok")
SWIFT

swiftc "$ROOT/Sources/SourceCatalog.swift" \
    "$ROOT/Sources/ActivitySourceMonitor.swift" \
    "$ROOT/Sources/SessionPresenter.swift" \
    "$TEST_MAIN" \
    -framework AppKit \
    -o "$BIN"
"$BIN"
