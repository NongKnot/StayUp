# Activity Source: Codex CLI

Status: verified / bundled

## Exact Surface

Codex CLI.

This is the terminal `codex` command-line surface. It is separate from Codex
Desktop, editor plugins, browser sessions, or cloud tasks.

## Method

`reported`

Codex CLI has lifecycle hooks, so it can report activity directly to StayUp.
Duck should not infer Codex work from the desktop app being open or from generic
Codex background processes.

## Idle Proof

Before the hooks are trusted, Codex CLI may show installed hooks with `Active 0`
and `Review` counts. In that state, no StayUp marker is written and Duck sees no
Codex activity.

After hooks are trusted, a waiting or stopped Codex turn removes the marker in
the bundled mapping, so the active folder is empty while no work is running.

```text
~/.stayup/sources/codex-cli/active/

# empty while idle / stopped
```

## Active Proof

When the user submits a prompt after trusting the StayUp hooks, Codex CLI calls
the source-specific wrapper and writes an `active` marker.

```text
~/.stayup/sources/codex-cli/active/<session-id>

active
cwd=/path/to/project
term=Codex
pid=<hook-parent-pid>
```

Codex CLI may display 7 hook events for review. That is expected: they all call
one StayUp wrapper, attached to several lifecycle moments.

## Stop Proof

The bundled Codex CLI mapping treats `Stop` as `stop`, because Codex has no
separate `SessionEnd` cleanup hook and its process can be long-lived or shared.
At the end of a turn, StayUp removes the marker instead of leaving a stale
waiting session behind.

## Recipe

Reported source recipe:

```json
{
  "schema": "app.getstayup.activity-source.v1",
  "name": "Codex",
  "displayName": "Codex CLI",
  "type": "reported",
  "method": "reported"
}
```

Hook config:

```text
hook config path: ~/.codex/hooks.json
wrapper path: ~/.stayup/bin/stayup-source-hook-codex-cli.sh
base writer: ~/.stayup/bin/stayup-source-hook.sh
```

Bundled event mapping:

```text
SessionStart     -> waiting
UserPromptSubmit -> turn-start
PreToolUse       -> tool-begin
PostToolUse      -> tool-end
SubagentStart    -> active
SubagentStop     -> active
Stop             -> stop
```

The source-specific wrapper exports:

```sh
STAYUP_SOURCE_NAME='Codex'
STAYUP_SOURCE_SLUG='codex-cli'
STAYUP_SOURCE_DISPLAY='Codex CLI'
STAYUP_SOURCE_KEY='Codex'
```

Then it execs:

```sh
~/.stayup/bin/stayup-source-hook.sh "$@"
```

## Trust Step

After StayUp connects Codex CLI:

1. Close any open Codex CLI session.
2. Reopen `codex`.
3. When Codex says hooks need review, trust the StayUp hooks.
4. Confirm the hook path is:

```text
~/.stayup/bin/stayup-source-hook-codex-cli.sh
```

If Codex shows installed hooks but `Active` is `0` and all hooks still need
review, Duck will not see activity yet.

## False Positives

- Codex Desktop being open is not Codex CLI activity.
- A Codex background process is not enough.
- Hooks installed but not trusted are not activity.
- A terminal sitting at the Codex prompt is not work.

## False Negatives

- Existing Codex CLI sessions may not reload newly installed hooks.
- Hooks that are not trusted do not run.
- Codex Desktop may not use the same hook surface as Codex CLI.
- If a hook config is overwritten by another process, StayUp may need to
  reconnect or repair its entries.

## Cleanup

Disable removes the StayUp source and replaces the source-specific wrapper with
a harmless no-op. Clean Up Hooks removes only hook entries whose command points
to StayUp's `stayup-source-hook` wrapper. It leaves Codex config, projects,
logs, and unrelated hooks alone.

