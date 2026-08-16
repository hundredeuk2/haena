# HAENA benchmark data contract

HAENA의 현재 제품 가설은 “녹음이 된다”가 아니라, 회의에서 나온 근거를 보존하면서 결정·업무·미해결 질문·다음 아젠다를 실행 가능한 상태로 전환할 수 있다는 것입니다. 따라서 한 종류의 점수로 전체 제품을 검증하지 않습니다.

## Benchmark layers

### `meeting-execution-v0`

- 대상: `기타 녹음` 중 실제 회의·온라인 회의 라벨에서 선택한 24개 텍스트 구간
- 목적: 결정, Action Item, Open Question, Next Agenda와 상태 전환의 정확성 검토
- 구성: 단일 산출물 8, 복합 산출물 4, 음성적 근거가 없는 추론 금지 4, 담당자·기한 모호성 4, 이전 상태 전환 4
- 분할: 개발 16 / 봉인 holdout 8
- 중요 경계: 자동 선별 신호는 정답이 아닙니다. 모든 의미 정답은 `human_review_pending`에서 시작하며 사람이 원문 근거를 검토한 뒤에만 확정합니다.

### `audio-robustness-v0`

- 대상: 현재 로컬에 풀려 있는 공중파 방송 WAV에서 원 발화 경계로 자른 24개 약 5분 구간
- 목적: CER, 화자 수 오차, 화자 귀속 정확도, target speaker B F1, speaker-attributed CER, 처리시간 검증
- 구성: clean 8 / turn-heavy 8 / noisy-stress 8, 정치 8 / 사회 8 / 기타 8
- 분할: 개발 16 / 봉인 holdout 8, 원본 파일 중복 없음
- 중요 경계: 공중파 토론은 HAENA의 결정·업무 의미 정확도를 대표하지 않으므로 Meeting Execution 점수를 매기지 않습니다.

### 이후 계층

- `audio-to-execution-v0`: 실제 회의형 원천 WAV를 ZIP에서 필요한 ID만 선택 추출한 8개 구간. 데이터 이용 범위와 외부 처리 허용 여부를 확인한 뒤 진행합니다.
- S3/S5 self-dogfood: 동의받은 3–5인 자연 회의, 겹침 발화, 한영 혼용·고유명사·날짜·숫자를 별도로 검증합니다.

## Local data layout

생성 결과는 `.gitignore`의 `/data/` 아래 `data/benchmarks/haena-v0/`에만 둡니다.

```text
haena-v0/
  build-report.json
  source-index.jsonl
  meeting-execution-v0/
    source-index.jsonl     # Harness 전용 metadata-only discovery index
    manifest.jsonl
    cases/MEV0-*.json
  audio-robustness-v0/
    manifest.jsonl
    gold/ARV0-*.json
    clips/                 # 요청한 경우에만 생성
```

`meeting-execution-v0/source-index.jsonl`의 허용 키는 `case_id`, `split`, `benchmark`,
`schema_version`, `review_status`, `case_path`뿐입니다. `case_path`는
`cases/<case_id>.json` 형식의 상대 경로입니다. Harness는 이 index만 discovery에 사용하며,
transcript가 포함된 `manifest.jsonl`은 생성·검증·사람 검토용 데이터일 뿐 Harness 입력 경로가
아닙니다. 상위 `source-index.jsonl`은 원천 corpus inventory로 서로 다른 파일입니다.

Audio development gold의 `metric_scope`는 `cer`, `speaker_count_error`, `der`,
`speaker_attribution_accuracy`, `target_speaker_b_f1`, `speaker_attributed_cer`,
`real_time_factor`의 정확한 7개 집합이어야 합니다. 누락·추가·중복 값은 development index 승인
후 malformed case로 거부하며, 이 검사를 위해 sealed gold를 열지 않습니다.

생성:

```bash
python3 scripts/benchmarks/build_haena_benchmark_data.py \
  --source-root 'data/benchmarks/002.주요 영역별 회의 음성인식 데이터/01.데이터' \
  --output-root data/benchmarks/haena-v0
```

검증:

```bash
python3 scripts/benchmarks/validate_haena_benchmark_data.py \
  --source-root 'data/benchmarks/002.주요 영역별 회의 음성인식 데이터/01.데이터' \
  --output-root data/benchmarks/haena-v0
```

24개 클립을 실제로 만들 필요가 생겼을 때만 생성 명령에 `--materialize-audio`를 추가합니다. 현재 PCM 형식에서는 24개 합계가 약 220MiB이며 각 클립은 앱의 25MiB 제한 안에 있어야 합니다.

## Data boundary

- 생성기는 표준 라이브러리만 사용하며 네트워크 호출을 하지 않습니다.
- 원본·구간 WAV·전사·gold·manifest는 커밋하거나 재배포하지 않습니다.
- 외부 모델 제공자에게 오디오·전사·gold를 보내기 전에 데이터셋의 별도 허용 범위를 확인합니다.
- 데이터셋을 이용한 파생 결과의 공개·외부 제공도 출처 표시와 이용 조건을 다시 확인합니다.
- 근거: [AI Hub AI 데이터 이용정책](https://aihub.or.kr/intrcn/guid/usagepolicy.do?currMenu=151&topMenu=105)

## Human review gate

`meeting-execution-v0`의 각 사례는 다음 항목을 사람이 확정해야 gold로 사용할 수 있습니다.

1. 발화자 A/B/C 매핑과 target B의 자기지시(“제가”)가 올바른지
2. 각 산출물의 직접 근거 발화와 명시성
3. 담당자·기한이 명시인지, 문맥 도출인지, 추론 금지인지
4. 결정·Action Item·Open Question·Next Agenda의 경계
5. 이전 상태가 있을 때 생성·갱신·해결·완료 전환
6. 시스템이 절대 생성하면 안 되는 `forbidden_inferences`

봉인 holdout은 개발 프롬프트와 규칙을 정하는 동안 열람하거나 수정하지 않습니다.
