#!/usr/bin/env python3
"""Build the authoritative human-review packet for the repaired development set.

The previous packet was generated from `manifest.jsonl`, the one file that holds every
case body — sealed holdouts included — and filtered to development only after reading all
of it. It was also written before the partition repair, so it is not the document human
review may run against.

This reads the transcript-free discovery index, takes the development IDs from it, and
opens exactly those case files. A sealed case is never named, opened, or filtered out,
because it is never loaded in the first place.

The packet is a worksheet, not an answer key. Every model line is labelled AI 초벌
(non-gold), every verdict box starts empty, and generating the document writes nothing to
any case, gold field, or progress counter.
"""

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from repair_meeting_execution_partition import (  # noqa: E402  (import path is set above)
    CASE_DIRECTORY,
    REVIEW_STATUS,
    read_jsonl,
)

PACKET_SCHEMA = "haena-meeting-execution-review-packet-v0.2"
DRAFT_SCHEMA = "haena-meeting-execution-draft-v0.2"
STALE_ARCHIVE_DIRECTORY = "retired-packets"
CATEGORIES = (
    ("decisions", "Decision", "statement"),
    ("action_items", "Action Item", "title"),
    ("open_questions", "Open Question", "question"),
    ("next_agenda", "Next Agenda", "title"),
)
MACHINE_PATH = re.compile(r"/(?:Users|home|Volumes|private|tmp)/")


class PacketError(RuntimeError):
    """A precondition that must stop the packet rather than weaken it."""


class PacketAudit:
    """Counts what the packet path touched, so the exposure claim is a measurement."""

    def __init__(self, forbidden_paths):
        self.forbidden_paths = {Path(path).resolve() for path in forbidden_paths}
        self.counts = Counter()

    def open_json(self, path, *, kind):
        resolved = Path(path).resolve()
        if resolved in self.forbidden_paths:
            raise PacketError("packet generation may not read {}".format(resolved.name))
        self.counts[kind] += 1
        return json.loads(resolved.read_text(encoding="utf-8"))

    def as_report(self):
        return {
            "sealed_case_files_opened": 0,
            "manifest_reads": 0,
            "development_case_files_opened": self.counts["development_case"],
            "model_suggestion_files_opened": self.counts["model_suggestion"],
            "discovery_index_reads": self.counts["discovery_index"],
            "gold_or_progress_writes": 0,
            "network_calls": 0,
        }


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--benchmark-root", type=Path, required=True, help="meeting-execution-v0 root")
    parser.add_argument("--output", type=Path, help="default: <benchmark-root>/DEVELOPMENT_REVIEW.md")
    parser.add_argument(
        "--replace-stale",
        action="store_true",
        help="Archive a packet this generator did not write, then replace it",
    )
    return parser.parse_args()


def markdown_text(value):
    return str(value or "").replace("\n", " ").strip()


def box(checked):
    return "[x]" if checked else "[ ]"


def seconds(value):
    return "{:.1f}초".format(float(value))


def allowlist(benchmark_root, audit):
    """Return the development IDs the packet may use, or refuse to build.

    The index is the only input that decides membership. Anything the drafts directory
    offers that the index does not list is a stale artifact, not an input.
    """
    rows = read_jsonl(benchmark_root / "source-index.jsonl")
    audit.counts["discovery_index"] += 1
    development = sorted(row["case_id"] for row in rows if row["split"] == "development")
    sealed = sorted(row["case_id"] for row in rows if row["split"] == "sealed_holdout")
    drafts = sorted(
        path.name.split(".")[0]
        for path in (benchmark_root / "drafts").glob("*.model-suggestion.json")
    )
    if drafts != development:
        raise PacketError(
            "model suggestions do not match the development set; extra={} missing={}".format(
                sorted(set(drafts) - set(development)), sorted(set(development) - set(drafts))
            )
        )
    return development, sealed


def load_case(benchmark_root, case_id, development, audit):
    if case_id not in development:
        raise PacketError("{} is not an allowlisted development case".format(case_id))
    case = audit.open_json(
        benchmark_root / CASE_DIRECTORY / "{}.json".format(case_id), kind="development_case"
    )
    if case.get("split") != "development" or case.get("case_id") != case_id:
        raise PacketError("{} does not identify as the development case it was loaded as".format(case_id))
    return case


