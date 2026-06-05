#!/bin/sh
# StayUp Activity Source hook.
#
# Registered by ActivitySourceHookInstaller or by a compatible local tool config. The
# tool pipes the hook event JSON on stdin.
#
#   <action> = turn-start | active | waiting | tool-begin | tool-end | stop
#
# Per-session state under ~/.stayup/sources/<source>/active/:
#   <session_id>        marker — line 1 state (active|waiting) + cwd/term/tx/pid;
#                       mtime = last activity.
#   <session_id>.tools/ one file per tool currently in flight (tool-begin adds,
#                       tool-end removes). Lets the reader tell "a tool is
#                       running right now" from "idle", so a long build never
#                       looks idle and an interrupted turn recovers fast.
# Always exits 0 — a hook must never block or fail a turn.

action="${1:-active}"

slugify() {
    out=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/^-*//; s/-*$//; s/--*/-/g')
    [ -n "$out" ] && printf '%s' "$out" || printf '%s' "source"
}
json_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

source_name="${STAYUP_SOURCE_NAME:-Tool}"
source_display="${STAYUP_SOURCE_DISPLAY:-$source_name}"
source_key="${STAYUP_SOURCE_KEY:-$source_name}"
source_slug=$(slugify "${STAYUP_SOURCE_SLUG:-$source_display}")

# Codex surfaces currently prove "activity happened" more reliably than paired
# tool lifetimes. Normalize old in-memory Codex hook mappings too, so a running
# Codex process that still calls `tool-begin` / `tool-end` can't create fake
# in-flight counters.
case "$source_slug:$action" in
    codex-cli:tool-begin|codex-cli:tool-end) action="active" ;;
esac

root="$HOME/.stayup/sources/$source_slug"
dir="$root/active"
source_file="$root/source.json"

json=$(cat)
field() {
    printf '%s' "$json" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

sid=$(printf '%s' "${STAYUP_SESSION_ID:-$(field session_id)}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.]*//')
[ -n "$sid" ] || sid="unknown"
file="$dir/$sid"
tools="$file.tools"

tool_raw="${STAYUP_TOOL_ID:-$(field tool_call_id)}"
[ -n "$tool_raw" ] || tool_raw="$(field tool_use_id)"
[ -n "$tool_raw" ] || tool_raw="$(field call_id)"
tool_id=$(printf '%s' "$tool_raw" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.]*//')

mkdir -m 700 -p "$dir" 2>/dev/null
if [ ! -f "$source_file" ]; then
    display_json=$(json_string "$source_display")
    source_json=$(json_string "$source_key")
    cat > "$source_file" <<EOF 2>/dev/null
{
  "displayName": "$display_json",
  "method": "reported",
  "name": "$source_json",
  "schema": "app.getstayup.activity-source.v1",
  "type": "reported"
}
EOF
fi

# Session end → drop everything for this session. Tool-specific installers decide
# which upstream event means "turn is waiting" and which means "session is gone".
if [ "$action" = "stop" ]; then
    rm -f "$file" 2>/dev/null
    rm -rf "$tools" 2>/dev/null
    exit 0
fi

# A repeated "waiting" ping must not refresh the heartbeat. The waiting TTL runs
# from the first transition into waiting; any non-waiting action resets it.
# Still clear stale tool markers: waiting means no tools are running.
if [ "$action" = "waiting" ] && [ "$(sed -n 1p "$file" 2>/dev/null)" = "waiting" ]; then
    rm -rf "$tools" 2>/dev/null
    exit 0
fi

# Write/refresh the marker (state token + context) for every other action.
# Refuse a pre-planted symlink: `> "$file"` would otherwise follow it and
# redirect our write to an attacker-chosen path. The marker must be a plain file.
[ -L "$file" ] && rm -f "$file" 2>/dev/null
cwd=$(field cwd)
tx=$(field transcript_path)
term="${STAYUP_SOURCE_NAME:-${TERM_PROGRAM:-}}"
case "$action" in waiting) tok="waiting" ;; *) tok="active" ;; esac
# Write via temp + atomic rename so state changes update the directory entry.
# The dotfile temp is skipped by the reader.
tmp="$dir/.$sid.tmp.$$"
{
    echo "$tok"
    [ -n "$cwd" ]  && echo "cwd=$cwd"
    [ -n "$term" ] && echo "term=$term"
    [ -n "$tx" ]   && echo "tx=$tx"
    echo "pid=$PPID"
} > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null

# Tool-in-flight bookkeeping.
case "$action" in
    turn-start)
        rm -rf "$tools" 2>/dev/null ;;                        # fresh turn: clear any leaked markers
    waiting)
        rm -rf "$tools" 2>/dev/null ;;                        # turn done: visible, but no tools in flight
    tool-begin)
        [ -L "$tools" ] && rm -rf "$tools" 2>/dev/null
        mkdir -m 700 -p "$tools" 2>/dev/null
        if [ -n "$tool_id" ]; then
            : > "$tools/$tool_id" 2>/dev/null
        else
            stamp="$(date +%s)-$$"
            : > "$tools/$stamp" 2>/dev/null
        fi ;;
    tool-end)
        if [ -n "$tool_id" ]; then
            rm -f "$tools/$tool_id" 2>/dev/null
        elif [ -d "$tools" ]; then
            for f in "$tools"/*; do [ -e "$f" ] && rm -f "$f" && break; done
        fi ;;
esac

exit 0
