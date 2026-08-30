#!/usr/bin/env python3
"""Project completed primary reviews into a canonical development gold draft.

This is a projection, not a migration. The primary reviews stay exactly as their
reviewers left them — three contract versions, byte-identical, never rewritten — and this
reads them into one shape so the four result types, evidence, bases, forbidden inferences
and prior-state records can be validated together.

The whole design turns on one distinction the source data forces: **not recorded is not the
same as unspecified**. An assignee scope that a reviewer never stated is `null` with
`scope_recorded: false`, not `unspecified`. A prior-state field that v0.1 had no place for is
`null` with `recorded: false`, not `absent`. Filling either in would manufacture a judgment
nobody made, and the validator fails the draft if it happens.

Two things are therefore deliberately not derived here. The reviewers wrote basis kinds like
`speaker_commitment` inside a free-text assignee value, and scope is nowhere in the schema at
all; recovering either means reading Korean prose, so those records are routed to secondary
review instead. Ambiguity taxonomy is likewise left `null` until its mapping is approved —
the raw kind, the reviewer's own wording, the evidence and the resolution all survive
regardless.

Nothing here is final gold. The draft carries
`primary_normalized_pending_secondary_review` and `scorer_ready: false`, and no prior-state
record in this corpus is eligible for a transition scorer.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from primary_review_contract import (  # noqa: E402  (import path is set above)
    CATEGORIES,
    FLAG_VERDICTS,
    INFERENCE_CLASSES,
    RESPONSIBILITY,
    VERDICTS,
    prior_transition_of,
)

SCHEMA_VERSION = "development-gold-draft-v0.1"
DRAFT_STATUS = "primary_normalized_pending_secondary_review"
NORMALIZATION_COMPLETE = "complete"
NORMALIZATION_PENDING = "pending_secondary_review"
NORMALIZATION_STATUSES = (NORMALIZATION_COMPLETE, NORMALIZATION_PENDING)

CANONICAL_OUTPUT_TYPES = {
    "decisions": "decision",
    "action_items": "action_item",
    "open_questions": "open_question",
    "next_agenda": "next_agenda",
}
ORIGINS = ("approved_candidate", "modified_candidate", "reviewer_added_missing_item")

# The only basis values that exist as their own source field. `speaker_commitment` and
# `team_or_role` appear only inside free-text assignee values and are never promoted.
PROMOTABLE_BASIS = ("supported_by_utterance", "absent_must_stay_empty")
DUE_STATUS_MAP = {
    "absent_must_stay_empty": "absent",
    "supported_by_utterance": "explicit",
    "explicit_relative": "explicit_relative",
    "corrected": "explicit",
}
# Only a transition judged against a typed prior object can be scored. Both other statuses
# mean the question could not be answered, which is not the same as answering "no change".
SCORER_ELIGIBLE_PRIOR_STATUS = ("expected",)
PRIOR_FIELDS = (
    "prior_reference", "object_identity", "transition_kind", "from_state", "to_state",
    "evidence_utterance_ids",
)


class GoldDraftError(RuntimeError):
    """A projection or validation failure that must stop the draft, not soften it."""


def _require(condition, message):
    if not condition:
        raise GoldDraftError(message)


def recorded_field(source, key, default=None):
    """Carry a field across only if the source actually had it.

    The value is copied, not referenced: a draft that aliased the review could mutate the
    reviewer's own record through a later edit, and the comparison that is supposed to catch
    a rewrite would compare the value against itself.
    """
    present = isinstance(source, dict) and key in source
    value = json.loads(json.dumps(source[key])) if present else default
    return {"value": value, "recorded": present}


def project_assignee(basis):
    """Preserve what the reviewer wrote and promote only what has its own field.

    `raw_value` and `source_status` are copied verbatim. `scope` has no source field at all,
    so it stays null and the record goes to secondary review — inferring it would mean
    reading the value text, which is the reviewer's prose, not data.
    """
    if basis is None:
        return {
            "raw_value": None, "source_status": None,
            "scope": None, "scope_recorded": False,
            "normalized_basis": None, "normalized_basis_recorded": False,
            "evidence_utterance_ids": [],
            "normalization_status": NORMALIZATION_COMPLETE,
        }
    status = basis.get("status")
    raw_value = basis.get("value")
    promotable = status in PROMOTABLE_BASIS
    # An assignee the reviewer judged absent has nothing to scope, so it needs no second
    # look. Everything else does, because scope was never a field they could fill.
    settled = status == "absent_must_stay_empty" and raw_value in (None, "")
    return {
        "raw_value": raw_value,
        "source_status": status,
        "scope": None,
        "scope_recorded": False,
        "normalized_basis": status if promotable else None,
        "normalized_basis_recorded": promotable,
        "evidence_utterance_ids": list(basis.get("utterance_ids") or []),
        "normalization_status": NORMALIZATION_COMPLETE if settled else NORMALIZATION_PENDING,
    }


def project_due(basis):
    if basis is None:
        return {
            "raw_value": None, "source_status": None,
            "normalized_status": None, "normalized_status_recorded": False,
            "normalized_absolute_date": None, "normalized_absolute_date_recorded": False,
            "evidence_utterance_ids": [],
        }
    status = basis.get("status")
    normalized = DUE_STATUS_MAP.get(status)
    absolute = recorded_field(basis, "normalized_absolute_date")
    return {
        "raw_value": basis.get("value"),
        "source_status": status,
        "normalized_status": normalized,
        "normalized_status_recorded": normalized is not None,
        "normalized_absolute_date": absolute["value"],
        "normalized_absolute_date_recorded": absolute["recorded"],
        "evidence_utterance_ids": list(basis.get("utterance_ids") or []),
    }


def project_note(entry):
    note = entry.get("note")
    return {"reviewer_note": note, "reviewer_note_recorded": note is not None}


def project_output(entry, category, origin, text):
    output = {
        "output_type": CANONICAL_OUTPUT_TYPES[category],
        "text": text,
        "origin": origin,
        "source_candidate_key": entry.get("candidate_key"),
        "evidence_utterance_ids": list(entry.get("evidence_utterance_ids") or []),
        "inference_class": entry.get("inference_class"),
        "target_speaker_responsibility": entry.get("target_speaker_b_responsibility"),
        "assignee": project_assignee(entry.get("assignee_basis")),
        "due": project_due(entry.get("due_basis")),
    }
    output.update(project_note(entry))
    return output


def project_case(review, review_digest):
    """Read one completed primary review into the canonical draft shape."""
    _require(review.get("review_status") == "complete", "only a complete review can be projected")
    _require(not review.get("unresolved"), "a review with unresolved fields cannot be projected")

    outputs = {key: [] for key in CANONICAL_OUTPUT_TYPES.values()}
    excluded = []
    for entry in review["candidate_verdicts"]:
        category = entry["category"]
        verdict = entry.get("verdict")
        _require(verdict in VERDICTS, "candidate {} has no verdict".format(entry["candidate_key"]))
        if verdict == "exclude":
            excluded.append(dict({
                "output_type": CANONICAL_OUTPUT_TYPES[category],
                "source_candidate_key": entry["candidate_key"],
                "ai_candidate_text": entry.get("ai_candidate_text"),
                "exclude_reason": entry.get("exclude_reason"),
                "exclude_evidence_utterance_ids": list(entry.get("exclude_evidence_utterance_ids") or []),
                "inference_class": entry.get("inference_class"),
                "target_speaker_responsibility": entry.get("target_speaker_b_responsibility"),
            }, **project_note(entry)))
            continue
        if verdict == "approve":
            origin, text = "approved_candidate", entry.get("ai_candidate_text")
        else:
            origin, text = "modified_candidate", entry.get("final_text")
        outputs[CANONICAL_OUTPUT_TYPES[category]].append(
            project_output(entry, category, origin, text)
        )

    for item in review["missing_items"]:
        category = item["category"]
        outputs[CANONICAL_OUTPUT_TYPES[category]].append(
            project_output(item, category, "reviewer_added_missing_item", item.get("text"))
        )

    source_prior = prior_transition_of(review) or {}
    prior = {
        "source_contract_version": review["schema_version"],
        "source_raw": json.loads(json.dumps(source_prior)),
        "status": source_prior.get("status"),
        "status_recorded": "status" in source_prior,
        "reason": source_prior.get("reason"),
        "scorer_eligible": source_prior.get("status") in SCORER_ELIGIBLE_PRIOR_STATUS,
    }
    for field in PRIOR_FIELDS:
        prior[field] = recorded_field(source_prior, field)
    prior["normalization_status"] = (
        NORMALIZATION_COMPLETE
        if all(prior[field]["recorded"] for field in PRIOR_FIELDS)
        else NORMALIZATION_PENDING
    )

    ambiguities = [
        {
            "taxonomy": None,
            "raw_kind": item.get("kind"),
            "about": item.get("about"),
            "statement": item.get("statement"),
            "evidence_utterance_ids": list(item.get("evidence_utterance_ids") or []),
            "resolution": item.get("resolution"),
            "normalization_status": NORMALIZATION_PENDING,
        }
        for item in review["ambiguities"]
    ]

    return {
        "schema_version": SCHEMA_VERSION,
        "status": DRAFT_STATUS,
        "scorer_ready": False,
        "primary_review_complete": True,
        "secondary_review_complete": False,
        "case_id": review["case_id"],
        "source_review_digest": review_digest,
        "source_contract_version": review["schema_version"],
        "outputs": outputs,
        "excluded_candidates": excluded,
        "forbidden_inferences": json.loads(json.dumps(review["forbidden_inference"]["items"])),
        "review_flag_verdicts": json.loads(json.dumps(review.get("review_flag_verdicts", []))),
        "ambiguities": ambiguities,
        "prior_transition": prior,
        "review_provenance": {
            "primary_review_complete": True,
            "full_window_confirmed": (review.get("transcript_coverage") or {}).get(
                "full_window_reviewed"
            ) is True,
            "unresolved_count": 0,
        },
    }


def validate_case(draft, review, review_digest):
    """Fail the draft for anything the projection could only have invented.

    Every rule here exists because the opposite would be silent: a filled-in scope, a
    merged identity, a dropped ambiguity, a note quietly summarized away.
    """
    errors = []

    def check(condition, message):
        if not condition:
            errors.append(message)

    check(draft["schema_version"] == SCHEMA_VERSION, "draft is not {}".format(SCHEMA_VERSION))
    check(draft["status"] == DRAFT_STATUS, "draft status must stay {}".format(DRAFT_STATUS))
    check(draft["scorer_ready"] is False, "a primary-normalized draft is never scorer-ready")
    check(draft["secondary_review_complete"] is False, "secondary review has not run")
    check(draft["case_id"] == review["case_id"], "draft and review disagree on the case")
    check(draft["source_review_digest"] == review_digest, "source review digest mismatch")
    check(
        draft["source_contract_version"] == review["schema_version"],
        "source contract version mismatch",
    )

    for kind, entries in draft["outputs"].items():
        for output in entries:
            label = "{} output".format(kind)
            check(output["origin"] in ORIGINS, "{} has an unknown origin".format(label))
            check(str(output["text"] or "").strip(), "{} has no text".format(label))
            check(
                output["inference_class"] in INFERENCE_CLASSES,
                "{} has an unknown inference class".format(label),
            )
            check(
                output["target_speaker_responsibility"] in RESPONSIBILITY,
                "{} has an unknown responsibility".format(label),
            )
            check(output["evidence_utterance_ids"], "{} cites no evidence".format(label))
            errors.extend(_assignee_errors(output["assignee"], label))
            errors.extend(_due_errors(output["due"], label))
            check(
                output["reviewer_note"] is None or output["reviewer_note_recorded"] is True,
                "{} carries a note it does not admit to".format(label),
            )

    source_notes = sum(
        1 for entry in list(review["candidate_verdicts"]) + list(review["missing_items"])
        if entry.get("note") is not None
    )
    draft_notes = sum(
        1 for entries in list(draft["outputs"].values()) + [draft["excluded_candidates"]]
        for entry in entries if entry["reviewer_note"] is not None
    )
    check(draft_notes == source_notes, "reviewer notes lost: {} of {}".format(draft_notes, source_notes))

    source_outputs = sum(
        1 for entry in review["candidate_verdicts"] if entry["verdict"] != "exclude"
    ) + len(review["missing_items"])
    check(
        sum(len(entries) for entries in draft["outputs"].values()) == source_outputs,
        "output count does not match the review",
    )
    check(
        len(draft["excluded_candidates"])
        == sum(1 for entry in review["candidate_verdicts"] if entry["verdict"] == "exclude"),
        "excluded candidate count does not match the review",
    )
    for excluded in draft["excluded_candidates"]:
        check(excluded["exclude_reason"], "an excluded candidate lost its reason")

    errors.extend(_ambiguity_errors(draft["ambiguities"], review["ambiguities"]))
    errors.extend(_prior_errors(draft["prior_transition"], prior_transition_of(review) or {}))

    check(
        len(draft["forbidden_inferences"]) == len(review["forbidden_inference"]["items"]),
        "forbidden inferences lost",
    )
    check(
        draft["review_provenance"]["unresolved_count"] == 0,
        "a draft may not be built from an unresolved review",
    )
    return errors


def _assignee_errors(assignee, label):
    errors = []
    if assignee["scope"] is not None and assignee["scope_recorded"] is not True:
        errors.append("{} claims a scope the review never recorded".format(label))
    if assignee["scope_recorded"] is False and assignee["scope"] is not None:
        errors.append("{} filled in an unrecorded scope".format(label))
    basis = assignee["normalized_basis"]
    if basis is not None:
        if basis not in PROMOTABLE_BASIS:
            errors.append(
                "{} promoted a basis that is not its own source field: {}".format(label, basis)
            )
        elif basis != assignee["source_status"]:
            errors.append("{} normalized basis does not match the source status".format(label))
    if assignee["normalization_status"] not in NORMALIZATION_STATUSES:
        errors.append("{} has an unknown normalization status".format(label))
    if assignee["source_status"] and assignee["source_status"] not in PROMOTABLE_BASIS:
        if assignee["normalization_status"] != NORMALIZATION_PENDING:
            errors.append("{} left an unpromotable basis marked complete".format(label))
    return errors


def _due_errors(due, label):
    errors = []
    if due["source_status"] is not None and due["normalized_status"] is None:
        errors.append("{} due status has no canonical mapping".format(label))
    if due["normalized_absolute_date"] is not None and not due["normalized_absolute_date_recorded"]:
        errors.append("{} invented a normalized due date".format(label))
    return errors


def _ambiguity_errors(drafted, source):
    errors = []
    if len(drafted) != len(source):
        errors.append("ambiguities lost: {} of {}".format(len(drafted), len(source)))
        return errors
    for position, (item, origin) in enumerate(zip(drafted, source), start=1):
        label = "ambiguity {}".format(position)
        for field, key in (("raw_kind", "kind"), ("about", "about"),
                           ("statement", "statement"), ("resolution", "resolution")):
            if item.get(field) != origin.get(key):
                errors.append("{} lost its {}".format(label, field))
        if item["evidence_utterance_ids"] != list(origin.get("evidence_utterance_ids") or []):
            errors.append("{} lost its evidence".format(label))
    return errors


def _prior_errors(drafted, source):
    errors = []
    if drafted["status"] != source.get("status"):
        errors.append("prior transition status was rewritten")
    if drafted["scorer_eligible"] is not (source.get("status") in SCORER_ELIGIBLE_PRIOR_STATUS):
        errors.append("prior transition scorer eligibility does not follow the status")
    for field in PRIOR_FIELDS:
        entry = drafted[field]
        present = field in source
        if entry["recorded"] is not present:
            errors.append("prior {} misreports whether the review recorded it".format(field))
        if not present and entry["value"] is not None:
            errors.append("prior {} was filled in for a review that never had it".format(field))
        if present and entry["value"] != source[field]:
            errors.append("prior {} was rewritten".format(field))
    return errors
