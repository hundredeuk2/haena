# Development 16 human semantic gold

Notion page `3baf6cd22fd581938839d70523e907dd` is the product and completion authority.
Task Master is only the offline branch-local execution graph. Git is the implementation evidence.

## Objective

Human reviewers establish the first trustworthy Meeting Execution development gold for 16 cases.
Model suggestions are review aids, never labels. The sealed holdout stays unavailable until the
development contract and semantic scorer are frozen.

## Read-only baseline audit — 2026-08-30

- Git baseline: `90df638baf518137e73e92106a6e61897a8b383f` from the approved lifecycle branch.
- New branch: `codex/development-human-gold`.
- `source-index.jsonl` and `manifest.jsonl` agree on 16 development and 8 sealed-holdout cases.
- All 24 cases remain `human_review_pending`.
- The model-suggestion set contains 16 IDs, but it is stale relative to the current split:
  - development `MEV0-001` has no suggestion;
  - sealed `MEV0-004` has a suggestion and appears in the prior validation set;
  - the remaining 15 suggestion IDs are current development cases.
- The old `16/16 passed` report proves schema and local evidence validity for the stale suggestion
  set. It does not prove current development partition integrity.
- The existing `DEVELOPMENT_REVIEW.md` must not be used for human gold until the split and packet
  are repaired.

## Exposure boundary

A model-suggestion file or appearance in a review packet is exposure. An exposed case cannot be a
sealed holdout. Repair must use metadata-only selection from the unused corpus and must not inspect
candidate transcripts, gold, source identity, audio, or content-derived scores.

During this baseline audit, an initially broad read-only search traversed sealed case paths and
returned some case text to the active agent context. No file was changed or transmitted, but this
session is not eligible to act as an independent sealed-holdout reviewer. A later sealed evaluation
must use a fresh reviewer/session without this context, or explicitly record a weaker independence
claim.

## Current gate

TM 2.1 is in `review`. Human semantic review has not started. TM 2.2 must first repair partition
integrity and add a fail-closed audit proving:

1. 16 development and 8 sealed cases;
2. manifest, source index, case metadata, draft IDs, and packet headings agree;
3. draft IDs equal development IDs;
4. draft IDs intersect sealed IDs is empty;
5. every exposed ID is non-sealed;
6. repeated metadata-only selection is deterministic;
7. external calls and sealed payload reads are zero.

## Privacy and execution limits

- Local corpus and review artifacts stay under ignored `data/` paths.
- No provider key, external AI, MCP/server, cloud sync, corpus upload, audio upload, or public release.
- Do not alter semantic labels during partition repair.
- Do not inspect the sealed payload to decide a replacement.
- Do not equate Task Master status counts with Notion evidence progress.
