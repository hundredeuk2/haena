#!/usr/bin/env python3
"""Validate HAENA benchmark discovery metadata without opening sealed content."""

import argparse
import json
import re
from collections import Counter
from pathlib import Path, PurePosixPath


ALLOWED_BENCHMARK_INDEX_KEYS = {
    "case_id", "split", "benchmark", "schema_version", "review_status", "case_path"
}
EXPECTED_SPLITS = Counter({"development": 16, "sealed_holdout": 8})
EXPECTED_AUDIO_METRIC_SCOPE = {
    "cer",
    "speaker_count_error",
    "der",
    "speaker_attribution_accuracy",
    "target_speaker_b_f1",
    "speaker_attributed_cer",
    "real_time_factor",
}


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    return parser.parse_args()


def read_jsonl(path):
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def check_relative(path_value, label, errors):
    path = PurePosixPath(path_value)
    if path.is_absolute() or ".." in path.parts:
        errors.append("{} is not a safe relative path: {}".format(label, path_value))


def require(condition, message, errors):
    if not condition:
        errors.append(message)


def validate_benchmark_index(rows, benchmark, case_directory, expected_review_status, errors):
    require(len(rows) == 24, "{} source index count must be 24".format(benchmark), errors)
    require(
        Counter(row.get("split") for row in rows) == EXPECTED_SPLITS,
        "{} source index split must be 16/8".format(benchmark),
        errors,
    )
    require(
        all(set(row) == ALLOWED_BENCHMARK_INDEX_KEYS for row in rows),
        "{} source index must contain metadata-only allowed keys".format(benchmark),
        errors,
    )
    require(
        len({row.get("case_id") for row in rows}) == len(rows),
        "{} case IDs must be unique".format(benchmark),
        errors,
    )
    for row in rows:
        require(row.get("benchmark") == benchmark, "benchmark identifier mismatch", errors)
        require(row.get("schema_version") == "haena-benchmark-v0.1", "schema version mismatch", errors)
        require(row.get("review_status") == expected_review_status, "review status mismatch", errors)
        case_id = row.get("case_id", "")
        require(
            bool(re.fullmatch(r"[A-Za-z0-9._-]{1,80}", case_id)),
            "case ID is not a bounded ASCII identifier",
            errors,
        )
        case_path = row.get("case_path", "")
        check_relative(case_path, "{} case path".format(benchmark), errors)
        require(
            case_path == "{}/{}.json".format(case_directory, case_id),
            "{} case path does not match its case ID".format(benchmark),
            errors,
        )


def validate_authorized_audio_metric_scopes(output_root, audio_index, errors):
    """Open only development gold after index authorization and validate the exact v0 scope."""
    for row in audio_index:
        if row.get("split") != "development":
            continue
        case_path = PurePosixPath(row["case_path"])
        gold_path = output_root / "audio-robustness-v0" / case_path
        gold = json.loads(gold_path.read_text(encoding="utf-8"))
        scope = gold.get("gold", {}).get("metric_scope")
        require(isinstance(scope, list), "development audio metric_scope must be an array", errors)
        if not isinstance(scope, list):
            continue
        require(
            len(scope) == len(EXPECTED_AUDIO_METRIC_SCOPE),
            "development audio metric_scope must contain seven unique metrics",
            errors,
        )
        require(
            len(set(scope)) == len(scope),
            "development audio metric_scope must not contain duplicates",
            errors,
        )
        require(
            set(scope) == EXPECTED_AUDIO_METRIC_SCOPE,
            "development audio metric_scope does not match the v0 contract",
            errors,
        )


