# Activity Sources

StayUp Auto mode wakes Duck from **Activity Sources**.

An Activity Source is any local tool signal that means "work is happening on
this Mac." Some tools report activity themselves. Other tools are observed by
local clues such as fresh files, log markers, sockets, or CPU.

The runtime contract is one pattern: every tool gets a folder under
`~/.stayup/sources/`. That folder contains the source recipe and, when work is
live, activity receipts.

## The Rule

Only detect local work:

- Good: shell commands, builds, tests, file searches, local model inference,
  local workers, local logs/databases that update while work runs.
- Bad by default: cloud/web work, idle apps, idle servers, browser tabs,
  generic app launches.

If the signal means "the tool is currently doing work," Duck accepts.

If the user only wants "keep awake while this app is open," treat that as an
explicit app-open / presence source. It is less precise than real-work
detection, but it is valid when the user asks for it. Prove open-vs-closed and
make the behavior clear.

## Proof, Not Identity

StayUp does not try to prove that a tool is "really" a brand or product.
Brand names are not sources. A CLI, desktop app, IDE extension, browser
automation surface, and local runner from the same product can expose different local signals.
StayUp asks for fresher, simpler evidence: what local proof changed recently?

- Reported sources show heartbeat freshness.
- Observed sources show the clue type: file, log, socket, or CPU.
- A source can be visible only after it has fresh proof, and Auto only trusts it
  after the user enables it.
- Chat text is not proof. A source must leave a local receipt StayUp can read.

## Quality Bar

An Activity Source is good enough when:

- Idle state is quiet: no marker would be written while the app/server is merely
  open.
- Active state is visible: a real local job changes the process CPU or file
  mtime, log marker, task socket, or heartbeat enough for StayUp's 15-second
  poll to catch it.
- The match is specific: avoid generic `node`, `python`, `Electron`, `Helper`,
  or browser renderer names unless the command line includes a unique script,
  path, model runner, or app name.
- The check is cheap and read-only.
- Failure is harmless: if the tool is not installed, the source simply never
  matches.

If you cannot compare idle and active states, say so. A low-confidence source
is worse than no source because it teaches Duck to believe noise.

## StayUp Folder

StayUp keeps the public local files together:

```text
~/.stayup/
├── sources/
│   ├── reported-cli/
│   │   ├── source.json
│   │   └── active/
│   ├── local-runner/
│   │   ├── source.json
│   │   └── active/
│   └── ollama/
│       ├── source.json
│       └── active/
└── status.json     # current app status for the bundled tester
```

Activity Source recipes live here:

```text
~/.stayup/sources/<source-slug>/source.json
```

Reported CLIs can write activity directly and show as normal Activity Sources
in Settings. Add one folder per local tool or app surface that needs StayUp to
observe activity clues.

Each `source.json` must be valid JSON:

```json
{
  "schema": "app.getstayup.activity-source.v1",
  "name": "My Runner",
  "displayName": "My Runner",
  "type": "socket",
  "match": "my-runner"
}
```

Supported observed source types:

| Type | Required fields | Meaning |
|------|-----------------|---------|
| `process` | `name`, `type`, `match`, `minCpu` | Any process whose command contains `match` and uses at least `minCpu` CPU counts as active. |
| `file` | `name`, `type`, `path`, `freshSecs` | The newest file matching `path` was modified within `freshSecs` seconds. |
| `logPattern` | `name`, `type`, `path`, `activePattern`, `freshSecs` | The newest matching log is fresh, and the latest active/idle marker still says work is running. |
| `socket` | `name`, `type`, `match` | Any process whose command contains `match` and has an ESTABLISHED TCP socket counts as active. |

`logPattern` uses simple case-insensitive substrings. Separate alternatives
with `|`, for example `"processing task|tokens decoded"`. `idlePattern` is
optional but strongly recommended when the log writes a clear "done" or "idle"
line.

No other `type` values exist in v1. If a tool can report activity directly, use
the heartbeat contract and `"type": "reported"` instead of an observed clue. If
a tool exposes a better API or state endpoint, use that evidence to choose one
of the supported observed source types, or return `needs_user_test`.

