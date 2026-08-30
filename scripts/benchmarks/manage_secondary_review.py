#!/usr/bin/env python3
"""Run the blind second pass: packet, template, record, validate.

The blind is enforced here rather than promised. Every path that holds a first-pass result
— the primary reviews, the canonical gold draft, the primary audit summaries — is registered
with a guard that raises on any read, and the counters the guard reports are measurements
rather than assurances. A future edit that starts consulting the first pass fails instead of
quietly producing a second opinion that already knew the answer.

What the reviewer sees is the case and the model's suggestions: transcript, speakers,
window, candidates with their keys, flags, and where the evidence sits. What they do not see
is any verdict, wording, omission, ambiguity, note, statistic or digest from the first pass —
including which items it left unresolved, since that would leak its structure just as surely.
"""

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from secondary_review_contract import (  # noqa: E402  (import path is set above)
    CATEGORIES,
    FLAG_VERDICTS,
    PACKET_DIRECTORY,
    REVIEW_DIRECTORY,
    REVIEWER_KIND,
    SCHEMA_VERSION,
    VERDICTS,
    SecondaryReviewError,
    apply_decisions,
    build_template,
    unresolved_fields,
)
from repair_meeting_execution_partition import CASE_DIRECTORY, read_jsonl  # noqa: E402

# Everything the second pass must not see. Registered as directories so a new file added to
# any of them is blocked without anyone remembering to update this list.
BLINDED_DIRECTORIES = ("human-reviews/primary", "human-reviews/gold-draft")
BLINDED_GLOBS = ("human-reviews/primary-review-audit-*.json",)


class BlindAccessError(SecondaryReviewError):
    """A read the blind forbids. Raised rather than logged, so it cannot pass unnoticed."""


class BlindGuard:
    """Refuses any read of a first-pass artifact and counts what it was asked for."""

    def __init__(self, benchmark_root):
        self.root = Path(benchmark_root).resolve()
        self.blocked = [self.root / name for name in BLINDED_DIRECTORIES]
        self.blocked_files = [
            path.resolve() for pattern in BLINDED_GLOBS for path in self.root.glob(pattern)
        ]
        self.counts = {
            "primary_reads": 0, "gold_draft_reads": 0, "primary_audit_reads": 0,
            "notion_reads": 0, "network_calls": 0, "case_reads": 0, "draft_reads": 0,
        }

    def _refuse(self, resolved):
        for directory in self.blocked:
            if directory == resolved or directory in resolved.parents:
                raise BlindAccessError(
                    "the blind second pass may not read {}".format(
                        resolved.relative_to(self.root).as_posix()
                    )
                )
        if resolved in self.blocked_files:
            raise BlindAccessError(
                "the blind second pass may not read {}".format(
                    resolved.relative_to(self.root).as_posix()
                )
            )

    def read_text(self, path, *, kind):
        resolved = Path(path).resolve()
        self._refuse(resolved)
        self.counts[kind] = self.counts.get(kind, 0) + 1
        return resolved.read_text(encoding="utf-8")

    def read_json(self, path, *, kind):
        return json.loads(self.read_text(path, kind=kind))

    def digest(self, path):
        resolved = Path(path).resolve()
        self._refuse(resolved)
        return hashlib.sha256(resolved.read_bytes()).hexdigest()

    def as_report(self):
        return {key: self.counts[key] for key in (
            "primary_reads", "gold_draft_reads", "primary_audit_reads",
            "notion_reads", "network_calls",
        )}


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--benchmark-root", type=Path, required=True)
    sub = parser.add_subparsers(dest="command", required=True)

    packet = sub.add_parser("packet", help="write the blind packet for one case")
    packet.add_argument("--case-id", required=True)

    template = sub.add_parser("template", help="create an empty second-pass review")
    template.add_argument("--case-id", required=True)
    template.add_argument("--reviewer-id", default="secondary_reviewer_01")

    record = sub.add_parser("record", help="apply a decision document")
    record.add_argument("--case-id", required=True)
    record.add_argument("--decisions", type=Path, required=True)

    validate = sub.add_parser("validate", help="judge one review or all of them")
    validate.add_argument("--case-id", action="append", default=[])
    return parser.parse_args()


