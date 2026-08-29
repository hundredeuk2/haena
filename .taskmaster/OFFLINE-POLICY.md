# HAE.NA Task Master offline policy

Notion is the product, scope, progress, and completion authority. This directory is only a
branch-local execution graph for the current engineering task.

## Required controls

- `task-master-ai@0.43.1` is pinned under `tools/task-master/`.
- `.taskmaster/config.json` must keep `global.anonymousTelemetry` and
  `global.enableCodebaseAnalysis` set to `false`.
- Do not add `.env`, provider API keys, MCP configuration, cloud/team sync, or proxy settings.
- AI roles point to the non-listening loopback endpoint `127.0.0.1:9` so an accidental AI
  command fails closed instead of sending repository context to a provider.
- Do not run `parse-prd`, `expand`, `research`, `loop`, `auto-implement`, or
  `fix-dependencies`.
- Allowed local graph commands are `list`, `show`, `next`, `set-status`,
  `validate-dependencies`, and `generate`.
- Update task details by editing the reviewed local graph. `update-subtask --prompt` is not
  used because version 0.43.1 routes that command through an AI provider.

## Status authority

Implementers may move a subtask through `pending`, `in-progress`, and `review`.
Only the control-tower review may mark it `done`. Task Master `done` never completes the
Notion task automatically; final completion still requires user approval.

## Initialization observation

The 0.43.1 initializer generated `anonymousTelemetry: true` even though the packaged fallback
configuration contains `false`. It also attempted to write Codex slash commands outside the
repository; that write failed with `EPERM`. The project configuration was changed to `false`
before any graph command ran, and every later CLI invocation printed that telemetry was disabled.
Because the initializer's Sentry implementation falls back to a built-in DSN, an empty
`SENTRY_DSN` alone is not a sufficient control. Whether the single initialization invocation
emitted metadata is not observable locally and must not be reported as proven zero.