def validate_meeting_holdout_provenance(output_root, meeting_by_id, report, errors):
    """Check the meeting holdout against whichever ledger is currently authoritative.

    The original build recorded one metadata-only swap. A later partition repair supersedes
    it, because the swap sealed a case the drafts had already exposed. Naming either set of
    case IDs inline would just re-freeze one of them, so the expectation is read from the
    ledger that exists.
    """
    repair_path = output_root / "meeting-execution-v0" / "partition-repair-report.json"
    if repair_path.is_file():
        repair = json.loads(repair_path.read_text(encoding="utf-8"))
        for case_id in repair.get("retired_case_ids", []):
            require(
                case_id not in meeting_by_id,
                "retired case {} is still in the partition".format(case_id),
                errors,
            )
        for entry in repair.get("replacements", []):
            require(
                meeting_by_id.get(entry.get("new_case_id"), {}).get("split") == "sealed_holdout",
                "replacement {} must be sealed".format(entry.get("new_case_id")),
                errors,
            )
        return
    for entry in report.get("metadata_only_holdout_replacements", {}).get("meeting_execution", []):
        require(
            meeting_by_id.get(entry.get("exposed_case_id"), {}).get("split") == "development",
            "exposed case {} must not be sealed".format(entry.get("exposed_case_id")),
            errors,
        )
        require(
            meeting_by_id.get(entry.get("replacement_case_id"), {}).get("split") == "sealed_holdout",
            "meeting replacement split mismatch",
            errors,
        )


def main():
    args = parse_args()
    output_root = args.output_root.resolve()
    errors = []

    report = json.loads((output_root / "build-report.json").read_text(encoding="utf-8"))
    index = read_jsonl(output_root / "source-index.jsonl")
    meeting_index = read_jsonl(output_root / "meeting-execution-v0" / "source-index.jsonl")
    audio_index = read_jsonl(output_root / "audio-robustness-v0" / "source-index.jsonl")

    require(len(index) == report["source_index_count"], "source index count mismatch", errors)
    require(len({row["source_id"] for row in index}) == len(index), "source IDs are not unique", errors)
    for row in index:
        check_relative(row["label_path"], "label_path", errors)
        if row["audio_path"]:
            check_relative(row["audio_path"], "audio_path", errors)

    validate_benchmark_index(
        meeting_index, "meeting-execution-v0", "cases", "human_review_pending", errors
    )
    validate_benchmark_index(
        audio_index, "audio-robustness-v0", "gold", "source_aligned_label", errors
    )
    meeting_by_id = {row["case_id"]: row for row in meeting_index}
    audio_by_id = {row["case_id"]: row for row in audio_index}
    validate_meeting_holdout_provenance(output_root, meeting_by_id, report, errors)
    require(audio_by_id.get("ARV0-001", {}).get("split") == "development", "ARV0-001 must be development", errors)
    require(audio_by_id.get("ARV0-002", {}).get("split") == "sealed_holdout", "audio replacement split mismatch", errors)
    validate_authorized_audio_metric_scopes(output_root, audio_index, errors)

    policy = report.get("data_policy", {})
    quality = report.get("quality_profile", {})
    require(quality.get("duplicate_source_id_count") == 0, "duplicate source IDs reported", errors)
    require(quality.get("labels_without_utterances") == 0, "empty labels reported", errors)
    require(quality.get("utterances_with_invalid_time_order") == 0, "invalid utterance time order reported", errors)
    require(quality.get("public_broadcast_label_count") == quality.get("public_broadcast_audio_match_count"), "broadcast label/audio matching is incomplete", errors)
    require(policy.get("storage") == "local_only", "data policy must be local_only", errors)
    require(policy.get("git_commit_allowed") is False, "data policy must forbid commit", errors)
    require(policy.get("external_provider_upload_allowed") is False, "data policy must forbid external upload", errors)
    require(report.get("network_calls") == 0, "build must make zero network calls", errors)

    if errors:
        print("FAILED: {} validation error(s)".format(len(errors)))
        for error in errors[:100]:
            print("- " + error)
        raise SystemExit(1)
    print("PASS: metadata-only discovery indexes contain 16 development / 8 sealed holdout cases each.")


if __name__ == "__main__":
    main()
