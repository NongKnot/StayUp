# StayUp Launch Kit

Public, shareable launch notes for StayUp. Keep this honest: Duck can be loud;
claims should stay boringly true.

## Core Story

**Your AI agent should not die because your Mac took a nap. Duck says no.**

StayUp is a free, open-source Apple Silicon menu-bar Duck that keeps local work
awake: Claude Code CLI, Codex CLI, Ollama, LM Studio, builds, renders,
downloads, and demos.

Trust line:

> Free. Open source. Notarized. Local-only. No telemetry. Just a Duck keeping
> the Mac awake.

## Positioning

Lead with the modern pain, not the category.

- Good: "My local AI agent died because macOS slept."
- Good: "Duck keeps real local work awake."
- Weak: "Another caffeine utility for Mac."
- Dangerous: "Supports every AI app."

StayUp v1 supports bundled starter sources for Claude Code CLI, Codex CLI,
Ollama, and LM Studio. Other tools should be described as roadmap or
contributor proposals until idle/active/stop proof passes.

## Launch Order

### 1. GitHub Proof Surface

GitHub is where technical users decide if this is safe enough to try.

Checklist:

- Release is signed/notarized and points to `getstayup.app`.
- README shows the Duck, the promise, Auto mode, privacy, uninstall, and source
  contribution path.
- `SECURITY.md` is clear about the helper daemon and privacy posture.
- `CONTRIBUTING.md` links Activity Source proposals.
- Issues are enabled for bugs, feature requests, and Activity Source proposals.

### 2. Hacker News Show HN

HN is the best first spike for open-source dev utility users.

Title:

```text
Show HN: StayUp, a Mac menu-bar Duck that keeps local AI agents awake
```

Body:

```text
I built StayUp because local AI/dev work kept dying when my Mac slept.

It is a free, open-source Apple Silicon menu-bar app. Manual mode works like a
simple keep-awake switch. Auto mode keeps the Mac awake only while trusted local
Activity Sources report real work.

v1 supports Claude Code CLI, Codex CLI, Ollama, and LM Studio. It is local-only:
no account, no telemetry, no cloud activity detection. The helper path is
documented in SECURITY.md because closed-lid-on-battery behavior needs macOS
approval.

Looking for feedback on the source model, uninstall/cleanup behavior, and other
local tools that can expose a clean idle/active/stop signal.
```

HN rules: submit something users can try and do not ask friends to upvote or
comment. Source: https://news.ycombinator.com/showhn.html

### 3. Social Video

Make one 15-25 second video. No explanation wall.

Shot list:

```text
1. Open StayUp menu: Auto enabled.
2. Start Codex / Claude Code / Ollama / LM Studio local work.
3. Duck switches active.
4. Show "local-only / no telemetry / open source" briefly.
5. End on: "Your Mac wants to sleep. Duck has other plans."
```

First post:

```text
I built a free Mac app because my AI agent kept falling asleep mid-task.

StayUp is an open-source menu-bar Duck for Claude Code, Codex CLI, Ollama, LM
Studio, renders, downloads, and other local work.

No account. No telemetry. Notarized. Duck-powered.

https://getstayup.app
https://github.com/NongKnot/StayUp
```

Short hooks to rotate:

- Your Mac wants to sleep. Duck has other plans.
- I made the world's least serious solution to a very real Mac problem.
- When Duck is awake, your Mac is awake.
- Caffeine for the AI-agent era, but Duck.
- Free, native, open source, no tracking, no subscription. Good Duck.

### 4. Reddit, Targeted

Post once per community, adapt the angle, disclose that you made it.

Best first communities:

- `r/macapps`: Mac utility users.
- `r/ClaudeCode`: Claude Code users with long local sessions.
- `r/LocalLLaMA`: local Ollama / LM Studio angle.
- `r/ollama`: local runner angle.
- `r/SideProject`: maker story.

`r/macapps` draft:

