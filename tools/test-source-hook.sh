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
        STAYUP_SOURCE_DISPLAY="Codex CLI" \
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

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

first_line() {
    sed -n '1p' "$MARKER" 2>/dev/null || true
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
[ "$(tool_count)" = "0" ] || fail "Codex tool-begin should be an active heartbeat, not a tool marker"

call_hook tool-begin
[ "$(tool_count)" = "0" ] || fail "Codex duplicate tool-begin should not add tool markers"

call_hook tool-end
[ "$(tool_count)" = "0" ] || fail "Codex tool-end should not add tool markers"

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

MARKER="$TMP/.stayup/sources/tool-cli/active/$SID"
TOOLS="$MARKER.tools"
call_generic_hook turn-start
TOOL_JSON='{"session_id":"stayup-test","tool_call_id":"stable-tool","cwd":"/tmp/stayup-test"}'
call_generic_hook tool-begin "$TOOL_JSON"
call_generic_hook tool-begin "$TOOL_JSON"
[ "$(tool_count)" = "1" ] || fail "stable tool id should not double-count duplicate tool-begin"
call_generic_hook tool-end "$TOOL_JSON"
[ "$(tool_count)" = "0" ] || fail "stable tool id should remove the matching tool marker"

call_generic_hook stop
[ ! -e "$MARKER" ] || fail "stop should remove marker"
[ ! -e "$TOOLS" ] || fail "stop should remove tool directory"

echo "source hook lifecycle: ok"
