#!/usr/bin/env python3
"""Generate review-only Meeting Execution draft labels through an OpenAI-compatible API.

Only development cases are eligible by default. Drafts are written separately from
human gold and are validated against the local transcript before being accepted.
"""

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


TOP_LEVEL_ARRAYS = (
    "decisions",
    "action_items",
    "open_questions",
    "next_agenda",
    "review_flags",
)
EVIDENCE_BEARING_ARRAYS = (
    "decisions",
    "action_items",
    "open_questions",
    "next_agenda",
)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--source-index", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--api-key-env", default="HAENA_VLLM_API_KEY")
    parser.add_argument("--case-id", action="append")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--attempts", type=int, default=2)
    parser.add_argument("--max-tokens", type=int, default=7000)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def read_jsonl(path):
    with path.open(encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def schema():
    evidence = {
        "type": "object",
        "additionalProperties": False,
        "required": ["utterance_id", "quote"],
        "properties": {
            "utterance_id": {"type": "string"},
            "quote": {"type": "string"},
        },
    }
    return {
        "type": "object",
        "additionalProperties": False,
        "required": list(TOP_LEVEL_ARRAYS) + ["coverage_notes"],
        "properties": {
            "decisions": {
                "type": "array",
                "maxItems": 8,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["statement", "evidence"],
                    "properties": {
                        "statement": {"type": "string"},
                        "evidence": evidence,
                    },
                },
            },
            "action_items": {
                "type": "array",
                "maxItems": 10,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": [
                        "title", "assignee_speaker", "assignee_basis",
                        "due_date", "due_text", "evidence",
                    ],
                    "properties": {
                        "title": {"type": "string"},
                        "assignee_speaker": {"type": ["string", "null"]},
                        "assignee_basis": {
                            "type": "string",
                            "enum": ["explicit_name", "self_reference", "speaker_commitment", "team_or_role", "unspecified"],
                        },
                        "due_date": {"type": ["string", "null"]},
                        "due_text": {"type": ["string", "null"]},
                        "evidence": evidence,
                    },
                },
            },
            "open_questions": {
                "type": "array",
                "maxItems": 8,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["question", "evidence"],
                    "properties": {
                        "question": {"type": "string"},
                        "evidence": evidence,
                    },
                },
            },
            "next_agenda": {
                "type": "array",
                "maxItems": 6,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["title", "reason", "evidence"],
                    "properties": {
                        "title": {"type": "string"},
                        "reason": {"type": "string"},
                        "evidence": evidence,
                    },
                },
            },
            "review_flags": {
                "type": "array",
                "maxItems": 8,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["kind", "category", "claim", "reason", "related_utterance_id"],
                    "properties": {
                        "kind": {"type": "string", "enum": ["forbidden", "uncertain"]},
                        "category": {
                            "type": "string",
                            "enum": ["decision", "action_item", "open_question", "next_agenda", "assignee", "due_date"],
                        },
                        "claim": {"type": "string"},
                        "reason": {"type": "string"},
                        "related_utterance_id": {"type": ["string", "null"]},
                    },
                },
            },
            "coverage_notes": {"type": "string"},
        },
    }


