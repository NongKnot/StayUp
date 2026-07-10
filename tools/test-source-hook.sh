#!/bin/bash
# Smoke-test the StayUp source hook lifecycle without touching real user state.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/tools/stayup-source-hook.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SID="stayup-test"
MARKER="$TMP/.stayup/sources/codex-cli/active/$SID"
TOOLS="$MARKER.tools"
JSON='{"session_id":"stayup-test","cwd":"/tmp/stayup-test","transcript_path":"/tmp/stayup-test.jsonl"}'

call_hook() {
    local payload="${2:-$JSON}"
    printf '%s' "$payload" | HOME="$TMP" \
        STAYUP_SOURCE_NAME=Codex \
        STAYUP_SOURCE_SLUG=codex-cli \
        STAYUP_SOURCE_DISPLAY="Codex" \
        STAYUP_SOURCE_KEY=Codex \
        /bin/sh "$HOOK" "$1"
}

call_generic_hook() {
    local payload="${2:-$JSON}"
    printf '%s' "$payload" | HOME="$TMP" \
        STAYUP_SOURCE_NAME=Tool \
        STAYUP_SOURCE_SLUG=tool-cli \
        STAYUP_SOURCE_DISPLAY="Tool CLI" \
        STAYUP_SOURCE_KEY=Tool \
        /bin/sh "$HOOK" "$1"
}

call_generic_hook_no_action() {
    local payload="${1:-$JSON}"
    printf '%s' "$payload" | HOME="$TMP" \
        STAYUP_SOURCE_NAME=Tool \
        STAYUP_SOURCE_SLUG=tool-cli \
        STAYUP_SOURCE_DISPLAY="Tool CLI" \
        STAYUP_SOURCE_KEY=Tool \
        /bin/sh "$HOOK"
}

call_scoped_claude_hook() {
    local payload="$1"
    printf '%s' "$payload" | HOME="$TMP" \
        STAYUP_SOURCE_NAME=Claude \
        STAYUP_SOURCE_SLUG=claude-code-cli \
        STAYUP_SOURCE_DISPLAY="Claude" \
        STAYUP_SOURCE_KEY=Claude \
        STAYUP_SOURCE_TRANSCRIPT_PREFIXES="$TMP/.claude/" \
        /bin/sh "$HOOK" working
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

first_line() {
    sed -n '1p' "$MARKER" 2>/dev/null || true
}

marker_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$MARKER" 2>/dev/null | head -n 1
}

tool_count() {
    if [ -d "$TOOLS" ]; then
        find "$TOOLS" -type f | wc -l | tr -d ' '
    else
        echo 0
    fi
}

call_hook turn-start
[ "$(first_line)" = "active" ] || fail "turn-start should write active marker"
[ "$(tool_count)" = "0" ] || fail "turn-start should clear tool markers"

call_hook tool-begin
[ "$(first_line)" = "active" ] || fail "tool-begin should keep active marker"
[ "$(tool_count)" = "1" ] || fail "Codex tool-begin should add a tool marker"

call_hook tool-begin
[ "$(tool_count)" = "2" ] || fail "Codex duplicate tool-begin without stable id should add a separate tool marker"

call_hook tool-end
[ "$(tool_count)" = "1" ] || fail "Codex tool-end without stable id should remove one tool marker"

call_hook turn-start
[ "$(tool_count)" = "0" ] || fail "Codex turn-start should clear leaked tool markers"

call_hook waiting
[ "$(first_line)" = "waiting" ] || fail "waiting should keep marker visible as waiting"
[ "$(tool_count)" = "0" ] || fail "waiting should clear tool markers"

mkdir -p "$TOOLS"
: > "$TOOLS/leaked-tool"
mtime_before="$(stat -f %m "$MARKER")"
sleep 1
call_hook waiting
mtime_after="$(stat -f %m "$MARKER")"
[ "$mtime_before" = "$mtime_after" ] || fail "repeated waiting should not refresh marker mtime"
[ "$(tool_count)" = "0" ] || fail "repeated waiting should still clear leaked tool markers"

call_hook active
[ "$(first_line)" = "active" ] || fail "active should refresh marker to active"

CLAUDE_MARKER="$TMP/.stayup/sources/claude-code-cli/active/cross-source"
CURSOR_PAYLOAD="{\"session_id\":\"cross-source\",\"transcript_path\":\"$TMP/.cursor/projects/cross-source.jsonl\"}"
CLAUDE_PAYLOAD="{\"session_id\":\"cross-source\",\"transcript_path\":\"$TMP/.claude/projects/cross-source.jsonl\"}"
call_scoped_claude_hook "$CURSOR_PAYLOAD"
[ ! -e "$CLAUDE_MARKER" ] || fail "scoped Claude wrapper should ignore Cursor transcript payloads"
[ ! -e "$TMP/.stayup/sources/claude-code-cli/source.json" ] || fail "ignored transcript payload should not create a source recipe"
call_scoped_claude_hook "$CLAUDE_PAYLOAD"
[ "$(sed -n '1p' "$CLAUDE_MARKER" 2>/dev/null)" = "active" ] || fail "scoped Claude wrapper should accept Claude transcript payloads"

MARKER="$TMP/.stayup/sources/tool-cli/active/$SID"
TOOLS="$MARKER.tools"
call_generic_hook turn-start
TOOL_JSON='{"session_id":"stayup-test","tool_call_id":"stable-tool","cwd":"/tmp/stayup-test"}'
call_generic_hook tool-begin "$TOOL_JSON"
call_generic_hook tool-begin "$TOOL_JSON"
[ "$(tool_count)" = "1" ] || fail "stable tool id should not double-count duplicate tool-begin"
call_generic_hook tool-end "$TOOL_JSON"
[ "$(tool_count)" = "0" ] || fail "stable tool id should remove the matching tool marker"

