#!/usr/bin/env python3
"""Build HAENA's local-only benchmark manifests from the AI Hub corpus.

The script deliberately does not call a network service. It creates text-review
cases and audio clip manifests under an ignored data directory. Audio clips are
only copied when --materialize-audio is supplied.
"""

import argparse
import hashlib
import json
import math
import re
import statistics
import unicodedata
import wave
from collections import Counter, defaultdict
from pathlib import Path


SCHEMA_VERSION = "haena-benchmark-v0.1"
WINDOW_SECONDS = 300.0
MEETING_QUOTAS = {
    "explicit_single_output": 8,
    "multi_output": 4,
    "negative_or_forbidden": 4,
    "assignee_or_due_ambiguity": 4,
    "prior_state_transition": 4,
}
AUDIO_CELL_QUOTAS = {
    ("politics", "clean"): 3,
    ("politics", "turn_heavy"): 3,
    ("politics", "noisy_stress"): 2,
    ("society", "clean"): 3,
    ("society", "turn_heavy"): 2,
    ("society", "noisy_stress"): 3,
    ("other", "clean"): 2,
    ("other", "turn_heavy"): 3,
    ("other", "noisy_stress"): 3,
}
AUDIO_HOLDOUT_CELL_QUOTAS = {
    ("other", "clean"): 1,
    ("other", "turn_heavy"): 0,
    ("other", "noisy_stress"): 1,
    ("politics", "clean"): 1,
    ("politics", "turn_heavy"): 1,
    ("politics", "noisy_stress"): 1,
    ("society", "clean"): 0,
    ("society", "turn_heavy"): 2,
    ("society", "noisy_stress"): 1,
}
EXPOSED_HOLDOUT_CASE_IDS = {
    "meeting-execution-v0": ("MEV0-001",),
    "audio-robustness-v0": ("ARV0-001",),
}
ACTION_PATTERNS = (
    "하겠습니다", "하도록", "해주세요", "해 주세요", "해야", "부탁", "준비", "제출",
    "공유", "전달", "검토", "확인", "보고", "정리", "작성", "연락", "결정", "확정",
)
DUE_PATTERNS = ("까지", "오늘", "내일", "이번 주", "다음 주", "금요일", "월요일", "마감")
SELF_PATTERNS = ("제가", "저희가", "제가요", "내가", "우리 쪽에서")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--materialize-audio", action="store_true")
    parser.add_argument(
        "--refresh-discovery-index-only",
        action="store_true",
        help="Swap exposed cases using existing metadata-only benchmark indexes; opens no content",
    )
    return parser.parse_args()


def dump_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def dump_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")


def benchmark_source_index_rows(cases, case_directory):
    """Return the exact transcript-free discovery contract consumed by the harness."""
    return [
        {
            "case_id": case["case_id"],
            "split": case["split"],
            "benchmark": case["benchmark"],
            "schema_version": case["schema_version"],
            "review_status": case["review_status"],
            "case_path": "{}/{}.json".format(case_directory, case["case_id"]),
        }
        for case in cases
    ]


def replace_exposed_holdouts(cases, benchmark, stratum_keys):
    """Move exposed holdouts to development using metadata-only stable replacements.

    Selection is deliberately limited to case identifiers and finite stratum metadata. Transcript,
    gold, source identity, audio metadata, and content-derived scores are never consulted. Choosing
    within the same stratum preserves the existing benchmark balance, while sorting by case_id makes
    repeated generation byte-for-byte deterministic.
    """
    changed = []
    by_id = {case["case_id"]: case for case in cases}
    for exposed_id in EXPOSED_HOLDOUT_CASE_IDS.get(benchmark, ()):
        exposed = by_id.get(exposed_id)
        if exposed is None or exposed["split"] != "sealed_holdout":
            raise RuntimeError("Expected exposed case to be a sealed holdout: {}".format(exposed_id))

        stratum = tuple(exposed[key] for key in stratum_keys)
        candidates = sorted(
            (
                case for case in cases
                if case["split"] == "development"
                and tuple(case[key] for key in stratum_keys) == stratum
                and case["case_id"] not in EXPOSED_HOLDOUT_CASE_IDS.get(benchmark, ())
            ),
            key=lambda case: case["case_id"],
        )
        if not candidates:
            raise RuntimeError("No metadata-only holdout replacement for {}".format(exposed_id))

        replacement = candidates[0]
        exposed["split"] = "development"
        replacement["split"] = "sealed_holdout"
        changed.append({
            "exposed_case_id": exposed_id,
            "replacement_case_id": replacement["case_id"],
            "selection": "first_development_case_id_in_same_metadata_stratum",
        })
    return changed


