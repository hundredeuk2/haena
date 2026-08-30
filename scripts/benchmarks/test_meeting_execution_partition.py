#!/usr/bin/env python3
"""Tests for the meeting-execution partition repair and its fail-closed validator.

Run with `python3 -m unittest discover -s scripts/benchmarks -p 'test_*.py'`.

Every fixture is synthetic. The tests reproduce the shape of the real defect — a corpus
whose 16/8 counts are correct while a suggested case is sealed and a development case has
no suggestion — so the negative controls fail for the same reason the real corpus did.
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import repair_meeting_execution_partition as repair  # noqa: E402  (import path is set above)

BENCHMARK_ROOT = Path(__file__).resolve().parent
REPAIR_SCRIPT = BENCHMARK_ROOT / "repair_meeting_execution_partition.py"
VALIDATE_SCRIPT = BENCHMARK_ROOT / "validate_meeting_execution_partition.py"

DEVELOPMENT_BEFORE = [
    "MEV0-001", "MEV0-005", "MEV0-006", "MEV0-007", "MEV0-008", "MEV0-010", "MEV0-011",
    "MEV0-012", "MEV0-014", "MEV0-015", "MEV0-016", "MEV0-018", "MEV0-019", "MEV0-020",
    "MEV0-023", "MEV0-024",
]
SEALED_BEFORE = [
    "MEV0-002", "MEV0-003", "MEV0-004", "MEV0-009", "MEV0-013", "MEV0-017", "MEV0-021",
    "MEV0-022",
]
# The stale suggestion set: generated before the holdout swap, so it names a sealed case
# and omits a development one.
SUGGESTIONS = sorted(set(DEVELOPMENT_BEFORE) - {"MEV0-001"} | {"MEV0-004"})
STRATUM = {"media": "기타 녹음", "type": "회의", "domain": "경제"}
UNUSED_SOURCE_IDS = ["UNU-001", "UNU-002", "UNU-003"]


def label_payload(source_id, topic):
    """A recording that satisfies the window rule: 300s, four speakers, B speaking often."""
    speakers = ["S1", "S2", "S3", "S4"]
    utterances = [
        {
            "id": "U{}".format(index),
            "start": index * 5.0,
            "end": index * 5.0 + 5.0,
            "speaker_id": speakers[index % len(speakers)],
            "form": "회의 진행 발화 {} 준비 부탁드립니다 내일까지".format(index),
            "environment": "",
        }
        for index in range(60)
    ]
    return {
        "metadata": dict(STRATUM, title=source_id, topic=topic, year=2021),
        "utterance": utterances,
    }


def corpus_row(source_id, topic, label_path):
    return {
        "source_id": source_id,
        "label_path": label_path,
        "audio_path": None,
        "metadata": dict(STRATUM, title=source_id, topic=topic, year=2021),
        "duration_seconds": 300.0,
        "speaker_count_observed": 4,
        "utterance_count": 60,
        "unknown_speaker_utterance_count": 0,
        "environment_coverage_ratio": 0.0,
        "topic_family": topic,
    }


def case_document(case_id, split, review_focus):
    index = int(case_id.split("-")[1])
    return {
        "schema_version": repair.SCHEMA_VERSION,
        "benchmark": repair.BENCHMARK,
        "case_id": case_id,
        "split": split,
        "review_status": repair.REVIEW_STATUS,
        "review_focus": review_focus,
        "target_speaker": "B",
        "source": dict(
            STRATUM,
            source_id="SRC-{:03d}".format(index),
            label_path="labels/SRC-{:03d}.json".format(index),
            topic="FAM-{:03d}".format(index),
            topic_family="FAM-{:03d}".format(index),
            prior_source_id=None,
        ),
        "window": {"source_start_seconds": 0.0, "source_end_seconds": 300.0, "duration_seconds": 300.0},
        "speaker_mapping": {"S1": "A", "S2": "B"},
        "features": {"speaker_mapping": {"S1": "A", "S2": "B"}, "active_speaker_count": 4},
        "heuristic_selection_signals_not_gold": {"action_keyword_hits": 1},
        "transcript": [{"utterance_id": "U0", "text_normalized": "봉인된 내용"}],
        "prior_state": None,
        "gold": {"status": repair.REVIEW_STATUS, "decisions": None, "reviewer_notes": ""},
    }


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(repair.jsonl_text(rows), encoding="utf-8")


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(repair.json_text(value), encoding="utf-8")


def build_fixture(root, *, unused_source_ids=UNUSED_SOURCE_IDS):
    """Create a corpus with the real defect and a source root that can materialize a fix."""
    corpus_root = root / "corpus"
    source_root = root / "source"
    benchmark_root = corpus_root / repair.BENCHMARK
    case_root = benchmark_root / repair.CASE_DIRECTORY

    split_by_id = {case_id: "development" for case_id in DEVELOPMENT_BEFORE}
    split_by_id.update({case_id: "sealed_holdout" for case_id in SEALED_BEFORE})
    documents = {
        case_id: case_document(case_id, split, "explicit_single_output")
        for case_id, split in split_by_id.items()
    }
    for case_id, document in documents.items():
        write_json(case_root / "{}.json".format(case_id), document)
    write_jsonl(benchmark_root / "manifest.jsonl", [documents[case_id] for case_id in sorted(documents)])
    write_jsonl(
        benchmark_root / "source-index.jsonl",
        [repair.index_row(case_id, split_by_id[case_id]) for case_id in sorted(split_by_id)],
    )

    for case_id in SUGGESTIONS:
        write_json(
            benchmark_root / "drafts" / "{}.model-suggestion.json".format(case_id),
            {"schema_version": "haena-meeting-execution-draft-v0.2", "case_id": case_id},
        )
    write_json(
        benchmark_root / "drafts" / "draft-validation-report.json",
        {"case_count": len(SUGGESTIONS), "results": [{"case_id": case_id} for case_id in SUGGESTIONS]},
    )
    (benchmark_root / "DEVELOPMENT_REVIEW.md").write_text(
        "\n".join("# {}".format(case_id) for case_id in SUGGESTIONS), encoding="utf-8"
    )

    rows = [
        corpus_row(
            "SRC-{:03d}".format(int(case_id.split("-")[1])),
            "FAM-{:03d}".format(int(case_id.split("-")[1])),
            "labels/SRC-{:03d}.json".format(int(case_id.split("-")[1])),
        )
        for case_id in sorted(split_by_id)
    ]
    for source_id in unused_source_ids:
        topic = "FREE-{}".format(source_id)
        label_path = "labels/{}.json".format(source_id)
        rows.append(corpus_row(source_id, topic, label_path))
        write_json(source_root / label_path, label_payload(source_id, topic))
    write_jsonl(corpus_root / "source-index.jsonl", rows)

    write_json(corpus_root / "build-report.json", {
        "schema_version": repair.SCHEMA_VERSION,
        "network_calls": 0,
        "meeting_execution": {
            "case_count": 24,
            "split_counts": {"development": 16, "sealed_holdout": 8},
            "focus_counts": {"explicit_single_output": 24},
        },
        # The only surviving record that MEV0-001 was itself exposed.
        "metadata_only_holdout_replacements": {
            "meeting_execution": [
                {"exposed_case_id": "MEV0-001", "replacement_case_id": "MEV0-004"}
            ]
        },
    })
    return corpus_root, source_root


def run(script, *args):
    return subprocess.run(
        [sys.executable, str(script), *args], capture_output=True, text=True, check=False
    )


def hash_tree(root):
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in sorted(root.rglob("*")) if path.is_file()
    }


class PartitionRepairTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.corpus_root, self.source_root = build_fixture(self.root)

    def repair(self, corpus_root=None):
        return run(
            REPAIR_SCRIPT,
            "--output-root", str(corpus_root or self.corpus_root),
            "--source-root", str(self.source_root),
        )

    def validate(self, corpus_root=None):
        return run(VALIDATE_SCRIPT, "--output-root", str(corpus_root or self.corpus_root))

    def report(self, corpus_root=None):
        path = (corpus_root or self.corpus_root) / repair.BENCHMARK / repair.REPAIR_REPORT_NAME
        return json.loads(path.read_text(encoding="utf-8"))

    def index_split(self, corpus_root=None):
        rows = repair.read_jsonl((corpus_root or self.corpus_root) / repair.BENCHMARK / "source-index.jsonl")
        return {row["case_id"]: row["split"] for row in rows}

    def test_unrepaired_corpus_fails_validation_despite_correct_counts(self):
        result = self.validate()
        self.assertEqual(result.returncode, 1)
        self.assertIn("development IDs must equal the model suggestion IDs", result.stdout)
        self.assertIn("exposed cases are sealed: ['MEV0-004']", result.stdout)
        summary = json.loads(result.stdout[result.stdout.index("{"):])
        self.assertEqual(summary["development"], 16)
        self.assertEqual(summary["sealed_holdout"], 8)

    def test_repair_makes_development_equal_the_suggestion_set(self):
        self.assertEqual(self.repair().returncode, 0)
        split = self.index_split()
        development = sorted(case_id for case_id, value in split.items() if value == "development")
        self.assertEqual(development, SUGGESTIONS)

    def test_repair_retires_the_exposed_case_that_has_no_suggestion(self):
        self.assertEqual(self.repair().returncode, 0)
        self.assertNotIn("MEV0-001", self.index_split())
        archived = self.corpus_root / repair.BENCHMARK / repair.RETIRED_DIRECTORY / "MEV0-001.json"
        self.assertTrue(archived.is_file())
        document = json.loads(archived.read_text(encoding="utf-8"))
        self.assertEqual(document["split"], repair.RETIRED_STATUS)
        self.assertEqual(document["retirement"]["replaced_by_case_id"], "MEV0-025")
        self.assertFalse((self.corpus_root / repair.BENCHMARK / repair.CASE_DIRECTORY / "MEV0-001.json").is_file())

    def test_replacement_comes_from_the_unused_corpus_by_metadata_order(self):
        self.assertEqual(self.repair().returncode, 0)
        entry, = self.report()["replacements"]
        self.assertEqual(entry["new_case_id"], "MEV0-025")
        self.assertEqual(entry["source_id"], "UNU-001")  # lowest source_id in the stratum
        self.assertEqual(entry["stratum"], STRATUM)
        self.assertEqual(entry["candidate_pool_size"], len(UNUSED_SOURCE_IDS))
        self.assertEqual(self.index_split()["MEV0-025"], "sealed_holdout")

    def test_repair_keeps_the_sealed_holdout_at_eight_unexposed_cases(self):
        self.assertEqual(self.repair().returncode, 0)
        split = self.index_split()
        sealed = sorted(case_id for case_id, value in split.items() if value == "sealed_holdout")
        self.assertEqual(len(sealed), 8)
        self.assertFalse(set(sealed) & set(SUGGESTIONS))
        self.assertFalse(set(sealed) & set(self.report()["exposed_case_ids"]))

    def test_repaired_corpus_passes_validation(self):
        self.assertEqual(self.repair().returncode, 0)
        result = self.validate()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PASS", result.stdout)

    def test_selection_reads_no_sealed_payload(self):
        self.assertEqual(self.repair().returncode, 0)
        audit = self.report()["access_audit"]
        self.assertEqual(audit["sealed_case_payload_reads"], 0)
        self.assertEqual(audit["network_calls"], 0)
        self.assertEqual(audit["label_files_opened"], 1)

    def test_sealed_case_files_are_refused_outright(self):
        audit = repair.AccessAudit()
        sealed = self.corpus_root / repair.BENCHMARK / repair.CASE_DIRECTORY / "MEV0-002.json"
        audit.seal([sealed])
        with self.assertRaises(repair.SealedPayloadAccess):
            audit.open_document(sealed, kind="discovery_index")

    def test_case_metadata_projection_drops_the_payload(self):
        audit = repair.AccessAudit()
        sealed = self.corpus_root / repair.BENCHMARK / repair.CASE_DIRECTORY / "MEV0-002.json"
        projection = audit.open_case_metadata(sealed, sealed=True)
        self.assertEqual(set(projection) - set(repair.PROJECTION_KEYS), set())
        for key in ("transcript", "gold", "features", "heuristic_selection_signals_not_gold"):
            self.assertNotIn(key, projection)

    def test_label_files_stay_closed_until_selection_is_fixed(self):
        audit = repair.AccessAudit()
        with self.assertRaises(repair.SealedPayloadAccess):
            audit.open_label(self.source_root / "labels" / "UNU-001.json")

    def test_repeated_generation_is_byte_identical(self):
        second = self.root / "corpus-second"
        shutil.copytree(self.corpus_root, second)
        self.assertEqual(self.repair().returncode, 0)
        self.assertEqual(self.repair(second).returncode, 0)
        self.assertEqual(hash_tree(self.corpus_root), hash_tree(second))

    def test_repairing_a_repaired_corpus_changes_nothing(self):
        self.assertEqual(self.repair().returncode, 0)
        before = hash_tree(self.corpus_root)
        result = self.repair()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["changed"], [])
        self.assertEqual(hash_tree(self.corpus_root), before)

    def test_repair_refuses_when_the_stratum_has_no_unused_candidate(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        corpus_root, source_root = build_fixture(root, unused_source_ids=[])
        result = run(REPAIR_SCRIPT, "--output-root", str(corpus_root), "--source-root", str(source_root))
        self.assertEqual(result.returncode, 1)
        self.assertIn("no unexposed corpus candidate", result.stderr)

    def test_validator_refuses_a_replacement_that_is_itself_exposed(self):
        self.assertEqual(self.repair().returncode, 0)
        report_path = self.corpus_root / repair.BENCHMARK / repair.REPAIR_REPORT_NAME
        report = json.loads(report_path.read_text(encoding="utf-8"))
        report["replacements"][0]["new_case_id"] = "MEV0-004"  # an exposed, suggested case
        write_json(report_path, report)
        result = self.validate()
        self.assertEqual(result.returncode, 1)
        self.assertIn("replacement MEV0-004 is itself exposed", result.stdout)

    def test_validator_refuses_a_manifest_that_disagrees_with_the_index(self):
        self.assertEqual(self.repair().returncode, 0)
        manifest = self.corpus_root / repair.BENCHMARK / "manifest.jsonl"
        rows = repair.read_jsonl(manifest)
        for row in rows:
            if row["case_id"] == "MEV0-025":
                row["split"] = "development"
        manifest.write_text(repair.jsonl_text(rows), encoding="utf-8")
        result = self.validate()
        self.assertEqual(result.returncode, 1)
        self.assertIn("manifest and source index disagree on the split", result.stdout)

    def test_validator_refuses_a_case_file_that_disagrees_with_the_index(self):
        self.assertEqual(self.repair().returncode, 0)
        path = self.corpus_root / repair.BENCHMARK / repair.CASE_DIRECTORY / "MEV0-025.json"
        document = json.loads(path.read_text(encoding="utf-8"))
        document["split"] = "development"
        write_json(path, document)
        result = self.validate()
        self.assertEqual(result.returncode, 1)
        self.assertIn("case files and source index disagree on the split", result.stdout)

    def test_validator_refuses_a_retired_case_returning_to_the_partition(self):
        self.assertEqual(self.repair().returncode, 0)
        index_path = self.corpus_root / repair.BENCHMARK / "source-index.jsonl"
        rows = repair.read_jsonl(index_path)
        rows.append(repair.index_row("MEV0-001", "sealed_holdout"))
        index_path.write_text(repair.jsonl_text(sorted(rows, key=lambda row: row["case_id"])), encoding="utf-8")
        result = self.validate()
        self.assertEqual(result.returncode, 1)
        self.assertIn("MEV0-001", result.stdout)

    def test_plan_refuses_a_suggestion_set_that_is_not_sixteen(self):
        with self.assertRaises(repair.PartitionRepairError):
            repair.plan_partition(DEVELOPMENT_BEFORE + SEALED_BEFORE, SUGGESTIONS[:15], SUGGESTIONS)

    def test_plan_refuses_a_suggestion_naming_a_case_outside_the_partition(self):
        with self.assertRaises(repair.PartitionRepairError):
            repair.plan_partition(
                DEVELOPMENT_BEFORE + SEALED_BEFORE,
                SUGGESTIONS[:15] + ["MEV0-999"],
                SUGGESTIONS,
            )


if __name__ == "__main__":
    unittest.main()
