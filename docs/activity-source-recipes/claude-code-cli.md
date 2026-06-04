# Activity Source: Claude Code CLI

Status: verified / bundled

## Exact Surface

Claude Code CLI.

This is the command-line coding-agent surface. It is separate from any desktop
app, editor extension, or web chat surface.

## Method

`reported`

Claude Code has lifecycle hooks, so it can report activity directly instead of
making Duck infer work from generic process or file noise.

## Idle Proof

When Claude Code is waiting for the user, the StayUp marker is either absent or
has `waiting` on line 1. A waiting marker can stay visible in the menu, but it
does not keep the Mac awake.

```text
~/.stayup/sources/claude-code-cli/active/<session-id>

waiting
cwd=/path/to/project
term=Claude
pid=<hook-parent-pid>
```

## Active Proof

When the user submits a prompt or Claude Code starts local work, its hooks call
the StayUp wrapper and write/refresh an `active` marker.

```text
~/.stayup/sources/claude-code-cli/active/<session-id>

active
cwd=/path/to/project
term=Claude
pid=<hook-parent-pid>
```

For local tool work such as shell commands, file searches, builds, or tests,
`PreToolUse` can also create a sibling tool marker:

```text
~/.stayup/sources/claude-code-cli/active/<session-id>.tools/<tool-id>
```

## Stop Proof

At the end of a normal turn, Claude Code fires `Stop`. StayUp maps that to
`waiting`, because the session is still open but blocked on the human. `waiting`
does not keep Duck awake; the app's grace timer decides when to stand down.

When the session actually ends, `SessionEnd` maps to `stop` and removes the
marker plus any `.tools/` folder.

## Recipe

Reported source recipe:

```json
{
  "schema": "app.getstayup.activity-source.v1",
  "name": "Claude",
  "displayName": "Claude Code CLI",
  "type": "reported",
  "method": "reported"
}
```

Hook config:

```text
hook config path: ~/.claude/settings.json
wrapper path: ~/.stayup/bin/stayup-source-hook-claude-code-cli.sh
base writer: ~/.stayup/bin/stayup-source-hook.sh
```

Bundled event mapping:

```text
UserPromptSubmit -> turn-start
PreToolUse       -> tool-begin
PostToolUse      -> tool-end
SubagentStop     -> active
SessionStart     -> active
Notification     -> waiting
Stop             -> waiting
SessionEnd       -> stop
```

The source-specific wrapper exports:

```sh
STAYUP_SOURCE_NAME='Claude'
STAYUP_SOURCE_SLUG='claude-code-cli'
STAYUP_SOURCE_DISPLAY='Claude Code CLI'
STAYUP_SOURCE_KEY='Claude'
```

Then it execs:

```sh
~/.stayup/bin/stayup-source-hook.sh "$@"
```

## False Positives

- A Claude Code session waiting for the user should not count as work.
- An idle terminal with Claude Code open should not count as work.
- Repeated idle/waiting notifications should not refresh the waiting marker
  forever.

## False Negatives

- If hooks are not installed or not trusted, Claude Code cannot report activity.
- If a hook config is overwritten by the tool from stale in-memory state, StayUp
  may need to reconnect or repair the hook entries.
- If the hook parent process exits before the app reads the marker, the marker
  can disappear quickly.

## Cleanup

Disable removes the StayUp source and replaces the source-specific wrapper with
a harmless no-op. Clean Up Hooks removes only hook entries whose command points
to StayUp's `stayup-source-hook` wrapper. It leaves Claude Code, projects, logs,
and unrelated hooks alone.