def read_strict_benchmark_source_index(path, benchmark, case_directory, expected_review_status):
    allowed_keys = {
        "schema_version", "benchmark", "case_id", "split", "review_status", "case_path"
    }
    if not path.is_file():
        raise RuntimeError("Metadata-only source index is missing: {}".format(path.name))
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            row = json.loads(line)
            case_id = row.get("case_id", "")
            if (
                set(row) != allowed_keys
                or row.get("benchmark") != benchmark
                or row.get("review_status") != expected_review_status
                or not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", case_id)
                or row.get("case_path") != "{}/{}.json".format(case_directory, case_id)
                or row.get("split") not in ("development", "sealed_holdout")
            ):
                raise RuntimeError("Malformed metadata-only source index line {}".format(line_number))
            rows.append(row)
    if len(rows) != 24 or Counter(row["split"] for row in rows) != Counter({
        "development": 16, "sealed_holdout": 8,
    }):
        raise RuntimeError("Metadata-only source index must contain a 16/8 split")
    return rows


def swap_existing_index_rows(rows, exposed_id, replacement_id):
    by_id = {row["case_id"]: row for row in rows}
    if len(by_id) != len(rows) or exposed_id not in by_id or replacement_id not in by_id:
        raise RuntimeError("Metadata-only replacement case IDs are unavailable")
    exposed = by_id[exposed_id]
    replacement = by_id[replacement_id]
    current = (exposed["split"], replacement["split"])
    if current == ("sealed_holdout", "development"):
        exposed["split"] = "development"
        replacement["split"] = "sealed_holdout"
        return True
    if current == ("development", "sealed_holdout"):
        return False
    raise RuntimeError("Metadata-only replacement precondition is not satisfied")


def refresh_existing_discovery_indexes(output_root):
    """Idempotently correct existing indexes without opening manifests or case assets.

    Both indexes are read and validated before either is written, so a missing audio index cannot
    leave a partially refreshed corpus. This mode intentionally cannot reconstruct an absent audio
    index: the other seven original audio holdout IDs are not recoverable from aggregate counts.
    """
    specifications = (
        ("meeting-execution-v0", "cases", "human_review_pending", "MEV0-001", "MEV0-004"),
        ("audio-robustness-v0", "gold", "source_aligned_label", "ARV0-001", "ARV0-002"),
    )
    loaded = []
    for benchmark, case_directory, review_status, exposed_id, replacement_id in specifications:
        path = output_root / benchmark / "source-index.jsonl"
        rows = read_strict_benchmark_source_index(path, benchmark, case_directory, review_status)
        loaded.append((path, rows, exposed_id, replacement_id))

    changed = []
    for path, rows, exposed_id, replacement_id in loaded:
        if swap_existing_index_rows(rows, exposed_id, replacement_id):
            changed.append({"exposed_case_id": exposed_id, "replacement_case_id": replacement_id})
    for path, rows, _, _ in loaded:
        dump_jsonl(path, rows)
    return changed


def relative(path, root):
    return unicodedata.normalize("NFC", path.relative_to(root).as_posix())