`path` supports `~` and `*`, including folder globs, for example:

```json
{
  "schema": "app.getstayup.activity-source.v1",
  "name": "Example",
  "displayName": "Example",
  "type": "file",
  "path": "~/.example/logs/*.jsonl",
  "freshSecs": 45
}
```

In StayUp Settings -> Advanced, use:

- `Copy setup prompt` to give a local tool or app surface the
  Activity Source setup task.
- `Open StayUp folder` to edit `sources/<tool>/source.json` and inspect live
  receipts in that source's `active/` folder.
- `Refresh` after saving so the new source appears in the checklist.

Nothing is trusted until the user enables it.

When Auto first needs to connect bundled reported sources such as Claude Code
CLI or Codex CLI, StayUp asks before editing that tool's hook config. If the
user chooses not to connect, Auto still works for observed sources such as
Ollama and LM Studio. If a connection fails, StayUp leaves Auto on, reports the
failure, and the source can be connected later from Settings.

## Contributing A Source

Contributors can help Duck learn more tools without starting in app code.

Use one of these paths:

- Open an Activity Source proposal issue with idle, active, and stop proof.
- Add a recipe under [activity-source-recipes](./activity-source-recipes/) using
  the [template](./activity-source-recipes/_template.md).

Keep proposals narrow:

- Name the exact surface: CLI, desktop app, IDE extension, daemon, local runner,
  or browser automation surface.
- Pick only supported v1 methods: `reported`, `file`, `logPattern`, `socket`,
  or `process`.
- Prove the idle state is quiet.
- Prove a real local job becomes visible.
- Prove the signal returns idle after stopping, including delayed cleanup.
- Explain false positives and false negatives.

Recipes are not automatically bundled. They are the proving ground. A source can
graduate into the app's prefilled list only after it passes real idle-vs-active
testing and has safe cleanup behavior.

## Copy Prompt For A Local Tool

Use this with a local tool or app surface:

````text
You are setting up one StayUp Activity Source for one local tool or app surface on this Mac.

StayUp is simple: Manual On/Off is direct user control. Auto protects the Mac while a selected local Activity Source is true, then turns off after StayUp's grace period. Best sources prove "working now." If the user explicitly wants "keep awake while this app is open," that is also allowed as a deliberate presence source.

Target one exact surface: CLI, desktop app, IDE extension, browser automation surface, local model runner, daemon, or other. Do not treat a brand as one source; different surfaces from the same product can expose different local signals.

If the user has not named the exact surface in the current conversation, ask one short question: "Which local app or tool should I connect, and should I use Easy, Normal, or Developer mode?" Do not search or inspect broadly until they answer. If they name a surface but do not choose a style, use Normal mode.

Talking style:
- Easy mode: plain user steps, almost no implementation detail.
- Normal mode: short explanations with the concrete checks and files you are using.
- Developer mode: include commands, paths, config details, and tradeoffs.

User-guided setup protocol:
- First clarify the user's intent: should Duck stay up only during real work, or whenever the app/tool is open? If they ask for app-open behavior, accept that choice and call it a presence source.
- For real-work sources, ask the user to put the target surface in an idle / not-working state. The app or daemon may stay open; idle means no generation, build, download, tool call, or local job is running.
- For app-open presence sources, prove open-vs-closed instead of idle-vs-active. Ask the user to open the exact app/tool, verify the local process/surface exists, then ask them to quit it and verify the signal goes quiet. Do not run a tiny job unless the user wants real-work detection.
- After the exact surface is named, do a quick online search for official documentation or primary sources for that exact surface before local probing. Look specifically for hooks, log files, sockets, task-state APIs, lifecycle events, and local inference/job status. If online search is unavailable, say so and continue with local evidence. Treat web results as a map, not proof. The Activity Source is valid only after local idle-vs-active evidence on this Mac.
- Inspect idle evidence and record what is quiet.
- Then ask the user to start one tiny local job in that exact surface. Name the smallest safe action you need. If a model is required, ask them to choose or load the smallest local model available.
- Inspect active evidence while the tiny job is running.
- Ask the user to let the job finish or stop it. The user's "stopped" answer is a cue, not proof: inspect once right away, then re-check after about 10 seconds. If the signal still looks active, keep re-checking for about 1 to 3 minutes before deciding it failed to return idle. Some tools flush logs, release sockets, or update task state late.
- Only install hooks or write source.json after the idle and active evidence support the source. If you cannot prove the difference, return needs_user_test or no_source.
- If the user asks to delete or undo a setup, prefer safe disable first: remove the StayUp source folder for that exact source under ~/.stayup/sources/<source-slug>/, disable that source if needed, and replace any StayUp source-specific wrapper with a harmless no-op that exits 0. Do not edit the target tool's hook/config file unless the user explicitly asks to clean up hooks. Do not delete the target app, model files, user projects, logs, or unrelated config.

