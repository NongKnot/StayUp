# Activity Source: Tool Surface Name

Status: proposed / needs user test / verified

## Exact Surface

Name the exact CLI, desktop app, IDE extension, daemon, local runner, or browser
automation surface.

Do not use only a brand name if the brand has multiple surfaces.

## Method

Pick one:

- `reported`
- `file`
- `logPattern`
- `socket`
- `process`

## Idle Proof

Describe the state with the tool open but not working.
App-open alone is not a good Auto source; recommend Manual On unless the user
explicitly accepts a noisy advanced source.

```text
commands, paths, or observations
```

## Active Proof

Describe one small local job and the signal observed while it ran.

```text
commands, paths, or observations
```

## Stop Proof

Describe what happens right after the job stops and after about 10 seconds. If
it still looks active, keep checking for 1-3 minutes and record when it returns
idle.

```text
commands, paths, or observations
```

## Recipe

For observed sources:

```json
{
  "schema": "app.getstayup.activity-source.v1",
  "name": "Tool Name",
  "displayName": "Tool Name",
  "type": "file",
  "path": "~/path/to/file-or-glob",
  "freshSecs": 45
}
```

For reported sources:

```text
hook config path:
events:
actions:
commands:
wrapper path:
```

## False Positives

What could make Duck think work is happening when it is not?

## False Negatives

What real work might this miss?

## Cleanup

Normal Delete should safe-disable the source without editing third-party config
when possible. If this edits third-party config, describe how Clean Up Hooks
removes only StayUp-owned entries and leaves apps, model files, projects, logs,
and unrelated config alone.