def normalized_text(text):
    value = text or ""
    previous = None
    while previous != value:
        previous = value
        value = re.sub(r"\(([^()]*)\)/\(([^()]*)\)", r"\2", value)
    value = re.sub(r"/\([^)]*\)", " ", value)
    value = re.sub(r"@[가-힣A-Za-z_]+", " ", value)
    return re.sub(r"\s+", " ", value).strip()


def topic_family(topic):
    return re.sub(r"\s*\(\d+\)\s*$", "", (topic or "").strip())


def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def read_records(source_root):
    label_files = sorted(source_root.rglob("*.json"), key=lambda p: unicodedata.normalize("NFC", str(p)))
    wav_by_stem = {}
    for wav_path in source_root.rglob("*.wav"):
        wav_by_stem[wav_path.stem] = wav_path

    records = []
    for path in label_files:
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
        metadata = payload.get("metadata", {})
        utterances = payload.get("utterance", [])
        source_id = str(metadata.get("title") or path.stem)
        duration = max((as_float(item.get("end")) for item in utterances), default=0.0)
        speaker_ids = {str(item.get("speaker_id", "")) for item in utterances if item.get("speaker_id")}
        environment_seconds = sum(
            max(0.0, as_float(item.get("end")) - as_float(item.get("start")))
            for item in utterances if str(item.get("environment", "")).strip()
        )
        records.append({
            "source_id": source_id,
            "label_path": relative(path, source_root),
            "audio_path": relative(wav_by_stem[source_id], source_root) if source_id in wav_by_stem else None,
            "metadata": metadata,
            "utterances": utterances,
            "duration_seconds": round(duration, 3),
            "speaker_count_observed": len(speaker_ids),
            "utterance_count": len(utterances),
            "unknown_speaker_utterance_count": sum(1 for item in utterances if item.get("speaker_id") in (None, "", "?")),
            "environment_coverage_ratio": round(environment_seconds / duration, 6) if duration else 0.0,
            "topic_family": topic_family(metadata.get("topic")),
        })
    return records


def source_index_row(record):
    return {key: record[key] for key in (
        "source_id", "label_path", "audio_path", "metadata", "duration_seconds",
        "speaker_count_observed", "utterance_count", "unknown_speaker_utterance_count",
        "environment_coverage_ratio", "topic_family",
    )}


def iter_windows(record, seconds=WINDOW_SECONDS):
    utterances = record["utterances"]
    if not utterances:
        return
    duration = record["duration_seconds"]
    starts = [0.0]
    cursor = seconds
    while cursor + seconds * 0.75 <= duration:
        starts.append(cursor)
        cursor += seconds
    for requested_start in starts:
        selected = [
            item for item in utterances
            if as_float(item.get("end")) > requested_start and as_float(item.get("start")) < requested_start + seconds
        ]
        if not selected:
            continue
        start = as_float(selected[0].get("start"))
        end = as_float(selected[-1].get("end"))
        if end - start < seconds * 0.65:
            continue
        yield start, end, selected


def speaker_mapping(utterances):
    mapping = {}
    for item in utterances:
        source_speaker = str(item.get("speaker_id") or "?")
        if source_speaker not in mapping:
            index = len(mapping)
            mapping[source_speaker] = chr(ord("A") + index) if index < 26 else "S{}".format(index + 1)
    return mapping