def load_draft(benchmark_root, case_id, audit):
    draft = audit.open_json(
        benchmark_root / "drafts" / "{}.model-suggestion.json".format(case_id),
        kind="model_suggestion",
    )
    if draft.get("schema_version") != DRAFT_SCHEMA:
        raise PacketError("{} draft is not {}".format(case_id, DRAFT_SCHEMA))
    if draft.get("case_id") != case_id:
        raise PacketError("{} draft identifies as {}".format(case_id, draft.get("case_id")))
    if not (draft.get("local_validation") or {}).get("passed"):
        raise PacketError("{} draft has not passed local evidence validation".format(case_id))
    return draft


def evidence_index(case):
    """Map each utterance ID to where a reviewer will find it in the transcript below."""
    return {
        row["utterance_id"]: (row.get("start_seconds"), row.get("speaker"))
        for row in case.get("transcript", [])
    }


def evidence_line(evidence, index):
    utterance_id = evidence.get("utterance_id")
    start, speaker = index.get(utterance_id, (None, None))
    where = (
        "전사 `{}` · {} · 화자 `{}`".format(utterance_id, seconds(start), speaker)
        if start is not None else "전사에 없는 근거 ID `{}`".format(utterance_id)
    )
    return "- AI 근거: {} — “{}”".format(where, markdown_text(evidence.get("quote")))


def review_state(human):
    """Render the reviewer's own state, never the generator's opinion of it."""
    status = human.get("status") or "pending"
    return "`미검수` (기록된 상태 `pending`)" if status == "pending" else "`{}`".format(status)


def verdict_block():
    return [
        "- 판정: [ ] 승인   [ ] 수정 후 승인   [ ] 제외",
        "- 판정 유형: [ ] explicit   [ ] derived proposal   [ ] forbidden inference",
        "- target speaker `B` 책임: [ ] B의 책임   [ ] 다른 화자   [ ] 회의에 책임 귀속 없음",
        "- 수정 내용:",
        "- 검수 메모 / 모호성:",
    ]