```text
Title:
I built a free open-source menu-bar Duck that keeps local AI/dev work awake

Body:
Hi, I made StayUp.

It is a free Apple Silicon Mac menu-bar app that keeps the Mac awake for local
work like Claude Code CLI, Codex CLI, Ollama, LM Studio, renders, downloads,
and demos.

Manual mode is a simple on/off keep-awake switch. Auto mode watches opt-in
local Activity Sources, so "app is open" does not count as work. It needs real
idle/active/stop proof.

No account, no telemetry, open source, notarized direct download:
https://getstayup.app

GitHub:
https://github.com/NongKnot/StayUp

I would love feedback on the setup flow, Activity Sources, and any Mac tool
that can expose a clean local work signal.
```

Avoid broad Mac subs unless the rules clearly allow developer posts. Some
communities limit self-promotion to certain days or App Store apps.

### 5. Directories

Submit to directories for long-tail discovery:

- MacMenuBar: https://macmenubar.com/submit-your-menu-bar-app/
- MacUpdate: https://www.macupdate.com/help
- Menubarlist: https://menubarlist.com/
- All Mac Apps: https://allmacapps.com/submit

Submission blurb:

```text
StayUp is a free, open-source Apple Silicon menu-bar app that keeps local work
awake. Manual mode works like a simple keep-awake switch. Auto mode can protect
trusted local Activity Sources such as Claude Code CLI, Codex CLI, Ollama, and
LM Studio. StayUp is notarized, local-only, and has no telemetry.
```

Hold Homebrew official cask until the repo has more public notability.
Homebrew can reject low-notability casks, especially self-submitted code-hosted
apps. Source: https://docs.brew.sh/Acceptable-Casks

### 6. Product Hunt Later

Do Product Hunt after there is proof: comments, screenshots, video, and early
users. Do not ask for upvotes. Product Hunt explicitly warns against direct
upvote asks.

Tagline:

```text
A tiny Mac Duck that keeps local work awake
```

Maker comment:

```text
I built StayUp because local AI agents, renders, downloads, and demos should
not die just because macOS decided to nap.

It is a free, open-source Apple Silicon menu-bar app. Manual mode is simple.
Auto mode is stricter: a trusted local Activity Source has to prove real work,
not just "the app is open."

v1 supports Claude Code CLI, Codex CLI, Ollama, and LM Studio. No account, no
telemetry, notarized direct download.

I am looking for feedback on setup, source recipes, and which local tools Duck
should learn next.
```

Sources:

- https://www.producthunt.com/launch
- https://www.producthunt.com/launch/preparing-for-launch
- https://www.producthunt.com/launch/sharing-your-launch

## What Not To Claim

- Do not claim "first" or "only."
- Do not claim "supports all agents."
- Do not imply cloud/web work is detected.
- Do not imply manual sleep can always be overridden.
- Do not call app-open, server-open, or model-loaded states "activity."
- Do not hide the helper permission path.

## First 72 Hours

Day 0:

- Post HN Show HN.
- Post one social video.
- Submit MacMenuBar and other directories.
- Watch issues/comments and respond fast.

Day 1:

- Post a "Duck got feedback, Duck fixed things" update if fixes ship.
- Post one targeted Reddit thread, not every subreddit at once.
- Invite Activity Source proposals from real users.

Day 2:

- Triage the highest-signal issues.
- Add roadmap notes for source requests that have real proof.
- Decide whether Product Hunt needs one more week of prep.

## Success Signals

Because StayUp has no telemetry, use public or aggregate signals:

- GitHub stars, forks, issues, PRs.
- GitHub release downloads.
- Website aggregate traffic/download logs from hosting.
- Directory approvals.
- HN/Reddit comments with real bug reports or source requests.
- First external Activity Source recipe from a contributor.

## Duck Voice

Use Duck words, but keep trust adult.

Good:

- "Duck says no."
- "Good Duck."
- "Your Mac wants to sleep. Duck has other plans."
- "Duck is bold, not fake."

Too much:

- Inside jokes that obscure what the app does.
- Anything that makes permissions, helper setup, or privacy feel unserious.