def window_features(start, end, utterances):
    mapping = speaker_mapping(utterances)
    durations = [max(0.0, as_float(item.get("end")) - as_float(item.get("start"))) for item in utterances]
    environment_seconds = sum(
        duration for duration, item in zip(durations, utterances) if str(item.get("environment", "")).strip()
    )
    speaker_seconds = defaultdict(float)
    speaker_turns = Counter()
    changes = 0
    previous = None
    for duration, item in zip(durations, utterances):
        speaker = mapping[str(item.get("speaker_id") or "?")]
        speaker_seconds[speaker] += duration
        speaker_turns[speaker] += 1
        if previous is not None and previous != speaker:
            changes += 1
        previous = speaker
    span = max(0.001, end - start)
    return {
        "speaker_mapping": mapping,
        "active_speaker_count": len(mapping),
        "utterance_count": len(utterances),
        "turns_per_minute": round(len(utterances) * 60.0 / span, 3),
        "speaker_changes_per_minute": round(changes * 60.0 / span, 3),
        "median_utterance_seconds": round(statistics.median(durations), 3) if durations else 0.0,
        "environment_coverage_ratio": round(environment_seconds / span, 6),
        "unknown_speaker_utterance_count": sum(1 for item in utterances if item.get("speaker_id") in (None, "", "?")),
        "speaker_seconds": {key: round(value, 3) for key, value in sorted(speaker_seconds.items())},
        "speaker_turns": dict(sorted(speaker_turns.items())),
    }


def transcript_rows(start, utterances, mapping):
    rows = []
    for item in utterances:
        source_speaker = str(item.get("speaker_id") or "?")
        rows.append({
            "utterance_id": item.get("id"),
            "start_seconds": round(as_float(item.get("start")) - start, 3),
            "end_seconds": round(as_float(item.get("end")) - start, 3),
            "speaker": mapping[source_speaker],
            "source_speaker_id": source_speaker,
            "speaker_role": item.get("speaker_role") or "",
            "text_raw": item.get("form") or "",
            "text_normalized": normalized_text(item.get("form") or item.get("original_form") or ""),
            "environment": item.get("environment") or "",
        })
    return rows


def meeting_window_candidates(record):
    results = []
    for start, end, utterances in iter_windows(record):
        features = window_features(start, end, utterances)
        if not (3 <= features["active_speaker_count"] <= 12):
            continue
        if features["speaker_turns"].get("B", 0) < 3 or features["speaker_seconds"].get("B", 0.0) < 8.0:
            continue
        joined = " ".join(item.get("form") or "" for item in utterances)
        b_text = " ".join(
            item.get("form") or "" for item in utterances
            if features["speaker_mapping"].get(str(item.get("speaker_id") or "?")) == "B"
        )
        action_hits = sum(joined.count(pattern) for pattern in ACTION_PATTERNS)
        due_hits = sum(joined.count(pattern) for pattern in DUE_PATTERNS)
        self_b_hits = sum(b_text.count(pattern) for pattern in SELF_PATTERNS)
        question_hits = joined.count("?") + joined.count("습니까") + joined.count("나요")
        signals = {
            "action_keyword_hits": action_hits,
            "due_keyword_hits": due_hits,
            "target_b_self_reference_hits": self_b_hits,
            "question_marker_hits": question_hits,
        }
        scores = {
            "explicit_single_output": action_hits * 2 + due_hits + min(question_hits, 3),
            "multi_output": action_hits * 2 + due_hits * 2 + features["active_speaker_count"],
            "negative_or_forbidden": 40 - action_hits * 4 - due_hits * 3 + min(question_hits, 5),
            "assignee_or_due_ambiguity": self_b_hits * 8 + due_hits * 2 + action_hits,
            "prior_state_transition": action_hits + due_hits + question_hits,
        }
        results.append({
            "record": record, "start": start, "end": end, "utterances": utterances,
            "features": features, "signals": signals, "scores": scores,
        })
    return results