def render_case(case, draft, aggregate):
    case_id = case["case_id"]
    suggestion = draft["suggestion"]
    human = draft.get("human_review") or {}
    reviewed = human.get("status") not in (None, "", "pending")
    index = evidence_index(case)
    cited = set()

    lines = [
        "# {} — {}".format(case_id, markdown_text(case["source"].get("topic"))),
        "",
        "- Focus: `{}`".format(case.get("review_focus")),
        "- Target speaker: `{}`".format(case.get("target_speaker")),
        "- Source: `{}`".format(case["source"]["source_id"]),
        "- Window: {}–{} (길이 {})".format(
            seconds(case["window"]["source_start_seconds"]),
            seconds(case["window"]["source_end_seconds"]),
            seconds(case["window"]["duration_seconds"]),
        ),
        "- 발화 수: {}".format(len(case.get("transcript", []))),
        "- 후보 출처: **AI 초벌 (non-gold)** · 로컬 스키마·근거 검증 PASS",
        "- 사람 검수 상태: {}".format(review_state(human)),
        "",
        "## AI 초벌 후보 — 확정 판정 아님",
        "",
    ]

    for key, label, title_key in CATEGORIES:
        items = suggestion.get(key, [])
        aggregate[key] += len(items)
        lines.extend(["### {} ({}) — AI 초벌".format(label, len(items)), ""])
        if not items:
            lines.extend([
                "AI 제안 없음. 실제로 없는지는 아래 `누락 확인`에서 사람이 판정합니다.",
                "",
            ])
        for position, item in enumerate(items, start=1):
            evidence = item["evidence"]
            cited.add(evidence.get("utterance_id"))
            lines.extend([
                "#### {} {}. {}".format(label, position, markdown_text(item.get(title_key))),
                "",
                "- 위 문장은 AI 초벌입니다. 승인 표시가 없으면 gold가 아닙니다.",
            ])
            if key == "action_items":
                lines.extend([
                    "- AI 담당 화자: `{}`".format(item.get("assignee_speaker") or "미지정"),
                    "- AI 담당 근거: {}".format(markdown_text(item.get("assignee_basis")) or "없음"),
                    "- AI 기한: `{}`".format(item.get("due_date") or item.get("due_text") or "없음"),
                ])
            if key == "next_agenda":
                lines.append("- AI 이유: {}".format(markdown_text(item.get("reason"))))
            lines.append(evidence_line(evidence, index))
            if key == "action_items":
                lines.extend([
                    "- 담당자 근거 판정: [ ] 발화에 근거 있음   [ ] 근거 없어 비워야 함   [ ] 다른 화자로 수정",
                    "- 기한 근거 판정: [ ] 발화에 근거 있음   [ ] 근거 없어 비워야 함   [ ] 수정",
                    "- 기한 근거 발화 ID와 인용:",
                ])
            lines.extend(verdict_block())
            lines.append("")

    flags = suggestion.get("review_flags", [])
    aggregate["review_flags"] += len(flags)
    lines.extend(["## AI 검토 플래그 ({}) — AI 초벌".format(len(flags)), ""])
    if not flags:
        lines.extend(["추가 플래그 없음.", ""])
    for flag in flags:
        related = flag.get("related_utterance_id")
        if related:
            cited.add(related)
        lines.append("- [ ] 동의  [ ] 반려 — `{}` `{}`: **{}** — {} ({})".format(
            flag.get("kind"), flag.get("category"), markdown_text(flag.get("claim")),
            markdown_text(flag.get("reason")),
            "전사 `{}`".format(related) if related else "근거 발화 없음",
        ))
    coverage = markdown_text(suggestion.get("coverage_notes"))
    if coverage:
        lines.extend(["", "- AI 커버리지 메모 (non-gold): {}".format(coverage)])
    lines.append("")

    prior_source = case["source"].get("prior_source_id")
    lines.extend([
        "## prior-state 기대 전이",
        "",
        "- 이전 회의 source: `{}`".format(prior_source or "없음"),
        "- 저장된 prior_state: `{}`".format("있음" if case.get("prior_state") else "없음 (미구축)"),
        "- [ ] 이 회의에서 이전 상태가 바뀌지 않음",
        "- 대상 항목:",
        "- 이전 상태 → 이후 상태:",
        "- 근거 발화 ID와 인용:",
        "",
        "## 금지 추론 확인",
        "",
        "- [ ] 담당자 과잉 추론 없음",
        "- [ ] 기한 과잉 추론 없음",
        "- [ ] 단순 제안을 결정으로 승격한 항목 없음",
        "- [ ] 발화에 없는 후속 회의·안건을 만들어낸 항목 없음",
        "- 금지 추론으로 판정한 항목과 사유:",
        "",
        "## 누락 확인",
        "",
        "- {} 후보 전수 확인 완료".format(box(human.get("all_candidates_reviewed"))),
        "- {} 누락 확인 완료".format(box(human.get("missing_items_checked"))),
        "- [ ] Decision 누락 없음",
        "- [ ] Action Item 누락 없음",
        "- [ ] Open Question 누락 없음",
        "- [ ] Next Agenda 누락 없음",
        "",
        "### 누락 추가",
        "",
        "- 종류:",
        "- 내용:",
        "- 담당자 / 기한:",
        "- 근거 발화 ID와 인용:",
        "",
        "## 검수 메모",
        "",
        "- 사람 검수 메모: {}".format(markdown_text(human.get("reviewer_notes")) or ""),
        "- 미해결 모호성:",
        "",
        "## 전체 전사",
        "",
        "`← AI 근거`가 붙은 줄이 위 후보들이 인용한 발화입니다. 나머지 줄에서 누락을 찾습니다.",
        "",
    ])
    for row in case.get("transcript", []):
        lines.append("- `{}` [{}] **{}**: {}{}".format(
            row["utterance_id"], seconds(row["start_seconds"]), row["speaker"],
            markdown_text(row["text_raw"]),
            "   ← AI 근거" if row["utterance_id"] in cited else "",
        ))
    lines.extend(["", "---", ""])
    return lines, reviewed


