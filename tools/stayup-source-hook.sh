#!/bin/sh
# StayUp Activity Source hook.
#
# Registered by ActivitySourceHookInstaller or by a compatible local tool config. The
# tool pipes the hook event JSON on stdin.
#
#   <action> = working | not-working | stop
#   Exact hook integrations may also use:
#   turn-start | active | waiting | tool-begin | tool-end
#
# Per-session state under ~/.stayup/sources/<source>/active/:
#   <session_id>        marker — line 1 state (active|waiting) + cwd/term/tx/pid;
#                       mtime = last activity.
#   <session_id>.tools/ one file per tool currently in flight (tool-begin adds,
#                       tool-end removes). Lets the reader tell "a tool is
#                       running right now" from "idle", so a long build never
#                       looks idle and an interrupted turn recovers fast.
# Always exits 0 — a hook must never block or fail a turn.

raw_action="${1:-not-working}"
action=$(printf '%s' "$raw_action" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
case "$action" in
    working|work|running|active|busy)
        action="active" ;;
    not-working|notworking|idle|waiting|wait|done|finished|complete|completed)
        action="waiting" ;;
    stop|stopped|end|ended|session-end|sessionend|off|remove|clear)
        action="stop" ;;
    turn-start|turnstart|userpromptsubmit|prompt-submit|prompt-start|start-turn)
        action="turn-start" ;;
    tool-begin|toolbegin|tool-start|toolstart|pretooluse)
        action="tool-begin" ;;
    tool-end|toolend|tool-stop|toolstop|posttooluse)
        action="tool-end" ;;
    *)
        # Unknown states must not accidentally keep the Mac awake.
        action="waiting" ;;
esac

slugify() {
    out=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g; s/^[.-]*//; s/[.-]*$//; s/--*/-/g')
    [ -n "$out" ] && printf '%s' "$out" || printf '%s' "source"
}
json_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

source_name="${STAYUP_SOURCE_NAME:-Tool}"
source_display="${STAYUP_SOURCE_DISPLAY:-$source_name}"
source_key="${STAYUP_SOURCE_KEY:-$source_name}"
source_slug=$(slugify "${STAYUP_SOURCE_SLUG:-$source_display}")
transcript_prefixes="${STAYUP_SOURCE_TRANSCRIPT_PREFIXES:-}"

sources_root="$HOME/.stayup/sources"
root="$sources_root/$source_slug"
dir="$root/active"
source_file="$root/source.json"

json=$(cat)
compact_json=$(printf '%s' "$json" | tr '\n' ' ')
field() {
    printf '%s' "$compact_json" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}
field_number() {
    printf '%s' "$compact_json" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\1/p" | head -n 1
}
process_parent() {
    ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '
}
process_name() {
    ps -o comm= -p "$1" 2>/dev/null | sed 's|.*/||' | tr -d ' '
}
transcript_allowed() {
    [ -n "$transcript_prefixes" ] || return 0
    [ -n "$1" ] || return 0

    old_ifs=$IFS
    IFS=:
    for prefix in $transcript_prefixes; do
        [ -n "$prefix" ] || continue
        case "$1" in
            "$prefix"*) IFS=$old_ifs; return 0 ;;
        esac
    done
    IFS=$old_ifs
    return 1
}
source_pid() {
    explicit="${STAYUP_SOURCE_PID:-$(field source_pid)}"
    [ -n "$explicit" ] || explicit="$(field_number source_pid)"
    [ -n "$explicit" ] || explicit="$(field process_id)"
    [ -n "$explicit" ] || explicit="$(field_number process_id)"
    [ -n "$explicit" ] || explicit="$(field pid)"
    [ -n "$explicit" ] || explicit="$(field_number pid)"
    case "$explicit" in
        ''|*[!0-9]*) ;;
        *) [ "$explicit" -gt 0 ] 2>/dev/null && { printf '%s' "$explicit"; return; } ;;
    esac

    parent="$PPID"
    parent_name=$(process_name "$parent")
    case "$parent_name" in
        sh|bash|zsh|dash)
            grandparent=$(process_parent "$parent")
            case "$grandparent" in
                ''|*[!0-9]*) ;;
                *) [ "$grandparent" -gt 0 ] 2>/dev/null && { printf '%s' "$grandparent"; return; } ;;
            esac ;;
    esac
    printf '%s' "$parent"
}

sid=$(printf '%s' "${STAYUP_SESSION_ID:-$(field session_id)}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.]*//')
[ -n "$sid" ] || sid="unknown"
file="$dir/$sid"
tools="$file.tools"

tool_raw="${STAYUP_TOOL_ID:-$(field tool_call_id)}"
[ -n "$tool_raw" ] || tool_raw="$(field tool_use_id)"
[ -n "$tool_raw" ] || tool_raw="$(field call_id)"
tool_id=$(printf '%s' "$tool_raw" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[.]*//')
tx=$(field transcript_path)

# Some hosts can execute another tool's compatible hook config. When a bundled
# wrapper declares transcript roots, ignore payloads that clearly belong to a
# different source instead of creating a cross-source heartbeat.
transcript_allowed "$tx" || exit 0

mkdir -m 700 -p "$sources_root" 2>/dev/null
[ -L "$root" ] && rm -f "$root" 2>/dev/null
mkdir -m 700 -p "$dir" 2>/dev/null
[ -L "$source_file" ] && rm -f "$source_file" 2>/dev/null
if [ ! -e "$source_file" ]; then
    display_json=$(json_string "$source_display")
    source_json=$(json_string "$source_key")
    source_tmp="$root/.source.json.tmp.$$"
    cat > "$source_tmp" <<EOF 2>/dev/null
{
  "displayName": "$display_json",
  "method": "reported",
  "name": "$source_json",
  "schema": "app.getstayup.activity-source.v1",
  "type": "reported"
}
EOF
    mv -f "$source_tmp" "$source_file" 2>/dev/null
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
term="${STAYUP_SOURCE_DISPLAY:-${STAYUP_SOURCE_NAME:-${TERM_PROGRAM:-}}}"
pid=$(source_pid)
case "$action" in waiting) tok="waiting" ;; *) tok="active" ;; esac
# Write via temp + atomic rename so state changes update the directory entry.
# The dotfile temp is skipped by the reader.
tmp="$dir/.$sid.tmp.$$"
{
    echo "$tok"
    [ -n "$cwd" ]  && echo "cwd=$cwd"
    [ -n "$term" ] && echo "term=$term"
    [ -n "$tx" ]   && echo "tx=$tx"
    echo "pid=$pid"
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
