#!/bin/sh
# Regression-test SourceCatalog — the one reader for
# ~/.stayup/sources/<slug>/source.json. Pure reads against a fixture tree;
# no Settings, no writes.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/stayup-source-catalog.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

TEST_MAIN="$TMP/main.swift"
BIN="$TMP/test-source-catalog"
FIXTURES="$TMP/sources"

mkdir -p "$FIXTURES/claude-code/active"
cat > "$FIXTURES/claude-code/source.json" <<'JSON'
{
  "schema": "app.getstayup.activity-source.v1",
  "name": "Claude Code",
  "displayName": "Claude Code",
  "type": "reported",
  "method": "reported"
}
JSON

mkdir -p "$FIXTURES/ollama"
cat > "$FIXTURES/ollama/source.json" <<'JSON'
{
  "name": "Ollama",
  "displayName": "Ollama",
  "type": "process",
  "match": "ollama",
  "minCpu": 12,
  "freshSecs": 45
}
JSON

# method falls back to type; reported classification can come from either field.
mkdir -p "$FIXTURES/legacy-reported"
cat > "$FIXTURES/legacy-reported/source.json" <<'JSON'
{ "name": "Legacy", "type": "reported" }
JSON

# name is required; a nameless file yields no record.
mkdir -p "$FIXTURES/nameless"
cat > "$FIXTURES/nameless/source.json" <<'JSON'
{ "type": "file", "path": "~/x" }
JSON

# a folder without source.json yields no record (hand-made marker dirs).
mkdir -p "$FIXTURES/empty-folder/active"

cat > "$TEST_MAIN" <<'SWIFT'
import Foundation

func fail(_ msg: String) -> Never {
    fputs("FAIL: \(msg)\n", stderr)
    exit(1)
}

let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FIXTURES"]!, isDirectory: true)

let records = SourceCatalog.records(in: dir)
guard records.count == 3 else { fail("want 3 records (nameless + empty skipped), got \(records.count)") }

guard let claude = records.first(where: { $0.name == "Claude Code" }) else { fail("Claude Code record missing") }
if claude.folderSlug != "claude-code" { fail("folderSlug should be the folder name, got \(claude.folderSlug)") }
if claude.method != "reported" || !claude.isReported { fail("Claude Code should classify reported") }

guard let ollama = records.first(where: { $0.name == "Ollama" }) else { fail("Ollama record missing") }
if ollama.isReported { fail("observed source misclassified as reported") }
if ollama.method != "process" { fail("method should fall back to type, got \(ollama.method)") }
if (ollama.raw["match"] as? String) != "ollama" { fail("raw dict should carry recipe fields") }
if (ollama.raw["minCpu"] as? NSNumber)?.doubleValue != 12 { fail("raw dict should carry numeric recipe fields") }

guard let legacy = records.first(where: { $0.name == "Legacy" }) else { fail("legacy record missing") }
if !legacy.isReported { fail("type==reported alone should classify reported") }

// Single-folder read: same parse, one folder.
guard let one = SourceCatalog.record(sourceDir: dir.appendingPathComponent("ollama")) else { fail("record(sourceDir:) missing") }
if one.name != "Ollama" { fail("record(sourceDir:) wrong record") }
if SourceCatalog.record(sourceDir: dir.appendingPathComponent("empty-folder")) != nil { fail("folder without source.json should be nil") }
if SourceCatalog.record(sourceDir: dir.appendingPathComponent("nameless")) != nil { fail("nameless source.json should be nil") }

// The reported rule has exactly one definition; both call forms agree.
if SourceCatalog.isReported(method: "reported", type: "file") != true { fail("method rule") }
if SourceCatalog.isReported(method: "", type: "reported") != true { fail("type rule") }
if SourceCatalog.isReported(method: "process", type: "process") != false { fail("observed rule") }

print("source catalog: ok")
SWIFT

swiftc "$ROOT/Sources/SourceCatalog.swift" "$TEST_MAIN" -o "$BIN"
FIXTURES="$FIXTURES" "$BIN"