def select_meeting_cases(records):
    meeting_records = [
        record for record in records
        if record["metadata"].get("media") == "기타 녹음"
        and record["metadata"].get("type") in ("회의", "온라인 회의")
    ]
    family_members = defaultdict(list)
    for record in meeting_records:
        family_members[record["topic_family"]].append(record)

    by_focus = defaultdict(list)
    for record in meeting_records:
        candidates = meeting_window_candidates(record)
        if not candidates:
            continue
        for focus in MEETING_QUOTAS:
            best = max(candidates, key=lambda item: (item["scores"][focus], -item["start"]))
            if focus == "prior_state_transition":
                siblings = sorted(family_members[record["topic_family"]], key=lambda item: item["source_id"])
                position = next((index for index, sibling in enumerate(siblings) if sibling["source_id"] == record["source_id"]), 0)
                if len(siblings) < 2 or position == 0:
                    continue
                best = dict(best)
                best["prior_source_id"] = siblings[position - 1]["source_id"]
            by_focus[focus].append(best)

    selected = []
    used_sources = set()
    used_families = set()
    selection_order = (
        "prior_state_transition", "assignee_or_due_ambiguity", "negative_or_forbidden",
        "multi_output", "explicit_single_output",
    )
    for focus in selection_order:
        ranked = sorted(
            by_focus[focus],
            key=lambda item: (-item["scores"][focus], item["record"]["source_id"], item["start"]),
        )
        chosen = []
        for item in ranked:
            record = item["record"]
            if record["source_id"] in used_sources or record["topic_family"] in used_families:
                continue
            chosen.append(item)
            used_sources.add(record["source_id"])
            used_families.add(record["topic_family"])
            if len(chosen) == MEETING_QUOTAS[focus]:
                break
        if len(chosen) != MEETING_QUOTAS[focus]:
            raise RuntimeError("Could not fill meeting quota for {}: {}".format(focus, len(chosen)))
        selected.extend((focus, item) for item in chosen)

    focus_order = list(MEETING_QUOTAS)
    selected.sort(key=lambda pair: (focus_order.index(pair[0]), pair[1]["record"]["source_id"]))
    holdout_quota = {
        "explicit_single_output": 3, "multi_output": 1, "negative_or_forbidden": 1,
        "assignee_or_due_ambiguity": 1, "prior_state_transition": 2,
    }
    holdout_seen = Counter()
    cases = []
    for index, (focus, item) in enumerate(selected, start=1):
        split = "sealed_holdout" if holdout_seen[focus] < holdout_quota[focus] else "development"
        if split == "sealed_holdout":
            holdout_seen[focus] += 1
        record = item["record"]
        mapping = item["features"]["speaker_mapping"]
        cases.append({
            "schema_version": SCHEMA_VERSION,
            "benchmark": "meeting-execution-v0",
            "case_id": "MEV0-{:03d}".format(index),
            "split": split,
            "review_status": "human_review_pending",
            "review_focus": focus,
            "target_speaker": "B",
            "source": {
                "source_id": record["source_id"],
                "label_path": record["label_path"],
                "media": record["metadata"].get("media"),
                "type": record["metadata"].get("type"),
                "domain": record["metadata"].get("domain"),
                "topic": record["metadata"].get("topic"),
                "topic_family": record["topic_family"],
                "prior_source_id": item.get("prior_source_id"),
            },
            "window": {
                "source_start_seconds": round(item["start"], 3),
                "source_end_seconds": round(item["end"], 3),
                "duration_seconds": round(item["end"] - item["start"], 3),
            },
            "speaker_mapping": mapping,
            "features": item["features"],
            "heuristic_selection_signals_not_gold": item["signals"],
            "transcript": transcript_rows(item["start"], item["utterances"], mapping),
            "prior_state": None,
            "gold": {
                "status": "human_review_pending",
                "decisions": None,
                "action_items": None,
                "open_questions": None,
                "next_agenda": None,
                "expected_state_transitions": None,
                "forbidden_inferences": None,
                "reviewer_notes": "",
            },
        })
    replacements = replace_exposed_holdouts(
        cases,
        benchmark="meeting-execution-v0",
        stratum_keys=("review_focus",),
    )
    return cases, replacements


def audio_domain(metadata):
    domain = metadata.get("domain")
    if domain == "정치":
        return "politics"
    if domain == "사회":
        return "society"
    return "other"


