#!/usr/bin/env python3
"""Tests for the primary human review contract.

Run with `python3 -m unittest discover -s scripts/benchmarks -p 'test_*.py'`.

The point of most of these is refusal. A review file is the input to semantic gold, so the
failures worth testing are the ones that would otherwise produce a plausible file: a
candidate that was never ruled on, a completion claim over an unanswered question, an
evidence ID nobody could check, an approval nobody gave.
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import primary_review_contract as contract  # noqa: E402  (import path is set above)
import repair_meeting_execution_partition as repair  # noqa: E402
import test_meeting_execution_partition as fixture  # noqa: E402
import test_meeting_execution_review_packet as packet_fixture  # noqa: E402

MANAGE_SCRIPT = Path(__file__).resolve().parent / "manage_primary_review.py"
PACKET_SCRIPT = packet_fixture.PACKET_SCRIPT


def full_decisions(case_id, statement_key, action_key):
    """A decision document that answers every structural question exactly once."""
    return {
        "case_id": case_id,
        "candidate_verdicts": {
            statement_key: {
                "verdict": "approve",
                "evidence_status": "ai_evidence_approved",
                "target_speaker_b_responsibility": "no_responsibility_assigned",
                "inference_class": "explicit",
            },
            action_key: {
                "verdict": "modify_and_approve",
                "final_text": "예산 자료를 제출한다",
                "evidence_status": "replaced",
                "evidence_utterance_ids": ["U2", "U3"],
                "target_speaker_b_responsibility": "b_responsible",
                "inference_class": "explicit",
                "assignee_basis": {
                    "status": "supported_by_utterance", "utterance_ids": ["U2"], "value": "B",
                },
                "due_basis": {"status": "absent_must_stay_empty", "utterance_ids": [], "value": None},
            },
        },
        "no_missing": {
            "decisions": True, "action_items": True, "open_questions": True, "next_agenda": True,
        },
        "forbidden_inference": {"checked": True, "items": []},
        "prior_state_expectation": {"status": "not_applicable", "reason": "이전 회의 source 없음"},
        "ambiguities": [],
        "transcript_coverage": {"full_window_reviewed": True, "statement": "전체 전사를 끝까지 확인했습니다"},
        "explicit_user_confirmation": {"confirmed": True, "statement": "이 사례 검수를 확정합니다"},
        "reviewed_at": "2026-08-30T00:00:00+00:00",
        "review_status": "complete",
    }


class PrimaryReviewTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        _, self.benchmark_root, self.development, _ = packet_fixture.build_packet_fixture(self.root)
        subprocess.run(
            [sys.executable, str(PACKET_SCRIPT),
             "--benchmark-root", str(self.benchmark_root), "--replace-stale"],
            capture_output=True, text=True, check=True,
        )
        self.case_id = self.development[0]
        self.statement_key = contract.candidate_key("decisions", 1)
        self.action_key = contract.candidate_key("action_items", 1)

    def run_command(self, *args):
        return subprocess.run(
            [sys.executable, str(MANAGE_SCRIPT), "--benchmark-root", str(self.benchmark_root), *args],
            capture_output=True, text=True, check=False,
        )

    def template(self, case_id=None):
        return self.run_command("template", "--case-id", case_id or self.case_id)

    def record(self, decisions, case_id=None):
        path = self.root / "decisions.json"
        path.write_text(json.dumps(decisions, ensure_ascii=False), encoding="utf-8")
        return self.run_command("record", "--case-id", case_id or self.case_id, "--decisions", str(path))

    def review(self, case_id=None):
        path = (
            self.benchmark_root / contract.REVIEW_DIRECTORY
            / "{}.review.json".format(case_id or self.case_id)
        )
        return json.loads(path.read_text(encoding="utf-8"))

    def complete(self):
        self.assertEqual(self.template().returncode, 0)
        return self.record(full_decisions(self.case_id, self.statement_key, self.action_key))

    def test_template_starts_with_no_human_judgment_at_all(self):
        result = self.template()
        self.assertEqual(result.returncode, 0)
        review = self.review()
        self.assertEqual(review["reviewer_kind"], "human_user")
        self.assertEqual(review["review_status"], "in_progress")
        for entry in review["candidate_verdicts"]:
            for field in ("verdict", "final_text", "evidence_status", "inference_class"):
                self.assertIsNone(entry[field], field)
        self.assertEqual(set(review["no_missing"].values()), {None})
        self.assertIsNone(review["explicit_user_confirmation"])
        self.assertIsNone(review["prior_state_expectation"])

    def test_template_carries_ai_text_only_as_labelled_traceability(self):
        self.assertEqual(self.template().returncode, 0)
        entry = self.review()["candidate_verdicts"][0]
        self.assertEqual(entry["ai_candidate_text"], "예산안을 원안대로 의결")
        self.assertIsNone(entry["final_text"])
        self.assertIsNone(entry["verdict"])

    def test_template_never_overwrites_an_existing_review(self):
        self.assertEqual(self.template().returncode, 0)
        before = self.review()
        result = self.template()
        self.assertEqual(result.returncode, 1)
        self.assertIn("never replaces it", result.stderr)
        self.assertEqual(self.review(), before)

    def test_a_sealed_case_is_refused(self):
        sealed = sorted(
            row["case_id"] for row in repair.read_jsonl(self.benchmark_root / "source-index.jsonl")
            if row["split"] == "sealed_holdout"
        )[0]
        result = self.template(sealed)
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not a development case", result.stderr)
        self.assertFalse(
            (self.benchmark_root / contract.REVIEW_DIRECTORY / "{}.review.json".format(sealed)).exists()
        )

    def test_a_packet_change_invalidates_a_review_in_progress(self):
        self.assertEqual(self.template().returncode, 0)
        packet = self.benchmark_root / "DEVELOPMENT_REVIEW.md"
        packet.write_text(packet.read_text(encoding="utf-8") + "\n<!-- edited -->\n", encoding="utf-8")
        result = self.record({"no_missing": {"decisions": True}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("different packet", result.stderr)

    def test_a_case_change_invalidates_a_review_in_progress(self):
        self.assertEqual(self.template().returncode, 0)
        path = self.benchmark_root / repair.CASE_DIRECTORY / "{}.json".format(self.case_id)
        case = json.loads(path.read_text(encoding="utf-8"))
        case["transcript"][0]["text_raw"] += " (수정)"
        fixture.write_json(path, case)
        result = self.record({"no_missing": {"decisions": True}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("case file changed", result.stderr)

    def test_recorder_changes_only_the_fields_the_document_names(self):
        self.assertEqual(self.template().returncode, 0)
        before = self.review()
        self.assertEqual(self.record({"no_missing": {"decisions": True}}).returncode, 0)
        after = self.review()
        self.assertTrue(after["no_missing"]["decisions"])
        self.assertIsNone(after["no_missing"]["action_items"])
        self.assertEqual(after["candidate_verdicts"], before["candidate_verdicts"])
        self.assertIsNone(after["explicit_user_confirmation"])

    def test_a_candidate_with_no_verdict_blocks_completion(self):
        self.assertEqual(self.template().returncode, 0)
        decisions = full_decisions(self.case_id, self.statement_key, self.action_key)
        decisions["candidate_verdicts"].pop(self.action_key)
        result = self.record(decisions)
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot be complete while unresolved", result.stderr)
        self.assertIn("{}.verdict".format(self.action_key), result.stderr)

    def test_an_unanswered_missing_check_blocks_completion(self):
        self.assertEqual(self.template().returncode, 0)
        decisions = full_decisions(self.case_id, self.statement_key, self.action_key)
        decisions["no_missing"].pop("next_agenda")
        result = self.record(decisions)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no_missing.next_agenda", result.stderr)

    def test_no_missing_false_needs_an_actual_missing_item(self):
        self.assertEqual(self.template().returncode, 0)
        decisions = full_decisions(self.case_id, self.statement_key, self.action_key)
        decisions["no_missing"]["open_questions"] = False
        result = self.record(decisions)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no_missing.open_questions", result.stderr)

        decisions["missing_items"] = [{
            "category": "open_questions",
            "text": "유치원 운영위원회 구성 여부",
            "evidence_utterance_ids": ["U3"],
            "target_speaker_b_responsibility": "no_responsibility_assigned",
            "inference_class": "explicit",
        }]
        self.assertEqual(self.record(decisions).returncode, 0)
        self.assertEqual(self.review()["review_status"], "complete")

    def test_completion_needs_the_reviewer_to_say_so(self):
        self.assertEqual(self.template().returncode, 0)
        decisions = full_decisions(self.case_id, self.statement_key, self.action_key)
        decisions.pop("explicit_user_confirmation")
        result = self.record(decisions)
        self.assertEqual(result.returncode, 1)
        self.assertIn("explicit_user_confirmation", result.stderr)

    def test_modify_without_the_corrected_text_is_refused(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"candidate_verdicts": {self.action_key: {
            "verdict": "modify_and_approve",
            "evidence_status": "ai_evidence_approved",
            "target_speaker_b_responsibility": "b_responsible",
            "inference_class": "explicit",
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("modify needs the corrected text", result.stderr)

    def test_exclude_without_a_reason_is_refused(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"candidate_verdicts": {self.statement_key: {
            "verdict": "exclude",
            "target_speaker_b_responsibility": "no_responsibility_assigned",
            "inference_class": "forbidden_inference",
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("exclude needs a reason", result.stderr)

    def test_exclude_with_a_reason_is_recorded(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"candidate_verdicts": {self.statement_key: {
            "verdict": "exclude",
            "exclude_reason": "not_supported_by_utterance",
            "target_speaker_b_responsibility": "no_responsibility_assigned",
            "inference_class": "forbidden_inference",
            "note": "발화에 의결 표현이 없음",
        }}}).returncode, 0)
        entry = self.review()["candidate_verdicts"][0]
        self.assertEqual(entry["verdict"], "exclude")
        self.assertEqual(entry["exclude_reason"], "not_supported_by_utterance")
        self.assertIsNone(entry["evidence_status"])

    def test_evidence_must_exist_in_the_case(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"candidate_verdicts": {self.statement_key: {
            "verdict": "approve",
            "evidence_status": "replaced",
            "evidence_utterance_ids": ["U99"],
            "target_speaker_b_responsibility": "no_responsibility_assigned",
            "inference_class": "explicit",
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("names utterances the case does not contain", result.stderr)

    def test_an_action_item_needs_both_bases(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"candidate_verdicts": {self.action_key: {
            "verdict": "approve",
            "evidence_status": "ai_evidence_approved",
            "target_speaker_b_responsibility": "b_responsible",
            "inference_class": "explicit",
            "assignee_basis": {
                "status": "supported_by_utterance", "utterance_ids": ["U2"], "value": "B",
            },
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("due-date basis", result.stderr)

    def test_a_basis_claiming_no_support_may_not_carry_a_value(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"candidate_verdicts": {self.action_key: {
            "verdict": "approve",
            "evidence_status": "ai_evidence_approved",
            "target_speaker_b_responsibility": "b_responsible",
            "inference_class": "explicit",
            "assignee_basis": {
                "status": "absent_must_stay_empty", "utterance_ids": [], "value": "B",
            },
            "due_basis": {"status": "absent_must_stay_empty", "utterance_ids": [], "value": None},
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("claims no basis but carries a value", result.stderr)

    def test_prior_state_must_be_answered_even_when_not_applicable(self):
        self.assertEqual(self.template().returncode, 0)
        decisions = full_decisions(self.case_id, self.statement_key, self.action_key)
        decisions.pop("prior_state_expectation")
        result = self.record(decisions)
        self.assertEqual(result.returncode, 1)
        self.assertIn("prior_state_expectation", result.stderr)

    def test_an_ambiguity_is_kept_rather_than_hidden(self):
        self.assertEqual(self.template().returncode, 0)
        decisions = full_decisions(self.case_id, self.statement_key, self.action_key)
        decisions["ambiguities"] = [
            {"about": self.action_key, "statement": "담당자가 B인지 부서 전체인지 확정 불가"}
        ]
        self.assertEqual(self.record(decisions).returncode, 0)
        review = self.review()
        self.assertEqual(review["review_status"], "complete")
        self.assertEqual(len(review["ambiguities"]), 1)

    def test_a_completed_review_validates_and_reports_its_verdicts(self):
        self.assertEqual(self.complete().returncode, 0)
        result = self.run_command("validate", "--case-id", self.case_id)
        self.assertEqual(result.returncode, 0)
        report = json.loads(result.stdout)
        self.assertTrue(report["passed"])
        entry, = report["reviews"]
        self.assertEqual(entry["review_status"], "complete")
        self.assertEqual(entry["verdicts"], {"approve": 1, "modify_and_approve": 1, "exclude": 0})
        self.assertEqual(entry["unresolved"], [])
        self.assertTrue(entry["case_file_unchanged"])
        self.assertEqual(report["network_calls"], 0)

    def test_validation_is_read_only_and_repeatable(self):
        self.assertEqual(self.complete().returncode, 0)
        before = fixture.hash_tree(self.benchmark_root)
        first = self.run_command("validate", "--case-id", self.case_id)
        second = self.run_command("validate", "--case-id", self.case_id)
        self.assertEqual(first.stdout, second.stdout)
        self.assertEqual(fixture.hash_tree(self.benchmark_root), before)

    def test_recording_mutates_no_case_and_no_gold(self):
        self.assertEqual(self.template().returncode, 0)
        case_path = self.benchmark_root / repair.CASE_DIRECTORY / "{}.json".format(self.case_id)
        before = case_path.read_bytes()
        packet_before = (self.benchmark_root / "DEVELOPMENT_REVIEW.md").read_bytes()
        self.assertEqual(self.record(full_decisions(
            self.case_id, self.statement_key, self.action_key
        )).returncode, 0)
        self.assertEqual(case_path.read_bytes(), before)
        self.assertEqual((self.benchmark_root / "DEVELOPMENT_REVIEW.md").read_bytes(), packet_before)
        case = json.loads(before.decode("utf-8"))
        self.assertEqual(case["gold"]["status"], "human_review_pending")

    def test_audit_summary_carries_identifiers_and_counts_only(self):
        self.assertEqual(self.complete().returncode, 0)
        output = self.root / "audit.json"
        result = self.run_command("audit", "--case-id", self.case_id, "--output", str(output))
        self.assertEqual(result.returncode, 0)
        summary = json.loads(output.read_text(encoding="utf-8"))
        text = output.read_text(encoding="utf-8")
        self.assertEqual(summary["totals"]["complete"], 1)
        self.assertNotIn("예산 자료를 제출한다", text)  # reviewer text
        self.assertNotIn("예산안을 의결합니다", text)  # transcript
        self.assertNotIn("이 사례 검수를 확정합니다", text)  # confirmation wording
        self.assertNotIn("U2", text)  # utterance identifiers

    def test_audit_refuses_to_summarize_a_review_that_does_not_validate(self):
        self.assertEqual(self.template().returncode, 0)
        path = self.benchmark_root / contract.REVIEW_DIRECTORY / "{}.review.json".format(self.case_id)
        review = json.loads(path.read_text(encoding="utf-8"))
        review["review_status"] = "complete"
        fixture.write_json(path, review)
        result = self.run_command("audit", "--case-id", self.case_id, "--output", str(self.root / "a.json"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("refusing to summarize", result.stderr)

    def test_a_missing_item_needs_its_own_inference_class(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"missing_items": [{
            "category": "decisions",
            "text": "예산안을 의결",
            "evidence_utterance_ids": ["U1"],
            "target_speaker_b_responsibility": "no_responsibility_assigned",
        }]})
        self.assertEqual(result.returncode, 1)
        self.assertIn("needs an inference class", result.stderr)

    def test_a_forbidden_inference_about_absence_cites_nothing(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"transcript_coverage": {
            "full_window_reviewed": True, "statement": "전체 전사를 끝까지 확인했습니다",
        }}).returncode, 0)
        self.assertEqual(self.record({"forbidden_inference": {"checked": True, "items": [
            {
                "claim": "근거 없는 기한 생성",
                "reason": "어떤 발화에도 기한 표현이 없음",
                "basis": "absence_in_window",
                "evidence_utterance_ids": [],
            },
            {
                "claim": "질문에 답변이 있었다고 추론",
                "reason": "창의 마지막 발화 이후 응답이 창 안에 없음",
                "basis": "utterance",
                "evidence_utterance_ids": ["U3"],
            },
        ]}}).returncode, 0)
        self.assertEqual(len(self.review()["forbidden_inference"]["items"]), 2)

    def test_absence_needs_a_confirmed_full_window_review(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"forbidden_inference": {"checked": True, "items": [{
            "claim": "근거 없는 기한 생성",
            "reason": "어떤 발화에도 기한 표현이 없음",
            "basis": "absence_in_window",
            "evidence_utterance_ids": [],
        }]}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("without a confirmed full-window review", result.stderr)

    def test_coverage_pins_the_window_from_the_case_itself(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"transcript_coverage": {
            "full_window_reviewed": True,
            "statement": "전체 전사를 끝까지 확인했습니다",
            "first_utterance_id": "U9", "last_utterance_id": "U9", "utterance_count": 1,
        }}).returncode, 0)
        coverage = self.review()["transcript_coverage"]
        self.assertEqual(coverage["first_utterance_id"], "U1")
        self.assertEqual(coverage["last_utterance_id"], "U3")
        self.assertEqual(coverage["utterance_count"], 3)

    def test_a_truncated_review_cannot_complete(self):
        self.assertEqual(self.template().returncode, 0)
        decisions = full_decisions(self.case_id, self.statement_key, self.action_key)
        decisions.pop("transcript_coverage")
        result = self.record(decisions)
        self.assertEqual(result.returncode, 1)
        self.assertIn("transcript_coverage", result.stderr)

    def test_coverage_that_no_longer_matches_the_case_fails_validation(self):
        self.assertEqual(self.complete().returncode, 0)
        path = self.benchmark_root / contract.REVIEW_DIRECTORY / "{}.review.json".format(self.case_id)
        review = json.loads(path.read_text(encoding="utf-8"))
        review["transcript_coverage"]["utterance_count"] = 2
        fixture.write_json(path, review)
        result = self.run_command("validate", "--case-id", self.case_id)
        self.assertEqual(result.returncode, 1)
        self.assertIn("a window the case does not have", result.stdout)

    def test_a_forbidden_inference_resting_on_absence_may_not_cite_utterances(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"forbidden_inference": {"checked": True, "items": [{
            "claim": "근거 없는 기한 생성",
            "reason": "어떤 발화에도 기한 표현이 없음",
            "basis": "absence_in_window",
            "evidence_utterance_ids": ["U1"],
        }]}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("rests on absence but cites utterances", result.stderr)

    def test_a_forbidden_inference_needs_a_stated_basis(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"forbidden_inference": {"checked": True, "items": [{
            "claim": "근거 없는 기한 생성",
            "reason": "어떤 발화에도 기한 표현이 없음",
            "evidence_utterance_ids": [],
        }]}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("needs a basis", result.stderr)

    def test_a_decision_document_for_another_case_is_refused(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"case_id": "MEV0-999", "no_missing": {"decisions": True}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("decision document is for MEV0-999", result.stderr)

    def test_an_unknown_field_is_refused_rather_than_ignored(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"gold": {"decisions": ["무언가"]}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown fields", result.stderr)


if __name__ == "__main__":
    unittest.main()
