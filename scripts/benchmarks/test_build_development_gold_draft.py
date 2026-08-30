#!/usr/bin/env python3
"""Tests for materializing the development gold draft.

Run with `python3 -m unittest discover -s scripts/benchmarks -p 'test_*.py'`.

Determinism and refusal are the two properties worth testing here. A draft that differs
between runs cannot be compared to the one before it, and a draft built from the wrong
mapping, an unfinished review, or a holdout would look exactly like a correct one.
"""

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build_development_gold_draft as normalizer  # noqa: E402
import repair_meeting_execution_partition as repair  # noqa: E402
import test_development_gold_draft as draft_tests  # noqa: E402
import test_meeting_execution_partition as fixture  # noqa: E402
import test_meeting_execution_review_packet as packet_fixture  # noqa: E402
from primary_review_contract import REVIEW_DIRECTORY  # noqa: E402

SCRIPT = Path(__file__).resolve().parent / "build_development_gold_draft.py"
CONFIG = Path(__file__).resolve().parent / "ambiguity-taxonomy-v0.1.json"
CONFIG_SHA = hashlib.sha256(CONFIG.read_bytes()).hexdigest()


def write_review(root, case_id, review):
    path = root / REVIEW_DIRECTORY / "{}.review.json".format(case_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(review, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return path


class GoldDraftMaterializationTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        # The repaired fixture: development equals the suggestion set, so every development
        # case actually has a model draft to project alongside.
        _, self.benchmark_root, development, _ = packet_fixture.build_packet_fixture(self.root)
        self.case_id = development[0]
        self.sealed_id = sorted(
            row["case_id"] for row in repair.read_jsonl(self.benchmark_root / "source-index.jsonl")
            if row["split"] == "sealed_holdout"
        )[0]
        review = draft_tests.review_fixture(case_id=self.case_id)
        self.review_path = write_review(self.benchmark_root, self.case_id, review)

    def run_normalizer(self, output_root=None, sha=CONFIG_SHA, config=CONFIG):
        return subprocess.run(
            [sys.executable, str(SCRIPT),
             "--benchmark-root", str(self.benchmark_root),
             "--output-root", str(output_root or self.root / "out"),
             "--taxonomy-config", str(config),
             "--taxonomy-sha256", sha],
            capture_output=True, text=True, check=False,
        )

    def drafts(self, output_root=None):
        directory = (output_root or self.root / "out") / normalizer.DRAFT_DIRECTORY
        return {p.name.split(".")[0]: json.loads(p.read_text(encoding="utf-8"))
                for p in sorted(directory.glob("MEV0-*.gold-draft.json"))}

    def test_a_draft_is_written_and_is_never_final(self):
        result = self.run_normalizer()
        self.assertEqual(result.returncode, 0, result.stderr)
        drafted, = self.drafts().values()
        self.assertEqual(drafted["status"], normalizer.DRAFT_STATUS)
        self.assertFalse(drafted["scorer_ready"])
        self.assertFalse(drafted["secondary_review_complete"])
        self.assertEqual(drafted["ambiguity_taxonomy"]["config_sha256"], CONFIG_SHA)

    def test_two_runs_are_byte_identical(self):
        first, second = self.root / "one", self.root / "two"
        self.assertEqual(self.run_normalizer(first).returncode, 0)
        self.assertEqual(self.run_normalizer(second).returncode, 0)
        self.assertEqual(fixture.hash_tree(first), fixture.hash_tree(second))

    def test_reading_order_does_not_change_the_output(self):
        first = self.root / "ordered"
        self.assertEqual(self.run_normalizer(first).returncode, 0)
        baseline = fixture.hash_tree(first)
        # Touch the review so the filesystem hands it back in a different order, and confirm
        # the normalizer's own sort is what decides.
        self.review_path.write_text(self.review_path.read_text(encoding="utf-8"), encoding="utf-8")
        second = self.root / "reordered"
        self.assertEqual(self.run_normalizer(second).returncode, 0)
        self.assertEqual(fixture.hash_tree(second), baseline)

    def test_a_config_digest_mismatch_refuses_the_run(self):
        result = self.run_normalizer(sha="f" * 64)
        self.assertEqual(result.returncode, 1)
        self.assertIn("digest mismatch", result.stderr)
        self.assertFalse((self.root / "out").exists())

    def test_an_unmapped_raw_kind_refuses_the_run(self):
        review = json.loads(self.review_path.read_text(encoding="utf-8"))
        review["ambiguities"][0]["kind"] = "a_kind_nobody_approved"
        write_review(self.benchmark_root, self.case_id, review)
        result = self.run_normalizer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("not in the approved mapping", result.stderr)

    def test_an_incomplete_review_refuses_the_run(self):
        review = json.loads(self.review_path.read_text(encoding="utf-8"))
        review["review_status"] = "in_progress"
        write_review(self.benchmark_root, self.case_id, review)
        result = self.run_normalizer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("not complete", result.stderr)

    def test_a_sealed_case_refuses_the_run(self):
        write_review(self.benchmark_root, self.sealed_id,
                     draft_tests.review_fixture(case_id=self.sealed_id))
        result = self.run_normalizer()
        self.assertEqual(result.returncode, 1)
        self.assertIn("never built from a holdout", result.stderr)

    def test_the_source_review_is_never_written(self):
        before = self.review_path.read_bytes()
        self.assertEqual(self.run_normalizer().returncode, 0)
        self.assertEqual(self.review_path.read_bytes(), before)

    def test_the_case_and_its_gold_are_never_written(self):
        case_path = self.benchmark_root / repair.CASE_DIRECTORY / "{}.json".format(self.case_id)
        draft_path = self.benchmark_root / "drafts" / "{}.model-suggestion.json".format(self.case_id)
        before = (case_path.read_bytes(), draft_path.read_bytes())
        self.assertEqual(self.run_normalizer().returncode, 0)
        self.assertEqual((case_path.read_bytes(), draft_path.read_bytes()), before)
        case = json.loads(case_path.read_text(encoding="utf-8"))
        self.assertEqual(case["gold"]["status"], "human_review_pending")

    def test_the_audit_summary_carries_no_transcript_or_identifiers(self):
        self.assertEqual(self.run_normalizer().returncode, 0)
        audit = (self.root / "out" / normalizer.DRAFT_DIRECTORY / normalizer.AUDIT_NAME)
        text = audit.read_text(encoding="utf-8")
        self.assertNotIn("예산 자료를 제출", text)  # reviewer wording
        self.assertNotIn("U1", text)  # utterance identifiers
        self.assertEqual(json.loads(text)["totals"]["network_calls"], 0)
        self.assertEqual(json.loads(text)["totals"]["scorer_eligible_prior_transitions"], 0)


if __name__ == "__main__":
    unittest.main()
