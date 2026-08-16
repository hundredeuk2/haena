#!/usr/bin/env python3
"""Build a local Markdown review packet from validated model suggestions."""

import argparse
import json
from collections import Counter
from pathlib import Path


CATEGORIES = (
    ("decisions", "Decision", "statement"),
    ("action_items", "Action Item", "title"),
    ("open_questions", "Open Question", "question"),
    ("next_agenda", "Next Agenda", "title"),
)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--draft-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def read_jsonl(path):
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def markdown_text(value):
    return str(value or "").replace("\n", " ").strip()


def main():
    args = parse_args()
    cases = [case for case in read_jsonl(args.manifest) if case.get("split") == "development"]
    drafts = {}
    for path in args.draft_dir.glob("*.model-suggestion.json"):
        draft = json.loads(path.read_text(encoding="utf-8"))
        if draft.get("schema_version") == "haena-meeting-execution-draft-v0.2":
            drafts[draft["case_id"]] = draft

    missing = [case["case_id"] for case in cases if case["case_id"] not in drafts]
    invalid = [
        case_id for case_id, draft in drafts.items()
        if not (draft.get("local_validation") or {}).get("passed")
    ]
    if missing or invalid:
        raise SystemExit("Cannot build review packet; missing={}, invalid={}".format(missing, invalid))

    lines = [
        "# Meeting Execution v0 — Development 16건 AI 초벌 검수",
        "",
        "> 이 문서는 회사 vLLM의 `model_suggestion`을 사람이 검수하기 위한 로컬 작업 문서입니다. 초벌은 semantic gold가 아닙니다.",
        "",
        "## 검수 방법",
        "",
        "1. 각 후보에서 `승인 / 수정 / 제외` 중 하나만 체크합니다.",
        "2. 수정하는 경우 바로 아래 `수정 내용`에 올바른 결과를 적습니다.",
        "3. AI가 놓친 결과는 각 사례의 `누락 추가`에 기록합니다.",
        "4. 전체 전사를 끝까지 확인한 뒤 네 종류별 `누락 없음`을 체크합니다.",
        "5. 담당자와 기한은 발화에 근거가 없으면 비워 둡니다.",
        "",
        "---",
        "",
    ]

    aggregate = Counter()
    for case in cases:
        draft = drafts[case["case_id"]]
        suggestion = draft["suggestion"]
        lines.extend([
            "# {} — {}".format(case["case_id"], markdown_text(case["source"].get("topic"))),
            "",
            "- Focus: `{}`".format(case.get("review_focus")),
            "- Target speaker: `{}`".format(case.get("target_speaker")),
            "- Source: `{}`".format(case["source"]["source_id"]),
            "- Window: {:.1f}–{:.1f}초".format(case["window"]["source_start_seconds"], case["window"]["source_end_seconds"]),
            "- Local validation: **PASS**",
            "",
            "## AI 초벌 후보",
            "",
        ])
        for key, label, title_key in CATEGORIES:
            items = suggestion.get(key, [])
            aggregate[key] += len(items)
            lines.append("### {} ({})".format(label, len(items)))
            lines.append("")
            if not items:
                lines.extend(["AI 제안 없음.", ""])
            for index, item in enumerate(items, start=1):
                evidence = item["evidence"]
                lines.extend([
                    "#### {} {}. {}".format(label, index, markdown_text(item.get(title_key))),
                    "",
                    "- [ ] 승인",
                    "- [ ] 수정 후 승인",
                    "- [ ] 제외",
                ])
                if key == "action_items":
                    lines.extend([
                        "- 담당 화자: `{}`".format(item.get("assignee_speaker") or "미지정"),
                        "- 담당 근거: `{}`".format(item.get("assignee_basis")),
                        "- 기한: `{}`".format(item.get("due_date") or item.get("due_text") or "없음"),
                    ])
                if key == "next_agenda":
                    lines.append("- 이유: {}".format(markdown_text(item.get("reason"))))
                lines.extend([
                    "- 근거: `[{}]` {}".format(evidence["utterance_id"], markdown_text(evidence["quote"])),
                    "- 수정 내용:",
                    "",
                ])

        flags = suggestion.get("review_flags", [])
        aggregate["review_flags"] += len(flags)
        lines.extend(["## AI 검토 플래그 ({})".format(len(flags)), ""])
        if not flags:
            lines.extend(["추가 플래그 없음.", ""])
        for index, flag in enumerate(flags, start=1):
            lines.extend([
                "- [ ] {} {}: **{}** — {} (`{}`)".format(
                    flag["kind"], flag["category"], markdown_text(flag["claim"]),
                    markdown_text(flag["reason"]), flag.get("related_utterance_id") or "근거 없음",
                ),
            ])
        lines.extend([
            "",
            "## 누락 확인",
            "",
            "- [ ] Decision 누락 없음",
            "- [ ] Action Item 누락 없음",
            "- [ ] Open Question 누락 없음",
            "- [ ] Next Agenda 누락 없음",
            "- [ ] 담당자·기한 과잉 추론 없음",
            "",
            "### 누락 추가",
            "",
            "- 종류:",
            "- 내용:",
            "- 담당자/기한:",
            "- 근거 utterance ID와 인용:",
            "",
            "## 전체 전사",
            "",
        ])
        for row in case["transcript"]:
            lines.append("- `{}` **{}**: {}".format(
                row["utterance_id"], row["speaker"], markdown_text(row["text_raw"])
            ))
        lines.extend(["", "---", ""])

    summary = [
        "## 초벌 전체 요약",
        "",
        "- Cases: {}".format(len(cases)),
        "- Decisions: {}".format(aggregate["decisions"]),
        "- Action Items: {}".format(aggregate["action_items"]),
        "- Open Questions: {}".format(aggregate["open_questions"]),
        "- Next Agenda: {}".format(aggregate["next_agenda"]),
        "- Review flags: {}".format(aggregate["review_flags"]),
        "",
        "---",
        "",
    ]
    lines[12:12] = summary
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines), encoding="utf-8")
    print(json.dumps({"case_count": len(cases), **dict(aggregate)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
