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

## Partition repair — TM 2.2, 2026-08-30

The 16/8 counts were right and the partition was still wrong, because the holdout swap ran
after the drafts were generated. `scripts/benchmarks/repair_meeting_execution_partition.py`
now derives the partition from exposure evidence instead of a hardcoded swap, and
`scripts/benchmarks/validate_meeting_execution_partition.py` fails closed on the identities
rather than the counts.

- Exposed: the 16 model suggestions, the draft reports, the review packet, and `MEV0-001`,
  which only the build report still remembered — 17 IDs, leaving at most 7 unexposed cases
  among the original 24. An internal swap therefore could not produce 8 sealed holdouts.
- Development is now exactly the 16 suggestion IDs. `MEV0-004` moved back into development
  because a model had already seen it.
- `MEV0-001` is exposed and has no suggestion, so it belongs in neither half. It is retired
  to `meeting-execution-v0/retired-cases/`, marked `retired_exposed`, and kept rather than
  deleted.
- The vacated `explicit_single_output` holdout seat is refilled by `MEV0-025`, selected from
  the 957-case corpus by `(media, type, domain)` strata and lowest `source_id` among 19
  unused, family-disjoint candidates. Selection opened no label file; exactly one was opened
  afterwards to materialize the case.
- Sealed payload reads during selection: 0. Sealed cases contribute provenance only through
  a projection that drops transcript, gold, features, and heuristic signals.
- A full rebuild now refuses to run over a repaired corpus unless `--allow-partition-reset`
  is passed, so the original swap cannot silently return.

## Current gate

TM 2.1 and TM 2.2 are in `review`. Human semantic review has not started. The fail-closed
audit added by TM 2.2 proves:

1. 16 development and 8 sealed cases;
2. manifest, source index, case metadata, draft IDs, and packet headings agree;
3. draft IDs equal development IDs;
4. draft IDs intersect sealed IDs is empty;
5. every exposed ID is non-sealed;
6. repeated metadata-only selection is deterministic and idempotent;
7. external calls and sealed payload reads are zero.

TM 2.3 still has to regenerate the review packet: the current `DEVELOPMENT_REVIEW.md`
matches the repaired development set by construction, but it was written before the repair
and is not yet the packet human review runs against.

## Privacy and execution limits

- Local corpus and review artifacts stay under ignored `data/` paths.
- No provider key, external AI, MCP/server, cloud sync, corpus upload, audio upload, or public release.
- Do not alter semantic labels during partition repair.
- Do not inspect the sealed payload to decide a replacement.
- Do not equate Task Master status counts with Notion evidence progress.