def audio_scores(features):
    speakers = features["active_speaker_count"]
    environment = features["environment_coverage_ratio"]
    unknown = features["unknown_speaker_utterance_count"]
    turn_rate = features["turns_per_minute"]
    changes = features["speaker_changes_per_minute"]
    median = features["median_utterance_seconds"]
    return {
        "clean": -(abs(speakers - 4) * 5 + environment * 200 + unknown * 3 + abs(median - 4)),
        "turn_heavy": turn_rate * 2 + changes * 3 - environment * 20 - abs(speakers - 4),
        "noisy_stress": environment * 300 + unknown * 8 + max(0, speakers - 5) * 5 + turn_rate,
    }


def inspect_wav(path):
    with wave.open(str(path), "rb") as handle:
        return {
            "channels": handle.getnchannels(),
            "sample_rate_hz": handle.getframerate(),
            "sample_width_bytes": handle.getsampwidth(),
            "frame_count": handle.getnframes(),
            "compression": handle.getcomptype(),
        }


def select_audio_cases(records, source_root):
    by_cell = defaultdict(list)
    for record in records:
        if record["metadata"].get("media") != "공중파방송" or not record["audio_path"]:
            continue
        audio_path = source_root / record["audio_path"]
        wav = inspect_wav(audio_path)
        if wav["compression"] != "NONE":
            continue
        for start, end, utterances in iter_windows(record):
            features = window_features(start, end, utterances)
            if not (3 <= features["active_speaker_count"] <= 12):
                continue
            if features["speaker_turns"].get("B", 0) < 3 or features["speaker_seconds"].get("B", 0.0) < 8.0:
                continue
            candidate = {
                "record": record, "start": start, "end": end, "utterances": utterances,
                "features": features, "wav": wav, "scores": audio_scores(features),
            }
            domain = audio_domain(record["metadata"])
            for difficulty in ("clean", "turn_heavy", "noisy_stress"):
                by_cell[(domain, difficulty)].append(candidate)

    selected = []
    used_sources = set()
    cell_order = sorted(AUDIO_CELL_QUOTAS, key=lambda cell: (len(by_cell[cell]), cell))
    for cell in cell_order:
        domain, difficulty = cell
        ranked = sorted(
            by_cell[cell],
            key=lambda item: (-item["scores"][difficulty], item["record"]["source_id"], item["start"]),
        )
        count = 0
        for item in ranked:
            source_id = item["record"]["source_id"]
            if source_id in used_sources:
                continue
            selected.append((domain, difficulty, item))
            used_sources.add(source_id)
            count += 1
            if count == AUDIO_CELL_QUOTAS[cell]:
                break
        if count != AUDIO_CELL_QUOTAS[cell]:
            raise RuntimeError("Could not fill audio quota for {}: {}".format(cell, count))

    selected.sort(key=lambda value: (value[0], value[1], value[2]["record"]["source_id"]))
    holdout_ids = set()
    for cell, quota in AUDIO_HOLDOUT_CELL_QUOTAS.items():
        cell_items = [value for value in selected if value[:2] == cell]
        ranked = sorted(
            cell_items,
            key=lambda value: hashlib.sha256(value[2]["record"]["source_id"].encode()).hexdigest(),
        )
        holdout_ids.update(value[2]["record"]["source_id"] for value in ranked[:quota])
    cases = []
    for index, (domain, difficulty, item) in enumerate(selected, start=1):
        record = item["record"]
        mapping = item["features"]["speaker_mapping"]
        wav = item["wav"]
        start_frame = max(0, math.floor(item["start"] * wav["sample_rate_hz"]))
        end_frame = min(wav["frame_count"], math.ceil(item["end"] * wav["sample_rate_hz"]))
        expected_bytes = (end_frame - start_frame) * wav["channels"] * wav["sample_width_bytes"] + 44
        case_id = "ARV0-{:03d}".format(index)
        cases.append({
            "schema_version": SCHEMA_VERSION,
            "benchmark": "audio-robustness-v0",
            "case_id": case_id,
            "split": "sealed_holdout" if record["source_id"] in holdout_ids else "development",
            "review_status": "source_aligned_label",
            "difficulty_bucket": difficulty,
            "domain_bucket": domain,
            "target_speaker": "B",
            "source": {
                "source_id": record["source_id"],
                "label_path": record["label_path"],
                "audio_path": record["audio_path"],
                "domain": record["metadata"].get("domain"),
                "topic": record["metadata"].get("topic"),
            },
            "clip": {
                "relative_path": "audio-robustness-v0/clips/{}.wav".format(case_id),
                "source_start_seconds": round(item["start"], 3),
                "source_end_seconds": round(item["end"], 3),
                "duration_seconds": round(item["end"] - item["start"], 3),
                "start_frame": start_frame,
                "end_frame": end_frame,
                "expected_pcm_bytes": expected_bytes,
                "materialized": False,
            },
            "audio_format": wav,
            "speaker_mapping": mapping,
            "features": item["features"],
            "gold": {
                "status": "source_aligned_label",
                "transcript": transcript_rows(item["start"], item["utterances"], mapping),
                "metric_scope": [
                    "cer", "speaker_count_error", "der", "speaker_attribution_accuracy",
                    "target_speaker_b_f1", "speaker_attributed_cer", "real_time_factor",
                ],
                "meeting_execution_semantics_scored": False,
            },
        })
    replacements = replace_exposed_holdouts(
        cases,
        benchmark="audio-robustness-v0",
        stratum_keys=("domain_bucket", "difficulty_bucket"),
    )
    return cases, replacements