def system_prompt():
    return """사고 과정, 분석 과정, 계획, 설명을 출력하지 마세요. 응답의 첫 글자는 반드시 { 이어야 하며 JSON 객체 하나만 출력하세요.
당신은 HAENA Meeting Execution benchmark의 초벌 라벨러입니다.
입력 전사에서 직접 말했거나 여러 발화가 강하게 뒷받침하는 결과만 제안하세요.

네 종류의 경계:
- decisions: 실제로 확정된 선택. 질문, 의견, 검토 제안, 의례적 진행 선언은 결정이 아닙니다.
- action_items: 누군가 수행해야 할 구체적 후속 업무. 일반적 당부나 희망은 업무가 아닙니다.
- open_questions: 구간에서 제기됐지만 끝까지 답이 확정되지 않은 질문. 뒤에서 답한 질문은 제외합니다.
- next_agenda: 다음 회의나 추후 논의로 명시적으로 넘긴 주제. 단순히 중요하거나 미해결이라는 이유만으로 만들지 마세요.

담당자 규칙:
- 화자가 "제가/내가"처럼 단수로 자신이 수행하겠다고 하면 그 발화의 A/B/C를 assignee_speaker로 사용하고 basis=self_reference입니다.
- 한국어에서 주어를 생략하고 "검토하겠습니다/보고드리겠습니다"처럼 화자 자신이 수행을 약속하면 basis=speaker_commitment로 해당 A/B/C를 지정할 수 있습니다.
- self_reference와 speaker_commitment의 evidence는 요청한 사람의 발화가 아니라, 반드시 실제 assignee_speaker가 수락·약속한 발화여야 합니다.
- "저희/우리/집행부/부서에서"는 개인 자기지시가 아니라 팀·역할입니다. basis=team_or_role, assignee_speaker=null로 두세요.
- 다른 사람을 명시적으로 지명하면 해당 화자를 확인할 수 있을 때만 지정합니다.
- 팀/부서/역할만 말하면 basis=team_or_role이고 assignee_speaker는 null입니다.
- 요청만 있고 수락·배정이 불명확하면 임의 확정하지 않습니다.

기한 규칙:
- 발화와 회의 날짜로 달력 날짜가 유일하게 결정될 때만 YYYY-MM-DD를 사용합니다.
- 모호하면 due_date=null이고 원 표현은 due_text에 보존합니다.

근거 규칙:
- 모든 제안은 입력에 존재하는 utterance_id와 해당 발화의 글자 그대로인 연속 quote를 사용합니다.
- utterance_id 값에는 입력 표시에 사용한 바깥 대괄호를 포함하지 마세요.
- 요약문을 quote로 만들거나 서로 다른 발화를 합치지 마세요.
- 같은 결과를 여러 종류에 중복하지 마세요. 비어 있는 배열은 올바른 답입니다.
- 제목과 설명은 전사의 언어를 유지하세요. 한국어 전사를 영어로 번역하지 마세요.

review_flags에는 모델이 만들기 쉽지만 근거가 부족한 대표적 오답(kind=forbidden)과 사람 판단이 필요한 경계 사례(kind=uncertain)를 기록하세요.
각 문구와 이유는 한두 문장으로 간결하게 작성하고, 대표성이 낮은 후보를 억지로 채우지 마세요.
이 결과는 사람 검수용 model_suggestion이며 확정 정답이라고 주장하지 마세요.

반드시 아래 키만 사용하세요. 배열이 비면 []로 반환하세요.
{"decisions":[{"statement":"", "evidence":{"utterance_id":"", "quote":""}}],
 "action_items":[{"title":"", "assignee_speaker":null, "assignee_basis":"unspecified", "due_date":null, "due_text":null, "evidence":{"utterance_id":"", "quote":""}}],
 "open_questions":[{"question":"", "evidence":{"utterance_id":"", "quote":""}}],
 "next_agenda":[{"title":"", "reason":"", "evidence":{"utterance_id":"", "quote":""}}],
 "review_flags":[{"kind":"uncertain", "category":"action_item", "claim":"", "reason":"", "related_utterance_id":null}],
 "coverage_notes":""}"""


def user_prompt(case, meeting_date):
    lines = [
        "case_id: {}".format(case["case_id"]),
        "회의 주제: {}".format(case["source"].get("topic") or ""),
        "회의 날짜: {}".format(meeting_date or "알 수 없음"),
        "target speaker: {}".format(case.get("target_speaker") or "B"),
        "review focus: {}".format(case.get("review_focus") or ""),
        "",
        "전사:",
    ]
    for row in case["transcript"]:
        lines.append("[{}] [{}] {}".format(row["utterance_id"], row["speaker"], row["text_raw"]))
    return "\n".join(lines)


def request_payload(case, meeting_date, model, max_tokens):
    return {
        "model": model,
        "temperature": 0,
        "max_tokens": max_tokens,
        "messages": [
            {"role": "system", "content": system_prompt()},
            {"role": "user", "content": user_prompt(case, meeting_date)},
        ],
        "response_format": {
            "type": "json_schema",
            "json_schema": {
                "name": "meeting_execution_draft",
                "strict": True,
                "schema": schema(),
            },
        },
    }