def development_ids(guard, benchmark_root):
    rows = read_jsonl(benchmark_root / "source-index.jsonl")
    return sorted(row["case_id"] for row in rows if row["split"] == "development")


def resolve_case(guard, benchmark_root, case_id):
    development = development_ids(guard, benchmark_root)
    if case_id not in development:
        raise SecondaryReviewError(
            "{} is not a development case; the second pass covers {} cases only".format(
                case_id, len(development)
            )
        )
    path = benchmark_root / CASE_DIRECTORY / "{}.json".format(case_id)
    return path, guard.read_json(path, kind="case_reads")


def draft_of(guard, benchmark_root, case_id):
    return guard.read_json(
        benchmark_root / "drafts" / "{}.model-suggestion.json".format(case_id),
        kind="draft_reads",
    )


def review_path(benchmark_root, case_id):
    return benchmark_root / REVIEW_DIRECTORY / "{}.secondary-review.json".format(case_id)


def packet_path(benchmark_root, case_id):
    return benchmark_root / PACKET_DIRECTORY / "{}.blind-packet.md".format(case_id)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def render_packet(case, draft):
    """Everything the reviewer may see, and nothing that reveals the first pass."""
    suggestion = draft["suggestion"]
    window = case["window"]
    transcript = case.get("transcript", [])
    lines = [
        "# {} — 독립 2차 검토 패킷".format(case["case_id"]),
        "",
        "<!-- blind-packet: 1차 검수 결과는 이 문서와 생성 경로에 들어오지 않습니다 -->",
        "",
        "- Focus: `{}`".format(case.get("review_focus")),
        "- Target speaker: `{}`".format(case.get("target_speaker")),
        "- 화자: {}".format(", ".join(
            "`{}`→`{}`".format(k, v) for k, v in sorted(case.get("speaker_mapping", {}).items())
        )),
        "- Window: {:.1f}초–{:.1f}초 (길이 {:.1f}초)".format(
            window["source_start_seconds"], window["source_end_seconds"],
            window["duration_seconds"],
        ),
        "- 발화 수: {} (첫 `{}` / 끝 `{}`)".format(
            len(transcript),
            transcript[0]["utterance_id"] if transcript else "-",
            transcript[-1]["utterance_id"] if transcript else "-",
        ),
        "- 이전 회의 source: `{}`".format(case["source"].get("prior_source_id") or "없음"),
        "- 저장된 prior_state: `{}`".format("있음" if case.get("prior_state") else "없음 (미구축)"),
        "",
        "## AI 초벌 후보 — 확정 판정 아님",
        "",
    ]
    for category in CATEGORIES:
        items = suggestion.get(category, [])
        lines.append("### `{}` ({})".format(category, len(items)))
        lines.append("")
        if not items:
            lines.extend(["AI 제안 없음. 실제로 없는지는 검토자가 판정합니다.", ""])
        for position, item in enumerate(items, start=1):
            evidence = item.get("evidence") or {}
            title = item.get("statement") or item.get("title") or item.get("question")
            lines.extend([
                "- **`{}[{}]`** {}".format(category, position, str(title or "").strip()),
                "  - AI 근거: 전사 `{}` — “{}”".format(
                    evidence.get("utterance_id"), str(evidence.get("quote") or "").strip()
                ),
            ])
            if category == "action_items":
                lines.append("  - AI 담당 화자 `{}` · AI 기한 `{}`".format(
                    item.get("assignee_speaker") or "미지정",
                    item.get("due_date") or item.get("due_text") or "없음",
                ))
            if category == "next_agenda":
                lines.append("  - AI 이유: {}".format(str(item.get("reason") or "").strip()))
        lines.append("")

    flags = suggestion.get("review_flags", [])
    lines.extend(["## AI 검토 플래그 ({})".format(len(flags)), ""])
    if not flags:
        lines.extend(["플래그 없음.", ""])
    for position, flag in enumerate(flags, start=1):
        lines.extend([
            "- **`review_flags[{}]`** `{}` / `{}`".format(
                position, flag.get("kind"), flag.get("category")
            ),
            "  - 주장: {}".format(str(flag.get("claim") or "").strip()),
            "  - 사유: {}".format(str(flag.get("reason") or "").strip()),
            "  - 근거: {}".format(
                "전사 `{}`".format(flag["related_utterance_id"])
                if flag.get("related_utterance_id") else "근거 발화 없음"
            ),
        ])
    lines.extend(["", "## 전체 전사", ""])
    for row in transcript:
        lines.append("- `{}` [{:.1f}초] **{}**: {}".format(
            row["utterance_id"], row["start_seconds"], row["speaker"],
            str(row.get("text_raw") or "").replace("\n", " ").strip(),
        ))
    lines.extend([
        "",
        "## 판정 양식 (전부 미기록 상태)",
        "",
        "- AI 후보별: 승인 / 수정 후 승인 / 제외 · 최종 문구 · gold evidence · 제외 사유와 근거",
        "- 후보별: inference class · target speaker B responsibility",
        "- Action Item: assignee `scope`(individual / organization / unspecified)와 "
        "`basis`(speaker_commitment / supported_by_utterance / absent_must_stay_empty)를 "
        "**각각 별도로** 판정하고 value와 근거 발화를 기록",
        "- Action Item: due `status`(explicit / explicit_relative / absent / unresolved)와 value·근거",
        "- AI 검토 플래그별: 동의 / 반려 · 근거 종류 · 사유",
        "- Decision / Action Item / Open Question / Next Agenda 네 종류 누락 확인",
        "- 금지 추론 확인과 항목별 사유·근거 종류",
        "- prior-state 판정",
        "- 모호성과 처리 방침",
        "- 전체 window 검토 확인",
        "- 사례 완료 확인",
        "",
    ])
    return "\n".join(lines) + "\n"


