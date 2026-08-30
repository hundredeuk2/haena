#!/usr/bin/env python3
"""Create, record, validate, and summarize primary human reviews.

Four subcommands, each with one job:

* `template` writes an empty review, and only when none exists. An existing review is a
  person's work; overwriting it to "start clean" would silently destroy the only copy.
* `record` applies a decision document through the contract. It changes only the fields the
  document names, and refuses anything the contract cannot record exactly as stated.
* `validate` reads and judges, and writes nothing at all.
* `audit` produces the shareable summary: case IDs, statuses, counts, and digests. No
  transcript, no reviewer text, no gold.

Sealed cases are unreachable from every subcommand: the case ID is checked against the
development set in the discovery index before any file is opened.
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from primary_review_contract import (  # noqa: E402  (import path is set above)
    CATEGORIES,
    FLAG_VERDICTS,
    LEGACY_SCHEMA_VERSIONS,
    REVIEW_DIRECTORY,
    SCHEMA_VERSION,
    VERDICTS,
    ReviewContractError,
    apply_decisions,
    build_flag_entries,
    build_template,
    prior_transition_of,
    sha256_of,
    unresolved_fields,
)
from repair_meeting_execution_partition import (  # noqa: E402
    CASE_DIRECTORY,
    read_jsonl,
)

PACKET_NAME = "DEVELOPMENT_REVIEW.md"


class ReviewCommandError(RuntimeError):
    """A refusal that must stop the command rather than produce a partial review."""


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--benchmark-root", type=Path, required=True)
    sub = parser.add_subparsers(dest="command", required=True)

    template = sub.add_parser("template", help="create an empty review if none exists")
    template.add_argument("--case-id", required=True)

    record = sub.add_parser("record", help="apply a decision document")
    record.add_argument("--case-id", required=True)
    record.add_argument("--decisions", type=Path, required=True)

    migrate = sub.add_parser("migrate", help="move an untouched template to the current schema")
    migrate.add_argument("--case-id", required=True)

    validate = sub.add_parser("validate", help="judge one review or all of them")
    validate.add_argument("--case-id", action="append", default=[])

    audit = sub.add_parser("audit", help="write a privacy-safe summary")
    audit.add_argument("--case-id", action="append", default=[])
    audit.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def development_ids(benchmark_root):
    rows = read_jsonl(benchmark_root / "source-index.jsonl")
    return sorted(row["case_id"] for row in rows if row["split"] == "development")


def resolve_case(benchmark_root, case_id):
    """Refuse anything outside development before a single case file is opened."""
    development = development_ids(benchmark_root)
    if case_id not in development:
        raise ReviewCommandError(
            "{} is not a development case; primary review covers {} cases only".format(
                case_id, len(development)
            )
        )
    path = benchmark_root / CASE_DIRECTORY / "{}.json".format(case_id)
    return path, json.loads(path.read_text(encoding="utf-8"))


def review_path(benchmark_root, case_id):
    return benchmark_root / REVIEW_DIRECTORY / "{}.review.json".format(case_id)


def draft_of(benchmark_root, case_id):
    return json.loads(
        (benchmark_root / "drafts" / "{}.model-suggestion.json".format(case_id))
        .read_text(encoding="utf-8")
    )


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load_review(benchmark_root, case_id, case_path, case):
    """Load a review and refuse it if the evidence underneath it has moved."""
    path = review_path(benchmark_root, case_id)
    if not path.is_file():
        raise ReviewCommandError("{} has no review yet; run `template` first".format(case_id))
    review = json.loads(path.read_text(encoding="utf-8"))
    if review.get("schema_version") not in (SCHEMA_VERSION,) + LEGACY_SCHEMA_VERSIONS:
        raise ReviewCommandError("{} review is not a known primary-review schema".format(case_id))
    if review.get("case_id") != case_id:
        raise ReviewCommandError("{} review identifies as {}".format(case_id, review.get("case_id")))
    packet_sha = sha256_of(benchmark_root / PACKET_NAME)
    if review.get("packet_sha256") != packet_sha:
        raise ReviewCommandError(
            "{} review was taken against a different packet; regenerating the packet "
            "invalidates a review in progress".format(case_id)
        )
    if review.get("case_sha256") != sha256_of(case_path):
        raise ReviewCommandError("{} case file changed after the review started".format(case_id))
    if "review_flag_verdicts" not in review:
        # A review written before AI flags were judgeable gains the empty entries, never a
        # verdict. Backfilling structure is safe; backfilling a judgment would not be, so a
        # review that was complete now reads as unresolved until a person rules on them.
        review["review_flag_verdicts"] = build_flag_entries(draft_of(benchmark_root, case_id))
    return path, review


def command_template(args):
    case_path, case = resolve_case(args.benchmark_root, args.case_id)
    path = review_path(args.benchmark_root, args.case_id)
    if path.exists():
        raise ReviewCommandError(
            "{} already has a review; the recorder edits it, this command never replaces it".format(
                args.case_id
            )
        )
    draft = draft_of(args.benchmark_root, args.case_id)
    review = build_template(
        case, draft, sha256_of(args.benchmark_root / PACKET_NAME), sha256_of(case_path)
    )
    write_json(path, review)
    return {
        "command": "template",
        "case_id": args.case_id,
        "created": path.name,
        "candidates": len(review["candidate_verdicts"]),
        "unresolved": unresolved_fields(review),
    }


def is_untouched(review):
    """True when nothing a person decided has been recorded yet."""
    if any(entry.get("verdict") for entry in review.get("candidate_verdicts", [])):
        return False
    if any(entry.get("verdict") for entry in review.get("review_flag_verdicts", [])):
        return False
    if review.get("missing_items") or review.get("ambiguities"):
        return False
    if any(value is not None for value in (review.get("no_missing") or {}).values()):
        return False
    if (review.get("forbidden_inference") or {}).get("checked") is not None:
        return False
    if (review.get("transcript_coverage") or {}).get("full_window_reviewed") is not None:
        return False
    if review.get("explicit_user_confirmation") or review.get("reviewed_at"):
        return False
    return prior_transition_of(review) is None


def command_migrate(args):
    """Move an empty template forward. A review with judgment in it is never rewritten."""
    case_path, case = resolve_case(args.benchmark_root, args.case_id)
    path, review = load_review(args.benchmark_root, args.case_id, case_path, case)
    if review.get("schema_version") == SCHEMA_VERSION:
        return {"command": "migrate", "case_id": args.case_id, "migrated": False,
                "reason": "already {}".format(SCHEMA_VERSION)}
    if not is_untouched(review):
        raise ReviewCommandError(
            "{} already holds review decisions; migrating it would rewrite a person's work".format(
                args.case_id
            )
        )
    review["schema_version"] = SCHEMA_VERSION
    review.pop("prior_state_expectation", None)
    review["prior_transition"] = None
    write_json(path, review)
    return {
        "command": "migrate",
        "case_id": args.case_id,
        "migrated": True,
        "schema_version": SCHEMA_VERSION,
        "unresolved": len(unresolved_fields(review)),
    }


def command_record(args):
    case_path, case = resolve_case(args.benchmark_root, args.case_id)
    path, review = load_review(args.benchmark_root, args.case_id, case_path, case)
    decisions = json.loads(args.decisions.read_text(encoding="utf-8"))
    if decisions.get("case_id") not in (None, args.case_id):
        raise ReviewCommandError(
            "decision document is for {}, not {}".format(decisions.get("case_id"), args.case_id)
        )
    decisions.pop("case_id", None)
    prior = decisions.get("prior_transition") or {}
    reference = (prior.get("prior_reference") or {}) if isinstance(prior, dict) else {}
    if reference.get("prior_case_id") and reference["prior_case_id"] not in development_ids(args.benchmark_root):
        raise ReviewCommandError(
            "prior case {} is not a development case; a typed reference must point at one that "
            "exists".format(reference["prior_case_id"])
        )
    if "reviewed_at" not in decisions and decisions.get("review_status") == "complete":
        decisions["reviewed_at"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    updated = apply_decisions(review, decisions, case)
    write_json(path, updated)
    return {
        "command": "record",
        "case_id": args.case_id,
        "review_status": updated["review_status"],
        "applied": sorted(set(decisions) - {"reviewed_at"}),
        "unresolved": unresolved_fields(updated),
        "review_sha256": sha256_of(path),
    }


def judge(benchmark_root, case_id):
    case_path, case = resolve_case(benchmark_root, case_id)
    path, review = load_review(benchmark_root, case_id, case_path, case)
    known = {row["utterance_id"] for row in case.get("transcript", [])}
    errors = []
    cited = []
    for entry in review["candidate_verdicts"]:
        cited.extend(entry.get("evidence_utterance_ids") or [])
    for item in review["missing_items"]:
        cited.extend(item.get("evidence_utterance_ids") or [])
    for item in (review.get("forbidden_inference") or {}).get("items", []):
        cited.extend(item.get("evidence_utterance_ids") or [])
    prior = review.get("prior_state_expectation") or {}
    cited.extend(prior.get("evidence_utterance_ids") or [])
    dangling = sorted(set(cited) - known)
    if dangling:
        errors.append("{} cites utterances outside the case: {}".format(case_id, dangling))
    if review.get("reviewer_kind") != "human_user":
        errors.append("{} is not recorded as a human review".format(case_id))
    expected_flags = [entry["flag_key"] for entry in build_flag_entries(draft_of(benchmark_root, case_id))]
    recorded_flags = [entry["flag_key"] for entry in review.get("review_flag_verdicts", [])]
    if recorded_flags != expected_flags:
        errors.append(
            "{} flag verdicts do not cover the packet's flags: {} vs {}".format(
                case_id, recorded_flags, expected_flags
            )
        )
    coverage = review.get("transcript_coverage") or {}
    if coverage.get("full_window_reviewed") is True:
        ordered = [row["utterance_id"] for row in case.get("transcript", [])]
        if (
            coverage.get("first_utterance_id") != (ordered[0] if ordered else None)
            or coverage.get("last_utterance_id") != (ordered[-1] if ordered else None)
            or coverage.get("utterance_count") != len(ordered)
        ):
            errors.append(
                "{} claims full-window coverage of a window the case does not have".format(case_id)
            )
    unresolved = unresolved_fields(review)
    if review["review_status"] == "complete" and unresolved:
        errors.append("{} claims complete while unresolved: {}".format(case_id, unresolved))
    verdicts = {
        verdict: sum(1 for entry in review["candidate_verdicts"] if entry.get("verdict") == verdict)
        for verdict in VERDICTS
    }
    return {
        "case_id": case_id,
        "review_status": review["review_status"],
        "review_sha256": sha256_of(path),
        "packet_sha256": review["packet_sha256"],
        "case_sha256": review["case_sha256"],
        "case_file_unchanged": review["case_sha256"] == sha256_of(case_path),
        "candidates": len(review["candidate_verdicts"]),
        "verdicts": verdicts,
        "review_flags": len(review.get("review_flag_verdicts", [])),
        "flag_verdicts": {
            verdict: sum(
                1 for entry in review.get("review_flag_verdicts", [])
                if entry.get("verdict") == verdict
            )
            for verdict in FLAG_VERDICTS
        },
        "missing_items": len(review["missing_items"]),
        "no_missing": {category: review["no_missing"][category] for category in CATEGORIES},
        "forbidden_inferences": len((review.get("forbidden_inference") or {}).get("items", [])),
        "schema_version": review.get("schema_version"),
        "prior_state_status": (prior_transition_of(review) or {}).get("status"),
        "full_window_reviewed": coverage.get("full_window_reviewed") is True,
        "ambiguities": len(review.get("ambiguities") or []),
        "explicit_user_confirmation": bool(
            (review.get("explicit_user_confirmation") or {}).get("confirmed")
        ),
        "unresolved": unresolved,
        "errors": errors,
    }


def command_validate(args):
    targets = args.case_id or [
        path.name.split(".")[0]
        for path in sorted((args.benchmark_root / REVIEW_DIRECTORY).glob("*.review.json"))
    ]
    results = [judge(args.benchmark_root, case_id) for case_id in targets]
    errors = [error for result in results for error in result["errors"]]
    return {
        "command": "validate",
        "reviews": results,
        "passed": not errors,
        "network_calls": 0,
    }, errors


def command_audit(args):
    """The only artifact meant to leave this machine: identifiers and counts."""
    report, errors = command_validate(args)
    if errors:
        raise ReviewCommandError("refusing to summarize reviews that do not validate")
    summary = {
        "schema_version": "haena-primary-review-audit-v0.1",
        "packet_sha256": sha256_of(args.benchmark_root / PACKET_NAME),
        "cases": [
            {
                "case_id": result["case_id"],
                "review_status": result["review_status"],
                "review_sha256": result["review_sha256"],
                "case_sha256": result["case_sha256"],
                "candidates": result["candidates"],
                "verdicts": result["verdicts"],
                "review_flags": result["review_flags"],
                "flag_verdicts": result["flag_verdicts"],
                "missing_items": result["missing_items"],
                "forbidden_inferences": result["forbidden_inferences"],
                "prior_state_status": result["prior_state_status"],
                "full_window_reviewed": result["full_window_reviewed"],
                "ambiguities": result["ambiguities"],
                "explicit_user_confirmation": result["explicit_user_confirmation"],
                "unresolved": len(result["unresolved"]),
            }
            for result in report["reviews"]
        ],
    }
    summary["totals"] = {
        "cases": len(summary["cases"]),
        "complete": sum(1 for case in summary["cases"] if case["review_status"] == "complete"),
        "candidates": sum(case["candidates"] for case in summary["cases"]),
        "missing_items": sum(case["missing_items"] for case in summary["cases"]),
        "ambiguities": sum(case["ambiguities"] for case in summary["cases"]),
        "unresolved": sum(case["unresolved"] for case in summary["cases"]),
    }
    write_json(args.output, summary)
    return {"command": "audit", "output": args.output.name, "totals": summary["totals"]}


def main():
    args = parse_args()
    args.benchmark_root = args.benchmark_root.resolve()
    if args.command == "validate":
        report, errors = command_validate(args)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if errors:
            raise SystemExit(1)
        return
    handlers = {
        "template": command_template,
        "migrate": command_migrate,
        "record": command_record,
        "audit": command_audit,
    }
    print(json.dumps(handlers[args.command](args), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ReviewCommandError, ReviewContractError) as error:
        raise SystemExit("FAILED: {}".format(error))