def call_api(endpoint, api_key, payload, timeout):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".json") as request_file:
        json.dump(payload, request_file, ensure_ascii=False)
        request_file.flush()
        completed = subprocess.run(
            [
                "curl", "--connect-timeout", "8", "--max-time", str(timeout), "--fail-with-body", "--silent", "--show-error",
                endpoint, "-H", "Authorization: Bearer {}".format(api_key), "-H", "Content-Type: application/json",
                "--data-binary", "@{}".format(request_file.name),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
    if completed.returncode:
        raise RuntimeError("API request failed with curl exit {}: {}".format(completed.returncode, completed.stderr.strip()[:500]))
    reply = json.loads(completed.stdout)
    if reply.get("error"):
        raise RuntimeError("API error: {}".format(json.dumps(reply["error"], ensure_ascii=False)[:500]))
    choices = reply.get("choices") or []
    if not choices:
        raise RuntimeError("API response has no choices")
    content = (choices[0].get("message") or {}).get("content")
    if not content:
        raise RuntimeError("API response has no message content")
    return parse_model_json(content), {
        "response_model": reply.get("model"),
        "finish_reason": choices[0].get("finish_reason"),
        "usage": reply.get("usage"),
    }


def parse_model_json(content):
    candidate = content.strip()
    if candidate.startswith("```"):
        first_newline = candidate.find("\n")
        if first_newline >= 0:
            candidate = candidate[first_newline + 1:]
        if candidate.endswith("```"):
            candidate = candidate[:-3]
        candidate = candidate.strip()
    expected = set(TOP_LEVEL_ARRAYS) | {"coverage_notes"}
    decoder = json.JSONDecoder()
    last_error = None
    first_object = None
    for index, character in enumerate(candidate):
        if character != "{":
            continue
        try:
            value, _ = decoder.raw_decode(candidate[index:])
        except json.JSONDecodeError as error:
            last_error = error
            continue
        if isinstance(value, dict):
            if first_object is None:
                first_object = value
            if set(value) == expected:
                return value
    if first_object is not None:
        return first_object
    safe_preview = candidate[:120].replace("\n", " ")
    raise RuntimeError("Model content has no valid JSON object ({}); prefix={!r}".format(last_error, safe_preview))


def normalize_draft(draft):
    changes = []
    for category in EVIDENCE_BEARING_ARRAYS:
        for item in draft.get(category, []):
            evidence = item.get("evidence", {})
            value = evidence.get("utterance_id")
            if isinstance(value, str) and value.startswith("[") and value.endswith("]"):
                evidence["utterance_id"] = value[1:-1]
                changes.append("stripped_brackets_from_utterance_id")
    for item in draft.get("review_flags", []):
        value = item.get("related_utterance_id")
        if isinstance(value, str) and value.startswith("[") and value.endswith("]"):
            item["related_utterance_id"] = value[1:-1]
            changes.append("stripped_brackets_from_related_utterance_id")
    return sorted(set(changes))


def validate_draft(case, draft):
    errors = []
    allowed_speakers = set(case["speaker_mapping"].values())
    transcript = {row["utterance_id"]: row for row in case["transcript"]}
    for name in TOP_LEVEL_ARRAYS:
        if not isinstance(draft.get(name), list):
            errors.append("{} must be an array".format(name))
    if not isinstance(draft.get("coverage_notes"), str):
        errors.append("coverage_notes must be a string")
    allowed_top_level = set(TOP_LEVEL_ARRAYS) | {"coverage_notes"}
    unexpected_top_level = set(draft) - allowed_top_level
    if unexpected_top_level:
        errors.append("unexpected top-level keys: {}".format(", ".join(sorted(unexpected_top_level))))

    item_contracts = {
        "decisions": {"statement", "evidence"},
        "action_items": {"title", "assignee_speaker", "assignee_basis", "due_date", "due_text", "evidence"},
        "open_questions": {"question", "evidence"},
        "next_agenda": {"title", "reason", "evidence"},
        "review_flags": {"kind", "category", "claim", "reason", "related_utterance_id"},
    }
    for category, required in item_contracts.items():
        for index, item in enumerate(draft.get(category, [])):
            if not isinstance(item, dict):
                errors.append("{}[{}] must be an object".format(category, index))
                continue
            missing = required - set(item)
            unexpected = set(item) - required
            if missing:
                errors.append("{}[{}] missing keys: {}".format(category, index, ", ".join(sorted(missing))))
            if unexpected:
                errors.append("{}[{}] unexpected keys: {}".format(category, index, ", ".join(sorted(unexpected))))

    for category in EVIDENCE_BEARING_ARRAYS:
        for index, item in enumerate(draft.get(category, [])):
            evidence = item.get("evidence")
            if not isinstance(evidence, dict):
                errors.append("{}[{}] has no evidence".format(category, index))
                continue
            utterance_id = evidence.get("utterance_id")
            quote = evidence.get("quote")
            row = transcript.get(utterance_id)
            if row is None:
                errors.append("{}[{}] cites unknown utterance {}".format(category, index, utterance_id))
            elif not isinstance(quote, str) or not quote.strip():
                errors.append("{}[{}] has an empty quote".format(category, index))
            elif quote not in row["text_raw"] and quote not in row["text_normalized"]:
                errors.append("{}[{}] quote is not verbatim in {}".format(category, index, utterance_id))

    for index, item in enumerate(draft.get("action_items", [])):
        speaker = item.get("assignee_speaker")
        basis = item.get("assignee_basis")
        if speaker is not None and speaker not in allowed_speakers:
            errors.append("action_items[{}] has unknown assignee speaker {}".format(index, speaker))
        if basis in ("team_or_role", "unspecified") and speaker is not None:
            errors.append("action_items[{}] assigns a person for {}".format(index, basis))
        if basis == "self_reference":
            quotes = (item.get("evidence") or {}).get("quote", "")
            if not re.search(r"(^|[\s,.'\"])(제가|내가)([\s,.'\"]|$)", quotes):
                errors.append("action_items[{}] claims self_reference without singular self-reference evidence".format(index))
        if basis == "speaker_commitment" and speaker is None:
            errors.append("action_items[{}] speaker_commitment has no speaker".format(index))
        if basis in ("self_reference", "speaker_commitment") and speaker is not None:
            evidence_id = (item.get("evidence") or {}).get("utterance_id")
            evidence_row = transcript.get(evidence_id)
            if evidence_row is not None and evidence_row.get("speaker") != speaker:
                errors.append("action_items[{}] {} evidence is spoken by {}, not assignee {}".format(
                    index, basis, evidence_row.get("speaker"), speaker
                ))
        due_date = item.get("due_date")
        if due_date is not None:
            try:
                dt.date.fromisoformat(due_date)
            except (TypeError, ValueError):
                errors.append("action_items[{}] has invalid due_date {}".format(index, due_date))

    for index, item in enumerate(draft.get("review_flags", [])):
        utterance_id = item.get("related_utterance_id")
        if utterance_id is not None and utterance_id not in transcript:
            errors.append("review_flags[{}] references unknown utterance {}".format(index, utterance_id))
    return errors


def atomic_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main():
    args = parse_args()
    api_key = os.environ.get(args.api_key_env, "").strip()
    if not api_key:
        raise SystemExit("Missing API key environment variable: {}".format(args.api_key_env))

    source_dates = {
        row["source_id"]: (row.get("metadata") or {}).get("date")
        for row in read_jsonl(args.source_index)
    }
    requested = set(args.case_id or [])
    cases = [case for case in read_jsonl(args.manifest) if case.get("split") == "development"]
    if requested:
        cases = [case for case in cases if case["case_id"] in requested]
        missing = requested - {case["case_id"] for case in cases}
        if missing:
            raise SystemExit("Requested case IDs are not development cases: {}".format(", ".join(sorted(missing))))

    report = []
    for position, case in enumerate(cases, start=1):
        output_path = args.output_dir / (case["case_id"] + ".model-suggestion.json")
        if output_path.exists() and not args.force:
            report.append({"case_id": case["case_id"], "status": "skipped_existing"})
            print("[{}/{}] {} skipped (exists)".format(position, len(cases), case["case_id"]), flush=True)
            continue
        print("[{}/{}] {} requesting".format(position, len(cases), case["case_id"]), flush=True)
        last_error = None
        for attempt in range(1, args.attempts + 1):
            try:
                draft, provider = call_api(
                    args.endpoint,
                    api_key,
                    request_payload(case, source_dates.get(case["source"]["source_id"]), args.model, args.max_tokens),
                    args.timeout,
                )
                break
            except Exception as error:
                last_error = error
                print("[{}/{}] {} attempt {}/{} failed: {}".format(
                    position, len(cases), case["case_id"], attempt, args.attempts, str(error)[:300]
                ), flush=True)
        else:
            report.append({"case_id": case["case_id"], "status": "request_failed", "error": str(last_error)[:500]})
            continue
        normalizations = normalize_draft(draft)
        errors = validate_draft(case, draft)
        result = {
            "schema_version": "haena-meeting-execution-draft-v0.2",
            "case_id": case["case_id"],
            "split": "development",
            "draft_status": "model_suggestion",
            "human_review": {
                "status": "pending",
                "all_candidates_reviewed": False,
                "missing_items_checked": False,
                "reviewer_notes": "",
            },
            "source": {
                "source_id": case["source"]["source_id"],
                "topic": case["source"].get("topic"),
                "meeting_date": source_dates.get(case["source"]["source_id"]),
                "target_speaker": case.get("target_speaker"),
            },
            "model_run": {
                "provider": "company_vllm",
                "requested_model": args.model,
                "response_model": provider.get("response_model"),
                "finish_reason": provider.get("finish_reason"),
                "usage": provider.get("usage"),
                "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            },
            "local_validation": {
                "passed": not errors,
                "errors": errors,
                "normalizations": normalizations,
            },
            "suggestion": draft,
        }
        atomic_write(output_path, result)
        status = "generated_valid" if not errors else "generated_invalid"
        report.append({"case_id": case["case_id"], "status": status, "validation_errors": errors})
        print("[{}/{}] {} {}".format(position, len(cases), case["case_id"], status), flush=True)

    atomic_write(args.output_dir / "draft-generation-report.json", {
        "schema_version": "haena-meeting-execution-draft-report-v0.1",
        "model": args.model,
        "case_count": len(cases),
        "results": report,
    })
    if any(item["status"] in ("generated_invalid", "request_failed") for item in report):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
