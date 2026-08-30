#!/usr/bin/env python3
"""Tests for the development gold draft projection.

Run with `python3 -m unittest discover -s scripts/benchmarks -p 'test_*.py'`.

Almost every test here is a refusal. The projection reads three contract versions of
reviewer judgment into one shape, and the dangerous failures are the quiet ones: a scope
filled in because the schema has a slot for it, a v0.1 prior field given a plausible
default, a `null` identity merged with an `undecidable` one, an ambiguity dropped because
its taxonomy is not decided yet, a reviewer's note summarized away.

The real reviews are read but never written, and one test checks exactly that.
"""

import copy
import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import development_gold_draft as draft  # noqa: E402  (import path is set above)

REVIEW_ROOT = Path("data/benchmarks/haena-v0/meeting-execution-v0/human-reviews/primary")


def review_fixture(**overrides):
    """A complete v0.3 review with one of each shape the corpus actually contains."""
    base = {
        "schema_version": "haena-meeting-execution-primary-review-v0.3",
        "case_id": "MEV0-999",
        "review_status": "complete",
        "reviewer_kind": "human_user",
        "candidate_verdicts": [
            {
                "candidate_key": "decisions[1]", "category": "decisions",
                "ai_candidate_text": "원안대로 가결", "verdict": "approve",
                "evidence_status": "replaced", "evidence_utterance_ids": ["U1", "U2"],
                "target_speaker_b_responsibility": "no_responsibility_assigned",
                "inference_class": "explicit", "assignee_basis": None, "due_basis": None,
                "note": "이의 확인 뒤 가결 선포됨",
            },
            {
                "candidate_key": "action_items[1]", "category": "action_items",
                "ai_candidate_text": "자료 제출", "verdict": "modify_and_approve",
                "final_text": "예산 자료를 제출", "evidence_status": "replaced",
                "evidence_utterance_ids": ["U3"],
                "target_speaker_b_responsibility": "b_responsible",
                "inference_class": "explicit",
                "assignee_basis": {
                    "status": "supported_by_utterance", "utterance_ids": ["U3"],
                    "value": "재무국 담당 조직 (speaker_commitment)",
                },
                "due_basis": {
                    "status": "explicit_relative", "utterance_ids": ["U3"],
                    "value": "오늘 중으로", "normalized_absolute_date": None,
                },
                "note": None,
            },
            {
                "candidate_key": "next_agenda[1]", "category": "next_agenda",
                "ai_candidate_text": "다음 안건", "verdict": "exclude",
                "exclude_reason": "not_a_meeting_output",
                "exclude_evidence_utterance_ids": ["U4"],
                "target_speaker_b_responsibility": "no_responsibility_assigned",
                "inference_class": "forbidden_inference",
                "assignee_basis": None, "due_basis": None,
                "note": "같은 회의에서 이미 진행됨",
            },
        ],
        "review_flag_verdicts": [
            {"flag_key": "review_flags[1]", "verdict": "agree", "basis": "utterance",
             "reason": "경계를 정확히 지적함", "evidence_utterance_ids": ["U1"]},
        ],
        "missing_items": [
            {
                "category": "open_questions", "text": "후속 절차를 진행했는가?",
                "evidence_utterance_ids": ["U5"], "inference_class": "explicit",
                "target_speaker_b_responsibility": "no_responsibility_assigned",
                "assignee_basis": None, "due_basis": None, "note": "답변이 나오지 않음",
            },
        ],
        "no_missing": {c: True for c in ("decisions", "action_items", "open_questions", "next_agenda")},
        "forbidden_inference": {"checked": True, "items": [
            {"claim": "상정을 가결로 기록", "reason": "심사 개시임",
             "basis": "utterance", "evidence_utterance_ids": ["U1"]},
        ]},
        "prior_transition": {
            "status": "insufficient_prior_state",
            "prior_reference": {"kind": "corpus_source_only", "prior_case_id": None,
                                "prior_source_id": "SRC-030"},
            "object_identity": {"decision": "undecidable", "reason": "typed object 없음"},
            "transition_kind": None, "from_state": None, "to_state": None,
            "evidence_utterance_ids": ["U1"], "reason": "비교 가능한 prior object 없음",
        },
        "ambiguities": [
            {"kind": "truncated_window_end", "about": "U5",
             "statement": "문장 중간에서 종료", "evidence_utterance_ids": ["U5"],
             "resolution": "이후 결론을 생성하지 않는다"},
            {"kind": "metadata_transcript_mismatch", "about": "metadata vs window",
             "statement": "주제가 전사에 없음", "evidence_utterance_ids": [],
             "resolution": "corpus 오류로 확정하지 않는다"},
        ],
        "transcript_coverage": {"full_window_reviewed": True, "statement": "끝까지 확인"},
        "explicit_user_confirmation": {"confirmed": True, "statement": "확정합니다"},
        "reviewed_at": "2026-08-30T00:00:00+00:00",
    }
    base.update(overrides)
    return base


