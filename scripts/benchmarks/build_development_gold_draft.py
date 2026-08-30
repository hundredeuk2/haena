#!/usr/bin/env python3
"""Materialize the canonical development gold draft from completed primary reviews.

Reads the sixteen reviews, applies the approved ambiguity taxonomy, and writes one draft
per case plus a privacy-safe audit summary. The reviews themselves are opened read-only and
never written; the original cases, their gold fields, and the model drafts are not touched
at all.

Determinism is a requirement, not a nicety: the same reviews must produce byte-identical
drafts no matter what order they are read in, because a later run has to be comparable to
this one. Nothing here is final gold — every draft carries
`primary_normalized_pending_secondary_review` and `scorer_ready: false`.
"""

import argparse
import hashlib
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ambiguity_taxonomy import AmbiguityTaxonomy, TaxonomyError  # noqa: E402
from development_gold_draft import (  # noqa: E402
    DRAFT_STATUS,
    NORMALIZATION_PENDING,
    SCHEMA_VERSION,
    GoldDraftError,
    project_case,
    validate_case,
)
from primary_review_contract import REVIEW_DIRECTORY  # noqa: E402
from repair_meeting_execution_partition import CASE_DIRECTORY, read_jsonl  # noqa: E402

DRAFT_DIRECTORY = "human-reviews/gold-draft"
AUDIT_NAME = "gold-draft-audit.json"


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--benchmark-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, help="default: <benchmark-root>")
    parser.add_argument("--taxonomy-config", type=Path, required=True)
    parser.add_argument(
        "--taxonomy-sha256",
        required=True,
        help="the approved config digest; a mismatch refuses the run",
    )
    return parser.parse_args()


def development_ids(benchmark_root):
    rows = read_jsonl(benchmark_root / "source-index.jsonl")
    return sorted(row["case_id"] for row in rows if row["split"] == "development")


def load_reviews(benchmark_root):
    """Read every completed review for a development case, and refuse anything else."""
    allowed = set(development_ids(benchmark_root))
    directory = benchmark_root / REVIEW_DIRECTORY
    loaded = {}
    for path in sorted(directory.glob("MEV0-*.review.json")):
        case_id = path.name.split(".")[0]
        if case_id not in allowed:
            raise GoldDraftError(
                "{} is not a development case; a draft is never built from a holdout".format(case_id)
            )
        raw = path.read_bytes()
        review = json.loads(raw.decode("utf-8"))
        if review.get("review_status") != "complete":
            raise GoldDraftError("{} review is not complete".format(case_id))
        loaded[case_id] = (review, hashlib.sha256(raw).hexdigest())
    return loaded


def classify_ambiguities(draft, table):
    for item in draft["ambiguities"]:
        item["taxonomy"] = table.classify(item["raw_kind"])
        item["normalization_status"] = NORMALIZATION_PENDING
    return draft


def json_text(value):
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def pending_assignee_fields(draft):
    return sum(
        1 for entries in draft["outputs"].values() for output in entries
        if output["assignee"]["normalization_status"] == NORMALIZATION_PENDING
    )


def main():
    args = parse_args()
    benchmark_root = args.benchmark_root.resolve()
    output_root = (args.output_root or benchmark_root).resolve()
    table = AmbiguityTaxonomy.load(args.taxonomy_config, args.taxonomy_sha256)

    reviews = load_reviews(benchmark_root)
    if not reviews:
        raise GoldDraftError("no completed reviews to normalize")

    drafts = {}
    errors = []
    for case_id in sorted(reviews):
        review, digest = reviews[case_id]
        draft = classify_ambiguities(project_case(review, digest), table)
        draft["ambiguity_taxonomy"] = {
            "schema_version": table.config["schema_version"],
            "mapping_version": table.config["mapping_version"],
            "config_sha256": table.digest,
        }
        errors.extend(validate_case(draft, review, digest))
        drafts[case_id] = draft
    if errors:
        raise GoldDraftError("; ".join(errors))

    directory = output_root / DRAFT_DIRECTORY
    directory.mkdir(parents=True, exist_ok=True)
    for case_id, draft in sorted(drafts.items()):
        (directory / "{}.gold-draft.json".format(case_id)).write_text(
            json_text(draft), encoding="utf-8"
        )

    taxonomy_counts = Counter(
        item["taxonomy"] for draft in drafts.values() for item in draft["ambiguities"]
    )
    audit = {
        "schema_version": "haena-gold-draft-audit-v0.1",
        "draft_schema_version": SCHEMA_VERSION,
        "status": DRAFT_STATUS,
        "ambiguity_taxonomy": {
            "schema_version": table.config["schema_version"],
            "mapping_version": table.config["mapping_version"],
            "config_sha256": table.digest,
        },
        "cases": [
            {
                "case_id": case_id,
                "source_contract_version": draft["source_contract_version"],
                "source_review_digest": draft["source_review_digest"],
                "draft_sha256": hashlib.sha256(
                    json_text(draft).encode("utf-8")
                ).hexdigest(),
                "outputs": {key: len(value) for key, value in sorted(draft["outputs"].items())},
                "excluded_candidates": len(draft["excluded_candidates"]),
                "forbidden_inferences": len(draft["forbidden_inferences"]),
                "ambiguities": len(draft["ambiguities"]),
                "reviewer_notes": sum(
                    1 for entries in list(draft["outputs"].values())
                    + [draft["excluded_candidates"]]
                    for entry in entries if entry["reviewer_note"] is not None
                ),
                "pending_assignee_fields": pending_assignee_fields(draft),
                "prior_status": draft["prior_transition"]["status"],
                "prior_scorer_eligible": draft["prior_transition"]["scorer_eligible"],
                "scorer_ready": draft["scorer_ready"],
                "secondary_review_complete": draft["secondary_review_complete"],
            }
            for case_id, draft in sorted(drafts.items())
        ],
    }
    audit["totals"] = {
        "cases": len(drafts),
        "outputs": sum(sum(c["outputs"].values()) for c in audit["cases"]),
        "excluded_candidates": sum(c["excluded_candidates"] for c in audit["cases"]),
        "forbidden_inferences": sum(c["forbidden_inferences"] for c in audit["cases"]),
        "ambiguities": sum(c["ambiguities"] for c in audit["cases"]),
        "reviewer_notes": sum(c["reviewer_notes"] for c in audit["cases"]),
        "pending_assignee_fields": sum(c["pending_assignee_fields"] for c in audit["cases"]),
        "scorer_eligible_prior_transitions": sum(
            1 for c in audit["cases"] if c["prior_scorer_eligible"]
        ),
        "taxonomy_distribution": dict(sorted(taxonomy_counts.items())),
        "network_calls": 0,
    }
    (directory / AUDIT_NAME).write_text(json_text(audit), encoding="utf-8")

    print(json.dumps({
        "mode": "development_gold_draft",
        "output": "{}/".format(DRAFT_DIRECTORY),
        "cases": len(drafts),
        "totals": audit["totals"],
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (GoldDraftError, TaxonomyError) as error:
        raise SystemExit("FAILED: {}".format(error))
