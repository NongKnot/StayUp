# StayUp Roadmap

Updated: 2026-06-04

This roadmap is for Activity Sources and Auto mode. It is not launch copy.
Public claims should stay narrower than this list unless the source has passed a
real idle-vs-active smoke test on macOS.

## v1.0 Launch Scope

For v1.0, StayUp should keep the promise small and testable:

- Claude Code CLI: first-class reported source using StayUp hook wrappers.
- Codex CLI: first-class reported source using StayUp hook wrappers.
- Ollama: bundled observed source for local inference activity.
- LM Studio: bundled observed source for local inference activity.

These are the sources that should block publish if they fail the final smoke
pass.

## v1.0 Prefilled Sources

StayUp can still prefill useful sources beyond the launch promise, as long as
the UI and docs do not overclaim:

- Claude Code CLI: reported source.
- Codex CLI: reported source.
- Cursor: observed source, best-effort until a stronger activity signal is
  verified.
- Gemini CLI: observed source, best-effort until a stronger activity signal is
  verified.
- Ollama: observed source.
- LM Studio: observed source.

Nothing is trusted until the user ticks it in Settings.

## v1.0 Non-Goals

- No broad marketplace of sources.
- No cloud-only activity detection. Remote work only counts if it leaves a local
  process, receipt, log, socket, or file signal on this Mac.
- No cost, quota, token, billing, or usage dashboard.
- No hidden edits to third-party configs. StayUp edits reported-source hook
  config only for known supported integrations, and cleanup must be explicit.
- No "app is open" or "model is loaded" signal. A local model server sitting in
  RAM/VRAM is idle unless it is generating, embedding, downloading, or running a
  real local job.

## Research Backlog

Contributor source proposals should start as issues or docs recipes, not app
code. Use `docs/activity-source-recipes/_template.md` and graduate only the
sources that pass the acceptance gate below.

### Coding Agents

- OpenCode: high priority after v1.0. It is a popular open-source coding agent
  with CLI and beta desktop surfaces. Research whether its plugin/config system
  can emit a clean reported Activity Source without brittle file watching.
  Source: https://github.com/anomalyco/opencode
- Gemini CLI: upgrade from best-effort observed source to a reported source if
  its hook system can safely report session/tool lifecycle events.
  Source: https://github.com/google-gemini/gemini-cli
- Cursor: research native agent hooks, session state, and stable local activity
  surfaces. Keep the current bundled source conservative until there is better
  idle-vs-active proof.
  Source: https://docs.cursor.com/en/cli/using
- GitHub Copilot / VS Code agent: research local agent hooks or extension state,
  but treat autocomplete/editor-idle noise as a false-positive risk.
- Aider, Goose, Crush, Continue, Cline, and similar agent CLIs/extensions:
  research only after the v1.0 core is published.

### Local Model Apps And Runners

- Jan: local desktop app and CLI/server surfaces. Research active generation
  logs, local API state, and whether the desktop app exposes a reliable local
  job signal.
  Source: https://github.com/janhq/jan
- GPT4All: local desktop app. Research logs and process/socket behavior during
  generation.
  Source: https://github.com/nomic-ai/gpt4all
- AnythingLLM: local/desktop and server-style surfaces. Research whether active
  jobs are observable without treating an idle server as work.
  Source: https://github.com/Mintplex-Labs/anything-llm
- llama.cpp / llama-server: likely useful for developer setups, but each launch
  command can differ. Prefer a setup-prompt flow unless a stable default signal
  is proven.
  Source: https://github.com/ggml-org/llama.cpp
- vLLM, SGLang, MLX, MLC, and other inference servers: roadmap only for now;
  prioritize macOS-local workflows first.

### Usage And Ecosystem Signals

- OpenUsage is not an Activity Source target for v1.0; it is a useful map of
  popular AI tools and providers. It currently tracks tools such as Claude Code,
  Cursor, Copilot, Codex CLI, Gemini CLI, OpenCode, OpenRouter, and Ollama, and
  has optional hooks for several coding tools.
  Source: https://github.com/janekbaraniewski/openusage

## Acceptance Gate For Any New Source

Before a source graduates from roadmap to bundled/published support:

- Idle proof: with the app/tool open but not working, StayUp does not see
  activity.
- Active proof: a real job produces a local signal StayUp sees within the
  normal poll window.
- Stop proof: after the user stops work, StayUp checks immediately, then
  rechecks over roughly one to three minutes before declaring the signal broken.
- Trust proof: Delete/Disable removes StayUp setup without touching unrelated
  app data; Restore recreates only StayUp setup.
- Safety proof: any third-party config edit is merged, backed up, and only
  removes StayUp-owned entries during explicit cleanup.