StayUp source model:
- Source recipe: ~/.stayup/sources/<source-slug>/source.json
- Live receipts: ~/.stayup/sources/<source-slug>/active/
- Preferred: the tool reports activity by writing heartbeat receipts under active/.
- Generic reported CLIs can call ~/.stayup/bin/stayup-source-hook.sh with STAYUP_SOURCE_NAME, STAYUP_SOURCE_SLUG, STAYUP_SOURCE_DISPLAY, STAYUP_SOURCE_KEY, and optional STAYUP_SESSION_ID.
- Custom reported sources do not require StayUp app-code changes. Prefer a short source-specific wrapper under ~/.stayup/bin/stayup-source-hook-<source-slug>.sh that sets STAYUP_SOURCE_NAME, STAYUP_SOURCE_SLUG, STAYUP_SOURCE_DISPLAY, and STAYUP_SOURCE_KEY, exports them, then execs ~/.stayup/bin/stayup-source-hook.sh "$@". Install the target tool's hooks so each event calls that wrapper with one StayUp action. The script creates the reported source.json automatically on first heartbeat.
- If reinstalling or restoring a reported source and its source-specific wrapper already exists as a harmless no-op, overwrite that wrapper with the real source wrapper. If the target tool's hooks already call that wrapper with the right actions, reuse them instead of adding duplicates.
- If ~/.stayup/bin/stayup-source-hook.sh is missing, create ~/.stayup/bin and copy it from /Applications/StayUp.app/Contents/Resources/stayup-source-hook.sh when that file exists, then chmod 755 it. If the installed app resource is unavailable, ask the user to open StayUp or return needs_user_test. Do not edit the StayUp source repo.
- Codex CLI trust step: after installing Codex CLI hooks, tell the user to close any open Codex CLI session, reopen `codex`, then trust the StayUp hooks when Codex shows "hooks need review." The trusted path should be ~/.stayup/bin/stayup-source-hook-codex-cli.sh. Codex may show 7 hook events; that is expected because one StayUp wrapper is attached to several Codex lifecycle events.
- Fallback observed types are exactly: file, logPattern, socket, process.
- Do not invent other type values.

Good signals mean active local work:
- heartbeat from tool events
- task/log file mtime changing during work and quiet while idle
- logPattern with clear active and idle/done markers
- ESTABLISHED socket that appears during work and is absent while idle
- CPU only when it clearly separates active work from idle
- process exists with minCpu 0 only when the user explicitly asked for app-open / presence behavior

Bad signals:
- app is installed, authenticated, or configured
- local LLM model is loaded in RAM, VRAM, memory, or ready state
- generic process exists, unless the user explicitly asked for app-open / presence behavior
- browser tab or chat text exists
- cloud/web-only work with no local receipt

Local LLM rule: loaded model, server alive, or model ready is idle unless tokens are being generated, embeddings are running, a download is active, or another local inference/job is actually working.

