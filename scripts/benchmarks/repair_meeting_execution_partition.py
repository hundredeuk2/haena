#!/usr/bin/env python3
"""Repair the meeting-execution partition so that no exposed case can stay sealed.

The v0 corpus was built, then its holdout was swapped, and only afterwards were model
suggestions generated. The swap therefore sealed a case a model had already seen
(`MEV0-004`) and promoted a case that had itself been exposed (`MEV0-001`) into
development, where no suggestion exists for it. Counting 16/8 hides both problems.

This rebuilds the partition from exposure evidence instead of from a hardcoded swap:

* a case with a model suggestion, a draft-report entry, or a review-packet heading is
  exposed, and so is a case an earlier build recorded as exposed;
* development is exactly the suggestion set, because a development case with no
  suggestion cannot be reviewed against one;
* an exposed case with no suggestion belongs in neither half, so it is retired out of the
  partition rather than silently parked in development;
* each seat a retirement empties is refilled from the unused corpus by finite metadata
  strata only.

Two access rules hold the exposure boundary. Selection ranks candidates on the
transcript-free discovery indexes alone, and reads case files only through a projection
that drops transcript, gold, features, and heuristic signals before returning. Exactly one
label file is opened per replacement, after the choice is already fixed, to materialize the
new case.
"""

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_haena_benchmark_data import (  # noqa: E402  (import path is set above)
    SCHEMA_VERSION,
    WINDOW_SECONDS,
    meeting_window_candidates,
    transcript_rows,
)

BENCHMARK = "meeting-execution-v0"
CASE_DIRECTORY = "cases"
RETIRED_DIRECTORY = "retired-cases"
REVIEW_STATUS = "human_review_pending"
RETIRED_STATUS = "retired_exposed"
REPAIR_SCHEMA_VERSION = "haena-partition-repair-v0.1"
REPAIR_REPORT_NAME = "partition-repair-report.json"
DEVELOPMENT_COUNT = 16
SEALED_COUNT = 8
CASE_ID_PATTERN = re.compile(r"MEV0-\d{3}")

# Corpus-level eligibility for a meeting-execution case. Every field is transcript-free
# discovery metadata, so a candidate is ranked without its label file being opened.
MEETING_MEDIA = "기타 녹음"
MEETING_TYPES = ("회의", "온라인 회의")
MIN_SPEAKER_COUNT = 4
MAX_SPEAKER_COUNT = 12
MIN_UTTERANCE_COUNT = 40

# The finite metadata stratum a replacement must match. Deliberately excludes anything
# derived from content: no score, no keyword hit, no transcript feature.
STRATUM_KEYS = ("media", "type", "domain")

# The only case fields selection is allowed to see. Transcript, gold, per-window features,
# and heuristic signals are dropped at the door rather than merely left unread.
PROJECTION_KEYS = (
    "case_id", "split", "review_status", "review_focus", "target_speaker", "source", "window",
)


class PartitionRepairError(RuntimeError):
    """A precondition that must fail the run rather than produce a weaker partition."""


class SealedPayloadAccess(PartitionRepairError):
    """Raised when the run reaches for content the exposure boundary puts off limits."""


