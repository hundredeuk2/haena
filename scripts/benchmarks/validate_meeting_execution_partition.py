#!/usr/bin/env python3
"""Fail closed on any meeting-execution partition that a model has already seen.

The v0 corpus proved that 16/8 counts can be correct while the partition is wrong: the
holdout swap ran after the drafts were generated, so a sealed case had a suggestion and a
development case had none. Counting is therefore not a check. Every assertion here is about
identity — which case IDs are in which half, and which of them something has already
looked at.

Like the repair itself, this reads sealed cases only through a projection that drops
transcript, gold, features, and heuristic signals, and it reports the resulting payload
read count so the claim is a measurement rather than a promise.
"""

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from repair_meeting_execution_partition import (  # noqa: E402  (import path is set above)
    BENCHMARK,
    CASE_DIRECTORY,
    CASE_ID_PATTERN,
    DEVELOPMENT_COUNT,
    REPAIR_REPORT_NAME,
    RETIRED_DIRECTORY,
    RETIRED_STATUS,
    REVIEW_STATUS,
    SEALED_COUNT,
    AccessAudit,
    discover_exposure,
    raw_lines,
    read_jsonl,
    recorded_prior_exposure,
)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output-root", type=Path, required=True, help="haena-v0 corpus root")
    return parser.parse_args()


def require(condition, message, errors):
    if not condition:
        errors.append(message)


def main():
    args = parse_args()
    corpus_root = args.output_root.resolve()
    benchmark_root = corpus_root / BENCHMARK
    case_root = benchmark_root / CASE_DIRECTORY
    retired_root = benchmark_root / RETIRED_DIRECTORY
    errors = []

    audit = AccessAudit()
    index_rows = read_jsonl(benchmark_root / "source-index.jsonl")
    audit.counts["discovery_index"] += 1
    index_split = {row["case_id"]: row["split"] for row in index_rows}
    development = sorted(case_id for case_id, split in index_split.items() if split == "development")
    sealed = sorted(case_id for case_id, split in index_split.items() if split == "sealed_holdout")

    evidence = discover_exposure(benchmark_root, audit)
    evidence["recorded_prior_exposure"] = recorded_prior_exposure(corpus_root, benchmark_root, audit)
    suggestions = sorted(evidence["model_suggestion"])
    exposed = sorted({case_id for ids in evidence.values() for case_id in ids})

    # 1. Cardinality. Kept last in importance on purpose: it is the check that passed while
    #    the partition was broken.
    require(len(index_rows) == DEVELOPMENT_COUNT + SEALED_COUNT, "partition must hold 24 cases", errors)
    require(len(development) == DEVELOPMENT_COUNT, "development must hold 16 cases", errors)
    require(len(sealed) == SEALED_COUNT, "sealed holdout must hold 8 cases", errors)
    require(len(index_split) == len(index_rows), "case IDs must be unique in the source index", errors)

    # 2. Identity. Development is reviewable only if every one of its cases has a suggestion,
    #    and the holdout is a holdout only if none of them does.
    require(suggestions == development, "development IDs must equal the model suggestion IDs", errors)
    require(not set(suggestions) & set(sealed), "a suggested case is sealed", errors)
    require(not set(development) & set(sealed), "development and sealed overlap", errors)
    leaked = sorted(set(exposed) & set(sealed))
    require(not leaked, "exposed cases are sealed: {}".format(leaked), errors)

    # 3. Agreement across the three places a split is written down.
    manifest_split = {}
    for line in raw_lines(benchmark_root / "manifest.jsonl"):
        case_id, split = audit.identity_of_line(line)
        manifest_split[case_id] = split
    require(manifest_split == index_split, "manifest and source index disagree on the split", errors)

    case_files = sorted(path.stem for path in case_root.glob("MEV0-*.json"))
    require(
        case_files == sorted(index_split),
        "the case directory must hold exactly the partition: {}".format(
            sorted(set(case_files) ^ set(index_split))
        ),
        errors,
    )
    case_split = {}
    provenance = Counter()
    families = Counter()
    for case_id in sorted(index_split):
        path = case_root / "{}.json".format(case_id)
        if not path.is_file():
            continue
        projection = audit.open_case_metadata(path, sealed=index_split[case_id] == "sealed_holdout")
        case_split[case_id] = projection.get("split")
        require(
            projection.get("review_status") == REVIEW_STATUS,
            "{} must still be pending human review".format(case_id),
            errors,
        )
        source = projection.get("source", {})
        provenance[source.get("source_id")] += 1
        families[source.get("topic_family")] += 1
        if source.get("prior_source_id"):
            provenance[source["prior_source_id"]] += 1
    require(case_split == index_split, "case files and source index disagree on the split", errors)

    # 4. Provenance. A replacement drawn from the corpus must not duplicate a source or a
    #    topic family already in the partition, or the two cases stop being independent.
    duplicates = sorted(key for key, count in provenance.items() if count > 1)
    require(not duplicates, "sources are claimed by more than one case: {}".format(duplicates), errors)
    duplicate_families = sorted(key for key, count in families.items() if count > 1)
    require(
        not duplicate_families,
        "topic families are claimed by more than one case: {}".format(duplicate_families),
        errors,
    )

    # 5. The repair ledger, and the trap that matters most: an exposed case must not come
    #    back as a replacement under a new identity or an old one.
    report_path = benchmark_root / REPAIR_REPORT_NAME
    if report_path.is_file():
        report = audit.open_document(report_path, kind="discovery_index")
        for entry in report.get("replacements", []):
            new_id = entry.get("new_case_id")
            require(
                new_id not in exposed,
                "replacement {} is itself exposed".format(new_id),
                errors,
            )
            require(
                new_id in sealed,
                "replacement {} is not in the sealed holdout".format(new_id),
                errors,
            )
            require(
                entry.get("vacancy_case_id") not in index_split,
                "retired case {} is still in the partition".format(entry.get("vacancy_case_id")),
                errors,
            )
        for case_id in report.get("retired_case_ids", []):
            require(
                CASE_ID_PATTERN.fullmatch(str(case_id)) is not None,
                "retired case ID is malformed: {}".format(case_id),
                errors,
            )
            path = retired_root / "{}.json".format(case_id)
            require(path.is_file(), "retired case {} was not archived".format(case_id), errors)
            if not path.is_file():
                continue
            archived = audit.open_document(path, kind="retired_case")
            require(
                archived.get("split") == RETIRED_STATUS,
                "retired case {} is not marked retired".format(case_id),
                errors,
            )
            require(
                case_id not in index_split,
                "retired case {} is still in the partition".format(case_id),
                errors,
            )

    summary = {
        "development": len(development),
        "sealed_holdout": len(sealed),
        "suggestions_equal_development": suggestions == development,
        "exposed_case_ids": len(exposed),
        "exposed_in_sealed": len(leaked),
        "access_audit": audit.as_report(),
    }
    if errors:
        print("FAILED: {} partition error(s)".format(len(errors)))
        for error in errors:
            print("- " + error)
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        raise SystemExit(1)
    print("PASS: 16 development / 8 unexposed sealed; development IDs equal the suggestion IDs.")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