Workflow:
1. If the exact surface is unclear, ask which local app or tool to connect and whether Duck should watch real work or app-open presence.
2. For real-work sources, inspect idle state first.
3. For app-open presence sources, inspect closed/absent state and open/present state. A process source with minCpu 0 is acceptable if it cleanly tracks the requested app/tool.
4. For real-work sources, inspect active state from a tiny local job; ask the user before running anything expensive, killing processes, installing software, or editing config.
5. Prefer reported heartbeat if the tool has hooks/events for turn start, active work, waiting/idle, or stop. Install that mapping in the tool's own hook/config file, not in ~/.stayup/sources by hand.
6. Use tool-begin/tool-end only when those hooks are reliable paired lifecycle events. If the tool can only prove "work happened recently", map those hooks to active instead of exposing a fake in-flight tool count.
7. Otherwise choose the smallest observed signal that matches the user's intent.
8. If the evidence is weak, return needs_user_test or no_source. Do not guess.

If you are asked to install a ready source, do not edit StayUp app code. For reported, install hooks in the target tool's own hook/config file so each event calls the source-specific wrapper under ~/.stayup/bin/stayup-source-hook-<source-slug>.sh. For file, logPattern, socket, or process, create exactly one source.json under ~/.stayup/sources/<source-slug>/source.json.

Return exactly this structure and no extra prose:

STAYUP_ACTIVITY_SOURCE_RESULT
status: ready | needs_user_test | no_source
source_method: reported | file | logPattern | socket | process | needs_user_test | no_source
surface:
reported_activity_plan:
- tool_hook_config_path:
- tool_events:
- stayup_actions:
- hook_commands:
- notes:
candidate_tests:
- file:
- logPattern:
- socket:
- process:
observed_source:
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
evidence:
- idle:
- active:
why_this_means_local_work:
false_positives:
false_negatives:
user_instruction:
If source_method is reported, add hooks to the tool's own hook/config file. Prefer a short source-specific wrapper under ~/.stayup/bin/stayup-source-hook-<source-slug>.sh; each hook should call that wrapper with one action: turn-start, active, waiting, stop, and only use tool-begin/tool-end for reliable paired tool lifecycle events. The wrapper should set and export STAYUP_SOURCE_NAME, STAYUP_SOURCE_SLUG, STAYUP_SOURCE_DISPLAY, STAYUP_SOURCE_KEY, and optional STAYUP_SESSION_ID, then exec ~/.stayup/bin/stayup-source-hook.sh "$@". If source_method is file, logPattern, socket, or process, save observed_source as ~/.stayup/sources/<source-slug>/source.json, then open StayUp Settings -> Advanced, click Refresh, and tick the source.
If no supported source is strong enough, say what support would make it detectable, such as a native heartbeat hook, task-state API, lifecycle log, active-work socket, or parent-scoped child-process tracking.
````

## Examples If Setup Gets Lost

These are examples, not rules. OpenClaw, a forked tool, or a weird local runner
may have a better signal on the user's Mac. The setup job is to investigate
that machine and prove idle-vs-active.

- Long-running shell tool that can report activity: write the heartbeat
  contract in `~/.stayup/sources/<source-slug>/active/`; do not use an observed
  clue.
- Local model runner that keeps a process alive while idle but opens an
  ESTABLISHED TCP connection only while generating: `socket`.
- App that appends `processing task`, token counts, and `all slots are idle` to
  a task log: `logPattern`.
- CLI that writes a transcript, sqlite WAL, or temp file only while working:
  `file`.
- Worker with no useful log/socket but clearly higher CPU while active:
  `process`.

## Candidate File Idea

Future StayUp can support source-candidate files, for example:

```text
~/.stayup/activity-source-candidates/<tool-name>.json
```

That should be a proposal only. The app should show "Found Activity Source.
Enable?" and create `~/.stayup/sources/<tool-name>/source.json` only after the
user accepts. Local tools do not silently mutate runtime config. Duck watches work,
not trust.

If candidate files are added later, they should also use a fixed schema:

```json
{
  "schema": "app.getstayup.activity-source-candidate.v1",
  "status": "ready",
  "source": {
    "name": "Tool Name",
    "type": "file",
    "path": "~/path/to/file-or-folder-*/*.log",
    "freshSecs": 45
  },
  "evidence": {
    "idle": ["what was quiet"],
    "active": ["what changed during local work"]
  },
  "falsePositives": [],
  "falseNegatives": [],
  "notes": "User must approve before this becomes a sources/<tool>/source.json file."
}
```
