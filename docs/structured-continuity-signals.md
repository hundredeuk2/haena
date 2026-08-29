# Structured continuity signal producer

The extraction layer produces four base work-state collections and three optional sidecar signal
collections. A sidecar can add a transition claim, but it can never make an otherwise invalid base
proposal valid and it can never prevent a valid base proposal from being stored.

## Provider identity boundary

The provider assigns request-local keys such as `decision_1`, `action_1`, `question_1`, and
`agenda_1`. Keys use a kind-specific prefix followed by a positive decimal ordinal, contain only
ASCII lowercase letters, digits, and underscores, and are limited to 32 characters. They are unique
within one payload. They are not UUIDs and must not contain transcript text or a person's name.

After evidence validation, the app derives each domain ID from:

```
haena.work-state-extraction.v1|<project-id>|<meeting-id>|<kind>|<provider-local-key>
```

The first 16 bytes of SHA-256 become an RFC-variant, v5-shaped UUID. A provider never chooses a
domain ID, while an identical meeting/key pair remains stable across retries, process restarts, and
machines.

Approved prior state is exposed through request-scoped opaque references such as
`prior_action_1`, `prior_question_1`, and `prior_decision_1`. The provider sees only the work-state
kind, minimal display text, finite current state, and opaque reference. A separate local allow-list
maps each reference to its domain UUID. Project, meeting, participant, and work-state UUIDs; prior
evidence quotes; and repository paths are not included in this provider context.

## Provider output

The structured response has eight required arrays. A provider returns an empty array when it has no
grounded claim.

- `decisions`, `action_items`, `open_questions`, `next_agenda_items`
- `progress_signals`: `completed`, `deferred`, or `blocked`, naming exactly one target through
  `target_type` and `target_reference` — either an incoming action key or a prior action reference
- `open_question_resolution_links`: a prior question reference plus an incoming decision, action,
  or agenda key
- `decision_derived_action_item_links`: exactly one incoming-decision key or prior-decision
  reference, plus an incoming action key
- `decision_change_links`: a prior decision reference plus the incoming decision key that revises it

Every signal carries evidence from the current meeting. An agenda resolution target means that the
question was carried forward, not answered. A derived link is provenance only; it does not mutate
the decision or action item.

A progress signal's two target namespaces are not interchangeable. `incoming_action_item` resolves
through the accepted base-key map; `prior_action_item` resolves through the request-scoped prior
allow-list and never through a model-supplied identifier. The prior form exists because a meeting
that only reports on existing work — "that one is done", "we pushed it", "it is stuck" — extracts no
action item to hang the signal on, and inventing one would put a task on the board that nobody
committed to in that meeting. A prior-target signal therefore creates no incoming object at all.

`decision_change_links` is the same idea for decisions, and it outranks the engine's own
title-similarity matching: when the model names the approved decision being revised, that answer is
used instead of a guess, and no ambiguous-match group is raised.

This replaced the earlier `action_item_key` field outright. Provider responses are never persisted,
so no stored payload needed migrating and no dual decoder was kept; the schema, DTO, and the
deterministic fixture changed together as one explicit payload contract change.

The prompt forbids guessing status from tone, probability, or conversational mood. It also forbids
inventing a base proposal merely to support a signal. There is no transcript keyword parser,
regular-expression status classifier, natural-language due-date parser, or fuzzy relationship
linker after the model response.

## Validation and write order

Mapping has two phases:

1. Validate base keys, payload-wide uniqueness, content, confidence, and current-meeting evidence.
   Derive stable IDs and build the accepted key-to-ID map.
2. Resolve sidecars only against accepted base keys and the original prior-reference allow-list.
   Missing or foreign evidence, dangling keys, unknown prior references, invalid target kinds, and
   ambiguous decision sources reject only that signal with a finite reason.

The extraction service loads the project and meeting, captures approved prior state, calls the
provider, maps the response, then reloads the project. It rechecks prior references against the
fresh approved snapshot immediately before the project write. A stale reference is removed from the
signal set without removing any accepted base object.

The project is saved before continuity transitions are generated. Only after that save succeeds are
validated sidecars handed to `WorkStateContinuityService`. A transition-store failure is reported by
a finite persistence status; it does not roll back `projects.json` and is not reported as successful
transition persistence.

Transition generation remains proposal-only. It never approves a transition, edits approved project
state, schedules a reminder, writes an Agent Ledger event, or invokes Calendar.

## Persistence and privacy

`projects.json` remains the sole store for work-state content and evidence quotes.
`continuity-transitions.json` keeps only finite enums, IDs, and quote-free evidence pointers. Engine
payload and user review state remain separate under schema 2, so an upsert preserves the first
`createdAt` and cannot turn `approved` or `rejected` back into `pending_review`.

The newly transmitted prior context is limited to kind, minimal display text, finite state, and an
opaque request-local reference. Tests and offline deterministic providers make no external API call,
send no audio, and do not access a sealed holdout.
