#!/usr/bin/env python3
"""The storage contract for primary human review of a development case.

A review file records what a person decided. It is not a place for the model's opinion to
sit until someone disagrees with it, so no field is ever seeded from the AI suggestion: a
candidate the reviewer has not ruled on is `null`, not `approve`. The distinction matters
because the file is the input to semantic gold, and a default that survives review becomes
a label nobody chose.

The AI candidate text is copied in for traceability only, under `ai_`-prefixed keys that no
completion rule reads. `approve` means the reviewer accepted that text; the reviewer's own
words live in `final_text` and appear only when they wrote them.

Everything here is pure: building a template, applying a decision, and judging completeness
are functions over dictionaries. The CLI in `manage_primary_review.py` owns the files.
"""

import hashlib
import json
import re
from pathlib import Path

SCHEMA_VERSION = "haena-meeting-execution-primary-review-v0.1"
REVIEWER_KIND = "human_user"
REVIEW_DIRECTORY = "human-reviews/primary"
CATEGORIES = ("decisions", "action_items", "open_questions", "next_agenda")
CATEGORY_TITLE_KEY = {
    "decisions": "statement",
    "action_items": "title",
    "open_questions": "question",
    "next_agenda": "title",
}
VERDICTS = ("approve", "modify_and_approve", "exclude")
EXCLUDE_REASONS = (
    "not_supported_by_utterance",
    "speculative_inference",
    "not_a_meeting_output",
    # Distinct from `not_a_meeting_output`: this is a real decision, reported here as an
    # existing state rather than reached in this window. Collapsing the two would erase the
    # boundary the benchmark exists to test.
    "historical_state_not_current_meeting_output",
    "wrong_category",
    "duplicate_of_another_candidate",
)
RESPONSIBILITY = ("b_responsible", "other_speaker", "no_responsibility_assigned")
INFERENCE_CLASSES = ("explicit", "derived_proposal", "forbidden_inference")
# `explicit_relative` is for a due date an utterance states in relative terms — "by today" —
# that cannot be resolved without an anchor the case does not carry. It is neither present
# nor absent, and forcing it into either would either invent a date or discard a real one.
BASIS_STATUS = (
    "supported_by_utterance", "absent_must_stay_empty", "corrected", "explicit_relative",
)
PRIOR_STATE_STATUS = ("not_applicable", "expected")
AMBIGUITY_KEYS = frozenset({"about", "statement", "kind", "evidence_utterance_ids", "resolution"})
# `kind` stays free-form through primary review and is normalized to a finite taxonomy (or
# `other`) at TM 2.8. A raw value here is not an input to gold or to the scorer.
FLAG_VERDICTS = ("agree", "reject")
FLAG_DECISION_KEYS = frozenset({
    "verdict", "reason", "evidence_utterance_ids", "wrong_boundary", "correction",
})
# `review_method` covers a prohibition that rests on how review is conducted rather than on
# the recording — "the focus label is a selection stratum, not an answer count". Like an
# absence claim it cites nothing, but it is not a claim about the window, so it does not
# borrow the coverage confirmation that an absence claim requires.
FORBIDDEN_BASIS = ("utterance", "absence_in_window", "review_method")
REVIEW_STATUSES = ("in_progress", "complete")
CANDIDATE_KEY = re.compile(r"(decisions|action_items|open_questions|next_agenda)\[(\d+)\]")

DECISION_KEYS = frozenset({
    "candidate_verdicts", "review_flag_verdicts", "missing_items", "no_missing",
    "forbidden_inference", "prior_state_expectation", "ambiguities",
    "explicit_user_confirmation", "review_status", "reviewed_at", "transcript_coverage",
})
VERDICT_KEYS = frozenset({
    "verdict", "final_text", "evidence_status", "evidence_utterance_ids",
    "target_speaker_b_responsibility", "inference_class", "assignee_basis", "due_basis",
    "exclude_reason", "exclude_evidence_utterance_ids", "note",
})


