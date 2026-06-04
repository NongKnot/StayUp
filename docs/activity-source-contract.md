# Activity Source contract (v1) — `~/.stayup/sources/<source>/active/`

**Status:** frozen interface. Both reported-source writers and the reader
(`ActivitySourceMonitor`) build against this and nothing else. Change it only by
bumping the version and updating both sides.

## Purpose

Let StayUp auto-engage its sleep-prevention stack *exactly while a selected
local source is working*, and let the Mac sleep otherwise. A source announces
activity by touching a file; StayUp watches the directory. This is the
software version of the "OpenClaw" lid-prop meme — but it only holds the Mac
awake when there's real work to protect.

The contract is deliberately source-agnostic. Bundled hook writers, observed
local tools, and custom scripts all participate by following the same file
convention. Concrete tool names belong in source recipes and installer mappings,
not in the contract shape.

## The directory

```text
~/.stayup/
└── sources/
    └── <source-slug>/
        ├── source.json
        └── active/
```

- One folder per source. Examples: `reported-cli`, `local-runner`, `model-server`.
- `source.json` names the source and, for observed sources, describes the local
  clue StayUp should read. Reported sources use `"type": "reported"`.
- `active/` contains one regular file per live source **session**.
- Filename = the session's stable id, sanitised to `[A-Za-z0-9._-]`. Any other
  character is replaced with `-`. If no id is available, use `unknown` (all
  such sessions then collapse onto one file — acceptable for v1).
- The directory is created lazily by the writer (`mkdir -p`).
- Absence of an `active/` marker means "no source working."

## File content

- **Line 1** is a state token, exactly one of:
  - `active`  — the source is mid-turn / running tools.
  - `waiting` — the source is blocked on the human (permission prompt, idle
    prompt). Does **not** keep the Mac awake (see reader semantics) — it's shown
    in the menu and feeds the post-idle grace.
- Any further lines are **optional** `key=value` context the reader surfaces in
  the menu (it MUST NOT depend on them). The writer currently emits:
  - `cwd=<path>` — working dir → "which project".
  - `term=<TERM_PROGRAM or STAYUP_SOURCE_NAME>` — terminal/app/source label
    (`iTerm.app`, `Apple_Terminal`, `vscode`, `Tool Name`, …) → "which surface".
  - `tx=<transcript_path>` — session transcript → lets the reader total **tokens
    used this session** (sum of `usage` input/output/cache across the JSONL).
    This is consumption, *not* remaining quota — quota is not exposed locally.
  - `pid=<source pid>` — liveness hint.
  - `signal=<file|logPattern|process|socket>` — optional source type for
    synthetic external markers.
  - `detail=<short human explanation>` — optional source explanation surfaced
    in the menu/status JSON.
- The file's **mtime** is the heartbeat: every write updates it.
- **`<session_id>.tools/`** — a sibling directory holding one file per tool
  **currently in flight** (`PreToolUse` adds one, `PostToolUse` removes one). Its
  non-emptiness is the precise "a tool is running right now" signal that lets the
  reader keep a long build awake without a long blanket timeout.

## Writer responsibilities (Track A — reported hooks)

The portable contract is intentionally small:

| Moment | Required writer behavior |
|--------|--------------------------|
| Source is thinking or doing local work | write/refresh `active` |
| Source starts a shell command, build, test, file search, or other local tool | write/refresh `active`; optionally add one file under `<id>.tools/` |
| That local tool finishes | remove one file from `<id>.tools/`; keep `active` if the turn continues |
| Source is blocked on the human | either write `waiting` or remove the marker |
| Source session/turn is done | remove the marker + `<id>.tools/` |

`waiting` is optional. It is a menu state, not a keep-awake state. Custom sources
do not need any bundled tool's exact event model; they only need to represent the
truth of local work.

StayUp's bundled hook script takes one action as **`$1`** so it never parses the
event name:

| Action       | Effect                                         |
|--------------|------------------------------------------------|
| `turn-start` | write `active`; **reset** `<id>.tools/` (fresh turn) |
| `active`     | write `active` (no tool change)                |
| `tool-begin` | write `active`; add a file to `<id>.tools/`    |
| `tool-end`   | write `active`; remove one file from `<id>.tools/` |
| `waiting`    | write `waiting`; clear `<id>.tools/` — but see the no-refresh rule below |
| `stop`       | remove the marker + `<id>.tools/`              |

The bundled script can be reused by any reported CLI if it exposes lifecycle
hooks. Configure that tool's hook file to call:

```bash
STAYUP_SOURCE_NAME="Tool Name" \
STAYUP_SOURCE_SLUG="tool-name-cli" \
STAYUP_SOURCE_DISPLAY="Tool Name CLI" \
STAYUP_SOURCE_KEY="Tool Name" \
STAYUP_SESSION_ID="<stable-session-id-if-available>" \
~/.stayup/bin/stayup-source-hook.sh <action>
```

`STAYUP_SOURCE_SLUG` chooses the folder under `~/.stayup/sources/`.
`STAYUP_SOURCE_KEY` is the Settings toggle key. If `STAYUP_SESSION_ID` is not
set, the script falls back to `session_id` in stdin JSON and then `unknown`.

