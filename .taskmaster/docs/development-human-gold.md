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

## Review packet — TM 2.3, 2026-08-30

`DEVELOPMENT_REVIEW.md` is now generated from the repaired development set and is the packet
human review runs against. The previous one is archived at
`meeting-execution-v0/retired-packets/DEVELOPMENT_REVIEW.stale.md`; it is superseded, not
wrong about its own inputs.

- The old generator read `manifest.jsonl` — the one file holding every case body, sealed
  holdouts included — and filtered to development afterwards. The new one reads the
  transcript-free index, takes the development IDs from it, and opens exactly those 16 case
  files. Sealed cases are never loaded, so there is nothing to filter out.
- Same AI content (7 decisions, 18 action items, 7 open questions, 2 next agenda, 26 flags),
  new review surfaces: per-item non-gold labelling, explicit / derived proposal / forbidden
  inference, target speaker B responsibility, assignee and due-date basis judgments,
  prior-state expected transition, forbidden-inference checks, reviewer note and ambiguity.
- Evidence now points at a transcript position (`전사 U12 · 45.2초 · 화자 B`) and the cited
  rows are marked in the full transcript, so a reviewer can check the original rather than
  the quote the model chose.
- The generator refuses to overwrite a packet it did not write, refuses a draft set that is
  not exactly the development set, refuses a draft that failed local evidence validation,
  and refuses to write text containing a sealed ID or a machine path.
- Generation writes nothing to any case, gold field, or progress counter, and does not
  advance review. All 16 cases remain `human_review_pending`, all drafts `pending`.

## Primary review storage — TM 2.4 checkpoint A, 2026-08-30

Before any case was presented, the storage contract was built so that a review can only hold
what a person actually said.

- Reviews live at `meeting-execution-v0/human-reviews/primary/<case>.review.json`, under the
  ignored `data/` tree. `DEVELOPMENT_REVIEW.md` stays read-only evidence.
- No human field is ever seeded from the AI suggestion. A candidate nobody ruled on is
  `null`, not `approve`. AI text is carried under `ai_`-prefixed keys that no completion rule
  reads, so a default cannot survive review and become a label nobody chose.
- `template` creates only when no review exists; an existing review is refused outright.
  `record` changes only the fields the decision document names. `validate` writes nothing.
- Completion is blocked while any structural field is unresolved: a candidate without a
  verdict, a result type without either `no_missing` or a recorded omission, an unchecked
  forbidden-inference pass, an unanswered prior-state question, or a missing explicit
  confirmation from the reviewer.
- `modify_and_approve` needs the corrected text and evidence, `exclude` needs a reason from a
  closed list, an action item needs both assignee and due-date basis, and every cited
  utterance ID must exist in that case. A basis claiming no support may not carry a value.
- Regenerating the packet or changing a case file invalidates a review in progress by digest,
  rather than letting it drift against evidence it no longer matches.
- The shareable artifact is an audit summary of IDs, statuses, digests, and counts. It refuses
  to run over reviews that do not validate, and carries no transcript, reviewer text, or
  utterance identifiers.

Three contract fields were added during batch 1, each because a real answer had nowhere to go
rather than because a gap was imagined:

- omissions carry their own `inference_class`, since a reviewer-added item can be a derived
  proposal just as a model candidate can;
- a forbidden inference may rest on `absence_in_window`, because "no due date was ever
  stated" cites nothing — demanding an utterance ID there would push a reviewer into citing
  an unrelated line to satisfy the schema, and such an item may cite nothing at all;
- `transcript_coverage` records that the whole window was read. An absence claim is refused
  without it, and no review completes without it, so a partial or truncated pass cannot end
  as `complete`. The window bounds are pinned from the case itself, and validation fails if a
  review later claims coverage of a window the case does not have;
- an exclusion carries `exclude_evidence_utterance_ids`, its own grounds. The contract had
  conflated those with the evidence that would have supported the item as gold and forbidden
  both, which left the reasoning behind a rejection nowhere to go;
- a forbidden inference may also rest on `review_method`, for a prohibition about how review
  is conducted rather than about the recording — "the focus label is a selection stratum, not
  an answer count". It cites nothing, like an absence claim, but makes no claim about the
  window, so it does not borrow the coverage confirmation;
- an ambiguity keeps its `kind`, span, and `resolution` instead of being flattened into a
  sentence. `kind` is deliberately not an enum: ambiguity types cannot be listed in advance,
  and a closed set would push a reviewer into the nearest wrong bucket. It stays free-form
  through primary review and is normalized to a finite taxonomy, or `other`, at TM 2.8; a raw
  value is not an input to gold or to the scorer;
