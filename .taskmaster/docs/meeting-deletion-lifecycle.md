# Meeting deletion lifecycle execution contract

Authority: Notion task `3c5f6cd22fd58151a2e3e2780052cae5`.

This file is a reviewed local summary, not an AI input and not a replacement for Notion.

## In scope

1. Selectively port the prior 60 percent checkpoint onto `main@2246509`.
2. Close refusal object-reference orphans.
3. Close ambiguity-group and ambiguity-review object-reference orphans.
4. Connect `deleteProject` to the continuity sidecar lifecycle.
5. Preserve durable intent ordering, crash recovery, and repeated idempotency.
6. Verify the focused slice and synchronize evidence.

## Invariants

- Use typed UUID references only.
- Meeting deletion is an explicit user verdict: Work State and terminal verdicts derived from
  that meeting are deleted under the approved contract.
- Unrelated meetings, projects, canonical state, and terminal verdicts are preserved.
- Do not infer links from transcript text, titles, names, keywords, regexes, or fuzzy matching.
- Do not edit user JSON directly or hide an orphan only in the UI.
- Deletion intent stores identifiers and timestamps only.
- Do not access or mutate a real user project for smoke validation without separate approval.

## Evidence policy

Task Master tracks dependency and local execution status. Git proves the implementation.
Notion alone owns progress, verification level, current focus, and final user approval.
