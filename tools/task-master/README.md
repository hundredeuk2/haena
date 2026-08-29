# Task Master offline pilot

Task Master is a branch-local execution graph for the current engineering task.
Notion remains the product and completion authority; Git remains the implementation evidence.

The dependency is pinned to `task-master-ai@0.43.1`. Do not configure provider API keys,
MCP, cloud/team sync, or AI-backed commands. Use the repository wrapper; it checks the
privacy configuration, removes provider credentials from the process, and blocks commands
outside the reviewed allowlist.

```sh
scripts/task-master-offline.sh next
scripts/task-master-offline.sh show 1.1
scripts/task-master-offline.sh set-status --id=1.1 --status=in-progress
scripts/task-master-offline.sh validate-dependencies
```

`.taskmaster/tasks/tasks.json` is the tracked graph. Markdown task files produced by
`generate` are local renderings and are ignored because the upstream generator emits
trailing spaces that fail this repository's `git diff --check` gate.

Allowed workflow commands:

- `list`, `show`, `next`
- `set-status`
- `validate-dependencies`, `generate`

Do not use `parse-prd`, `expand`, `research`, `loop`, `auto-implement`,
`update-subtask`, or `fix-dependencies` in this pilot. In version 0.43.1,
`update-subtask --prompt` uses an AI provider rather than performing a purely local note append.