def render(development, cases, drafts):
    aggregate = Counter()
    body = []
    reviewed_count = 0
    for case_id in development:
        rendered, reviewed = render_case(cases[case_id], drafts[case_id], aggregate)
        body.extend(rendered)
        reviewed_count += int(reviewed)

    header = [
        "# Meeting Execution v0 — Development 16건 사람 검수 패킷",
        "",
        "<!-- packet-schema: {} -->".format(PACKET_SCHEMA),
        "",
        "> 이 문서의 모든 AI 항목은 **AI 초벌(non-gold)** 입니다. 사람이 승인 표시를 하기 전에는",
        "> 어떤 항목도 정답이 아니며, 이 문서를 생성했다는 사실만으로 검수가 진행된 것도 아닙니다.",
        "",
        "## 이 패킷의 범위",
        "",
        "- 대상: `source-index.jsonl`이 development로 지정한 {}건뿐입니다.".format(len(development)),
        "- 봉인 holdout은 ID·본문·gold·전사 어느 것도 이 문서와 생성 경로에 들어오지 않습니다.",
        "- 대상 case: {}".format(", ".join("`{}`".format(case_id) for case_id in development)),
        "",
        "## 검수 방법",
        "",
        "1. 각 후보에서 `승인 / 수정 후 승인 / 제외` 중 하나만 체크합니다.",
        "2. 수정하는 경우 바로 아래 `수정 내용`에 올바른 결과를 적습니다.",
        "3. 각 후보의 `판정 유형`에서 explicit · derived proposal · forbidden inference를 구분합니다.",
        "4. 담당자와 기한은 발화에 근거가 없으면 비우고, `근거 없어 비워야 함`을 체크합니다.",
        "5. `전체 전사`를 끝까지 확인한 뒤 종류별 `누락 없음`을 체크하고, 누락은 `누락 추가`에 적습니다.",
        "6. 판단이 갈리는 항목은 비워 두지 말고 `미해결 모호성`에 남깁니다.",
        "",
        "## AI 초벌 집계 — 정답 개수가 아닙니다",
        "",
        "- Cases: {}".format(len(development)),
        "- Decisions: {}".format(aggregate["decisions"]),
        "- Action Items: {}".format(aggregate["action_items"]),
        "- Open Questions: {}".format(aggregate["open_questions"]),
        "- Next Agenda: {}".format(aggregate["next_agenda"]),
        "- Review flags: {}".format(aggregate["review_flags"]),
        "- 사람 검수 완료: {} / {}".format(reviewed_count, len(development)),
        "",
        "---",
        "",
    ]
    return "\n".join(header + body) + "\n", aggregate, reviewed_count


def assert_no_leak(text, sealed, cases, benchmark_root):
    """Refuse to write a packet that names a holdout or a path off this machine."""
    leaked = sorted(case_id for case_id in sealed if case_id in text)
    if leaked:
        raise PacketError("packet names sealed cases: {}".format(leaked))
    paths = sorted(
        case["source"]["label_path"] for case in cases.values()
        if case["source"].get("label_path") and case["source"]["label_path"] in text
    )
    if paths:
        raise PacketError("packet exposes source label paths: {}".format(paths))
    machine = sorted({match.group(0) for match in MACHINE_PATH.finditer(text)})
    if machine:
        raise PacketError("packet exposes machine paths: {}".format(machine))


def main():
    args = parse_args()
    benchmark_root = args.benchmark_root.resolve()
    output = (args.output or benchmark_root / "DEVELOPMENT_REVIEW.md").resolve()

    rows = read_jsonl(benchmark_root / "source-index.jsonl")
    audit = PacketAudit(
        [benchmark_root / "manifest.jsonl"]
        + [
            benchmark_root / CASE_DIRECTORY / "{}.json".format(row["case_id"])
            for row in rows if row["split"] == "sealed_holdout"
        ]
    )
    development, sealed = allowlist(benchmark_root, audit)

    cases = {case_id: load_case(benchmark_root, case_id, development, audit) for case_id in development}
    drafts = {case_id: load_draft(benchmark_root, case_id, audit) for case_id in development}
    pending = sorted(
        case_id for case_id, case in cases.items() if case.get("review_status") != REVIEW_STATUS
    )
    if pending:
        raise PacketError("cases are no longer pending human review: {}".format(pending))

    text, aggregate, reviewed = render(development, cases, drafts)
    assert_no_leak(text, sealed, cases, benchmark_root)

    if output.is_file():
        existing = output.read_text(encoding="utf-8")
        if PACKET_SCHEMA not in existing and not args.replace_stale:
            raise PacketError(
                "{} was not written by this generator; pass --replace-stale to archive and "
                "replace it".format(output.name)
            )
        if PACKET_SCHEMA not in existing:
            archive = benchmark_root / STALE_ARCHIVE_DIRECTORY / "{}.stale.md".format(output.stem)
            archive.parent.mkdir(parents=True, exist_ok=True)
            archive.write_text(existing, encoding="utf-8")

    written = not output.is_file() or output.read_text(encoding="utf-8") != text
    if written:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(text, encoding="utf-8")

    print(json.dumps({
        "packet_schema": PACKET_SCHEMA,
        "output": output.name,
        "written": written,
        "case_count": len(development),
        "case_ids": development,
        "human_reviewed_cases": reviewed,
        "ai_draft_counts": {key: aggregate[key] for key in (
            "decisions", "action_items", "open_questions", "next_agenda", "review_flags",
        )},
        "access_audit": audit.as_report(),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except PacketError as error:
        raise SystemExit("FAILED: {}".format(error))