call_generic_hook working
[ "$(first_line)" = "active" ] || fail "working alias should write active marker"

expected_pid="$$"
STAYUP_SOURCE_PID="$expected_pid" call_generic_hook working
[ "$(marker_value pid)" = "$expected_pid" ] || fail "STAYUP_SOURCE_PID should be preferred as the source pid"

MULTILINE_JSON='{
  "session_id": "multi-session",
  "cwd": "/tmp/stayup-test-multiline",
  "source_pid": 12345
}'
MULTILINE_MARKER="$TMP/.stayup/sources/tool-cli/active/multi-session"
call_generic_hook working "$MULTILINE_JSON"
[ -e "$MULTILINE_MARKER" ] || fail "multiline JSON session_id should be parsed"
[ "$(sed -n 's/^pid=//p' "$MULTILINE_MARKER" | head -n 1)" = "12345" ] || fail "numeric JSON source_pid should be parsed"

call_generic_hook PreToolUse "$TOOL_JSON"
[ "$(tool_count)" = "1" ] || fail "PreToolUse alias should add a tool marker"
call_generic_hook PostToolUse "$TOOL_JSON"
[ "$(tool_count)" = "0" ] || fail "PostToolUse alias should remove the matching tool marker"
call_generic_hook PreCompact "$TOOL_JSON"
[ "$(first_line)" = "active" ] || fail "PreCompact alias should refresh active marker"
call_generic_hook PostCompact "$TOOL_JSON"
[ "$(first_line)" = "active" ] || fail "PostCompact alias should refresh active marker"
call_generic_hook PermissionRequest "$TOOL_JSON"
[ "$(first_line)" = "waiting" ] || fail "PermissionRequest alias should mark waiting"
call_generic_hook PermissionDenied "$TOOL_JSON"
[ "$(first_line)" = "waiting" ] || fail "PermissionDenied alias should mark waiting"
call_generic_hook StopFailure "$TOOL_JSON"
[ "$(first_line)" = "waiting" ] || fail "StopFailure alias should mark waiting"
call_generic_hook PostToolUseFailure "$TOOL_JSON"
[ "$(first_line)" = "active" ] || fail "PostToolUseFailure alias should keep marker active"
call_generic_hook afterAgentThought "$TOOL_JSON"
[ "$(first_line)" = "active" ] || fail "afterAgentThought alias should refresh active marker"
call_generic_hook afterAgentResponse "$TOOL_JSON"
[ "$(first_line)" = "waiting" ] || fail "afterAgentResponse alias should mark waiting"

call_generic_hook not-working
[ "$(first_line)" = "waiting" ] || fail "not-working alias should write waiting marker"

call_generic_hook nonsense-state
[ "$(first_line)" = "waiting" ] || fail "unknown action should not mark the source active"

call_generic_hook_no_action
[ "$(first_line)" = "waiting" ] || fail "missing action should not mark the source active"

call_generic_hook stop
[ ! -e "$MARKER" ] || fail "stop should remove marker"
[ ! -e "$TOOLS" ] || fail "stop should remove tool directory"

printf '{}' | HOME="$TMP" \
    STAYUP_SOURCE_NAME=Odd \
    STAYUP_SOURCE_SLUG=".." \
    STAYUP_SOURCE_DISPLAY="Odd CLI" \
    STAYUP_SOURCE_KEY=Odd \
    /bin/sh "$HOOK" working
[ ! -e "$TMP/.stayup/source.json" ] || fail "dot source slug should not escape sources directory"
[ -e "$TMP/.stayup/sources/source/source.json" ] || fail "dot source slug should fall back to safe source slug"

SYMLINK_TARGET="$TMP/symlink-target"
mkdir -p "$TMP/.stayup/sources/symlink-cli"
ln -s "$SYMLINK_TARGET" "$TMP/.stayup/sources/symlink-cli/source.json"
printf '{}' | HOME="$TMP" \
    STAYUP_SOURCE_NAME=Symlink \
    STAYUP_SOURCE_SLUG=symlink-cli \
    STAYUP_SOURCE_DISPLAY="Symlink CLI" \
    STAYUP_SOURCE_KEY=Symlink \
    STAYUP_SESSION_ID=symlink-test \
    /bin/sh "$HOOK" working
[ ! -L "$TMP/.stayup/sources/symlink-cli/source.json" ] || fail "source.json symlink should be replaced"
[ ! -e "$SYMLINK_TARGET" ] || fail "source.json symlink target should not be written"

OUTSIDE="$TMP/outside-source-root"
mkdir -p "$OUTSIDE"
ln -s "$OUTSIDE" "$TMP/.stayup/sources/rootlink-cli"
printf '{}' | HOME="$TMP" \
    STAYUP_SOURCE_NAME=Rootlink \
    STAYUP_SOURCE_SLUG=rootlink-cli \
    STAYUP_SOURCE_DISPLAY="Rootlink CLI" \
    STAYUP_SOURCE_KEY=Rootlink \
    STAYUP_SESSION_ID=rootlink-test \
    /bin/sh "$HOOK" working
[ ! -e "$OUTSIDE/source.json" ] || fail "source root symlink target should not be written"
[ ! -L "$TMP/.stayup/sources/rootlink-cli" ] || fail "source root symlink should be replaced"
[ -e "$TMP/.stayup/sources/rootlink-cli/source.json" ] || fail "source root symlink should become a real source folder"

echo "source hook lifecycle: ok"
