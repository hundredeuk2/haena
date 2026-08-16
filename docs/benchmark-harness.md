# HAENA benchmark harness

이 문서의 기본 명령은 사람이 확정한 semantic gold가 없는 meeting-execution case를 HAE.NA의
**실제 extraction 계약**에 반복 입력하고, 결과와 실행 조건을 재현 가능하게 남기는 harness입니다.
같은 개발 전용 binary의 `audio` subcommand에는 source-aligned gold를 사용하는 별도 Audio/STT v0
runner와 scorer가 있습니다. 두 report 계약은 섞이지 않습니다.

meeting-execution harness는 **점수를 계산하지 않습니다.** 확정된 semantic gold가 없는 상태에서
0점을 적어두면 그것은 측정이 아니라 조작이므로 모든 결과의 scoring status는 `unscored`입니다.
Audio/STT scorer의 시간·문자 지표는 Meeting Execution 의미 점수가 아닙니다.

## 무엇을 실행하는가

앱이 실제로 쓰는 두 단계만 직접 호출합니다.

```
source-index.jsonl            (transcript 없는 discovery metadata)
  → BenchmarkCaseStore        (split discovery + holdout 잠금)
        → development case JSON만 개별 로드
  → BenchmarkExtractionInputAdapter
        → Meeting / Participant / TranscriptSegment / WorkStateExtractionInput
  → WorkStateExtractor.extract(from:)            ← 앱과 동일한 provider-neutral seam
  → WorkStateProposalMapper.map(...)             ← 앱과 동일한 근거 검증
  → PredictionArtifact (prediction-v0.1)
```

`WorkStateExtractionService`는 **쓰지 않습니다.** 그것은 결과를 `ProjectRepository`에 저장하는
서비스이고, benchmark 실행이 사용자 프로젝트를 건드릴 이유는 없습니다. `HAENABenchmarkCLI`
타깃은 아예 그 파일과 `HAENA/Persistence`를 컴파일하지 않으므로, 저장 경로는 검토 규율이 아니라
링크 단계에서 차단됩니다.

`BenchmarkCaseStore`는 transcript가 든 `manifest.jsonl`을 discovery에 사용하지 않습니다.
허용 키가 `case_id`, `split`, `benchmark`, `schema_version`, `review_status`, `case_path`뿐인
`source-index.jsonl`만 읽고, development 선택 뒤 해당 case 파일만 엽니다. 전체 development 실행을
Recording FileManager로 검사해 manifest 접근 0회와 holdout case 접근 0회를 회귀 테스트로 고정합니다.

## 앱 패키징 경계

`project.yml`의 HAENA 앱 타깃은 `HAENA/Benchmark`를 소스에서 제외합니다. Benchmark 구현은
독립 `HAENABenchmarkCLI`와 `HAENABenchmarkTests` 두 타깃만 컴파일합니다. 테스트 타깃은 앱의
내부 domain seam을 검증하기 위해 hosted test bundle로 구성되지만, 앱은 테스트나 CLI를 의존하지
않습니다. 따라서 Debug 테스트 편의가 Release HAENA.app의 compile/link/package 경계를 넓히지
않습니다.

## 실행

```bash
scripts/benchmarks/run_meeting_execution_harness.sh
```

빌드부터 development 16건 오프라인 실행까지 합니다. 직접 부를 때는:

```bash
haena-benchmark --dataset-root data/benchmarks/haena-v0/meeting-execution-v0 --output-dir <경로>
```

Audio/STT v0는 명시적인 원본 root가 추가로 필요합니다. 기본 provider는 reference를 보지 않는
빈-recognition fake이며 network와 credential을 사용하지 않습니다.

```bash
haena-benchmark audio \
  --dataset-root data/benchmarks/haena-v0/audio-robustness-v0 \
  --source-root <로컬 AI Hub corpus root> \
  --output-dir <경로>
```

`--provider openai` adapter 계약은 컴파일되지만, 이번 v0 CLI는 별도 provider·전송·비용 승인 전까지
실행을 거부합니다. Audio의 metric, holdout, 임시 WAV, report 계약은
[audio-stt-benchmark.md](audio-stt-benchmark.md)에 고정되어 있습니다.

| 옵션 | 뜻 |
|---|---|
| `--dataset-root <path>` | corpus 루트. 필수 |
| `--output-dir <path>` | artifact 기록 위치. **필수이며 기본값이 없습니다** — 기본 경로가 있으면 사용자 데이터 디렉터리로 흘러듭니다 |
| `--split development\|sealed_holdout` | 기본 `development` |
| `--case <ID>` | 반복 가능. 주면 `--split`보다 우선 |
| `--provider stub\|openai` | 기본 `stub`(in-process, network 0) |
| `--allow-network` | 외부 provider의 network 사용 허용 |
| `--i-accept-dataset-transfer` | corpus 전사를 외부 provider에 보내는 것에 대한 동의 |
| `--unlock-sealed-holdout` | 봉인 holdout 열람 허용 |
| `--git-revision <sha>` | 기본값은 현재 short HEAD |

