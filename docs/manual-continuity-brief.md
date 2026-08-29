# Manual Continuity Brief v0

Manual Continuity Brief is a local, user-triggered view of three different things:

1. work state the user already approved or entered;
2. changes proposed from a later meeting and still awaiting review; and
3. agenda items the user approved for the next meeting.

Opening the Brief is read-only. It loads `Project`, continuity transition records, and the local
profile. It does not call a model, re-analyse a transcript, create an agenda item, approve a
transition, change project state, or schedule a Reminder or Calendar event. Evidence text is
resolved at render time from the `Project`; it is not copied into the continuity store.

## Confirmed state and review candidates

`ApprovedWorkStatePolicy` is the only definition of confirmed prior state. A pending transition is
shown as a candidate, never as a fact: completion is phrased as a completion confirmation,
resolution as a resolution candidate, and an ambiguous match as a choice between a prior candidate
and a new object.

`MyWorkPolicy` is the only definition of personal work. Without a linked `LocalUserProfile`, the
Brief uses neutral wording for active or assigned work and never guesses that a transcript speaker
is the local user.

Briefing and Next Agenda remain different surfaces. An incomplete, delayed, blocked, or overdue
Action Item can be useful briefing context, but none of those facts manufactures an Agenda Item.
Only an extracted pending Agenda Item or the target of a typed `carriedToAgenda` relation is an
agenda candidate; only a user-reviewed pending Agenda Item is active Next Agenda.

## Progress facts

The continuity record keeps structured delay detail as a finite optional value:

| Transition | Progress detail | Meaning |
| --- | --- | --- |
| `completed` | none | completion candidate |
| `delayed` | `deferred` | explicitly deferred in a meeting |
| `delayed` | `blocked` | explicitly blocked in a meeting |
| `delayed` | none, basis `overdueApprovedDueDate` | approved due date had passed |

These are not interchangeable. A missing due date cannot produce overdue, and approving any delayed
case does not alter the task status or due date. No blocker prose is stored beside the finite detail.

## Evidence

The presentation layer resolves evidence in this order:

1. the current Work State's `EvidenceReference`;
2. the transition meeting/segment pointer;
3. that segment in the stored source meeting; or
4. the approved due date for an overdue fact.

A hand-entered prior state can legitimately have no transcript evidence and is labelled as user
input. A dangling meeting or segment pointer is different: the Brief says the evidence cannot be
found and disables an evidence-dependent destructive apply. An overdue fact remains reviewable
without transcript evidence while its approved due date is still present and valid.

## Review and apply

The dedicated transition review service reloads both repositories before every verdict and checks
project ownership, dedup identity, pending review state, object kind and existence, and evidence.

- `new` approves the current object using the existing Work State approval rules.
- `same` keeps the prior canonical object and consumes the incoming duplicate.
- `changed` applies only displayed, typed fields to the prior canonical object. Its ID and original
  `createdAt` stay unchanged; for an Action Item this also preserves every Reminder reference.
- `completed` marks the prior Action Item completed and consumes the incoming status-report object.
- `delayed` preserves the prior Action Item's active status and due date.
- `resolved` resolves the prior Open Question and approves its typed relation target.
- `derivedFrom` approves only the typed relation record; it creates no second Work State.
- rejection changes no Project Work State.

Ambiguity selection is one transition-store batch write. Choosing a prior candidate approves only
that candidate proposal and rejects its siblings. Choosing `new` rejects every candidate and
approves the incoming object as new. The persisted selection contains identifiers, a finite choice,
and a timestamp only, and engine reruns cannot reset it.

## Two-store failure boundary

An approval writes the Project first and the transition review second. A failed Project save leaves
the review pending. If the Project save succeeds and the review save fails, the operation reports a
finite partial failure and offers retry; the Project mutation is idempotent, so retry completes the
review record without changing canonical identity again. This is deliberately not described as an
atomic transaction. Rejection writes only the transition review store.

The finite partial-commit receipt is held by the stable, app-owned review service actor. v0 does not
persist that receipt separately, so after an app restart it cannot automatically identify a review
write that failed after the Project mutation. The durable Project mutation remains idempotent, but
the user must retry while the same app session still owns the receipt.

The continuity store contains identifiers, finite enums, timestamps, and evidence pointers. It does
not contain transcript text, quotes, titles, participant names, blocker prose, or raw repository
errors.

## v0 limits

The Brief is manually opened from a Project. There is no Calendar trigger, approve-all action,
natural-language due-date parser, model call, Reminder/Ledger automation, collaboration workspace,
or separately persisted free-form Brief document. Semantic model quality and human-gold accuracy are
not claims of this implementation.
