---
name: Activity Source proposal
about: Teach Duck a new local work signal for Auto mode
title: 'Activity Source: '
labels: activity-source
assignees: ''
---

**Exact surface**
<!-- Name the exact CLI, desktop app, IDE extension, daemon, local runner, or browser automation surface.
     Do not use only a brand name if the brand has multiple surfaces. -->

**Source method**
<!-- Pick one: reported / file / logPattern / socket / process / unsure -->

**Why this is real local work**
<!-- What is the tool doing on this Mac when the source should be active? -->

**Idle proof**
<!-- With the app/tool open but not working, what did you check? What stayed quiet? -->

```text
paste idle commands / paths / observations here
```

**Active proof**
<!-- Start one small local job. What changed while work was running? -->

```text
paste active commands / paths / observations here
```

**Stop proof**
<!-- After the job stops, what happens right away? What happens after 10-60 seconds? -->

```text
paste stop observations here
```

**False positives**
<!-- What could make Duck think work is happening when it is not? Example: app is open, model loaded, server idle. -->

**False negatives**
<!-- What real work might this source miss? -->

**Suggested recipe**
<!-- For observed sources, paste source.json. For reported sources, describe the hook events and commands. -->

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

**Cleanup behavior**
<!-- If this edits any third-party config, how does StayUp remove only its own entries? -->

