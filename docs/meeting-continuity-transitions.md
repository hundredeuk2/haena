# Meeting Continuity v0 — transition contract

HAE.NA is not a minutes generator. Its claim is that it can say what changed between one meeting and
the next. This document is the contract behind that claim: what the engine is allowed to conclude,
what it must refuse, and what it may never decide on a user's behalf.

Code: `HAENA/Continuity/`. Tests: `HAENATests/WorkStateTransition*.swift`.

## The shape of the thing

```
approved prior state  +  new meeting's mapped proposals
        -> transition proposals        (this task)
        -> user review                 (follow-up task)
        -> approved next state
```

The engine is a pure function. `WorkStateTransitionEngine.generate(_:now:)` has no `async`, no
`throws`, no repository, no `Date()`, no `UUID()`, no I/O, and no randomness. `now` is stamped into
`createdAt` and used for nothing else — lateness is judged against the meeting's own `occurredAt`, so
re-running the engine a month later cannot retroactively make a task overdue.

Transition proposals are stored in `continuity-transitions.json`, a sibling of `projects.json`.
**Nothing in this feature ever opens `projects.json` for writing.** `WorkStateContinuityService` holds
a `ProjectRepository` solely to read the approved snapshot, and no path from it reaches
`ProjectRepository.save`. "Generating proposals cannot alter approved work state" is therefore a
property of which calls exist, not of when they run.

The engine only generates `pending_review`. The store keeps that engine payload separate from
user-owned `approved`/`rejected` review state, so an engine rerun cannot undo a later review.
`WorkStateTransitionReviewService` is the sole application boundary that can turn a pending
proposal into a Project mutation and terminal verdict; generation itself still approves nothing.

## Transition matrix

| Work state | new | same | changed | completed | delayed | resolved |
| --- | --- | --- | --- | --- | --- | --- |
| Decision | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| Action Item | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Open Question | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| Next Agenda | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |

A decision is not a task and not a question: it cannot complete, run late, or be answered. An action
item is the only work state with a lifecycle and a due date, so it is the only one that can be
`completed` or `delayed`.

`AgendaItem` is deliberately the most conservative row. It is the only work state allowed to be
user-authored — `evidence` and `confidence` are both optional precisely so a hand-added entry never
has to invent a source — and its `title`/`reason` are free-form, giving it the weakest identity of
the four. v0 will only say "this agenda line is new" or "this is the same one as before". A question
that stays on the agenda is modelled as an **Open Question `resolved` transition carrying a
`carried_to_agenda` relation**, never as an agenda-item transition.

A pair outside this table is refused with `unsupported_transition_for_kind`. It is never bent into
the nearest allowed transition — otherwise the matrix could be reviewed as a table while the engine
quietly worked around it.

## The automatic / confirm / refuse boundary

**Automatic** (`requiresConfirmation == false`) — exactly two cases:
- `new`: no prior candidate at all.
- `same`: exactly one candidate, exact normalized-text match, and (for an action item) an assignee
  attribution that is resolved or absent.

Neither asserts a change to approved state, which is the whole reason they are allowed to be
automatic.

**Needs confirmation** — `changed`, `completed`, `delayed`, `resolved`, every ambiguous candidate, and
any `same` downgraded by an unresolved assignee. All of these would alter approved state if accepted.

**Refused** — cross-project objects, missing or foreign evidence, unapproved prior items, unsupported
pairs, and structured links pointing at objects not present in the input.

### Matching, and what it is not

The only matching signal is text. `normalize` applies Unicode NFC, lowercasing, whitespace
collapsing, and trailing-terminator removal — every one of which is a *rendering* difference. It
does not stem, translate, expand abbreviations, or drop stop words; each of those would let two
genuinely different statements normalize to the same string and become an automatic `same`.

Near matches use Jaccard overlap of token sets at `>= 0.6`. **Similarity alone never confirms
anything** — a near match is always a question put to the user. There is deliberately no upper bound
on the near band: token *sets* can score 1.0 across strings that are not equal ("fix the bug" vs
"fix the the bug"), and excluding those would emit `new` beside the item it duplicates.

Assignee attribution is never a matching signal. It can only take away an automatic `same`; it can
neither create a link nor break one.

On ambiguity (two or more candidates) the engine emits one confirm-required row per candidate and
**no automatic `new` proposal**. It also emits one deterministic group containing the incoming
object id and sorted prior candidate ids. The review contract offers every candidate plus an explicit
`new` choice, so a user can say "none of these" without the engine creating a duplicate first.

## `delayed`, and why there is no date parser

There is no natural-language date parsing anywhere in this feature, and no inference of lateness from
prose. `delayed` rests on two structural bases only:

1. **`overdue_approved_due_date`** — an approved action item whose `dueDate` precedes the meeting's
   `occurredAt`. This needs no mention in the new meeting at all; the lateness is a fact about stored
   state, so `currentObjectID` and `evidence` are nil.
