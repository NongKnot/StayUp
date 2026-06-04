# Contributing

Thanks for helping Duck.

StayUp is small on purpose. The best contributions are clear, tested, and easy
to undo.

## Bugs

Open a bug report with:

- what happened
- what you expected
- steps to reproduce
- macOS version, Mac model, and StayUp version
- power state: AC, battery, lid open, or lid closed

## Activity Sources

Auto mode sources need proof before code.

Duck does not accept "app is open" as work. A good Activity Source proves:

- exact local surface, not just a brand
- idle state is quiet
- active local work is visible
- stop returns idle, including delayed cleanup if needed
- false positives and false negatives are understood

Start with one of these:

- [Activity Source proposal](./.github/ISSUE_TEMPLATE/activity_source.md)
- [Activity Source recipe template](./docs/activity-source-recipes/_template.md)

Supported v1 source methods:

- `reported`
- `file`
- `logPattern`
- `socket`
- `process`

No other source types exist in v1.

## Pull Requests

Before opening a PR:

- keep the change narrow
- avoid unrelated cleanup
- run the smallest useful test
- do not include secrets, local paths, private launch notes, or generated build
  products
- for Activity Sources, include idle / active / stop proof

Useful local checks:

```bash
bash build.sh
bash tools/test-hook-installer.sh
bash tools/test-source-hook.sh
```

## Product Rule

Protect the user's trust. No hidden data use, no brittle magic, no surprising
destructive actions.