Bundled mappings:

| Source | Mapping |
|-------|---------|
| Claude Code | `SessionStart` / `UserPromptSubmit` / `SubagentStop` → active-ish actions; `PreToolUse` → `tool-begin`; `PostToolUse` → `tool-end`; `Stop` → `waiting`; `SessionEnd` → `stop` |
| Codex CLI | `UserPromptSubmit` / `SubagentStart` / `SubagentStop` → active-ish actions; `PreToolUse` / `PostToolUse` keep the trusted command shape but the bundled script normalizes them to `active`; `Stop` → `stop` |

Rules:
- Extract `session_id` from the hook's **stdin JSON** (always present, stable).
  No `jq` — `grep`/`sed` on `"session_id":"…"` suffices. There is **no**
  `CLAUDE_SESSION_ID` env var.
- Writes are cheap/non-blocking; the reader fails safe on a torn/empty read.
- `exit 0` always — a hook must never block or fail a turn.
- Bundled mappings are examples, not the canonical state machine. If another
  source has different hooks, map them to the portable moments above.
- Only map a source to `tool-begin` / `tool-end` when those hooks are reliable
  paired lifecycle events. If a surface can only prove "work happened recently",
  use `active` heartbeats instead of exposing a fake in-flight tool count.
- Some tools fire `Stop` at the end of *every* turn, not once per session. Map
  those end-turn events to the portable truth: `waiting` if the session remains
  visible and blocked on the human, `stop` if the local work/session is gone. Do
  **not** remove on subtask/subagent stop events when the main turn continues.
- `turn-start` resets the tool dir so a tool marker leaked by an Esc-mid-tool
  (no `PostToolUse`) can't persist into the next turn.
- `waiting` clears the tool dir. A waiting session is still visible, but it is
  not running tools and must not carry stale in-flight markers forward.
- **A repeated `waiting` must NOT refresh the marker.** Some sources re-fire idle
  notifications while a session waits for input. If each one rewrote the marker,
  its mtime would keep resetting and the reader's waiting TTL would never
  elapse. So the writer skips the write when the marker is **already**
  `waiting`, but still clears `<id>.tools/`; the TTL then runs from the *first*
  transition into waiting. Any non-`waiting` action (active/tool) resets mtime
  normally.

## Reader semantics (Track B — `ActivitySourceMonitor`)

This is reader *policy*, not the wire format — the marker layout above is
unchanged. A session marker keeps the Mac awake (`isWorking`) iff it's a regular
file with a valid `active`/`waiting` first line (empty/torn → `active`, fail
toward awake), it is not `waiting`, and it is still live:

- **tool in flight** → keep awake while the owning process is alive (`pid=`
  line, `kill(pid,0)`), so a real build runs as long as it takes and a crash
  drops immediately. No time cap on a live pid.
- **active with no tool** → keep awake while the marker is fresh and the owning
  process is alive, covering model-thinking / between-tool gaps without pinning
  the Mac forever after an interrupted turn.
- **no verifiable pid** → use the 15-min staleness ceiling as the crash backstop.

Everything else — `waiting` on the human or a removed/dead marker — is **not
working**. The Mac doesn't sleep the instant work stops: `MenuController` runs a
single user-set **grace** (`Settings.autoGraceSecs`; 5 / 15 / 30 / 60 / 180 min,
floor 5 min) after work stops before standing the stack down.

`anySourceWorking` === at least one marker is currently active/live. The status
JSON also keeps the old `anySourceWorking` key for compatibility with older tools.

The menu shows a *looser* set (`isLive`): any valid marker whose owner is still
around (pid alive, or fresh within the staleness ceiling for pid-less external
markers), each flagged running vs waiting/idle — so a waiting session is
*visible* without *keeping the Mac awake*.

### Why active/fresh
- A long single tool (10-min build) fires no hook between `PreToolUse` and
  `PostToolUse`, but its `<id>.tools/` file is present → stays awake via
  pid-liveness. No false mid-build sleep.
- Model-thinking and between-tool gaps are still part of an active turn; a fresh
  `active` marker keeps the Mac protected through them.
- An interrupted turn with no `Stop` ages out on the staleness ceiling;
  `turn-start` clears any leaked tool dir on the next prompt.

## Test handshake (lets the two tracks verify independently)

Track A is done when, with the hooks installed/trusted, a live source turn makes
a file appear/refresh under the source's `active/` folder and the end-state hook
marks it waiting or removes it. Verify with:

```bash
ls -l ~/.stayup/sources/<source-slug>/active/
# during a turn: marker is active, .tools may exist
# waiting action: marker stays waiting, .tools is gone
# stop action: marker is removed
```

Track B is done when StayUp auto-engages within ~1s of a file appearing and
auto-disengages shortly after it's removed. Track B can be tested *without*
Track A by faking the writer:

```bash
mkdir -p ~/.stayup/sources/test-source/active
printf 'active\nterm=FakeTester\npid=0\n' > ~/.stayup/sources/test-source/active/test-session
# StayUp should engage.
rm ~/.stayup/sources/test-source/active/test-session
# StayUp should disengage (subject to the auto/manual reconciliation policy).
```