def legacy_review_fixture():
    """A v0.1 review: the prior block is only `{status, reason}`."""
    review = review_fixture(schema_version="haena-meeting-execution-primary-review-v0.1")
    review.pop("prior_transition")
    review["prior_state_expectation"] = {"status": "not_applicable", "reason": "이전 source 없음"}
    return review


DIGEST = "0" * 64


class GoldDraftProjectionTests(unittest.TestCase):
    def project(self, review=None, digest=DIGEST):
        review = review or review_fixture()
        return draft.project_case(review, digest), review

    def validate(self, projected, review, digest=DIGEST):
        return draft.validate_case(projected, review, digest)

    def test_a_clean_projection_validates(self):
        projected, review = self.project()
        self.assertEqual(self.validate(projected, review), [])
        self.assertEqual(projected["schema_version"], draft.SCHEMA_VERSION)
        self.assertEqual(projected["status"], draft.DRAFT_STATUS)
        self.assertFalse(projected["scorer_ready"])
        self.assertFalse(projected["secondary_review_complete"])

    def test_outputs_carry_their_origin(self):
        projected, _ = self.project()
        origins = {
            output["origin"]
            for entries in projected["outputs"].values() for output in entries
        }
        self.assertEqual(origins, {"approved_candidate", "modified_candidate",
                                   "reviewer_added_missing_item"})
        decision, = projected["outputs"]["decision"]
        self.assertEqual(decision["text"], "원안대로 가결")  # approve keeps the AI wording
        action, = projected["outputs"]["action_item"]
        self.assertEqual(action["text"], "예산 자료를 제출")  # modify keeps the reviewer's

    def test_assignee_keeps_the_raw_value_and_refuses_to_read_it(self):
        projected, _ = self.project()
        assignee = projected["outputs"]["action_item"][0]["assignee"]
        self.assertEqual(assignee["raw_value"], "재무국 담당 조직 (speaker_commitment)")
        self.assertEqual(assignee["source_status"], "supported_by_utterance")
        self.assertEqual(assignee["normalized_basis"], "supported_by_utterance")
        self.assertIsNone(assignee["scope"])  # never derived from the value text
        self.assertFalse(assignee["scope_recorded"])
        self.assertEqual(assignee["normalization_status"], draft.NORMALIZATION_PENDING)

    def test_an_unrecorded_scope_may_not_be_filled_in(self):
        projected, review = self.project()
        projected["outputs"]["action_item"][0]["assignee"]["scope"] = "organization"
        errors = self.validate(projected, review)
        self.assertTrue(any("scope" in e for e in errors), errors)

    def test_a_basis_extracted_from_the_value_string_is_refused(self):
        projected, review = self.project()
        projected["outputs"]["action_item"][0]["assignee"]["normalized_basis"] = "speaker_commitment"
        errors = self.validate(projected, review)
        self.assertTrue(any("not its own source field" in e for e in errors), errors)

    def test_an_absent_assignee_needs_no_second_look(self):
        review = review_fixture()
        review["candidate_verdicts"][1]["assignee_basis"] = {
            "status": "absent_must_stay_empty", "utterance_ids": [], "value": None,
        }
        projected, _ = self.project(review)
        assignee = projected["outputs"]["action_item"][0]["assignee"]
        self.assertEqual(assignee["normalization_status"], draft.NORMALIZATION_COMPLETE)
        self.assertEqual(assignee["normalized_basis"], "absent_must_stay_empty")

    def test_a_relative_due_keeps_its_unresolved_anchor(self):
        projected, _ = self.project()
        due = projected["outputs"]["action_item"][0]["due"]
        self.assertEqual(due["source_status"], "explicit_relative")
        self.assertEqual(due["normalized_status"], "explicit_relative")
        self.assertEqual(due["raw_value"], "오늘 중으로")
        self.assertIsNone(due["normalized_absolute_date"])
        self.assertTrue(due["normalized_absolute_date_recorded"])

    def test_an_invented_absolute_due_date_is_refused(self):
        projected, review = self.project()
        due = projected["outputs"]["action_item"][0]["due"]
        due["normalized_absolute_date"] = "2014-11-14"
        due["normalized_absolute_date_recorded"] = False
        self.assertTrue(any("invented a normalized due date" in e
                            for e in self.validate(projected, review)))

    def test_a_v0_1_prior_block_keeps_its_missing_fields_missing(self):
        review = legacy_review_fixture()
        projected, _ = self.project(review)
        prior = projected["prior_transition"]
        self.assertEqual(prior["status"], "not_applicable")
        self.assertEqual(prior["source_raw"], {"status": "not_applicable", "reason": "이전 source 없음"})
        for field in draft.PRIOR_FIELDS:
            self.assertIsNone(prior[field]["value"], field)
            self.assertFalse(prior[field]["recorded"], field)
        self.assertEqual(prior["normalization_status"], draft.NORMALIZATION_PENDING)
        self.assertEqual(self.validate(projected, review), [])

    def test_filling_in_a_missing_v0_1_prior_field_is_refused(self):
        review = legacy_review_fixture()
        projected, _ = self.project(review)
        projected["prior_transition"]["prior_reference"] = {
            "value": {"kind": "absent"}, "recorded": True,
        }
        errors = self.validate(projected, review)
        self.assertTrue(any("prior_reference" in e for e in errors), errors)

    def test_null_and_undecidable_identities_are_not_merged(self):
        review = review_fixture()
        review["prior_transition"]["object_identity"] = {"decision": None, "reason": None}
        projected, _ = self.project(review)
        self.assertIsNone(projected["prior_transition"]["object_identity"]["value"]["decision"])
        projected["prior_transition"]["object_identity"]["value"]["decision"] = "undecidable"
        self.assertTrue(any("object_identity was rewritten" in e
                            for e in self.validate(projected, review)))

    def test_insufficient_prior_state_is_never_scorer_eligible(self):
        projected, review = self.project()
        self.assertFalse(projected["prior_transition"]["scorer_eligible"])
        projected["prior_transition"]["scorer_eligible"] = True
        self.assertTrue(any("scorer eligibility" in e for e in self.validate(projected, review)))

    def test_not_applicable_is_never_scorer_eligible(self):
        review = legacy_review_fixture()
        projected, _ = self.project(review)
        self.assertFalse(projected["prior_transition"]["scorer_eligible"])

    def test_ambiguities_keep_every_field_the_reviewer_wrote(self):
        projected, review = self.project()
        self.assertEqual(len(projected["ambiguities"]), 2)
        first = projected["ambiguities"][0]
        self.assertIsNone(first["taxonomy"])  # mapping not approved yet
        self.assertEqual(first["raw_kind"], "truncated_window_end")
        self.assertEqual(first["about"], "U5")
        self.assertEqual(first["statement"], "문장 중간에서 종료")
        self.assertEqual(first["resolution"], "이후 결론을 생성하지 않는다")
        self.assertEqual(first["normalization_status"], draft.NORMALIZATION_PENDING)

    def test_a_dropped_ambiguity_is_refused(self):
        projected, review = self.project()
        projected["ambiguities"].pop()
        self.assertTrue(any("ambiguities lost" in e for e in self.validate(projected, review)))

    def test_a_dropped_ambiguity_field_is_refused(self):
        for field in ("about", "statement", "raw_kind", "resolution"):
            projected, review = self.project()
            projected["ambiguities"][0][field] = None
            errors = self.validate(projected, review)
            self.assertTrue(any(field in e for e in errors), (field, errors))

    def test_reviewer_notes_survive_on_outputs_and_exclusions(self):
        projected, review = self.project()
        decision, = projected["outputs"]["decision"]
        self.assertEqual(decision["reviewer_note"], "이의 확인 뒤 가결 선포됨")
        self.assertTrue(decision["reviewer_note_recorded"])
        action, = projected["outputs"]["action_item"]
        self.assertIsNone(action["reviewer_note"])
        self.assertFalse(action["reviewer_note_recorded"])
        excluded, = projected["excluded_candidates"]
        self.assertEqual(excluded["reviewer_note"], "같은 회의에서 이미 진행됨")

    def test_a_dropped_reviewer_note_is_refused(self):
        projected, review = self.project()
        projected["excluded_candidates"][0]["reviewer_note"] = None
        self.assertTrue(any("reviewer notes lost" in e for e in self.validate(projected, review)))

    def test_an_exclusion_keeps_its_reason_and_grounds(self):
        projected, _ = self.project()
        excluded, = projected["excluded_candidates"]
        self.assertEqual(excluded["exclude_reason"], "not_a_meeting_output")
        self.assertEqual(excluded["exclude_evidence_utterance_ids"], ["U4"])
        self.assertEqual(excluded["output_type"], "next_agenda")

    def test_a_scorer_ready_or_final_draft_is_refused(self):
        projected, review = self.project()
        projected["scorer_ready"] = True
        self.assertTrue(any("never scorer-ready" in e for e in self.validate(projected, review)))
        projected["scorer_ready"] = False
        projected["status"] = "final_gold"
        self.assertTrue(any("status must stay" in e for e in self.validate(projected, review)))

    def test_a_secondary_review_cannot_be_claimed(self):
        projected, review = self.project()
        projected["secondary_review_complete"] = True
        self.assertTrue(any("secondary review has not run" in e
                            for e in self.validate(projected, review)))

    def test_a_digest_mismatch_is_refused(self):
        projected, review = self.project()
        self.assertTrue(any("digest mismatch" in e
                            for e in self.validate(projected, review, digest="f" * 64)))

    def test_an_incomplete_review_cannot_be_projected(self):
        review = review_fixture(review_status="in_progress")
        with self.assertRaises(draft.GoldDraftError):
            draft.project_case(review, DIGEST)

    def test_a_review_with_unresolved_fields_cannot_be_projected(self):
        review = review_fixture(unresolved=["no_missing.decisions"])
        with self.assertRaises(draft.GoldDraftError):
            draft.project_case(review, DIGEST)

    def test_a_candidate_without_a_verdict_cannot_be_projected(self):
        review = review_fixture()
        review["candidate_verdicts"][0]["verdict"] = None
        with self.assertRaises(draft.GoldDraftError):
            draft.project_case(review, DIGEST)