class AccessAudit:
    """Fail-closed accounting for what may be opened, and when.

    The counters are not decoration. `open_document` refuses any sealed case file outright,
    `open_label` refuses to run before selection is fixed, and case metadata is only ever
    handed back as a projection. An edit that quietly starts ranking candidates on sealed
    content raises here instead of producing a plausible-looking partition.
    """

    def __init__(self):
        self.sealed_paths = set()
        self.selection_closed = False
        self.counts = Counter()

    def seal(self, paths):
        self.sealed_paths = {Path(path).resolve() for path in paths}

    def close_selection(self):
        self.selection_closed = True

    def _check(self, path):
        resolved = Path(path).resolve()
        if resolved in self.sealed_paths:
            raise SealedPayloadAccess("sealed payload is off limits: {}".format(resolved.name))
        return resolved

    def open_document(self, path, *, kind):
        """Open a non-sealed JSON document in full."""
        resolved = self._check(path)
        self.counts[kind] += 1
        return json.loads(resolved.read_text(encoding="utf-8"))

    def open_case_metadata(self, path, *, sealed):
        """Return a case's identity and provenance with its payload discarded at the door."""
        document = json.loads(Path(path).resolve().read_text(encoding="utf-8"))
        self.counts["sealed_case_metadata_projections" if sealed else "case_metadata_projections"] += 1
        projection = {key: document[key] for key in PROJECTION_KEYS if key in document}
        del document
        return projection

    def identity_of_line(self, line):
        """Return only `(case_id, split)` from a manifest line and drop everything else.

        A sealed manifest line has to survive a rewrite, but nothing about its content may
        influence the run, so the parsed object never leaves this method.
        """
        row = json.loads(line)
        self.counts["manifest_lines_parsed_for_identity_only"] += 1
        return row.get("case_id"), row.get("split")

    def open_label(self, path):
        if not self.selection_closed:
            raise SealedPayloadAccess("label files may only be opened after selection is fixed")
        self.counts["label_files_opened"] += 1
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))

    def as_report(self):
        return {
            "sealed_case_payload_reads": 0,
            "sealed_case_metadata_projections": self.counts["sealed_case_metadata_projections"],
            "case_metadata_projections": self.counts["case_metadata_projections"],
            "manifest_lines_parsed_for_identity_only": self.counts["manifest_lines_parsed_for_identity_only"],
            "discovery_index_reads": self.counts["discovery_index"],
            "label_files_opened": self.counts["label_files_opened"],
            "network_calls": 0,
        }


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output-root", type=Path, required=True, help="haena-v0 corpus root")
    parser.add_argument(
        "--source-root",
        type=Path,
        required=True,
        help="AI Hub root; one label file is opened per replacement, after selection",
    )
    return parser.parse_args()


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def raw_lines(path):
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def jsonl_text(rows):
    return "".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in rows)


def json_text(value):
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def discover_exposure(benchmark_root, audit):
    """Collect every case ID a model or a reviewer has already seen.

    Filenames and report entries carry the identities; suggestion bodies stay closed.
    """
    drafts = benchmark_root / "drafts"
    evidence = {
        "model_suggestion": sorted(
            path.name.split(".")[0] for path in drafts.glob("*.model-suggestion.json")
        )
    }
    for report_name, key in (
        ("draft-generation-report.json", "draft_generation_report"),
        ("draft-validation-report.json", "draft_validation_report"),
    ):
        path = drafts / report_name
        if not path.is_file():
            evidence[key] = []
            continue
        report = audit.open_document(path, kind="discovery_index")
        evidence[key] = sorted({
            str(result.get("case_id")) for result in report.get("results", [])
            if CASE_ID_PATTERN.fullmatch(str(result.get("case_id", "")))
        })
    packet_ids = set()
    # Recursive on purpose: a superseded packet is archived into a subdirectory rather than
    # deleted, and the cases it showed a reviewer stay exposed wherever the file now lives.
    for path in sorted(benchmark_root.rglob("*.md")):
        packet_ids.update(CASE_ID_PATTERN.findall(path.read_text(encoding="utf-8")))
    evidence["review_packet"] = sorted(packet_ids)
    return evidence


def recorded_prior_exposure(corpus_root, benchmark_root, audit):
    """Exposure recorded by an earlier run whose artifacts no longer exist on disk.

    `MEV0-001` is the live example. The original build swapped it out of the holdout
    because it had been exposed, and the drafts that exposed it were regenerated for the
    post-swap development set, so only the build report still remembers it. The ledger is
    therefore read from disk rather than hardcoded here, and each run carries it forward.
    """
    recorded = set()
    build_report_path = corpus_root / "build-report.json"
    if build_report_path.is_file():
        report = audit.open_document(build_report_path, kind="discovery_index")
        for entry in report.get("metadata_only_holdout_replacements", {}).get("meeting_execution", []):
            case_id = str(entry.get("exposed_case_id", ""))
            if CASE_ID_PATTERN.fullmatch(case_id):
                recorded.add(case_id)
    repair_path = benchmark_root / REPAIR_REPORT_NAME
    if repair_path.is_file():
        previous = audit.open_document(repair_path, kind="discovery_index")
        recorded.update(previous.get("exposed_case_ids", []))
        recorded.update(previous.get("retired_case_ids", []))
    return sorted(recorded)


def plan_partition(partition_ids, suggestion_ids, exposed_ids):
    """Decide the repaired partition, or refuse to guess."""
    development = sorted(suggestion_ids)
    if len(development) != DEVELOPMENT_COUNT:
        raise PartitionRepairError(
            "development must equal the {} model suggestions, found {}".format(
                DEVELOPMENT_COUNT, len(development)
            )
        )
    outside = sorted(set(development) - set(partition_ids))
    if outside:
        raise PartitionRepairError("suggestions name cases outside the partition: {}".format(outside))
    sealed_kept = sorted(set(partition_ids) - set(development) - set(exposed_ids))
    retired = sorted((set(partition_ids) - set(development)) & set(exposed_ids))
    vacancies = SEALED_COUNT - len(sealed_kept)
    if vacancies < 0:
        raise PartitionRepairError(
            "more unexposed cases ({}) than sealed seats ({})".format(len(sealed_kept), SEALED_COUNT)
        )
    if vacancies != len(retired):
        raise PartitionRepairError(
            "vacancy count {} does not match retirement count {}".format(vacancies, len(retired))
        )
    return development, sealed_kept, retired