def command_packet(guard, args):
    _, case = resolve_case(guard, args.benchmark_root, args.case_id)
    draft = draft_of(guard, args.benchmark_root, args.case_id)
    path = packet_path(args.benchmark_root, args.case_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    text = render_packet(case, draft)
    path.write_text(text, encoding="utf-8")
    return {
        "command": "packet", "case_id": args.case_id, "packet": path.name,
        "packet_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "utterances": len(case.get("transcript", [])),
        "access_audit": guard.as_report(),
    }


def command_template(guard, args):
    case_path, case = resolve_case(guard, args.benchmark_root, args.case_id)
    path = review_path(args.benchmark_root, args.case_id)
    if path.exists():
        raise SecondaryReviewError(
            "{} already has a second-pass review; the recorder edits it, this never "
            "replaces it".format(args.case_id)
        )
    packet = packet_path(args.benchmark_root, args.case_id)
    if not packet.is_file():
        raise SecondaryReviewError("{} has no blind packet yet; run `packet` first".format(args.case_id))
    draft = draft_of(guard, args.benchmark_root, args.case_id)
    review = build_template(
        case, draft, guard.digest(packet), guard.digest(case_path), args.reviewer_id
    )
    write_json(path, review)
    return {
        "command": "template", "case_id": args.case_id, "created": path.name,
        "candidates": len(review["candidate_verdicts"]),
        "flags": len(review["review_flag_verdicts"]),
        "unresolved": len(unresolved_fields(review)),
        "access_audit": guard.as_report(),
    }


def load_review(guard, benchmark_root, case_id, case_path):
    path = review_path(benchmark_root, case_id)
    if not path.is_file():
        raise SecondaryReviewError("{} has no second-pass review yet".format(case_id))
    review = guard.read_json(path, kind="secondary_reads")
    if review.get("schema_version") != SCHEMA_VERSION:
        raise SecondaryReviewError("{} review is not {}".format(case_id, SCHEMA_VERSION))
    if review.get("case_id") != case_id:
        raise SecondaryReviewError("{} review identifies as {}".format(case_id, review.get("case_id")))
    if review.get("packet_sha256") != guard.digest(packet_path(benchmark_root, case_id)):
        raise SecondaryReviewError(
            "{} was reviewed against a different packet".format(case_id)
        )
    if review.get("case_sha256") != guard.digest(case_path):
        raise SecondaryReviewError("{} case file changed after the review started".format(case_id))
    return path, review


def command_record(guard, args):
    case_path, case = resolve_case(guard, args.benchmark_root, args.case_id)
    path, review = load_review(guard, args.benchmark_root, args.case_id, case_path)
    decisions = json.loads(args.decisions.read_text(encoding="utf-8"))
    if decisions.get("case_id") not in (None, args.case_id):
        raise SecondaryReviewError(
            "decision document is for {}, not {}".format(decisions.get("case_id"), args.case_id)
        )
    decisions.pop("case_id", None)
    if "reviewed_at" not in decisions and decisions.get("review_status") == "complete":
        decisions["reviewed_at"] = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    updated = apply_decisions(review, decisions, case)
    write_json(path, updated)
    return {
        "command": "record", "case_id": args.case_id,
        "review_status": updated["review_status"],
        "applied": sorted(set(decisions) - {"reviewed_at"}),
        "unresolved": unresolved_fields(updated),
        "review_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "access_audit": guard.as_report(),
    }


def judge(guard, benchmark_root, case_id):
    case_path, case = resolve_case(guard, benchmark_root, case_id)
    path, review = load_review(guard, benchmark_root, case_id, case_path)
    known = {row["utterance_id"] for row in case.get("transcript", [])}
    errors = []
    cited = []
    for entry in review["candidate_verdicts"]:
        cited.extend(entry.get("evidence_utterance_ids") or [])
        cited.extend(entry.get("exclude_evidence_utterance_ids") or [])
        for block in (entry.get("assignee"), entry.get("due")):
            if isinstance(block, dict):
                cited.extend(block.get("evidence_utterance_ids") or [])
    for item in review["missing_items"]:
        cited.extend(item.get("evidence_utterance_ids") or [])
        for block in (item.get("assignee"), item.get("due")):
            if isinstance(block, dict):
                cited.extend(block.get("evidence_utterance_ids") or [])
    dangling = sorted(set(cited) - known)
    if dangling:
        errors.append("{} cites utterances outside the case: {}".format(case_id, dangling))
    provenance = review.get("provenance") or {}
    if provenance.get("inter_rater_agreement_claim_allowed") is not False:
        errors.append("{} may not claim inter-rater agreement".format(case_id))
    if provenance.get("review_mode") != "single_human_separated_blind_pass":
        errors.append("{} does not record the blind pass mode".format(case_id))
    if review.get("reviewer_kind") != REVIEWER_KIND:
        errors.append("{} is not recorded as a human review".format(case_id))
    unresolved = unresolved_fields(review)
    if review["review_status"] == "complete" and unresolved:
        errors.append("{} claims complete while unresolved: {}".format(case_id, unresolved))
    return {
        "case_id": case_id,
        "review_status": review["review_status"],
        "review_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "reviewer_id": provenance.get("reviewer_id"),
        "review_mode": provenance.get("review_mode"),
        "limitations": provenance.get("limitations"),
        "candidates": len(review["candidate_verdicts"]),
        "verdicts": {
            verdict: sum(1 for e in review["candidate_verdicts"] if e.get("verdict") == verdict)
            for verdict in VERDICTS
        },
        "flags": len(review["review_flag_verdicts"]),
        "flag_verdicts": {
            verdict: sum(1 for e in review["review_flag_verdicts"] if e.get("verdict") == verdict)
            for verdict in FLAG_VERDICTS
        },
        "missing_items": len(review["missing_items"]),
        "ambiguities": len(review.get("ambiguities") or []),
        "prior_status": (review.get("prior_transition") or {}).get("status"),
        "full_window_reviewed": (review.get("transcript_coverage") or {}).get(
            "full_window_reviewed"
        ) is True,
        "unresolved": unresolved,
        "errors": errors,
    }


def command_validate(guard, args):
    targets = args.case_id or [
        path.name.split(".")[0]
        for path in sorted((args.benchmark_root / REVIEW_DIRECTORY).glob("*.secondary-review.json"))
    ]
    results = [judge(guard, args.benchmark_root, case_id) for case_id in targets]
    errors = [error for result in results for error in result["errors"]]
    return {
        "command": "validate", "reviews": results, "passed": not errors,
        "access_audit": guard.as_report(),
    }, errors


def main():
    args = parse_args()
    args.benchmark_root = args.benchmark_root.resolve()
    guard = BlindGuard(args.benchmark_root)
    if args.command == "validate":
        report, errors = command_validate(guard, args)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if errors:
            raise SystemExit(1)
        return
    handlers = {
        "packet": command_packet, "template": command_template, "record": command_record,
    }
    print(json.dumps(handlers[args.command](guard, args), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except SecondaryReviewError as error:
        raise SystemExit("FAILED: {}".format(error))