@unittest.skipUnless(REVIEW_ROOT.is_dir(), "local corpus is not present")
class RealReviewProjectionTests(unittest.TestCase):
    """Reads the sixteen real reviews. Writes nothing, and proves it."""

    def load(self):
        loaded = {}
        for path in sorted(REVIEW_ROOT.glob("MEV0-*.review.json")):
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            loaded[path.stem.split(".")[0]] = (json.loads(path.read_text(encoding="utf-8")), digest)
        return loaded

    def test_every_completed_review_projects_and_validates(self):
        loaded = self.load()
        self.assertEqual(len(loaded), 16)
        for case_id, (review, digest) in loaded.items():
            projected = draft.project_case(review, digest)
            self.assertEqual(draft.validate_case(projected, review, digest), [], case_id)

    def test_projection_writes_nothing(self):
        before = {p: p.read_bytes() for p in sorted(REVIEW_ROOT.glob("MEV0-*.review.json"))}
        for review, digest in self.load().values():
            draft.project_case(review, digest)
        after = {p: p.read_bytes() for p in sorted(REVIEW_ROOT.glob("MEV0-*.review.json"))}
        self.assertEqual(after, before)

    def test_projection_does_not_mutate_the_review_in_memory(self):
        for review, digest in self.load().values():
            original = copy.deepcopy(review)
            draft.project_case(review, digest)
            self.assertEqual(review, original)

    def test_no_case_is_scorer_eligible_and_every_ambiguity_survives(self):
        eligible = 0
        ambiguities = 0
        notes = 0
        for review, digest in self.load().values():
            projected = draft.project_case(review, digest)
            eligible += int(projected["prior_transition"]["scorer_eligible"])
            ambiguities += len(projected["ambiguities"])
            notes += sum(
                1 for entries in list(projected["outputs"].values())
                + [projected["excluded_candidates"]]
                for entry in entries if entry["reviewer_note"] is not None
            )
        self.assertEqual(eligible, 0)
        self.assertEqual(ambiguities, 68)
        self.assertEqual(notes, 42)


if __name__ == "__main__":
    unittest.main()