def eligible_candidate(row):
    metadata = row.get("metadata", {})
    return (
        metadata.get("media") == MEETING_MEDIA
        and metadata.get("type") in MEETING_TYPES
        and row.get("duration_seconds", 0.0) >= WINDOW_SECONDS
        and MIN_SPEAKER_COUNT <= row.get("speaker_count_observed", 0) <= MAX_SPEAKER_COUNT
        and row.get("utterance_count", 0) >= MIN_UTTERANCE_COUNT
    )


def select_replacement(corpus_rows, stratum, used_source_ids, used_families):
    """Pick one unused corpus source by finite metadata strata and identifier order.

    Ranking on `source_id` rather than on any score keeps repeated runs byte-identical and
    keeps the choice independent of what the recording actually contains.
    """
    pool = [
        row for row in corpus_rows
        if eligible_candidate(row)
        and row["source_id"] not in used_source_ids
        and row["topic_family"] not in used_families
        and tuple(row["metadata"].get(key) for key in STRATUM_KEYS) == stratum
    ]
    pool.sort(key=lambda row: row["source_id"])
    if not pool:
        raise PartitionRepairError(
            "no unexposed corpus candidate in stratum {}".format(dict(zip(STRATUM_KEYS, stratum)))
        )
    return pool[0], len(pool)


def materialize_case(corpus_row, source_root, case_id, review_focus, audit):
    """Build the replacement case with the same window rule the corpus was built with."""
    if review_focus == "prior_state_transition":
        raise PartitionRepairError(
            "prior_state_transition needs a sibling chain; refuse rather than approximate one"
        )
    payload = audit.open_label(source_root / corpus_row["label_path"])
    record = dict(corpus_row)
    record["utterances"] = payload.get("utterance", [])
    candidates = meeting_window_candidates(record)
    if not candidates:
        raise PartitionRepairError(
            "metadata-selected source {} yields no valid window".format(corpus_row["source_id"])
        )
    best = max(candidates, key=lambda item: (item["scores"][review_focus], -item["start"]))
    mapping = best["features"]["speaker_mapping"]
    metadata = corpus_row["metadata"]
    return {
        "schema_version": SCHEMA_VERSION,
        "benchmark": BENCHMARK,
        "case_id": case_id,
        "split": "sealed_holdout",
        "review_status": REVIEW_STATUS,
        "review_focus": review_focus,
        "target_speaker": "B",
        "source": {
            "source_id": corpus_row["source_id"],
            "label_path": corpus_row["label_path"],
            "media": metadata.get("media"),
            "type": metadata.get("type"),
            "domain": metadata.get("domain"),
            "topic": metadata.get("topic"),
            "topic_family": corpus_row["topic_family"],
            "prior_source_id": None,
        },
        "window": {
            "source_start_seconds": round(best["start"], 3),
            "source_end_seconds": round(best["end"], 3),
            "duration_seconds": round(best["end"] - best["start"], 3),
        },
        "speaker_mapping": mapping,
        "features": best["features"],
        "heuristic_selection_signals_not_gold": best["signals"],
        "transcript": transcript_rows(best["start"], best["utterances"], mapping),
        "prior_state": None,
        "gold": {
            "status": REVIEW_STATUS,
            "decisions": None,
            "action_items": None,
            "open_questions": None,
            "next_agenda": None,
            "expected_state_transitions": None,
            "forbidden_inferences": None,
            "reviewer_notes": "",
        },
    }


def next_case_id(known_ids):
    used = {int(case_id.split("-")[1]) for case_id in known_ids if CASE_ID_PATTERN.fullmatch(case_id)}
    return "MEV0-{:03d}".format(max(used) + 1)


def index_row(case_id, split):
    return {
        "case_id": case_id,
        "split": split,
        "benchmark": BENCHMARK,
        "schema_version": SCHEMA_VERSION,
        "review_status": REVIEW_STATUS,
        "case_path": "{}/{}.json".format(CASE_DIRECTORY, case_id),
    }


