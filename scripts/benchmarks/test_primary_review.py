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
        "prior_transition": {"status": "not_applicable", "reason": "이전 회의 source 없음"},
        "ambiguities": [],
        "review_flag_verdicts": {
            "review_flags[1]": {
                "verdict": "agree",
                "basis": "utterance",
                "reason": "이미 수행 중인 관행 설명이므로 신규 업무가 아님",
                "evidence_utterance_ids": ["U2"],
            }
        },
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
        self.assertIsNone(review["prior_transition"])

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
        decisions.pop("prior_transition")
        result = self.record(decisions)
        self.assertEqual(result.returncode, 1)
        self.assertIn("prior_transition", result.stderr)

    def test_a_completed_v0_1_review_still_reads_and_validates_unchanged(self):
        self.assertEqual(self.complete().returncode, 0)
        path = self.benchmark_root / contract.REVIEW_DIRECTORY / "{}.review.json".format(self.case_id)
        review = json.loads(path.read_text(encoding="utf-8"))
        review["schema_version"] = contract.LEGACY_SCHEMA_VERSIONS[0]
        review["prior_state_expectation"] = review.pop("prior_transition")
        fixture.write_json(path, review)
        before = path.read_bytes()
        result = self.run_command("validate", "--case-id", self.case_id)
        self.assertEqual(result.returncode, 0, result.stdout)
        entry, = json.loads(result.stdout)["reviews"]
        self.assertEqual(entry["review_status"], "complete")
        self.assertEqual(entry["unresolved"], [])
        self.assertEqual(entry["prior_state_status"], "not_applicable")
        self.assertEqual(path.read_bytes(), before)

    def test_an_untouched_v0_1_template_migrates_losslessly(self):
        self.assertEqual(self.template().returncode, 0)
        path = self.benchmark_root / contract.REVIEW_DIRECTORY / "{}.review.json".format(self.case_id)
        review = json.loads(path.read_text(encoding="utf-8"))
        review["schema_version"] = contract.LEGACY_SCHEMA_VERSIONS[0]
        review["prior_state_expectation"] = review.pop("prior_transition")
        fixture.write_json(path, review)
        before = json.loads(path.read_text(encoding="utf-8"))

        result = self.run_command("migrate", "--case-id", self.case_id)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(json.loads(result.stdout)["migrated"])
        after = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(after["schema_version"], contract.SCHEMA_VERSION)
        self.assertNotIn("prior_state_expectation", after)
        self.assertIsNone(after["prior_transition"])
        for key in ("candidate_verdicts", "review_flag_verdicts", "no_missing", "missing_items"):
            self.assertEqual(after[key], before[key])

    def test_a_review_with_decisions_in_it_is_never_migrated(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"no_missing": {"decisions": True}}).returncode, 0)
        path = self.benchmark_root / contract.REVIEW_DIRECTORY / "{}.review.json".format(self.case_id)
        review = json.loads(path.read_text(encoding="utf-8"))
        review["schema_version"] = contract.LEGACY_SCHEMA_VERSIONS[0]
        fixture.write_json(path, review)
        before = path.read_bytes()
        result = self.run_command("migrate", "--case-id", self.case_id)
        self.assertEqual(result.returncode, 1)
        self.assertIn("would rewrite a person's work", result.stderr)
        self.assertEqual(path.read_bytes(), before)

    def test_a_corpus_source_cannot_be_called_the_same_object(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"prior_transition": {
            "status": "insufficient_prior_state",
            "prior_reference": {"kind": "corpus_source_only", "prior_source_id": "SRC-030"},
            "object_identity": {"decision": "same_object", "reason": "같은 회의 시리즈"},
            "reason": "prior case가 없음",
        }})
        self.assertEqual(result.returncode, 1)
        self.assertIn("object identity cannot be decided", result.stderr)

    def test_a_corpus_source_cannot_carry_a_transition_kind(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"prior_transition": {
            "status": "insufficient_prior_state",
            "prior_reference": {"kind": "corpus_source_only", "prior_source_id": "SRC-030"},
            "object_identity": {"decision": "undecidable", "reason": "prior object 없음"},
            "transition_kind": "changed",
            "reason": "prior case가 없음",
        }})
        self.assertEqual(result.returncode, 1)
        self.assertIn("transition cannot be chosen without a prior object", result.stderr)

    def test_an_expected_transition_needs_a_typed_prior_case(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"prior_transition": {
            "status": "expected",
            "prior_reference": {"kind": "corpus_source_only", "prior_source_id": "SRC-030"},
            "object_identity": {"decision": "same_object", "reason": "동일 안건"},
            "transition_kind": "changed",
            "from_state": "검토 중", "to_state": "의결",
            "evidence_utterance_ids": ["U1"],
            "reason": "전이 확인",
        }})
        self.assertEqual(result.returncode, 1)
        self.assertIn("needs a typed prior case", result.stderr)

    def test_a_typed_prior_case_must_be_a_development_case(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"prior_transition": {
            "status": "expected",
            "prior_reference": {"kind": "typed_case", "prior_case_id": "MEV0-999"},
            "object_identity": {"decision": "same_object", "reason": "동일 안건"},
            "transition_kind": "changed",
            "from_state": "검토 중", "to_state": "의결",
            "evidence_utterance_ids": ["U1"],
            "reason": "전이 확인",
        }})
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not a development case", result.stderr)

    def test_insufficient_prior_state_needs_the_reviewer_reason(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"prior_transition": {
            "status": "insufficient_prior_state",
            "prior_reference": {"kind": "corpus_source_only", "prior_source_id": "SRC-030"},
            "object_identity": {"decision": "undecidable", "reason": "prior object 없음"},
        }})
        self.assertEqual(result.returncode, 1)
        self.assertIn("needs the reviewer's reason", result.stderr)

    def test_insufficient_prior_state_records_the_gap_as_a_finding(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"prior_transition": {
            "status": "insufficient_prior_state",
            "prior_reference": {"kind": "corpus_source_only", "prior_source_id": "SRC-030"},
            "object_identity": {"decision": "undecidable", "reason": "prior object가 만들어진 적 없음"},
            "reason": "corpus에 이전 회차 녹취는 있으나 typed case와 Work State가 없음",
        }}).returncode, 0)
        block = self.review()["prior_transition"]
        self.assertEqual(block["status"], "insufficient_prior_state")
        self.assertIsNone(block["transition_kind"])
        self.assertIsNone(block["prior_reference"]["prior_case_id"])

    def test_no_sealed_file_is_opened_by_any_review_command(self):
        sealed = sorted(
            row["case_id"] for row in repair.read_jsonl(self.benchmark_root / "source-index.jsonl")
            if row["split"] == "sealed_holdout"
        )
        self.assertEqual(self.complete().returncode, 0)
        for command in (("template",), ("migrate",), ("validate",)):
            for case_id in sealed:
                result = self.run_command(*command, "--case-id", case_id)
                self.assertEqual(result.returncode, 1, command)
                self.assertIn("is not a development case", result.stderr)

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
        self.assertIn("rests on absence_in_window but cites utterances", result.stderr)

    def test_a_forbidden_inference_needs_a_stated_basis(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"forbidden_inference": {"checked": True, "items": [{
            "claim": "근거 없는 기한 생성",
            "reason": "어떤 발화에도 기한 표현이 없음",
            "evidence_utterance_ids": [],
        }]}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("needs a basis", result.stderr)

    def test_an_exclusion_records_its_own_grounds(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"candidate_verdicts": {self.statement_key: {
            "verdict": "exclude",
            "exclude_reason": "not_a_meeting_output",
            "exclude_evidence_utterance_ids": ["U1", "U2"],
            "target_speaker_b_responsibility": "other_speaker",
            "inference_class": "forbidden_inference",
        }}}).returncode, 0)
        entry = self.review()["candidate_verdicts"][0]
        self.assertEqual(entry["exclude_evidence_utterance_ids"], ["U1", "U2"])
        self.assertIsNone(entry["evidence_status"])

    def test_exclusion_grounds_must_exist_in_the_case(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"candidate_verdicts": {self.statement_key: {
            "verdict": "exclude",
            "exclude_reason": "not_a_meeting_output",
            "exclude_evidence_utterance_ids": ["U99"],
            "target_speaker_b_responsibility": "other_speaker",
            "inference_class": "forbidden_inference",
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("exclusion grounds names utterances", result.stderr)

    def test_exclusion_grounds_need_an_exclude_verdict(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"candidate_verdicts": {self.statement_key: {
            "verdict": "approve",
            "evidence_status": "ai_evidence_approved",
            "exclude_evidence_utterance_ids": ["U1"],
            "target_speaker_b_responsibility": "other_speaker",
            "inference_class": "explicit",
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("without an exclude verdict", result.stderr)

    def test_an_ambiguity_keeps_its_kind_span_and_handling(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"ambiguities": [{
            "kind": "truncated_window",
            "about": "U3",
            "statement": "문장이 중단돼 결론을 판단할 수 없음",
            "evidence_utterance_ids": ["U3"],
            "resolution": "결과를 억지로 생성하지 않고 ambiguity로 보존",
        }]}).returncode, 0)
        item, = self.review()["ambiguities"]
        self.assertEqual(item["kind"], "truncated_window")
        self.assertEqual(item["resolution"], "결과를 억지로 생성하지 않고 ambiguity로 보존")

    def test_an_ambiguity_field_outside_the_contract_is_refused(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"ambiguities": [
            {"about": "U3", "statement": "결론 없음", "verdict": "approve"}
        ]})
        self.assertEqual(result.returncode, 1)
        self.assertIn("carries unknown fields", result.stderr)

    def test_a_method_based_prohibition_needs_no_window_coverage(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"forbidden_inference": {"checked": True, "items": [{
            "claim": "focus 라벨을 근거로 결과 수를 늘림",
            "reason": "focus는 사례 선정 strata이며 정답 cardinality가 아님",
            "basis": "review_method",
            "evidence_utterance_ids": [],
        }]}}).returncode, 0)
        self.assertEqual(self.review()["forbidden_inference"]["items"][0]["basis"], "review_method")

    def test_flags_start_unjudged_and_block_completion(self):
        self.assertEqual(self.template().returncode, 0)
        entry, = self.review()["review_flag_verdicts"]
        self.assertEqual(entry["flag_key"], "review_flags[1]")
        self.assertEqual(entry["ai_claim"], "담당자가 분명하지 않음")
        self.assertIsNone(entry["verdict"])
        decisions = full_decisions(self.case_id, self.statement_key, self.action_key)
        decisions.pop("review_flag_verdicts")
        result = self.record(decisions)
        self.assertEqual(result.returncode, 1)
        self.assertIn("review_flags[1].verdict", result.stderr)

    def test_agreeing_on_an_utterance_basis_needs_evidence(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"review_flag_verdicts": {"review_flags[1]": {
            "verdict": "agree", "basis": "utterance", "reason": "관행 설명임",
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("evidence needs at least one utterance ID", result.stderr)

    def test_agreeing_with_a_flag_needs_a_basis(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"review_flag_verdicts": {"review_flags[1]": {
            "verdict": "agree", "reason": "관행 설명임", "evidence_utterance_ids": ["U2"],
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("needs a basis from", result.stderr)

    def test_a_flag_about_absence_needs_confirmed_coverage(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"review_flag_verdicts": {"review_flags[1]": {
            "verdict": "agree", "basis": "absence_in_window",
            "reason": "window 전체에 해당 주제가 없음", "evidence_utterance_ids": [],
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("without a confirmed review of this exact window", result.stderr)

    def test_a_flag_about_absence_may_not_cite_utterances(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({
            "transcript_coverage": {"full_window_reviewed": True, "statement": "끝까지 확인"},
            "review_flag_verdicts": {"review_flags[1]": {
                "verdict": "agree", "basis": "absence_in_window",
                "reason": "window 전체에 해당 주제가 없음", "evidence_utterance_ids": ["U1"],
            }},
        })
        self.assertEqual(result.returncode, 1)
        self.assertIn("rests on absence_in_window but cites utterances", result.stderr)

    def test_absence_cannot_borrow_coverage_of_a_different_window(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({
            "transcript_coverage": {"full_window_reviewed": True, "statement": "끝까지 확인"},
        }).returncode, 0)
        path = self.benchmark_root / contract.REVIEW_DIRECTORY / "{}.review.json".format(self.case_id)
        review = json.loads(path.read_text(encoding="utf-8"))
        review["transcript_coverage"]["utterance_count"] = 2  # a partial pass
        fixture.write_json(path, review)
        result = self.record({"review_flag_verdicts": {"review_flags[1]": {
            "verdict": "agree", "basis": "absence_in_window",
            "reason": "window 전체에 해당 주제가 없음", "evidence_utterance_ids": [],
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("without a confirmed review of this exact window", result.stderr)

    def test_a_flag_on_review_method_cites_nothing_and_needs_no_coverage(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"review_flag_verdicts": {"review_flags[1]": {
            "verdict": "agree", "basis": "review_method",
            "reason": "focus 라벨은 선정 strata이며 정답 수가 아님", "evidence_utterance_ids": [],
        }}}).returncode, 0)
        self.assertEqual(self.review()["review_flag_verdicts"][0]["basis"], "review_method")

    def test_an_ambiguity_citing_nothing_needs_confirmed_coverage(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"ambiguities": [{
            "kind": "metadata_transcript_mismatch",
            "about": "메타데이터와 전사",
            "statement": "window 전체에 메타데이터가 가리키는 주제가 없음",
            "evidence_utterance_ids": [],
        }]})
        self.assertEqual(result.returncode, 1)
        self.assertIn("cites nothing, so it needs a confirmed review", result.stderr)

    def test_a_completed_v0_2_review_reads_unchanged(self):
        self.assertEqual(self.complete().returncode, 0)
        path = self.benchmark_root / contract.REVIEW_DIRECTORY / "{}.review.json".format(self.case_id)
        review = json.loads(path.read_text(encoding="utf-8"))
        review["schema_version"] = "haena-meeting-execution-primary-review-v0.2"
        fixture.write_json(path, review)
        before = path.read_bytes()
        result = self.run_command("validate", "--case-id", self.case_id)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(result.stdout)["reviews"][0]["unresolved"], [])
        self.assertEqual(path.read_bytes(), before)

    def test_rejecting_a_flag_needs_the_boundary_and_the_correction(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"review_flag_verdicts": {"review_flags[1]": {
            "verdict": "reject", "reason": "플래그가 경계를 잘못 잡음",
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("must name the boundary it got wrong", result.stderr)

        self.assertEqual(self.record({"review_flag_verdicts": {"review_flags[1]": {
            "verdict": "reject",
            "reason": "플래그가 경계를 잘못 잡음",
            "wrong_boundary": "담당자 불명이 아니라 화자 자신이 수행을 약속함",
            "correction": "담당 화자를 B로 확정",
        }}}).returncode, 0)
        entry, = self.review()["review_flag_verdicts"]
        self.assertEqual(entry["verdict"], "reject")
        self.assertEqual(entry["correction"], "담당 화자를 B로 확정")

    def test_a_flag_verdict_needs_a_reason(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"review_flag_verdicts": {"review_flags[1]": {
            "verdict": "agree", "basis": "utterance", "evidence_utterance_ids": ["U2"],
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("needs the reviewer's reason", result.stderr)

    def test_a_flag_key_the_packet_does_not_have_is_refused(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"review_flag_verdicts": {"review_flags[2]": {
            "verdict": "agree", "basis": "utterance", "reason": "동의",
            "evidence_utterance_ids": ["U2"],
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not an AI flag in this case", result.stderr)

    def test_a_review_written_before_flags_reopens_rather_than_staying_complete(self):
        self.assertEqual(self.complete().returncode, 0)
        path = self.benchmark_root / contract.REVIEW_DIRECTORY / "{}.review.json".format(self.case_id)
        review = json.loads(path.read_text(encoding="utf-8"))
        del review["review_flag_verdicts"]  # a review from before flags were judgeable
        fixture.write_json(path, review)
        result = self.run_command("validate", "--case-id", self.case_id)
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertIn("review_flags[1].verdict", report["reviews"][0]["unresolved"])

    def test_flag_verdicts_must_cover_the_packet_flags_exactly(self):
        self.assertEqual(self.complete().returncode, 0)
        path = self.benchmark_root / contract.REVIEW_DIRECTORY / "{}.review.json".format(self.case_id)
        review = json.loads(path.read_text(encoding="utf-8"))
        review["review_flag_verdicts"] = []
        fixture.write_json(path, review)
        result = self.run_command("validate", "--case-id", self.case_id)
        self.assertEqual(result.returncode, 1)
        self.assertIn("do not cover the packet's flags", result.stdout)

    def test_a_relative_due_date_records_whether_it_could_be_anchored(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"candidate_verdicts": {self.action_key: {
            "verdict": "approve",
            "evidence_status": "ai_evidence_approved",
            "target_speaker_b_responsibility": "b_responsible",
            "inference_class": "explicit",
            "assignee_basis": {
                "status": "supported_by_utterance", "utterance_ids": ["U2"], "value": "B",
            },
            "due_basis": {
                "status": "explicit_relative", "utterance_ids": ["U2"], "value": "오늘 중으로",
                "normalized_absolute_date": None,
            },
        }}}).returncode, 0)
        entry = self.review()["candidate_verdicts"][1]
        self.assertEqual(entry["due_basis"]["status"], "explicit_relative")
        self.assertIsNone(entry["due_basis"]["normalized_absolute_date"])

    def test_a_relative_due_date_must_say_whether_it_was_normalized(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"candidate_verdicts": {self.action_key: {
            "verdict": "approve",
            "evidence_status": "ai_evidence_approved",
            "target_speaker_b_responsibility": "b_responsible",
            "inference_class": "explicit",
            "assignee_basis": {
                "status": "supported_by_utterance", "utterance_ids": ["U2"], "value": "B",
            },
            "due_basis": {
                "status": "explicit_relative", "utterance_ids": ["U2"], "value": "오늘 중으로",
            },
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("whether the relative date could be normalized", result.stderr)

    def test_a_normalized_date_needs_a_relative_basis(self):
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"candidate_verdicts": {self.action_key: {
            "verdict": "approve",
            "evidence_status": "ai_evidence_approved",
            "target_speaker_b_responsibility": "b_responsible",
            "inference_class": "explicit",
            "assignee_basis": {
                "status": "supported_by_utterance", "utterance_ids": ["U2"], "value": "B",
            },
            "due_basis": {
                "status": "absent_must_stay_empty", "utterance_ids": [], "value": None,
                "normalized_absolute_date": "2014-11-14",
            },
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("without a relative basis", result.stderr)

    def test_a_reported_prior_decision_has_its_own_exclude_reason(self):
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"candidate_verdicts": {self.statement_key: {
            "verdict": "exclude",
            "exclude_reason": "historical_state_not_current_meeting_output",
            "exclude_evidence_utterance_ids": ["U1"],
            "target_speaker_b_responsibility": "no_responsibility_assigned",
            "inference_class": "forbidden_inference",
        }}}).returncode, 0)
        self.assertEqual(
            self.review()["candidate_verdicts"][0]["exclude_reason"],
            "historical_state_not_current_meeting_output",
        )

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
