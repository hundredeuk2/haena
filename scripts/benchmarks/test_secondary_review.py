#!/usr/bin/env python3
"""Tests for the blind second pass.

Run with `python3 -m unittest discover -s scripts/benchmarks -p 'test_*.py'`.

The blind is the thing under test. A second opinion that has seen the first one is not a
second opinion, so the tests check that every first-pass path raises on read, that the
packet contains nothing from it, and that the counters saying so are produced by the same
guard that does the refusing.
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import manage_secondary_review as manage  # noqa: E402  (import path is set above)
import repair_meeting_execution_partition as repair  # noqa: E402
import secondary_review_contract as contract  # noqa: E402
import test_meeting_execution_review_packet as packet_fixture  # noqa: E402

SCRIPT = Path(__file__).resolve().parent / "manage_secondary_review.py"


class BlindSecondPassTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        _, self.benchmark_root, self.development, _ = packet_fixture.build_packet_fixture(self.root)
        self.case_id = self.development[0]
        self.sealed_id = sorted(
            row["case_id"] for row in repair.read_jsonl(self.benchmark_root / "source-index.jsonl")
            if row["split"] == "sealed_holdout"
        )[0]
        # A first-pass result the second pass must never reach.
        primary = self.benchmark_root / "human-reviews/primary"
        primary.mkdir(parents=True, exist_ok=True)
        (primary / "{}.review.json".format(self.case_id)).write_text(
            json.dumps({"case_id": self.case_id, "verdict": "PRIMARY_SECRET"}), encoding="utf-8"
        )
        (self.benchmark_root / "human-reviews/gold-draft").mkdir(parents=True, exist_ok=True)
        (self.benchmark_root / "human-reviews/gold-draft/{}.gold-draft.json".format(self.case_id)
         ).write_text(json.dumps({"text": "DRAFT_SECRET"}), encoding="utf-8")
        (self.benchmark_root / "human-reviews/primary-review-audit-batch1.json").write_text(
            json.dumps({"totals": {"complete": 4}}), encoding="utf-8"
        )

    def run_command(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--benchmark-root", str(self.benchmark_root), *args],
            capture_output=True, text=True, check=False,
        )

    def packet(self, case_id=None):
        return self.run_command("packet", "--case-id", case_id or self.case_id)

    def template(self, case_id=None, reviewer="secondary_reviewer_01"):
        return self.run_command("template", "--case-id", case_id or self.case_id,
                                "--reviewer-id", reviewer)

    def record(self, decisions, case_id=None):
        path = self.root / "decisions.json"
        path.write_text(json.dumps(decisions, ensure_ascii=False), encoding="utf-8")
        return self.run_command("record", "--case-id", case_id or self.case_id,
                                "--decisions", str(path))

    def review(self, case_id=None):
        return json.loads(
            (self.benchmark_root / contract.REVIEW_DIRECTORY
             / "{}.secondary-review.json".format(case_id or self.case_id)).read_text(encoding="utf-8")
        )

    def test_the_guard_refuses_every_first_pass_path(self):
        guard = manage.BlindGuard(self.benchmark_root)
        for relative in (
            "human-reviews/primary/{}.review.json".format(self.case_id),
            "human-reviews/gold-draft/{}.gold-draft.json".format(self.case_id),
            "human-reviews/primary-review-audit-batch1.json",
        ):
            with self.assertRaises(manage.BlindAccessError, msg=relative):
                guard.read_text(self.benchmark_root / relative, kind="case_reads")

    def test_the_packet_carries_the_case_and_nothing_from_the_first_pass(self):
        result = self.packet()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.benchmark_root / contract.PACKET_DIRECTORY
                / "{}.blind-packet.md".format(self.case_id)).read_text(encoding="utf-8")
        self.assertIn("전체 전사", text)
        self.assertIn("decisions[1]", text)
        self.assertNotIn("PRIMARY_SECRET", text)
        self.assertNotIn("DRAFT_SECRET", text)
        audit = json.loads(result.stdout)["access_audit"]
        self.assertEqual(audit["primary_reads"], 0)
        self.assertEqual(audit["gold_draft_reads"], 0)
        self.assertEqual(audit["primary_audit_reads"], 0)
        self.assertEqual(audit["notion_reads"], 0)
        self.assertEqual(audit["network_calls"], 0)

    def test_a_template_starts_with_no_judgment_and_records_its_limitations(self):
        self.assertEqual(self.packet().returncode, 0)
        self.assertEqual(self.template().returncode, 0)
        review = self.review()
        self.assertEqual(review["provenance"]["review_mode"], contract.REVIEW_MODE)
        self.assertFalse(review["provenance"]["inter_rater_agreement_claim_allowed"])
        self.assertEqual(review["provenance"]["limitations"], list(contract.LIMITATIONS))
        self.assertEqual(review["provenance"]["reviewer_id"], "secondary_reviewer_01")
        for entry in review["candidate_verdicts"]:
            self.assertIsNone(entry["verdict"])
            self.assertIsNone(entry["assignee"])
            self.assertIsNone(entry["due"])
        self.assertEqual(set(review["no_missing"].values()), {None})
        self.assertIsNone(review["prior_transition"])

    def test_a_template_needs_its_packet_first(self):
        result = self.template()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no blind packet yet", result.stderr)

    def test_a_template_never_overwrites_an_existing_review(self):
        self.assertEqual(self.packet().returncode, 0)
        self.assertEqual(self.template().returncode, 0)
        before = self.review()
        result = self.template()
        self.assertEqual(result.returncode, 1)
        self.assertIn("never replaces it", result.stderr)
        self.assertEqual(self.review(), before)

    def test_a_reviewer_name_is_refused_in_favour_of_an_opaque_id(self):
        self.assertEqual(self.packet().returncode, 0)
        result = self.template(reviewer="patrick")
        self.assertEqual(result.returncode, 1)
        self.assertIn("opaque local identifier", result.stderr)

    def test_a_sealed_case_is_refused(self):
        result = self.packet(self.sealed_id)
        self.assertEqual(result.returncode, 1)
        self.assertIn("is not a development case", result.stderr)

    def test_an_action_item_needs_scope_and_basis_answered_separately(self):
        self.assertEqual(self.packet().returncode, 0)
        self.assertEqual(self.template().returncode, 0)
        base = {
            "verdict": "approve", "evidence_status": "ai_evidence_approved",
            "target_speaker_b_responsibility": "b_responsible", "inference_class": "explicit",
            "due": {"status": "absent", "value": None, "evidence_utterance_ids": []},
        }
        result = self.record({"candidate_verdicts": {"action_items[1]": dict(base, assignee={
            "basis": "speaker_commitment", "value": "B", "evidence_utterance_ids": ["U2"],
        })}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("assignee scope must be one of", result.stderr)

        result = self.record({"candidate_verdicts": {"action_items[1]": dict(base, assignee={
            "scope": "individual", "value": "B", "evidence_utterance_ids": ["U2"],
        })}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("assignee basis must be one of", result.stderr)

    def test_an_absent_assignee_may_not_carry_a_scope_or_a_value(self):
        self.assertEqual(self.packet().returncode, 0)
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"candidate_verdicts": {"action_items[1]": {
            "verdict": "approve", "evidence_status": "ai_evidence_approved",
            "target_speaker_b_responsibility": "b_responsible", "inference_class": "explicit",
            "assignee": {"scope": "organization", "basis": "absent_must_stay_empty",
                         "value": None, "evidence_utterance_ids": []},
            "due": {"status": "absent", "value": None, "evidence_utterance_ids": []},
        }}})
        self.assertEqual(result.returncode, 1)
        self.assertIn("no basis cannot have a scope", result.stderr)

    def test_a_scope_and_basis_pair_is_recorded_as_given(self):
        self.assertEqual(self.packet().returncode, 0)
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual(self.record({"candidate_verdicts": {"action_items[1]": {
            "verdict": "approve", "evidence_status": "ai_evidence_approved",
            "target_speaker_b_responsibility": "b_responsible", "inference_class": "explicit",
            "assignee": {"scope": "organization", "basis": "speaker_commitment",
                         "value": "재무국 담당 조직", "evidence_utterance_ids": ["U2"]},
            "due": {"status": "explicit_relative", "value": "오늘 중으로",
                    "evidence_utterance_ids": ["U2"]},
        }}}).returncode, 0)
        entry = next(e for e in self.review()["candidate_verdicts"]
                     if e["candidate_key"] == "action_items[1]")
        self.assertEqual(entry["assignee"]["scope"], "organization")
        self.assertEqual(entry["assignee"]["basis"], "speaker_commitment")
        self.assertEqual(entry["due"]["status"], "explicit_relative")

    def test_completion_is_blocked_while_anything_is_unresolved(self):
        self.assertEqual(self.packet().returncode, 0)
        self.assertEqual(self.template().returncode, 0)
        result = self.record({"review_status": "complete"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot be complete while unresolved", result.stderr)

    def test_validation_reports_the_blind_mode_and_its_limitations(self):
        self.assertEqual(self.packet().returncode, 0)
        self.assertEqual(self.template().returncode, 0)
        result = self.run_command("validate", "--case-id", self.case_id)
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        entry, = report["reviews"]
        self.assertEqual(entry["review_mode"], contract.REVIEW_MODE)
        self.assertEqual(entry["limitations"], list(contract.LIMITATIONS))
        self.assertEqual(report["access_audit"]["primary_reads"], 0)

    def test_a_review_claiming_inter_rater_agreement_fails_validation(self):
        self.assertEqual(self.packet().returncode, 0)
        self.assertEqual(self.template().returncode, 0)
        path = (self.benchmark_root / contract.REVIEW_DIRECTORY
                / "{}.secondary-review.json".format(self.case_id))
        review = json.loads(path.read_text(encoding="utf-8"))
        review["provenance"]["inter_rater_agreement_claim_allowed"] = True
        path.write_text(json.dumps(review, ensure_ascii=False, indent=2), encoding="utf-8")
        result = self.run_command("validate", "--case-id", self.case_id)
        self.assertEqual(result.returncode, 1)
        self.assertIn("may not claim inter-rater agreement", result.stdout)

    def test_the_first_pass_files_are_never_written(self):
        primary = self.benchmark_root / "human-reviews/primary/{}.review.json".format(self.case_id)
        draft = (self.benchmark_root
                 / "human-reviews/gold-draft/{}.gold-draft.json".format(self.case_id))
        before = (primary.read_bytes(), draft.read_bytes())
        self.assertEqual(self.packet().returncode, 0)
        self.assertEqual(self.template().returncode, 0)
        self.assertEqual((primary.read_bytes(), draft.read_bytes()), before)


if __name__ == "__main__":
    unittest.main()