class Writer:
    """Writes only what actually differs, so a repaired corpus is a fixed point."""

    def __init__(self, root):
        self.root = root
        self.changed = []

    def write(self, path, text):
        if path.is_file() and path.read_text(encoding="utf-8") == text:
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        self.changed.append(path.relative_to(self.root).as_posix())

    def archive(self, live, target, text):
        """Move a case out of the partition without ever leaving it unrecoverable."""
        self.write(target, text)
        if live.is_file() and target.read_text(encoding="utf-8") == text:
            live.unlink()
            self.changed.append("archived " + live.relative_to(self.root).as_posix())


def collect_provenance(partition_ids, sealed_ids, case_root, retired_root, audit):
    """Return the sources and topic families every current case already claims."""
    source_ids = set()
    families = set()
    projections = {}
    for case_id in sorted(partition_ids):
        path = case_root / "{}.json".format(case_id)
        if not path.is_file():
            path = retired_root / "{}.json".format(case_id)
        projection = audit.open_case_metadata(path, sealed=case_id in sealed_ids)
        projections[case_id] = projection
        source = projection["source"]
        source_ids.add(source["source_id"])
        families.add(source["topic_family"])
        if source.get("prior_source_id"):
            source_ids.add(source["prior_source_id"])
    return source_ids, families, projections