- `historical_state_not_current_meeting_output` is its own exclusion reason. A decision
  reported here as an existing state is not the same as something that was never a meeting
  output at all, and collapsing the two would erase the boundary the benchmark exists to
  test;
- a due date can be `explicit_relative`: an utterance says "by today" and the case carries no
  anchor to resolve it. It is neither present nor absent, and forcing it into either would
  invent a date or discard a real one. Whether it could be normalized must be stated even
  when the answer is null, because an absent key would read as "not looked at";
- AI review flags are judged, not read. The packet had `동의 / 반려` boxes with nowhere to
  store the answer, so a review could close with the model's warnings unanswered. Flag keys
  must match the packet's exactly, `agree` needs evidence, `reject` needs the boundary the
  flag got wrong and the correction, both need a reason, and an unjudged flag blocks
  completion. A review written before flags were judgeable gains the empty entries on load —
  structure, never a verdict — so it reopens as unresolved instead of staying complete.

## Primary review batch 1 — TM 2.4, 2026-08-30

Four cases reviewed against packet `78ec6c28…`, all `complete`, zero unresolved structural
fields, validation PASS, zero network calls. The reviews themselves stay local; only
identifiers, digests, and counts are recorded here.

| case | focus | candidates | flags | omissions | forbidden | ambiguities | review sha256 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| MEV0-004 | explicit_single_output | approve 1, modify 1 | reject 2 | 2 | 7 | 0 | `27d1d7c9` |
| MEV0-010 | multi_output | exclude 1 | — | 1 | 8 | 1 | `179601f0` |
| MEV0-014 | negative_or_forbidden | none offered | agree 1 | 0 | 9 | 1 | `fc8f248e` |
| MEV0-019 | assignee_or_due_ambiguity | approve 1, modify 1, exclude 1 | agree 1 | 1 | 11 | 3 | `4b5fadd1` |

Six AI candidates drew two approvals, two corrections, and two exclusions; four omissions
were added that no candidate covered. The model's own uncertainty flags fared worse than its
candidates: of four, three were rejected as having drawn the wrong boundary rather than
having found a real ambiguity.

Every case reached `not_applicable` on prior state, and no case file, gold field, or draft
was modified by any of it.

### Primary review contract freeze

Batch 1 closes `primary-review-v0.1`. Batch 2 must use that version without silently adding,
removing, or reinterpreting fields. A real contract defect still must be reported; it becomes
a new explicit version with a migration impact report across all completed reviews. A lossless
structural migration may run automatically only when it invents no semantic value. If the new
contract requires a human decision that v0.1 did not capture, only the affected completed cases
reopen and must be explicitly re-confirmed.

## Current gate

TM 2.1 through TM 2.4 are `done`. Primary human review is 4 / 16, with batch 1 validated
and user-approved. The fail-closed audit added by TM 2.2 proves:

1. 16 development and 8 sealed cases;
2. manifest, source index, case metadata, draft IDs, and packet headings agree;
3. draft IDs equal development IDs;
4. draft IDs intersect sealed IDs is empty;
5. every exposed ID is non-sealed;
6. repeated metadata-only selection is deterministic and idempotent;
7. external calls and sealed payload reads are zero.

TM 2.5 continues primary human review batch 2 against the regenerated packet. The generated
`DEVELOPMENT_REVIEW.md` is read-only evidence, not the decision store. Primary decisions live
in separate per-case JSON under a local `human-reviews/primary/` directory. A generator may
create a missing template, but it must never overwrite an existing review. Only explicit user
decisions may populate semantic fields; the code agent presents, records, and validates but
does not choose truth. A generated packet is a worksheet, not progress.

The four deterministic batches are:

1. `MEV0-004`, `MEV0-010`, `MEV0-014`, `MEV0-019`;
2. `MEV0-005`, `MEV0-012`, `MEV0-015`, `MEV0-023`;
3. `MEV0-006`, `MEV0-011`, `MEV0-016`, `MEV0-018`;
4. `MEV0-007`, `MEV0-008`, `MEV0-020`, `MEV0-024`.

## Privacy and execution limits

- Local corpus and review artifacts stay under ignored `data/` paths.
- No provider key, external AI, MCP/server, cloud sync, corpus upload, audio upload, or public release.
- Do not alter semantic labels during partition repair.
- Do not inspect the sealed payload to decide a replacement.
- Do not equate Task Master status counts with Notion evidence progress.