class ReviewContractError(RuntimeError):
    """A decision that cannot be recorded as stated, rather than recorded approximately."""


def sha256_of(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def candidate_key(category, position):
    return "{}[{}]".format(category, position)


def build_template(case, draft, packet_sha256, case_sha256):
    """An empty review: every human field null, every AI field labelled as AI."""
    suggestion = draft["suggestion"]
    verdicts = []
    for category in CATEGORIES:
        for position, item in enumerate(suggestion.get(category, []), start=1):
            verdicts.append({
                "candidate_key": candidate_key(category, position),
                "category": category,
                # ai_* fields are traceability only. No completion rule reads them, and no
                # human field is ever seeded from them.
                "ai_candidate_text": item.get(CATEGORY_TITLE_KEY[category]),
                "ai_evidence_utterance_id": (item.get("evidence") or {}).get("utterance_id"),
                "ai_assignee_speaker": item.get("assignee_speaker"),
                "ai_assignee_basis": item.get("assignee_basis"),
                "ai_due": item.get("due_date") or item.get("due_text"),
                "verdict": None,
                "final_text": None,
                "evidence_status": None,
                "evidence_utterance_ids": None,
                "target_speaker_b_responsibility": None,
                "inference_class": None,
                "assignee_basis": None,
                "due_basis": None,
                "exclude_reason": None,
                "exclude_evidence_utterance_ids": None,
                "note": None,
            })
    return {
        "schema_version": SCHEMA_VERSION,
        "case_id": case["case_id"],
        "review_focus": case.get("review_focus"),
        "packet_sha256": packet_sha256,
        "case_sha256": case_sha256,
        "review_status": "in_progress",
        "reviewer_kind": REVIEWER_KIND,
        "candidate_verdicts": verdicts,
        "review_flag_verdicts": build_flag_entries(draft),
        "missing_items": [],
        "no_missing": {category: None for category in CATEGORIES},
        "forbidden_inference": {"checked": None, "items": []},
        "prior_state_expectation": None,
        "ambiguities": [],
        "transcript_coverage": {
            "full_window_reviewed": None,
            "statement": None,
            "first_utterance_id": None,
            "last_utterance_id": None,
            "utterance_count": None,
        },
        "explicit_user_confirmation": None,
        "reviewed_at": None,
    }


def flag_key(position):
    return "review_flags[{}]".format(position)


def build_flag_entries(draft):
    """One unjudged entry per AI flag. An AI flag is a question, not a finding."""
    return [
        {
            "flag_key": flag_key(position),
            "ai_kind": flag.get("kind"),
            "ai_category": flag.get("category"),
            "ai_claim": flag.get("claim"),
            "ai_reason": flag.get("reason"),
            "ai_related_utterance_id": flag.get("related_utterance_id"),
            "verdict": None,
            "reason": None,
            "evidence_utterance_ids": None,
            "wrong_boundary": None,
            "correction": None,
        }
        for position, flag in enumerate(draft["suggestion"].get("review_flags", []), start=1)
    ]


def utterance_ids(case):
    return [row["utterance_id"] for row in case.get("transcript", [])]


def _require(condition, message):
    if not condition:
        raise ReviewContractError(message)


def _check_ids(values, known, label):
    _require(isinstance(values, list) and values, "{} needs at least one utterance ID".format(label))
    unknown = [value for value in values if value not in known]
    _require(not unknown, "{} names utterances the case does not contain: {}".format(label, unknown))


def _check_basis(basis, known, label):
    _require(isinstance(basis, dict), "{} must be an object".format(label))
    _require(basis.get("status") in BASIS_STATUS, "{} status must be one of {}".format(label, BASIS_STATUS))
    if basis["status"] != "explicit_relative":
        _require(
            not basis.get("normalized_absolute_date"),
            "{} carries a normalized date without a relative basis".format(label),
        )
    if basis["status"] == "absent_must_stay_empty":
        _require(not basis.get("utterance_ids"), "{} claims no basis but cites utterances".format(label))
        _require(basis.get("value") in (None, ""), "{} claims no basis but carries a value".format(label))
        return
    _check_ids(basis.get("utterance_ids"), known, label)
    _require(str(basis.get("value") or "").strip(), "{} needs the value it is the basis for".format(label))
    if basis["status"] == "explicit_relative":
        # The key must be present even when it is null: whether the reviewer could anchor the
        # date is itself the finding, and an absent key would read as "not looked at".
        _require(
            "normalized_absolute_date" in basis,
            "{} must state whether the relative date could be normalized".format(label),
        )
        normalized = basis["normalized_absolute_date"]
        _require(
            normalized is None or str(normalized).strip(),
            "{} normalized date must be a date or explicitly null".format(label),
        )


def apply_verdict(entry, decision, case):
    """Apply one candidate decision, or refuse it. Silence is never a verdict."""
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
        _require(
            decision.get("final_text") in (None, ""),
            "{} carries corrected text without a modify verdict".format(key),
        )
    if verdict == "exclude":
        _require(
            decision.get("exclude_reason") in EXCLUDE_REASONS,
            "{} exclude needs a reason from {}".format(key, EXCLUDE_REASONS),
        )
    else:
        _require(decision.get("exclude_reason") is None, "{} carries an exclude reason".format(key))

    if verdict == "exclude":
        _require(
            decision.get("evidence_status") is None and not decision.get("evidence_utterance_ids"),
            "{} is excluded, so it carries no approved evidence".format(key),
        )
        if decision.get("exclude_evidence_utterance_ids"):
            _check_ids(
                decision["exclude_evidence_utterance_ids"], known, "{} exclusion grounds".format(key)
            )
    else:
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

    if entry["category"] == "action_items" and verdict != "exclude":
        _check_basis(decision.get("assignee_basis"), known, "{} assignee basis".format(key))
        _check_basis(decision.get("due_basis"), known, "{} due-date basis".format(key))
    else:
        _require(
            decision.get("assignee_basis") is None and decision.get("due_basis") is None,
            "{} carries an assignee or due basis it cannot have".format(key),
        )

    updated = dict(entry)
    for field in VERDICT_KEYS:
        if field in decision:
            updated[field] = decision[field]
    return updated


def apply_flag_verdict(entry, decision, case):
    """Judge one AI flag, or refuse. Agreeing is a decision, not the absence of one."""
    key = entry["flag_key"]
    unknown = sorted(set(decision) - FLAG_DECISION_KEYS)
    _require(not unknown, "{} carries fields outside the contract: {}".format(key, unknown))
    known = utterance_ids(case)

    verdict = decision.get("verdict")
    _require(verdict in FLAG_VERDICTS, "{} verdict must be one of {}".format(key, FLAG_VERDICTS))
    _require(str(decision.get("reason") or "").strip(), "{} needs the reviewer's reason".format(key))
    if verdict == "agree":
        _check_ids(decision.get("evidence_utterance_ids"), known, "{} evidence".format(key))
        _require(
            not decision.get("wrong_boundary") and not decision.get("correction"),
            "{} agrees with the flag but records a correction".format(key),
        )
    else:
        _require(
            str(decision.get("wrong_boundary") or "").strip(),
            "{} rejects the flag and must name the boundary it got wrong".format(key),
        )
        _require(
            str(decision.get("correction") or "").strip(),
            "{} rejects the flag and must record the correction".format(key),
        )
        if decision.get("evidence_utterance_ids"):
            _check_ids(decision["evidence_utterance_ids"], known, "{} evidence".format(key))

    updated = dict(entry)
    for field in FLAG_DECISION_KEYS:
        if field in decision:
            updated[field] = decision[field]
    return updated


def apply_missing_items(items, case):
    known = utterance_ids(case)
    applied = []
    for position, item in enumerate(items, start=1):
        label = "missing item {}".format(position)
        _require(item.get("category") in CATEGORIES, "{} needs a category from {}".format(label, CATEGORIES))
        _require(str(item.get("text") or "").strip(), "{} needs the reviewer's text".format(label))
        _check_ids(item.get("evidence_utterance_ids"), known, "{} evidence".format(label))
        _require(
            item.get("target_speaker_b_responsibility") in RESPONSIBILITY,
            "{} needs a target speaker B responsibility judgment".format(label),
        )
        _require(
            item.get("inference_class") in INFERENCE_CLASSES,
            "{} needs an inference class from {}".format(label, INFERENCE_CLASSES),
        )
        entry = {
            "category": item["category"],
            "text": item["text"],
            "evidence_utterance_ids": item["evidence_utterance_ids"],
            "target_speaker_b_responsibility": item["target_speaker_b_responsibility"],
            "inference_class": item["inference_class"],
            "assignee_basis": item.get("assignee_basis"),
            "due_basis": item.get("due_basis"),
            "note": item.get("note"),
        }
        if item["category"] == "action_items":
            _check_basis(entry["assignee_basis"], known, "{} assignee basis".format(label))
            _check_basis(entry["due_basis"], known, "{} due-date basis".format(label))
        else:
            _require(
                entry["assignee_basis"] is None and entry["due_basis"] is None,
                "{} carries an assignee or due basis it cannot have".format(label),
            )
        applied.append(entry)
    return applied


def apply_decisions(review, decisions, case):
    """Merge only the fields the reviewer actually spoke to."""
    unknown = sorted(set(decisions) - DECISION_KEYS)
    _require(not unknown, "decision document carries unknown fields: {}".format(unknown))
    updated = json.loads(json.dumps(review))
    known = utterance_ids(case)

    for key, decision in (decisions.get("candidate_verdicts") or {}).items():
        entries = [item for item in updated["candidate_verdicts"] if item["candidate_key"] == key]
        _require(entries, "{} is not a candidate in this case".format(key))
        index = updated["candidate_verdicts"].index(entries[0])
        updated["candidate_verdicts"][index] = apply_verdict(entries[0], decision, case)

    for key, decision in (decisions.get("review_flag_verdicts") or {}).items():
        entries = [item for item in updated.get("review_flag_verdicts", []) if item["flag_key"] == key]
        _require(entries, "{} is not an AI flag in this case".format(key))
        index = updated["review_flag_verdicts"].index(entries[0])
        updated["review_flag_verdicts"][index] = apply_flag_verdict(entries[0], decision, case)

    if "missing_items" in decisions:
        updated["missing_items"] = apply_missing_items(decisions["missing_items"], case)

    for category, value in (decisions.get("no_missing") or {}).items():
        _require(category in CATEGORIES, "{} is not a result category".format(category))
        _require(isinstance(value, bool), "no_missing[{}] must be stated as true or false".format(category))
        updated["no_missing"][category] = value

    if "transcript_coverage" in decisions:
        block = decisions["transcript_coverage"]
        _require(isinstance(block, dict), "transcript_coverage must be an object")
        _require(
            block.get("full_window_reviewed") is True,
            "transcript coverage must be an explicit confirmation that the whole window was read",
        )
        _require(
            str(block.get("statement") or "").strip(),
            "transcript coverage must quote what the reviewer said",
        )
        _require(known, "transcript coverage cannot be confirmed for a case with no transcript")
        # The window is pinned from the case itself, so a later partial review cannot inherit
        # this confirmation: the case digest and these bounds have to agree.
        updated["transcript_coverage"] = {
            "full_window_reviewed": True,
            "statement": block["statement"],
            "first_utterance_id": known[0],
            "last_utterance_id": known[-1],
            "utterance_count": len(known),
        }

    if "forbidden_inference" in decisions:
        block = decisions["forbidden_inference"]
        _require(isinstance(block, dict), "forbidden_inference must be an object")
        _require(block.get("checked") is True, "forbidden inference must be explicitly checked")
        items = block.get("items") or []
        for position, item in enumerate(items, start=1):
            label = "forbidden inference {}".format(position)
            _require(str(item.get("claim") or "").strip(), "{} needs the claim it rejects".format(label))
            _require(str(item.get("reason") or "").strip(), "{} needs the reviewer's reason".format(label))
            # Half of these are about what the window does not contain — "no due date was
            # ever stated" cites nothing by construction. Demanding an utterance ID there
            # would push the reviewer into citing an unrelated line to satisfy the schema.
            _require(
                item.get("basis") in FORBIDDEN_BASIS,
                "{} needs a basis from {}".format(label, FORBIDDEN_BASIS),
            )
            if item["basis"] == "utterance":
                _check_ids(item.get("evidence_utterance_ids"), known, "{} evidence".format(label))
            else:
                _require(
                    not item.get("evidence_utterance_ids"),
                    "{} rests on {} but cites utterances".format(label, item["basis"]),
                )
                if item["basis"] == "absence_in_window":
                    _require(
                        (updated.get("transcript_coverage") or {}).get("full_window_reviewed") is True,
                        "{} claims absence without a confirmed full-window review".format(label),
                    )
        updated["forbidden_inference"] = {"checked": True, "items": items}

    if "prior_state_expectation" in decisions:
        block = decisions["prior_state_expectation"]
        _require(isinstance(block, dict), "prior_state_expectation must be an object")
        _require(
            block.get("status") in PRIOR_STATE_STATUS,
            "prior state status must be one of {}".format(PRIOR_STATE_STATUS),
        )
        if block["status"] == "not_applicable":
            _require(str(block.get("reason") or "").strip(), "not_applicable needs the reviewer's reason")
        else:
            for field in ("target", "from_state", "to_state"):
                _require(str(block.get(field) or "").strip(), "expected transition needs {}".format(field))
            _check_ids(block.get("evidence_utterance_ids"), known, "prior state evidence")
        updated["prior_state_expectation"] = block

    if "ambiguities" in decisions:
        items = decisions["ambiguities"] or []
        for position, item in enumerate(items, start=1):
            label = "ambiguity {}".format(position)
            unknown_keys = sorted(set(item) - AMBIGUITY_KEYS)
            _require(not unknown_keys, "{} carries unknown fields: {}".format(label, unknown_keys))
            _require(str(item.get("about") or "").strip(), "{} needs what it is about".format(label))
            _require(str(item.get("statement") or "").strip(), "{} needs the reviewer's statement".format(label))
            # `kind` is deliberately not an enum. Ambiguity types cannot be listed in advance,
            # and a closed set would push a reviewer into the nearest wrong bucket.
            if "kind" in item:
                _require(str(item.get("kind") or "").strip(), "{} kind must not be blank".format(label))
            if item.get("evidence_utterance_ids"):
                _check_ids(item["evidence_utterance_ids"], known, "{} evidence".format(label))
        updated["ambiguities"] = items

    if "explicit_user_confirmation" in decisions:
        block = decisions["explicit_user_confirmation"]
        _require(isinstance(block, dict), "explicit_user_confirmation must be an object")
        _require(block.get("confirmed") is True, "confirmation must be an explicit yes")
        _require(str(block.get("statement") or "").strip(), "confirmation must quote what the reviewer said")
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
    """Everything a completion claim would be hiding."""
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
        if value is True:
            continue
        if value is False and category in stated:
            continue
        unresolved.append("no_missing.{}".format(category))
    if (review.get("forbidden_inference") or {}).get("checked") is not True:
        unresolved.append("forbidden_inference.checked")
    if not isinstance(review.get("prior_state_expectation"), dict):
        unresolved.append("prior_state_expectation")
    confirmation = review.get("explicit_user_confirmation")
    if not (isinstance(confirmation, dict) and confirmation.get("confirmed") is True):
        unresolved.append("explicit_user_confirmation")
    coverage = review.get("transcript_coverage") or {}
    if coverage.get("full_window_reviewed") is not True:
        unresolved.append("transcript_coverage")
    if not review.get("reviewed_at"):
        unresolved.append("reviewed_at")
    return unresolved