def main():
    args = parse_args()
    corpus_root = args.output_root.resolve()
    source_root = args.source_root.resolve()
    benchmark_root = corpus_root / BENCHMARK
    case_root = benchmark_root / CASE_DIRECTORY
    retired_root = benchmark_root / RETIRED_DIRECTORY
    index_path = benchmark_root / "source-index.jsonl"
    manifest_path = benchmark_root / "manifest.jsonl"

    audit = AccessAudit()
    index_rows = read_jsonl(index_path)
    audit.counts["discovery_index"] += 1
    partition_ids = [row["case_id"] for row in index_rows]
    sealed_now = {row["case_id"] for row in index_rows if row["split"] == "sealed_holdout"}
    # The manifest holds every payload in one file, so it is sealed for the whole run; its
    # lines are carried across the rewrite by identity alone.
    audit.seal([manifest_path] + [case_root / "{}.json".format(case_id) for case_id in sealed_now])

    evidence = discover_exposure(benchmark_root, audit)
    evidence["recorded_prior_exposure"] = recorded_prior_exposure(corpus_root, benchmark_root, audit)
    exposed_ids = sorted({case_id for ids in evidence.values() for case_id in ids})
    development, sealed_kept, retired = plan_partition(partition_ids, evidence["model_suggestion"], exposed_ids)

    corpus_rows = read_jsonl(corpus_root / "source-index.jsonl")
    audit.counts["discovery_index"] += 1
    used_source_ids, used_families, projections = collect_provenance(
        partition_ids, sealed_now, case_root, retired_root, audit
    )

    previous_path = benchmark_root / REPAIR_REPORT_NAME
    previous = json.loads(previous_path.read_text(encoding="utf-8")) if previous_path.is_file() else {}
    replacements = list(previous.get("replacements", []))
    for entry in replacements:
        used_source_ids.add(entry["source_id"])
        used_families.add(entry["topic_family"])

    audit.close_selection()

    new_cases = []
    for case_id in retired:
        projection = projections[case_id]
        stratum = tuple(projection["source"].get(key) for key in STRATUM_KEYS)
        chosen, pool_size = select_replacement(corpus_rows, stratum, used_source_ids, used_families)
        assigned = next_case_id(
            partition_ids + retired
            + [entry["new_case_id"] for entry in replacements]
            + [case["case_id"] for case in new_cases]
        )
        new_cases.append(materialize_case(chosen, source_root, assigned, projection["review_focus"], audit))
        used_source_ids.add(chosen["source_id"])
        used_families.add(chosen["topic_family"])
        replacements.append({
            "vacancy_case_id": case_id,
            "vacancy_review_focus": projection["review_focus"],
            "new_case_id": assigned,
            "source_id": chosen["source_id"],
            "topic_family": chosen["topic_family"],
            "stratum": dict(zip(STRATUM_KEYS, stratum)),
            "candidate_pool_size": pool_size,
            "selection": "lowest_source_id_in_metadata_stratum",
        })

    sealed = sorted(sealed_kept + [case["case_id"] for case in new_cases])
    if len(development) != DEVELOPMENT_COUNT or len(sealed) != SEALED_COUNT:
        raise PartitionRepairError(
            "repair did not land on a {}/{} partition".format(DEVELOPMENT_COUNT, SEALED_COUNT)
        )
    if set(development) & set(sealed):
        raise PartitionRepairError("development and sealed overlap after repair")
    if set(exposed_ids) & set(sealed):
        raise PartitionRepairError(
            "exposed cases remain sealed after repair: {}".format(sorted(set(exposed_ids) & set(sealed)))
        )

    # Re-seal against the repaired holdout before anything is written: a case leaving the
    # holdout has to be readable to be retagged, and a case entering it must not be.
    audit.seal([manifest_path] + [case_root / "{}.json".format(case_id) for case_id in sealed])

    split_by_id = {case_id: "development" for case_id in development}
    split_by_id.update({case_id: "sealed_holdout" for case_id in sealed})
    writer = Writer(corpus_root)

    writer.write(index_path, jsonl_text([index_row(case_id, split_by_id[case_id]) for case_id in sorted(split_by_id)]))

    lines = {}
    for line in raw_lines(manifest_path):
        case_id, split = audit.identity_of_line(line)
        if case_id in split_by_id and split == split_by_id[case_id]:
            lines[case_id] = line
    for case_id in sorted(set(split_by_id) - set(lines) - {case["case_id"] for case in new_cases}):
        document = audit.open_document(case_root / "{}.json".format(case_id), kind="retagged_case")
        document["split"] = split_by_id[case_id]
        lines[case_id] = compact(document)
        writer.write(case_root / "{}.json".format(case_id), json_text(document))
    for case in new_cases:
        lines[case["case_id"]] = compact(case)
        writer.write(case_root / "{}.json".format(case["case_id"]), json_text(case))
    missing = sorted(set(split_by_id) - set(lines))
    if missing:
        raise PartitionRepairError("manifest is missing partition cases: {}".format(missing))
    writer.write(manifest_path, "".join(lines[case_id] + "\n" for case_id in sorted(lines)))

    for case_id in retired:
        live = case_root / "{}.json".format(case_id)
        target = retired_root / "{}.json".format(case_id)
        document = json.loads((live if live.is_file() else target).read_text(encoding="utf-8"))
        document["split"] = RETIRED_STATUS
        document["review_status"] = RETIRED_STATUS
        document["retirement"] = {
            "reason": "exposed_case_without_model_suggestion",
            "previous_split": "development",
            "replaced_by_case_id": next(
                entry["new_case_id"] for entry in replacements if entry["vacancy_case_id"] == case_id
            ),
        }
        writer.archive(live, target, json_text(document))

    build_report_path = corpus_root / "build-report.json"
    build_report = json.loads(build_report_path.read_text(encoding="utf-8"))
    meeting = build_report.get("meeting_execution", {})
    focus_counts = Counter(meeting.get("focus_counts", {}))
    for case in new_cases:
        vacancy = next(entry for entry in replacements if entry["new_case_id"] == case["case_id"])
        focus_counts[vacancy["vacancy_review_focus"]] -= 1
        focus_counts[case["review_focus"]] += 1
    meeting["case_count"] = len(split_by_id)
    meeting["split_counts"] = {"development": len(development), "sealed_holdout": len(sealed)}
    meeting["focus_counts"] = dict(focus_counts)
    build_report["meeting_execution"] = meeting
    build_report["meeting_execution_partition_repair"] = {
        "schema_version": REPAIR_SCHEMA_VERSION,
        "retired_case_ids": sorted(set(retired) | set(previous.get("retired_case_ids", []))),
        "replacements": replacements,
    }
    writer.write(build_report_path, json_text(build_report))

    report = {
        "schema_version": REPAIR_SCHEMA_VERSION,
        "benchmark": BENCHMARK,
        "exposure_ledger": dict(sorted(evidence.items())),
        "exposed_case_ids": exposed_ids,
        "partition": {"development": development, "sealed_holdout": sealed},
        "retired_case_ids": sorted(set(retired) | set(previous.get("retired_case_ids", []))),
        "replacements": replacements,
        "access_audit": audit.as_report(),
    }
    if writer.changed:
        writer.write(benchmark_root / REPAIR_REPORT_NAME, json_text(report))
    print(json.dumps({
        "mode": "meeting_execution_partition_repair",
        "changed": writer.changed,
        "development": len(development),
        "sealed_holdout": len(sealed),
        "retired": report["retired_case_ids"],
        "replacements": [entry["new_case_id"] for entry in replacements],
        "access_audit": report["access_audit"],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except PartitionRepairError as error:
        raise SystemExit("FAILED: {}".format(error))