def materialize_audio(cases, source_root, output_root):
    for case in cases:
        source_path = source_root / case["source"]["audio_path"]
        destination = output_root / case["clip"]["relative_path"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        with wave.open(str(source_path), "rb") as reader:
            reader.setpos(case["clip"]["start_frame"])
            frames = reader.readframes(case["clip"]["end_frame"] - case["clip"]["start_frame"])
            with wave.open(str(destination), "wb") as writer:
                writer.setparams(reader.getparams())
                writer.writeframes(frames)
        case["clip"]["materialized"] = True


def write_local_readme(output_root, index_count):
    text = "# HAENA local benchmark data\n\n"
    text += "This directory is local-only and is excluded by `/data/` in `.gitignore`.\n"
    text += "It was generated from {} label files without any network call.\n\n".format(index_count)
    text += "- `source-index.jsonl`: transcript-free source-corpus inventory (metadata and counts only).\n"
    text += "- `meeting-execution-v0/source-index.jsonl`: transcript-free Harness discovery index (16 development / 8 sealed holdout).\n"
    text += "- `audio-robustness-v0/source-index.jsonl`: transcript-free Audio Harness discovery index (16 development / 8 sealed holdout).\n"
    text += "- `meeting-execution-v0/manifest.jsonl`: 24 review candidates. Semantic gold is not valid until a human changes `human_review_pending`.\n"
    text += "- `audio-robustness-v0/manifest.jsonl`: 24 source-aligned 5-minute clip definitions. Clips are not duplicated unless explicitly requested.\n"
    text += "- Do not upload, commit, redistribute, or send these files to an external model provider without confirming the dataset permission.\n"
    (output_root / "README.local.md").write_text(text, encoding="utf-8")


def main():
    args = parse_args()
    output_root = args.output_root.resolve()
    if args.refresh_discovery_index_only:
        if args.materialize_audio:
            raise SystemExit("--materialize-audio is incompatible with metadata-only refresh")
        try:
            changed = refresh_existing_discovery_indexes(output_root)
        except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
            raise SystemExit(str(error))
        print(json.dumps({
            "mode": "metadata_only_discovery_refresh",
            "changed": changed,
            "meeting_execution_split": {"development": 16, "sealed_holdout": 8},
            "audio_robustness_split": {"development": 16, "sealed_holdout": 8},
            "manifest_case_gold_audio_reads": 0,
        }, ensure_ascii=False, indent=2))
        return

    if args.source_root is None:
        raise SystemExit("--source-root is required unless --refresh-discovery-index-only is used")
    source_root = args.source_root.resolve()
    if not source_root.exists():
        raise SystemExit("Source root does not exist: {}".format(source_root))
    output_root.mkdir(parents=True, exist_ok=True)

    records = read_records(source_root)
    meeting_cases, meeting_replacements = select_meeting_cases(records)
    audio_cases, audio_replacements = select_audio_cases(records, source_root)
    if args.materialize_audio:
        materialize_audio(audio_cases, source_root, output_root)

    dump_jsonl(output_root / "source-index.jsonl", [source_index_row(record) for record in records])
    dump_jsonl(
        output_root / "meeting-execution-v0" / "source-index.jsonl",
        benchmark_source_index_rows(meeting_cases, "cases"),
    )
    dump_jsonl(
        output_root / "audio-robustness-v0" / "source-index.jsonl",
        benchmark_source_index_rows(audio_cases, "gold"),
    )
    dump_jsonl(output_root / "meeting-execution-v0" / "manifest.jsonl", meeting_cases)
    dump_jsonl(output_root / "audio-robustness-v0" / "manifest.jsonl", audio_cases)
    for case in meeting_cases:
        dump_json(output_root / "meeting-execution-v0" / "cases" / (case["case_id"] + ".json"), case)
    for case in audio_cases:
        dump_json(output_root / "audio-robustness-v0" / "gold" / (case["case_id"] + ".json"), case)

    report = {
        "schema_version": SCHEMA_VERSION,
        "network_calls": 0,
        "data_policy": {
            "storage": "local_only",
            "git_commit_allowed": False,
            "external_provider_upload_allowed": False,
            "semantic_gold_requires_human_review": True,
        },
        "source_index_count": len(records),
        "source_media_counts": dict(sorted(Counter(record["metadata"].get("media", "") for record in records).items())),
        "quality_profile": {
            "duplicate_source_id_count": len(records) - len({record["source_id"] for record in records}),
            "labels_without_utterances": sum(1 for record in records if not record["utterances"]),
            "utterances_with_invalid_time_order": sum(
                1 for record in records for item in record["utterances"]
                if as_float(item.get("end")) < as_float(item.get("start"))
            ),
            "unknown_speaker_utterance_count": sum(record["unknown_speaker_utterance_count"] for record in records),
            "public_broadcast_label_count": sum(1 for record in records if record["metadata"].get("media") == "공중파방송"),
            "public_broadcast_audio_match_count": sum(
                1 for record in records
                if record["metadata"].get("media") == "공중파방송" and record["audio_path"]
            ),
            "eligible_meeting_label_count": sum(
                1 for record in records
                if record["metadata"].get("media") == "기타 녹음"
                and record["metadata"].get("type") in ("회의", "온라인 회의")
            ),
        },
        "meeting_execution": {
            "case_count": len(meeting_cases),
            "split_counts": dict(Counter(case["split"] for case in meeting_cases)),
            "focus_counts": dict(Counter(case["review_focus"] for case in meeting_cases)),
        },
        "audio_robustness": {
            "case_count": len(audio_cases),
            "split_counts": dict(Counter(case["split"] for case in audio_cases)),
            "difficulty_counts": dict(Counter(case["difficulty_bucket"] for case in audio_cases)),
            "domain_counts": dict(Counter(case["domain_bucket"] for case in audio_cases)),
            "clips_materialized": sum(1 for case in audio_cases if case["clip"]["materialized"]),
            "predicted_clip_bytes": sum(case["clip"]["expected_pcm_bytes"] for case in audio_cases),
        },
        "metadata_only_holdout_replacements": {
            "meeting_execution": meeting_replacements,
            "audio_robustness": audio_replacements,
        },
    }
    dump_json(output_root / "build-report.json", report)
    write_local_readme(output_root, len(records))
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