종료 코드: `0` 전건 성공, `1` 일부 case 실패, `2` 인자·정책·corpus 오류.

## 산출물

`<output-dir>/<CASE-ID>.prediction.json` (case당 1건)과 `<output-dir>/run-report.json`(개수만).

`prediction-v0.1`은 `model_suggestion` draft와도, 사람 gold와도 **다른 스키마**입니다.
`artifact_kind: "haena_prediction"`으로 파일만 보고도 구분됩니다.

- provenance: `source_case_hash`, `dataset_schema_version`, `extraction_schema_version`,
  `prompt_revision`, `git_revision`, `provider`, `model_id`, `run_mode`, `executed_at`
- 결과: `raw`(모델이 말한 그대로) / `mapped`(mapper가 수락) / `rejected`(구조화된 탈락 사유)
- 모든 evidence에 원 corpus `utterance_id`가 함께 기록됩니다
- `scoring`: 항상 `{"status": "unscored", "reason": "human_review_pending"}`

`executed_at`은 의도적으로 매번 달라지는 값이므로 재현성 비교에서 제외합니다. 그 외 모든 필드는
같은 입력·같은 extractor에 대해 byte 단위로 동일합니다(`PredictionArtifact.reproducibleFields`).

### rejection 사유

조용히 버리지 않고 전부 기록합니다.

| stage | reason | 언제 |
|---|---|---|
| `input` | `unknown_speaker` | corpus의 화자를 A/B/C 매핑으로 해석할 수 없음 |
| `mapper` | `evidence_not_found` | 인용한 segment가 이 회의에 없음 |
| `mapper` | `quote_not_in_transcript` | 인용문이 해당 발화에 그대로 존재하지 않음 |
| `mapper` | `missing_required_field` | 내용이 비어 있음 |
| `mapper` | `confidence_out_of_range` | confidence가 [0,1] 밖 |
| `mapper` | `unsupported_proposal_type` | 건별 매핑과 전체 매핑 결과가 불일치 |
| `mapper` | `mapper_validation_failed` | 위에 이름이 없는 mapper 거절 |

## 경계

- **봉인 holdout은 기본 차단입니다.** 경고가 아니라 실패입니다. 잠긴 case는 점수를 안 매기는
  정도가 아니라 **파일을 열지 않습니다** — 전체 split 요청은 index보다 먼저 거절되고, explicit
  case 요청은 transcript-free index로 split만 판별한 뒤 case 파일을 열기 전에 거절됩니다.
- **외부 provider는 기본 비활성화입니다.** `--provider` 지정, `--allow-network`,
  `--i-accept-dataset-transfer` 세 가지가 모두 있어야 통과합니다. 전송 동의와 network 허용은
  별개의 결정입니다.
- **기본 실행은 network 호출 0건입니다.** `BenchmarkStubExtractor`는 in-process이며 소켓을 열지
  않고 credential을 읽지 않습니다.
- **artifact에는** API key, 절대 경로, 전체 transcript, gold 내용, draft 내용이 들어가지 않습니다.
  모델이 실제로 인용한 quote만 담깁니다.
- corpus·prediction은 `/data/` 아래에만 두며 `.gitignore`가 제외합니다. 커밋·재배포·외부 전송은
  [AI Hub 데이터 이용정책](https://aihub.or.kr/intrcn/guid/usagepolicy.do?currMenu=151&topMenu=105)
  확인 뒤에만 합니다.

## 읽을 때 주의

- **stub 실행 결과는 정확도가 아닙니다.** `BenchmarkStubExtractor`는 mapper의 수락·거절 경로를
  전부 밟게 하려고 만든 고정 출력이며, 실제 corpus에 대한 모델 성능과 아무 관계가 없습니다.
  synthetic 통과를 실제 정확도로 옮겨 적으면 안 됩니다.
- **`model_suggestion` draft는 gold가 아닙니다.** 사람 검수 시간을 줄이는 초벌입니다. 그것에
  맞춰 prompt를 튜닝하면 순환 평가가 됩니다. harness는 draft를 읽지 않습니다.
- **pending gold는 빈 정답이 아닙니다.** "아직 사람이 확인하지 않았다"이지 "정답이 없다"가
  아닙니다.

## 아직 하지 않은 것

Meeting Execution semantic scorer, 담당자 자기지시("제가 하겠습니다") 해석, 상태 전이 엔진,
실제 외부 STT 평가와 sealed Audio holdout 평가는 각각 별도 승인·Task입니다.

관련 문서: [benchmark-data-contract.md](benchmark-data-contract.md),
[audio-stt-benchmark.md](audio-stt-benchmark.md)
