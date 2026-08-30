#!/usr/bin/env python3
"""Tests for the development-only human review packet.

Run with `python3 -m unittest discover -s scripts/benchmarks -p 'test_*.py'`.

The fixtures reuse the repaired-partition fixture, then add a sealed case whose body is a
tripwire: if the generator ever loads the manifest or a holdout file, its text lands in the
packet and the leak tests fail.
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

import build_meeting_execution_review_packet as packet  # noqa: E402  (import path is set above)
import repair_meeting_execution_partition as repair  # noqa: E402
import test_meeting_execution_partition as fixture  # noqa: E402

PACKET_SCRIPT = Path(__file__).resolve().parent / "build_meeting_execution_review_packet.py"
SEALED_TRIPWIRE = "봉인된 내용"


def draft_document(case_id):
    return {
        "schema_version": packet.DRAFT_SCHEMA,
        "case_id": case_id,
        "split": "development",
        "draft_status": "model_suggestion",
        "human_review": {
            "status": "pending",
            "all_candidates_reviewed": False,
            "missing_items_checked": False,
            "reviewer_notes": "",
        },
        "local_validation": {"passed": True, "errors": [], "normalizations": []},
        "suggestion": {
            "decisions": [
                {"statement": "예산안을 원안대로 의결", "evidence": {"utterance_id": "U1", "quote": "의결합니다"}}
            ],
            "action_items": [
                {
                    "title": "자료 제출",
                    "assignee_speaker": "B",
                    "assignee_basis": "explicit_self_commitment",
                    "due_date": None,
                    "due_text": None,
                    "evidence": {"utterance_id": "U2", "quote": "제출하겠습니다"},
                }
            ],
            "open_questions": [],
            "next_agenda": [],
            "review_flags": [
                {
                    "kind": "uncertain",
                    "category": "action_item",
                    "claim": "담당자가 분명하지 않음",
                    "reason": "발화가 짧음",
                    "related_utterance_id": "U2",
                }
            ],
            "coverage_notes": "예산 심사 질의 단계",
        },
    }


def build_packet_fixture(root):
    """A repaired corpus plus drafts, with sealed bodies carrying a tripwire string."""
    corpus_root, source_root = fixture.build_fixture(root)
    benchmark_root = corpus_root / repair.BENCHMARK
    result = subprocess.run(
        [sys.executable, str(fixture.REPAIR_SCRIPT),
         "--output-root", str(corpus_root), "--source-root", str(source_root)],
        capture_output=True, text=True, check=True,
    )
    development = sorted(
        row["case_id"] for row in repair.read_jsonl(benchmark_root / "source-index.jsonl")
        if row["split"] == "development"
    )
    for path in (benchmark_root / "drafts").glob("*.model-suggestion.json"):
        path.unlink()
    for case_id in development:
        fixture.write_json(
            benchmark_root / "drafts" / "{}.model-suggestion.json".format(case_id),
            draft_document(case_id),
        )
        case_path = benchmark_root / repair.CASE_DIRECTORY / "{}.json".format(case_id)
        case = json.loads(case_path.read_text(encoding="utf-8"))
        case["transcript"] = [
            {"utterance_id": "U1", "start_seconds": 1.0, "end_seconds": 4.0, "speaker": "A",
             "text_raw": "예산안을 의결합니다", "text_normalized": "예산안을 의결합니다"},
            {"utterance_id": "U2", "start_seconds": 5.0, "end_seconds": 9.0, "speaker": "B",
             "text_raw": "자료를 제출하겠습니다", "text_normalized": "자료를 제출하겠습니다"},
            {"utterance_id": "U3", "start_seconds": 10.0, "end_seconds": 14.0, "speaker": "C",
             "text_raw": "추가 논의가 필요합니다", "text_normalized": "추가 논의가 필요합니다"},
        ]
        fixture.write_json(case_path, case)
    return corpus_root, benchmark_root, development, json.loads(result.stdout)


class ReviewPacketTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.corpus_root, self.benchmark_root, self.development, _ = build_packet_fixture(self.root)
        self.output = self.root / "packet.md"

    def build(self, *extra, output=None):
        return subprocess.run(
            [sys.executable, str(PACKET_SCRIPT),
             "--benchmark-root", str(self.benchmark_root),
             "--output", str(output or self.output), *extra],
            capture_output=True, text=True, check=False,
        )

    def text(self, output=None):
        return (output or self.output).read_text(encoding="utf-8")

    def sealed_ids(self):
        return sorted(
            row["case_id"] for row in repair.read_jsonl(self.benchmark_root / "source-index.jsonl")
            if row["split"] == "sealed_holdout"
        )

    def test_headings_equal_the_development_ids(self):
        self.assertEqual(self.build().returncode, 0)
        headings = [
            line[2:].split(" ")[0] for line in self.text().splitlines()
            if line.startswith("# MEV0-")
        ]
        self.assertEqual(headings, self.development)
        self.assertEqual(len(headings), 16)

    def test_packet_names_no_sealed_case_and_no_sealed_content(self):
        self.assertEqual(self.build().returncode, 0)
        text = self.text()
        for case_id in self.sealed_ids():
            self.assertNotIn(case_id, text)
        self.assertNotIn(SEALED_TRIPWIRE, text)

    def test_generation_opens_no_sealed_file_and_no_manifest(self):
        result = self.build()
        self.assertEqual(result.returncode, 0)
        audit = json.loads(result.stdout)["access_audit"]
        self.assertEqual(audit["sealed_case_files_opened"], 0)
        self.assertEqual(audit["manifest_reads"], 0)
        self.assertEqual(audit["development_case_files_opened"], 16)
        self.assertEqual(audit["gold_or_progress_writes"], 0)
        self.assertEqual(audit["network_calls"], 0)

    def test_manifest_is_refused_outright(self):
        audit = packet.PacketAudit([self.benchmark_root / "manifest.jsonl"])
        with self.assertRaises(packet.PacketError):
            audit.open_json(self.benchmark_root / "manifest.jsonl", kind="development_case")

    def test_every_ai_item_is_labelled_non_gold(self):
        self.assertEqual(self.build().returncode, 0)
        text = self.text()
        headings = [line for line in text.splitlines() if line.startswith("#### ")]
        self.assertEqual(len(headings), 32)  # one decision and one action item per case
        self.assertEqual(text.count("위 문장은 AI 초벌입니다. 승인 표시가 없으면 gold가 아닙니다."), 32)
        self.assertIn("AI 초벌(non-gold)", text)
        self.assertIn("정답 개수가 아닙니다", text)

    def test_every_case_exposes_the_required_review_surfaces(self):
        self.assertEqual(self.build().returncode, 0)
        text = self.text()
        for marker, expected in (
            ("- 판정: [ ] 승인   [ ] 수정 후 승인   [ ] 제외", 32),
            ("- 판정 유형: [ ] explicit   [ ] derived proposal   [ ] forbidden inference", 32),
            ("target speaker `B` 책임:", 32),
            ("- 담당자 근거 판정:", 16),
            ("- 기한 근거 판정:", 16),
            ("## prior-state 기대 전이", 16),
            ("## 금지 추론 확인", 16),
            ("### 누락 추가", 16),
            ("- 미해결 모호성:", 16),
            ("## 전체 전사", 16),
        ):
            self.assertEqual(text.count(marker), expected, marker)

    def test_evidence_points_at_a_transcript_position(self):
        self.assertEqual(self.build().returncode, 0)
        text = self.text()
        self.assertIn("- AI 근거: 전사 `U2` · 5.0초 · 화자 `B`", text)
        # Three spaces: the legend line names the marker in backticks and must not be counted.
        self.assertEqual(text.count("   ← AI 근거"), 32)  # U1 and U2 marked in each case
        self.assertEqual(text.count("`← AI 근거`가 붙은"), 16)

    def test_unreviewed_cases_stay_unreviewed(self):
        result = self.build()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["human_reviewed_cases"], 0)
        text = self.text()
        self.assertIn("사람 검수 완료: 0 / 16", text)
        self.assertEqual(text.count("- 사람 검수 상태: `미검수` (기록된 상태 `pending`)"), 16)
        self.assertNotIn("[x]", text)

    def test_recorded_human_state_is_carried_forward(self):
        case_id = self.development[0]
        path = self.benchmark_root / "drafts" / "{}.model-suggestion.json".format(case_id)
        draft = json.loads(path.read_text(encoding="utf-8"))
        draft["human_review"].update({
            "status": "in_review", "all_candidates_reviewed": True, "reviewer_notes": "1차 확인함",
        })
        fixture.write_json(path, draft)
        self.assertEqual(self.build().returncode, 0)
        text = self.text()
        self.assertIn("- 사람 검수 상태: `in_review`", text)
        self.assertIn("- [x] 후보 전수 확인 완료", text)
        self.assertIn("1차 확인함", text)

    def test_generation_writes_nothing_but_the_packet(self):
        before = fixture.hash_tree(self.corpus_root)
        self.assertEqual(self.build().returncode, 0)
        self.assertEqual(fixture.hash_tree(self.corpus_root), before)

    def test_repeated_generation_is_byte_identical(self):
        first = self.root / "first.md"
        second = self.root / "second.md"
        self.assertEqual(self.build(output=first).returncode, 0)
        self.assertEqual(self.build(output=second).returncode, 0)
        digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()  # noqa: E731
        self.assertEqual(digest(first), digest(second))

    def test_a_draft_outside_development_stops_the_packet(self):
        sealed_id = self.sealed_ids()[0]
        fixture.write_json(
            self.benchmark_root / "drafts" / "{}.model-suggestion.json".format(sealed_id),
            draft_document(sealed_id),
        )
        result = self.build()
        self.assertEqual(result.returncode, 1)
        self.assertIn("model suggestions do not match the development set", result.stderr)
        self.assertIn(sealed_id, result.stderr)

    def test_a_missing_draft_stops_the_packet(self):
        (self.benchmark_root / "drafts" / "{}.model-suggestion.json".format(self.development[0])).unlink()
        result = self.build()
        self.assertEqual(result.returncode, 1)
        self.assertIn("model suggestions do not match the development set", result.stderr)

    def test_a_draft_that_failed_local_validation_stops_the_packet(self):
        case_id = self.development[0]
        path = self.benchmark_root / "drafts" / "{}.model-suggestion.json".format(case_id)
        draft = json.loads(path.read_text(encoding="utf-8"))
        draft["local_validation"]["passed"] = False
        fixture.write_json(path, draft)
        result = self.build()
        self.assertEqual(result.returncode, 1)
        self.assertIn("has not passed local evidence validation", result.stderr)

    def test_a_sealed_id_in_the_rendered_text_stops_the_packet(self):
        case_id = self.development[0]
        case_path = self.benchmark_root / repair.CASE_DIRECTORY / "{}.json".format(case_id)
        case = json.loads(case_path.read_text(encoding="utf-8"))
        case["source"]["topic"] = "예산 심사 {}".format(self.sealed_ids()[0])
        fixture.write_json(case_path, case)
        result = self.build()
        self.assertEqual(result.returncode, 1)
        self.assertIn("packet names sealed cases", result.stderr)

    def test_a_machine_path_in_the_rendered_text_stops_the_packet(self):
        case_id = self.development[0]
        case_path = self.benchmark_root / repair.CASE_DIRECTORY / "{}.json".format(case_id)
        case = json.loads(case_path.read_text(encoding="utf-8"))
        case["source"]["topic"] = "/Users/reviewer/corpus 예산 심사"
        fixture.write_json(case_path, case)
        result = self.build()
        self.assertEqual(result.returncode, 1)
        self.assertIn("packet exposes machine paths", result.stderr)

    def test_a_stale_packet_is_archived_rather_than_overwritten(self):
        self.output.write_text("# 예전 패킷\n\n검수 흔적\n", encoding="utf-8")
        refused = self.build()
        self.assertEqual(refused.returncode, 1)
        self.assertIn("--replace-stale", refused.stderr)
        self.assertIn("예전 패킷", self.text())

        self.assertEqual(self.build("--replace-stale", output=self.benchmark_root / "DEVELOPMENT_REVIEW.md").returncode, 0)
        shutil.copy(self.output, self.benchmark_root / "DEVELOPMENT_REVIEW.md")
        self.output.write_text("# 예전 패킷\n\n검수 흔적\n", encoding="utf-8")
        self.assertEqual(self.build("--replace-stale").returncode, 0)
        archived = self.benchmark_root / packet.STALE_ARCHIVE_DIRECTORY / "packet.stale.md"
        self.assertTrue(archived.is_file())
        self.assertIn("검수 흔적", archived.read_text(encoding="utf-8"))
        self.assertIn(packet.PACKET_SCHEMA, self.text())

    def test_regenerating_over_its_own_packet_needs_no_flag(self):
        self.assertEqual(self.build().returncode, 0)
        result = self.build()
        self.assertEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["written"])


if __name__ == "__main__":
    unittest.main()
