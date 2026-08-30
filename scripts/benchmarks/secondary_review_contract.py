#!/usr/bin/env python3
"""Storage contract for the blind second pass over the development set.

The second pass is not a check of the first one. It is a fresh judgment made without the
first one in view, so the two can be compared afterwards and their disagreements found.
That only works if the blind is real, which is why the reviewer's own file starts empty and
why every path holding a primary result is unreachable from this side of the wall.

One thing is recorded here that the primary contract could not hold: an action item's
assignee `scope` and `basis` as separate answers to separate questions. The primary pass had
no field for scope at all and its basis kinds ended up inside free text, which is why
eighteen of its assignee records are still pending. That count is deliberately not shown to
this reviewer — telling them which items the first pass left open would leak its structure.

This is a single-human separated blind pass, not inter-rater agreement, and the contract
says so in the file rather than leaving it to a report.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from primary_review_contract import (  # noqa: E402  (import path is set above)
    CATEGORIES,
    CATEGORY_TITLE_KEY,
    EXCLUDE_REASONS,
    FLAG_BASIS,
    FLAG_VERDICTS,
    FORBIDDEN_BASIS,
    INFERENCE_CLASSES,
    OBJECT_IDENTITY_DECISIONS,
    PRIOR_REFERENCE_KINDS,
    PRIOR_STATE_STATUS,
    RESPONSIBILITY,
    REVIEW_STATUSES,
    TRANSITION_KINDS,
    VERDICTS,
    candidate_key,
    flag_key,
)

SCHEMA_VERSION = "haena-meeting-execution-secondary-review-v0.1"
REVIEW_DIRECTORY = "human-reviews/secondary"
PACKET_DIRECTORY = "human-reviews/secondary/packets"
REVIEWER_KIND = "human_user"
REVIEW_MODE = "single_human_separated_blind_pass"
REVIEWER_ID_PATTERN = re.compile(r"^secondary_reviewer_\d{2}$")
LIMITATIONS = (
    "same_human_as_primary",
    "memory_contamination_possible",
    "repository_level_blinding_enforced",
)

# Scope and basis are separate questions on purpose. "An organization committed" and "a
# named person committed" are different findings, and neither can be read off a value string.
ASSIGNEE_SCOPES = ("individual", "organization", "unspecified")
ASSIGNEE_BASES = ("speaker_commitment", "supported_by_utterance", "absent_must_stay_empty")
DUE_STATUSES = ("explicit", "explicit_relative", "absent", "unresolved")

DECISION_KEYS = frozenset({
    "candidate_verdicts", "review_flag_verdicts", "missing_items", "no_missing",
    "forbidden_inference", "prior_transition", "ambiguities", "transcript_coverage",
    "explicit_user_confirmation", "review_status", "reviewed_at",
})
VERDICT_KEYS = frozenset({
    "verdict", "final_text", "evidence_status", "evidence_utterance_ids",
    "target_speaker_b_responsibility", "inference_class", "assignee", "due",
    "exclude_reason", "exclude_evidence_utterance_ids", "note",
})
FLAG_DECISION_KEYS = frozenset({
    "verdict", "basis", "reason", "evidence_utterance_ids", "wrong_boundary", "correction",
})
AMBIGUITY_KEYS = frozenset({"about", "statement", "kind", "evidence_utterance_ids", "resolution"})
PRIOR_TRANSITION_KEYS = frozenset({
    "status", "prior_reference", "object_identity", "transition_kind", "from_state",
    "to_state", "evidence_utterance_ids", "reason",
})


class SecondaryReviewError(RuntimeError):
    """A decision the contract cannot record exactly as stated."""


def _require(condition, message):
    if not condition:
        raise SecondaryReviewError(message)


def _check_ids(values, known, label):
    _require(isinstance(values, list) and values, "{} needs at least one utterance ID".format(label))
    unknown = [value for value in values if value not in known]
    _require(not unknown, "{} names utterances the case does not contain: {}".format(label, unknown))


def build_template(case, draft, packet_sha256, case_sha256, reviewer_id):
    """An empty second-pass review. Nothing from the first pass reaches this file."""
    _require(
        REVIEWER_ID_PATTERN.match(reviewer_id or ""),
        "reviewer id must be an opaque local identifier like secondary_reviewer_01",
    )
    suggestion = draft["suggestion"]
    verdicts = []
    for category in CATEGORIES:
        for position, item in enumerate(suggestion.get(category, []), start=1):
            verdicts.append({
                "candidate_key": candidate_key(category, position),
                "category": category,
                "ai_candidate_text": item.get(CATEGORY_TITLE_KEY[category]),
                "ai_evidence_utterance_id": (item.get("evidence") or {}).get("utterance_id"),
                "ai_assignee_speaker": item.get("assignee_speaker"),
                "ai_due": item.get("due_date") or item.get("due_text"),
                "verdict": None,
                "final_text": None,
                "evidence_status": None,
                "evidence_utterance_ids": None,
                "target_speaker_b_responsibility": None,
                "inference_class": None,
                "assignee": None,
                "due": None,
                "exclude_reason": None,
                "exclude_evidence_utterance_ids": None,
                "note": None,
            })
    flags = [
        {
            "flag_key": flag_key(position),
            "ai_kind": flag.get("kind"),
            "ai_category": flag.get("category"),
            "ai_claim": flag.get("claim"),
            "ai_reason": flag.get("reason"),
            "ai_related_utterance_id": flag.get("related_utterance_id"),
            "verdict": None, "basis": None, "reason": None,
            "evidence_utterance_ids": None, "wrong_boundary": None, "correction": None,
        }
        for position, flag in enumerate(suggestion.get("review_flags", []), start=1)
    ]
    return {
        "schema_version": SCHEMA_VERSION,
        "case_id": case["case_id"],
        "review_focus": case.get("review_focus"),
        "packet_sha256": packet_sha256,
        "case_sha256": case_sha256,
        "review_status": "in_progress",
        "reviewer_kind": REVIEWER_KIND,
        "provenance": {
            "review_mode": REVIEW_MODE,
            "reviewer_id": reviewer_id,
            "inter_rater_agreement_claim_allowed": False,
            "limitations": list(LIMITATIONS),
            "primary_reads": 0,
            "gold_draft_reads": 0,
            "primary_audit_reads": 0,
            "notion_reads": 0,
            "network_calls": 0,
        },
        "candidate_verdicts": verdicts,
        "review_flag_verdicts": flags,
        "missing_items": [],
        "no_missing": {category: None for category in CATEGORIES},
        "forbidden_inference": {"checked": None, "items": []},
        "prior_transition": None,
        "ambiguities": [],
        "transcript_coverage": {
            "full_window_reviewed": None, "statement": None,
            "first_utterance_id": None, "last_utterance_id": None, "utterance_count": None,
        },
        "explicit_user_confirmation": None,
        "reviewed_at": None,
    }


def utterance_ids(case):
    return [row["utterance_id"] for row in case.get("transcript", [])]


def check_assignee(assignee, known, label):
    """Scope and basis are answered separately and never read off a value string."""
    _require(isinstance(assignee, dict), "{} assignee must be an object".format(label))
    unknown = sorted(set(assignee) - {"scope", "basis", "value", "evidence_utterance_ids"})
    _require(not unknown, "{} assignee carries unknown fields: {}".format(label, unknown))
    _require(
        assignee.get("scope") in ASSIGNEE_SCOPES,
        "{} assignee scope must be one of {}".format(label, ASSIGNEE_SCOPES),
    )
    _require(
        assignee.get("basis") in ASSIGNEE_BASES,
        "{} assignee basis must be one of {}".format(label, ASSIGNEE_BASES),
    )
    if assignee["basis"] == "absent_must_stay_empty":
        _require(
            assignee.get("value") in (None, "") and not assignee.get("evidence_utterance_ids"),
            "{} assignee claims no basis but carries a value or evidence".format(label),
        )
        _require(
            assignee["scope"] == "unspecified",
            "{} assignee with no basis cannot have a scope".format(label),
        )
        return
    _require(
        str(assignee.get("value") or "").strip(),
        "{} assignee needs the value its basis supports".format(label),
    )
    _check_ids(assignee.get("evidence_utterance_ids"), known, "{} assignee evidence".format(label))


def check_due(due, known, label):
    _require(isinstance(due, dict), "{} due must be an object".format(label))
    unknown = sorted(set(due) - {"status", "value", "evidence_utterance_ids"})
    _require(not unknown, "{} due carries unknown fields: {}".format(label, unknown))
    _require(
        due.get("status") in DUE_STATUSES,
        "{} due status must be one of {}".format(label, DUE_STATUSES),
    )
    if due["status"] == "absent":
        _require(
            due.get("value") in (None, "") and not due.get("evidence_utterance_ids"),
            "{} due is absent but carries a value or evidence".format(label),
        )
        return
    if due["status"] == "unresolved":
        _require(
            str(due.get("value") or "").strip(),
            "{} unresolved due needs what could not be resolved".format(label),
        )
        return
    _require(str(due.get("value") or "").strip(), "{} due needs its value".format(label))
    _check_ids(due.get("evidence_utterance_ids"), known, "{} due evidence".format(label))


def apply_verdict(entry, decision, case):
    key = entry["candidate_key"]
    unknown = sorted(set(decision) - VERDICT_KEYS)
    _require(not unknown, "{} carries fields outside the contract: {}".format(key, unknown))
    known = utterance_ids(case)

    verdict = decision.get("verdict")
    _require(verdict in VERDICTS, "{} verdict must be one of {}".format(key, VERDICTS))
    _require(
        decision.get("target_speaker_b_responsibility") in RESPONSIBILITY,
        "{} needs a target speaker B responsibility judgment".format(key),
    )
    _require(
        decision.get("inference_class") in INFERENCE_CLASSES,
        "{} needs an inference class from {}".format(key, INFERENCE_CLASSES),
    )
    if verdict == "modify_and_approve":
        _require(str(decision.get("final_text") or "").strip(), "{} modify needs the corrected text".format(key))
    else:
        _require(decision.get("final_text") in (None, ""), "{} carries corrected text".format(key))
    if verdict == "exclude":
        _require(
            decision.get("exclude_reason") in EXCLUDE_REASONS,
            "{} exclude needs a reason from {}".format(key, EXCLUDE_REASONS),
        )
        _require(
            decision.get("evidence_status") is None and not decision.get("evidence_utterance_ids"),
            "{} is excluded, so it carries no approved evidence".format(key),
        )
        if decision.get("exclude_evidence_utterance_ids"):
            _check_ids(decision["exclude_evidence_utterance_ids"], known,
                       "{} exclusion grounds".format(key))
        _require(
            decision.get("assignee") is None and decision.get("due") is None,
            "{} is excluded and carries no assignee or due".format(key),
        )
    else:
        _require(decision.get("exclude_reason") is None, "{} carries an exclude reason".format(key))
        _require(
            not decision.get("exclude_evidence_utterance_ids"),
            "{} carries exclusion grounds without an exclude verdict".format(key),
        )
        status = decision.get("evidence_status")
        _require(
            status in ("ai_evidence_approved", "replaced"),
            "{} needs an explicit evidence decision".format(key),
        )
        if status == "ai_evidence_approved":
            ai_evidence = entry.get("ai_evidence_utterance_id")
            _require(ai_evidence, "{} has no AI evidence to approve".format(key))
            decision = dict(decision, evidence_utterance_ids=[ai_evidence])
        _check_ids(decision.get("evidence_utterance_ids"), known, "{} evidence".format(key))
        if entry["category"] == "action_items":
            check_assignee(decision.get("assignee"), known, key)
            check_due(decision.get("due"), known, key)
        else:
            _require(
                decision.get("assignee") is None and decision.get("due") is None,
                "{} carries an assignee or due it cannot have".format(key),
            )

    updated = dict(entry)
    for field in VERDICT_KEYS:
        if field in decision:
            updated[field] = decision[field]
    return updated


def apply_flag_verdict(entry, decision, case, coverage):
    key = entry["flag_key"]
    unknown = sorted(set(decision) - FLAG_DECISION_KEYS)
    _require(not unknown, "{} carries fields outside the contract: {}".format(key, unknown))
    known = utterance_ids(case)
    verdict = decision.get("verdict")
    _require(verdict in FLAG_VERDICTS, "{} verdict must be one of {}".format(key, FLAG_VERDICTS))
    _require(str(decision.get("reason") or "").strip(), "{} needs the reviewer's reason".format(key))
    if verdict == "agree":
        basis = decision.get("basis")
        _require(basis in FLAG_BASIS, "{} needs a basis from {}".format(key, FLAG_BASIS))
        if basis == "utterance":
            _check_ids(decision.get("evidence_utterance_ids"), known, "{} evidence".format(key))
        else:
            _require(
                not decision.get("evidence_utterance_ids"),
                "{} rests on {} but cites utterances".format(key, basis),
            )
            if basis == "absence_in_window":
                _require(
                    covers_whole_window(coverage, known),
                    "{} claims absence without a confirmed review of this exact window".format(key),
                )
    else:
        _require(str(decision.get("wrong_boundary") or "").strip(),
                 "{} rejects the flag and must name the boundary it got wrong".format(key))
        _require(str(decision.get("correction") or "").strip(),
                 "{} rejects the flag and must record the correction".format(key))
        if decision.get("evidence_utterance_ids"):
            _check_ids(decision["evidence_utterance_ids"], known, "{} evidence".format(key))
    updated = dict(entry)
    for field in FLAG_DECISION_KEYS:
        if field in decision:
            updated[field] = decision[field]
    return updated


def covers_whole_window(coverage, known):
    if not isinstance(coverage, dict) or coverage.get("full_window_reviewed") is not True:
        return False
    return (
        coverage.get("first_utterance_id") == (known[0] if known else None)
        and coverage.get("last_utterance_id") == (known[-1] if known else None)
        and coverage.get("utterance_count") == len(known)
    )


def apply_missing_items(items, case):
    known = utterance_ids(case)
    applied = []
    for position, item in enumerate(items, start=1):
        label = "missing item {}".format(position)
        _require(item.get("category") in CATEGORIES, "{} needs a category".format(label))
        _require(str(item.get("text") or "").strip(), "{} needs the reviewer's text".format(label))
        _check_ids(item.get("evidence_utterance_ids"), known, "{} evidence".format(label))
        _require(
            item.get("target_speaker_b_responsibility") in RESPONSIBILITY,
            "{} needs a target speaker B responsibility judgment".format(label),
        )
        _require(
            item.get("inference_class") in INFERENCE_CLASSES,
            "{} needs an inference class".format(label),
        )
        entry = {
            "category": item["category"],
            "text": item["text"],
            "evidence_utterance_ids": item["evidence_utterance_ids"],
            "target_speaker_b_responsibility": item["target_speaker_b_responsibility"],
            "inference_class": item["inference_class"],
            "assignee": item.get("assignee"),
            "due": item.get("due"),
            "note": item.get("note"),
        }
        if item["category"] == "action_items":
            check_assignee(entry["assignee"], known, label)
            check_due(entry["due"], known, label)
        else:
            _require(
                entry["assignee"] is None and entry["due"] is None,
                "{} carries an assignee or due it cannot have".format(label),
            )
        applied.append(entry)
    return applied


def normalized_prior_transition(block, known):
    _require(isinstance(block, dict), "prior_transition must be an object")
    unknown = sorted(set(block) - PRIOR_TRANSITION_KEYS)
    _require(not unknown, "prior_transition carries unknown fields: {}".format(unknown))
    status = block.get("status")
    _require(status in PRIOR_STATE_STATUS, "prior status must be one of {}".format(PRIOR_STATE_STATUS))
    reference = block.get("prior_reference") or {}
    identity = block.get("object_identity") or {}
    kind = reference.get("kind")
    decision = identity.get("decision")
    transition = block.get("transition_kind")
    evidence = block.get("evidence_utterance_ids") or []
    _require(str(block.get("reason") or "").strip(), "prior_transition needs the reviewer's reason")
    _require(
        transition is None or transition in TRANSITION_KINDS,
        "transition_kind must be one of {} or null".format(TRANSITION_KINDS),
    )
    _require(
        decision is None or decision in OBJECT_IDENTITY_DECISIONS,
        "object identity decision must be one of {}".format(OBJECT_IDENTITY_DECISIONS),
    )
    _require(
        kind is None or kind in PRIOR_REFERENCE_KINDS,
        "prior reference kind must be one of {}".format(PRIOR_REFERENCE_KINDS),
    )
    if status == "expected":
        _require(kind == "typed_case", "an expected transition needs a typed prior case")
        _require(str(reference.get("prior_case_id") or "").strip(),
                 "an expected transition needs the prior case it points at")
        _require(decision not in (None, "undecidable"),
                 "an expected transition needs the object identity decided")
        _require(transition is not None, "an expected transition needs a transition kind")
        _require(str(block.get("to_state") or "").strip(), "an expected transition needs to_state")
        if transition == "new":
            _require(block.get("from_state") in (None, ""), "a new object has no previous state")
        else:
            _require(str(block.get("from_state") or "").strip(),
                     "an expected transition needs from_state unless the object is new")
        _check_ids(evidence, known, "prior transition evidence")
    elif status == "insufficient_prior_state":
        _require(kind == "corpus_source_only",
                 "insufficient_prior_state is for a corpus source with no typed case")
        _require(str(reference.get("prior_source_id") or "").strip(),
                 "insufficient_prior_state needs the corpus source it found")
        _require(reference.get("prior_case_id") is None,
                 "a corpus source without a typed case cannot name a prior case")
        _require(decision == "undecidable",
                 "object identity cannot be decided against a prior object that was never built")
        _require(transition is None, "a transition cannot be chosen without a prior object")
        _require(block.get("from_state") in (None, ""), "there is no prior state to record")
    else:
        _require(kind in (None, "absent"), "not_applicable cannot point at a prior reference")
        _require(transition is None, "not_applicable records no transition")
        _require(block.get("from_state") in (None, ""), "not_applicable records no previous state")
        _require(block.get("to_state") in (None, ""), "not_applicable records no resulting state")
        _require(not evidence, "not_applicable cites no transition evidence")
    return {
        "status": status,
        "prior_reference": {
            "kind": kind,
            "prior_case_id": reference.get("prior_case_id"),
            "prior_source_id": reference.get("prior_source_id"),
        },
        "object_identity": {"decision": decision, "reason": identity.get("reason")},
        "transition_kind": transition,
        "from_state": block.get("from_state"),
        "to_state": block.get("to_state"),
        "evidence_utterance_ids": evidence,
        "reason": block["reason"],
    }


def apply_decisions(review, decisions, case):
    import json as _json

    unknown = sorted(set(decisions) - DECISION_KEYS)
    _require(not unknown, "decision document carries unknown fields: {}".format(unknown))
    updated = _json.loads(_json.dumps(review))
    known = utterance_ids(case)

    for key, decision in (decisions.get("candidate_verdicts") or {}).items():
        entries = [item for item in updated["candidate_verdicts"] if item["candidate_key"] == key]
        _require(entries, "{} is not a candidate in this case".format(key))
        index = updated["candidate_verdicts"].index(entries[0])
        updated["candidate_verdicts"][index] = apply_verdict(entries[0], decision, case)

    if "missing_items" in decisions:
        updated["missing_items"] = apply_missing_items(decisions["missing_items"], case)

    for category, value in (decisions.get("no_missing") or {}).items():
        _require(category in CATEGORIES, "{} is not a result category".format(category))
        _require(isinstance(value, bool), "no_missing[{}] must be stated".format(category))
        updated["no_missing"][category] = value

    if "transcript_coverage" in decisions:
        block = decisions["transcript_coverage"]
        _require(isinstance(block, dict), "transcript_coverage must be an object")
        _require(block.get("full_window_reviewed") is True,
                 "transcript coverage must confirm the whole window was read")
        _require(str(block.get("statement") or "").strip(),
                 "transcript coverage must quote what the reviewer said")
        _require(known, "transcript coverage needs a transcript")
        updated["transcript_coverage"] = {
            "full_window_reviewed": True,
            "statement": block["statement"],
            "first_utterance_id": known[0],
            "last_utterance_id": known[-1],
            "utterance_count": len(known),
        }

    for key, decision in (decisions.get("review_flag_verdicts") or {}).items():
        entries = [item for item in updated["review_flag_verdicts"] if item["flag_key"] == key]
        _require(entries, "{} is not an AI flag in this case".format(key))
        index = updated["review_flag_verdicts"].index(entries[0])
        updated["review_flag_verdicts"][index] = apply_flag_verdict(
            entries[0], decision, case, updated.get("transcript_coverage")
        )

    if "forbidden_inference" in decisions:
        block = decisions["forbidden_inference"]
        _require(isinstance(block, dict), "forbidden_inference must be an object")
        _require(block.get("checked") is True, "forbidden inference must be explicitly checked")
        items = block.get("items") or []
        for position, item in enumerate(items, start=1):
            label = "forbidden inference {}".format(position)
            _require(str(item.get("claim") or "").strip(), "{} needs the claim it rejects".format(label))
            _require(str(item.get("reason") or "").strip(), "{} needs the reviewer's reason".format(label))
            _require(item.get("basis") in FORBIDDEN_BASIS,
                     "{} needs a basis from {}".format(label, FORBIDDEN_BASIS))
            if item["basis"] == "utterance":
                _check_ids(item.get("evidence_utterance_ids"), known, "{} evidence".format(label))
            else:
                _require(not item.get("evidence_utterance_ids"),
                         "{} rests on {} but cites utterances".format(label, item["basis"]))
                if item["basis"] == "absence_in_window":
                    _require(
                        covers_whole_window(updated.get("transcript_coverage"), known),
                        "{} claims absence without a confirmed full-window review".format(label),
                    )
        updated["forbidden_inference"] = {"checked": True, "items": items}

    if "prior_transition" in decisions:
        updated["prior_transition"] = normalized_prior_transition(decisions["prior_transition"], known)

    if "ambiguities" in decisions:
        items = decisions["ambiguities"] or []
        for position, item in enumerate(items, start=1):
            label = "ambiguity {}".format(position)
            unknown_keys = sorted(set(item) - AMBIGUITY_KEYS)
            _require(not unknown_keys, "{} carries unknown fields: {}".format(label, unknown_keys))
            _require(str(item.get("about") or "").strip(), "{} needs what it is about".format(label))
            _require(str(item.get("statement") or "").strip(), "{} needs the statement".format(label))
            if "kind" in item:
                _require(str(item.get("kind") or "").strip(), "{} kind must not be blank".format(label))
            if item.get("evidence_utterance_ids"):
                _check_ids(item["evidence_utterance_ids"], known, "{} evidence".format(label))
            else:
                _require(
                    covers_whole_window(updated.get("transcript_coverage"), known),
                    "{} cites nothing, so it needs a confirmed full-window review".format(label),
                )
        updated["ambiguities"] = items

    if "explicit_user_confirmation" in decisions:
        block = decisions["explicit_user_confirmation"]
        _require(isinstance(block, dict), "explicit_user_confirmation must be an object")
        _require(block.get("confirmed") is True, "confirmation must be an explicit yes")
        _require(str(block.get("statement") or "").strip(),
                 "confirmation must quote what the reviewer said")
        updated["explicit_user_confirmation"] = block

    if "reviewed_at" in decisions:
        updated["reviewed_at"] = decisions["reviewed_at"]

    if "review_status" in decisions:
        status = decisions["review_status"]
        _require(status in REVIEW_STATUSES, "review_status must be one of {}".format(REVIEW_STATUSES))
        if status == "complete":
            unresolved = unresolved_fields(updated)
            _require(not unresolved, "review cannot be complete while unresolved: {}".format(unresolved))
        updated["review_status"] = status
    return updated


def unresolved_fields(review):
    unresolved = []
    for entry in review.get("candidate_verdicts", []):
        if entry.get("verdict") not in VERDICTS:
            unresolved.append("{}.verdict".format(entry["candidate_key"]))
    for entry in review.get("review_flag_verdicts", []):
        if entry.get("verdict") not in FLAG_VERDICTS:
            unresolved.append("{}.verdict".format(entry["flag_key"]))
    stated = {item.get("category") for item in review.get("missing_items", [])}
    for category in CATEGORIES:
        value = (review.get("no_missing") or {}).get(category)
        if value is True or (value is False and category in stated):
            continue
        unresolved.append("no_missing.{}".format(category))
    if (review.get("forbidden_inference") or {}).get("checked") is not True:
        unresolved.append("forbidden_inference.checked")
    if not isinstance(review.get("prior_transition"), dict):
        unresolved.append("prior_transition")
    if (review.get("transcript_coverage") or {}).get("full_window_reviewed") is not True:
        unresolved.append("transcript_coverage")
    confirmation = review.get("explicit_user_confirmation")
    if not (isinstance(confirmation, dict) and confirmation.get("confirmed") is True):
        unresolved.append("explicit_user_confirmation")
    if not review.get("reviewed_at"):
        unresolved.append("reviewed_at")
    return unresolved