2. **`structured_progress_signal`** — a typed `deferred`/`blocked` `WorkStateProgressSignal` carrying
   its own evidence. Its target is either an incoming action item or, when the meeting only reported
   on work that already exists, the approved prior item itself; the prior form leaves
   `currentObjectID` nil because no incoming duplicate was created to carry it.

When both apply to one prior item they collapse to a single `delayed` row and the signal wins, since
an explicit statement is the better explanation. The persisted proposal also carries an optional,
finite `progressDisposition`: `deferred` or `blocked` for a structured signal, and `nil` for an
overdue due-date fact. No blocker prose is stored.

A `completed` proposal has the same two target shapes for the same reason. Approving a prior-target
`completed` marks the prior item completed and consumes nothing, because there is nothing to
consume; approving a prior-target `delayed` records the fact and leaves the prior item's status and
due date exactly as they were. The absence of a current object is the shape of these proposals, not
evidence that they went stale.

## Direct decision-change references

A `changed` decision proposal has one further basis: **`structured_decision_change_link`**, raised
when the model names the approved decision an incoming one revises. It outranks near-text matching
for that incoming decision — the engine does not re-derive from titles an answer it asked for, and
it raises no ambiguous-match group over a question already settled. Two links claiming the same
incoming decision cancel each other and both are refused. The apply contract is unchanged: the prior
canonical id and original `createdAt` survive, and the incoming duplicate is consumed.

## Idempotency

```
haena.work-state-transition.v1|<projectID>|<workStateKind>|<transitionKind>|<previousStateID>|<currentObjectID>
```

UUIDs are lowercased; a nil renders as the literal `none`. A proposal's `id` is **not random** — it is
a deterministic UUID derived by SHA-256 over this key, so the same structural facts reproduce the same
id across processes, restarts, and machines. Storage upserts on the key, so a repeated run refreshes
engine-owned explanation fields rather than appending. It preserves the first `createdAt`, and the
separate review map prevents `approved` or `rejected` from reverting to `pending_review`.

`transitionKind` is part of the key: one prior/current pair may legitimately carry both a `changed`
and a `delayed` statement. `basis`, `reasons`, `relations`, and `createdAt` are deliberately *not* in
the key, so enriching an explanation later lands on the same row instead of forking it.

## Privacy boundary

A transition record never duplicates transcript text. Instead of `EvidenceReference` it stores
`TransitionEvidencePointer { meetingID, transcriptSegmentID }` — the quote is dropped and recovered
from the referenced object when needed. No titles, statements, questions, or person names are stored,
and every explanation is a closed enum rather than free text. A `String` reason would eventually carry
a quote or a participant's name into a store that is not the transcript store, and no reviewer of a
later change would notice.

Finite refusal records contain only enums and ids, tied to deterministic run/project/meeting
identity. They carry no transcript, title, name, or free-form field and deduplicate on rerun.

The file is written atomically with `0o600`. Schema 2 added separate reviews, ambiguity groups, and
refusals. Schema 3 adds terminal ambiguity selections and preserves the finite progress disposition
on proposal payloads. Schema-1 and schema-2 files remain readable and are upgraded on the next
write.

## Manual review and apply

Review writes use typed terminal verdicts and reject unknown proposals, cross-project references,
and attempts to flip one terminal verdict into another. Ambiguity selection persists one finite
choice and terminal sibling verdicts in a single transition-store write.

Approval reloads and validates both repositories, saves the idempotent Project mutation first, and
then records the transition verdict. A Project-save failure leaves the proposal pending. If the
Project save succeeds and the review write fails, the service returns a finite partial failure; a
retry on the same stable service actor completes the review without changing the canonical Work
State ID or `createdAt` again. Rejection never mutates Project Work State.

## Structured signal producer

The extraction side now has a typed producer contract for progress signals, question-resolution
links, and decision-derived action links. Provider-local keys are resolved to deterministic
app-owned IDs only after base evidence passes validation; approved prior state is exposed through
request-local opaque references and revalidated before persistence. See
[`structured-continuity-signals.md`](structured-continuity-signals.md) for the provider, mapper,
privacy, and failure-isolation boundaries.

There is still no transcript-phrase parser or fuzzy relation linker. A missing structured signal
therefore produces no corresponding `completed`, signal-based `delayed`, `resolved`, or
`derived_from` claim.

## Known limitations
- **Two different incoming items may defer the same prior item**, producing two `delayed` rows with
  distinct keys. Both require confirmation, so nothing is decided automatically, but the pair is not
  itself flagged as ambiguous.
- **Prior state needs no evidence.** Approval, not provenance, is what qualifies stored state as
  prior state — otherwise every hand-entered decision would be invisible to continuity. A
  `previousStateID` may therefore point at an object with no transcript behind it, and a brief must
  not present that as missing data.
