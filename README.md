<a id="english"></a>

# HAE.NA

![HAE.NA — Turn conversations into next actions](docs/banner.png)

<p align="center">
  <strong>Local-first Meeting Continuity for macOS.</strong><br>
  Turn meeting evidence into reviewed work state—and carry it into the next meeting.
</p>

<p align="center">
  <a href="#english">English</a> · <a href="#korean">한국어</a>
</p>

<p align="center">
  <a href="#why-haena">Why HAE.NA</a> ·
  <a href="#install-the-preview">Install</a> ·
  <a href="#how-meeting-continuity-works">How it works</a> ·
  <a href="#privacy-and-cost">Privacy</a> ·
  <a href="#current-limitations">Limitations</a>
</p>

> [!WARNING]
> HAE.NA is currently an unsigned, unnotarized **Private Developer Preview**. There is no public
> download yet. Read [Install the preview](#install-the-preview) and
> [Current limitations](#current-limitations) before using it with real meeting data.

## Why HAE.NA

Most meeting tools stop at a transcript, summary, or list of action items. HAE.NA focuses on what
happens after that output:

```text
Conversation
    ↓
Evidence-backed proposals
    ↓
Human review and approval
    ↓
Persistent work state
    ↓
Next-meeting brief
    ↓
Updated work state
```

**Transcription is an input, not the product.** HAE.NA keeps decisions, action items, open questions,
and next-agenda items connected to their evidence. AI may propose a change, but only the user can
approve it into project state.

## What you can do

| Area | Current capability |
| --- | --- |
| Capture | Record from the microphone, import an audio file, or paste meeting notes |
| Inspect | Read timestamped, speaker-labelled transcripts and confirm anonymous speakers |
| Extract | Generate evidence-backed proposals for decisions, action items, open questions, and next agenda |
| Review | Approve or exclude proposals; edit an owner or due date before approval |
| Continue | Open a Continuity Brief that separates approved state from new completed, changed, delayed, blocked, or resolved candidates |
| Act | See one recommended next action and schedule local reminders for confirmed personal action items |
| Audit | Inspect a local agent event ledger and honest, local-only preview metrics |
| Share | Export the current project state and transcript as Markdown or copy it to the clipboard |

Audio import currently accepts `mp3`, `mp4`, `mpeg`, `mpga`, `m4a`, `wav`, and `webm` files up to
25MB.

Opening a project or Continuity Brief does **not** call a model or change state. There is no automatic
approval or bulk apply.

## Product boundaries

- **Solo-first** — one person uses the app on one Mac. HAE.NA is not a team workspace today.
- **Local-first** — project state, transcripts, audio copies, and app records stay on the Mac. Model
  requests are the explicit exception described under [Privacy and cost](#privacy-and-cost).
- **Execution-first** — the primary object is reviewed work state, not a growing archive of summaries.
- **Share-ready** — collaboration currently happens through user-controlled Markdown and clipboard
  output, not accounts or silent synchronization.
- **Not a general-purpose agent platform** — HAE.NA does not run arbitrary tools or attempt to replace
  a personal assistant framework. Its scope is meeting-to-meeting continuity.

## Install the preview

Current candidate: **0.2.4 (8) Private Developer Preview**

| Item | Value |
| --- | --- |
| macOS | 14.0 or later |
| Package | `HAE.NA-0.2.4-8-unsigned.app.zip` |
| Architecture | universal — Apple silicon + Intel |
| SHA-256 | `64d85ffc9186f47fffb3d92c450d88297836c0e69235b29a7982ea0522eb1726` |
| Signing | ad-hoc; no Developer ID signature or notarization |

The package is distributed directly to designated preview users. It is not attached to a public
GitHub Release. See the [0.2.4 release notes](docs/private-preview-0.2.4.md) for build-specific facts
and verification status.

Verify the package before opening it:

```bash
shasum -a 256 HAE.NA-0.2.4-8-unsigned.app.zip
```

Then:

1. Unzip the package and move `HAE.NA.app` to `/Applications`.
2. In Finder, Control-click the app and choose **Open**.
3. Confirm **Open** in the macOS warning dialog.
4. If macOS still blocks it, go to **System Settings → Privacy & Security** and allow this app.

Do not disable Gatekeeper globally or remove quarantine attributes recursively just to run HAE.NA.

### First run

HAE.NA uses your own OpenAI API key. Open **AI Settings**, save the key, and optionally run the
connection check. The check lists models to verify authentication and does not run a model.

The key is stored in macOS Keychain under `com.haena.HAENA` / `openai-api-key` and is never shown
again after saving.

Current model configuration: `gpt-4o-transcribe-diarize` for transcription and `gpt-5.6` for work-state
extraction.

## Build from source

Requirements: macOS 14+, Xcode with the Swift 6 toolchain, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open HAENA.xcodeproj
```

Select the `HAENA` scheme in Xcode. For a command-line build:

```bash
xcodebuild -project HAENA.xcodeproj -scheme HAENA -configuration Debug build
```

`HAENA.xcodeproj` is generated from `project.yml`. Change `project.yml` and regenerate the project
instead of editing generated project settings by hand.

To create an isolated unsigned package:

```bash
./scripts/package-unsigned.sh
```

The script writes a versioned ZIP and `.sha256` file under `dist/` without silently overwriting an
existing package.

## How Meeting Continuity works

1. **Capture evidence.** HAE.NA stores the meeting before AI extraction begins, so a failed request
   does not erase the meeting.
2. **Propose structured state.** The model proposes typed decisions, action items, open questions,
   and next-agenda items with evidence and confidence.
3. **Review explicitly.** The user approves, excludes, or edits supported fields. A proposal is not
   project state before approval.
4. **Carry state forward.** The next Continuity Brief shows approved state separately from new
   transition candidates.
5. **Apply another verdict.** New completion, change, delay, blockage, and resolution candidates
   remain pending until the user reviews them.

This approval boundary is the product contract. A different prompt, model, internal tool, or future
MCP interface must not bypass it.

## Privacy and cost

Local-first does not mean fully offline. Network requests occur only when the user explicitly runs
transcription, extraction, retry, or the connection check.

| Stays on this Mac | Sent to OpenAI when requested |
| --- | --- |
| Project, meeting, and participant identifiers | Meeting audio for transcription |
| Local user profile | Meeting title and transcript for extraction |
| Existing evidence quotations | Minimum approved-state text needed for continuity analysis |
| Agent ledger and preview metrics | Authentication metadata for the connection check |

- The app contains no shared developer key. API usage is billed to the account behind the key you
  provide; ChatGPT subscriptions and API billing are separate.
- Requests use `store: false`.
- Project, meeting, and participant UUIDs and the local profile are not sent for extraction.
- An extraction may make up to three HTTP attempts after retryable 429 or 5xx responses. Timeouts and
  network failures are not retried automatically.
- Preview metrics are aggregated locally and contain no meeting title, transcript, or participant
  name.

Read [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) before using sensitive data.

## Local data and deletion

All app data is under:

```text
~/Library/Application Support/com.haena.HAENA/
```

| Data | File or location |
| --- | --- |
| Projects, meetings, transcripts, and work state | `projects.json` |
| Continuity proposals and review state | `continuity-transitions.json` |
| Local profile | `profile.json` |
| Reminder jobs | `agent-jobs.json` |
| Agent events and optional feedback | `agent-ledger.json` |
| Local preview metrics | `beta-metrics.json` |
| Stored audio copies | `Audio/` |
| API key | macOS Keychain |

Deleting a meeting or project also cleans up its persisted work state and continuity records, then
attempts to remove its stored audio copy. If the process stops after record cleanup but before the
audio unlink, an orphaned file can remain in `Audio/`. Deletion is ordinary file deletion, not secure
erase. For complete removal, quit the app, inspect or delete the application-support directory, and
remove the Keychain item separately.

## Language status

HAE.NA's product model is intended to be language-independent, but the current app is **not yet a
globally validated build**:

- The interface is Korean-first and has not been localized into English.
- Korean meetings have received the most hands-on testing.
- English and other languages have not completed end-to-end quality evaluation.
- Mixed-language detection and post-meeting translation are not implemented.

The goal is not to win on Korean transcription alone. Future multilingual work must preserve the
same source evidence, work-state identity, owner, date, and approval boundary across the original and
translated text.

## Current limitations

- Unsigned and unnotarized; installation requires the manual macOS steps above.
- No public release channel or automatic updates.
- No English UI localization yet; language quality is not broadly validated.
- No mixed-language detection or translation.
- No quantitative WER or speaker-diarization accuracy report yet.
- No video-to-audio extraction.
- No team accounts, permissions, sync, or concurrent multi-user editing.
- Continuity Briefs are opened manually; there is no Calendar trigger.
- Multiple app instances can race over the same local files.
- An interrupted deletion can leave an orphaned audio file as described above.

## Evaluation status

The 0.2.4 deletion lifecycle passed **149/149 focused tests**. Package version, universal architecture,
ad-hoc signature, SHA-256, and privacy contents were checked. The remaining Private Preview gate is a
short packaged-app tryout of:

```text
Save → Extract → Review/Approve → Next Brief → Quit/Reopen
```

The project also contains development-only benchmark contracts for extraction and audio/STT quality.
They are not a claim of finished product quality, and sealed evaluation data is not a public corpus.
See [Benchmark harness](docs/benchmark-harness.md) and
[Audio/STT benchmark](docs/audio-stt-benchmark.md).

## Direction, not a promise

- Validate repeated real meeting-to-meeting use before expanding the platform.
- Add English UI localization and multilingual end-to-end evaluation.
- Explore translation only with traceable original evidence and unchanged approval semantics.
- Add change-since-last-review summaries, evidence-linked audio navigation, and shareable briefs.
- Use Calendar context to surface a proven brief—not to auto-start recording or auto-apply state.
- Consider Developer ID signing and notarization when installation friction blocks testing.

MCP or toolized orchestration may become useful internally, but it is an architecture choice to be
validated against quality, latency, cost, and recovery—not a feature-count goal.

## Contributing and security

- Use GitHub Issues for bugs and proposals.
- Never attach meeting audio, raw transcripts, API keys, `projects.json`, agent records, or preview
  metrics to an issue.
- Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting code and
  [SECURITY.md](SECURITY.md) before reporting a vulnerability.

## License

HAE.NA is licensed under [Apache License 2.0](LICENSE). The explicit patent grant and patent-retaliation
terms are intentional. OpenAI APIs and models are not covered by this license; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

<a id="korean"></a>

# 한국어

<p align="center">
  <strong>macOS를 위한 로컬 우선 Meeting Continuity.</strong><br>
  회의 근거를 검토된 업무 상태로 바꾸고, 그 상태를 다음 회의까지 이어갑니다.
</p>

<p align="center">
  <a href="#english">English</a> · <a href="#korean">한국어</a>
</p>

<p align="center">
  <a href="#왜-haena인가">왜 HAE.NA인가</a> ·
  <a href="#preview-설치">설치</a> ·
  <a href="#meeting-continuity-작동-방식">작동 방식</a> ·
  <a href="#개인정보와-비용">개인정보</a> ·
  <a href="#현재-제한사항">제한사항</a>
</p>

> [!WARNING]
> HAE.NA는 현재 서명·공증되지 않은 **Private Developer Preview**입니다. 공개 다운로드는 아직
> 제공하지 않습니다. 실제 회의 데이터를 사용하기 전에 [Preview 설치](#preview-설치)와
> [현재 제한사항](#현재-제한사항)을 확인하세요.

## 왜 HAE.NA인가

대부분의 회의 도구는 전사, 요약 또는 액션 아이템 목록에서 끝납니다. HAE.NA는 그 결과 이후에
집중합니다.

```text
대화
  ↓
근거가 연결된 제안
  ↓
사용자 검토와 승인
  ↓
지속되는 업무 상태
  ↓
다음 회의 Brief
  ↓
갱신된 업무 상태
```

**전사는 입력이지 제품의 끝이 아닙니다.** HAE.NA는 결정, 업무, 미해결 질문, 다음 아젠다를 원문
근거와 연결합니다. AI가 변경을 제안할 수는 있지만, 사용자가 승인해야만 프로젝트 상태가 됩니다.

## 지금 할 수 있는 것

| 영역 | 현재 기능 |
| --- | --- |
| 입력 | 마이크 녹음, 음성 파일 불러오기, 텍스트 회의록 붙여넣기 |
| 확인 | 타임스탬프·화자가 표시된 전사와 익명 화자 확인 |
| 추출 | 결정, 업무, 미해결 질문, 다음 아젠다를 근거·확신도와 함께 제안 |
| 검토 | 제안 승인·제외, 승인 전 담당자·마감일 수정 |
| 연속성 | 승인 상태와 새 완료·변경·지연·차단·해결 후보를 구분하는 Continuity Brief |
| 실행 | 지금 할 한 가지 추천과 확정된 내 업무의 macOS 로컬 알림 |
| 기록 | Agent 사건 기록과 정직한 로컬 전용 Preview 측정 |
| 공유 | 프로젝트 현재 상태와 전사 원문을 Markdown으로 내보내거나 복사 |

현재 `mp3`, `mp4`, `mpeg`, `mpga`, `m4a`, `wav`, `webm` 파일을 최대 25MB까지 불러올 수
있습니다.

프로젝트나 Continuity Brief를 여는 것만으로는 모델을 호출하거나 상태를 바꾸지 않습니다. 자동 승인과
일괄 적용도 없습니다.

## 제품 경계

- **Solo-first** — 한 사람이 한 Mac에서 사용합니다. 현재 팀 협업 워크스페이스가 아닙니다.
- **Local-first** — 프로젝트 상태, 전사, 오디오 사본과 앱 기록은 Mac에 남습니다. 명시적 예외는
  [개인정보와 비용](#개인정보와-비용)에 설명한 모델 요청입니다.
- **Execution-first** — 계속 쌓이는 요약문보다 검토된 업무 상태를 중심에 둡니다.
- **Share-ready** — 협업은 계정이나 자동 동기화가 아니라 사용자가 통제하는 Markdown·클립보드
  산출물로 지원합니다.
- **범용 Agent 플랫폼이 아님** — 임의의 도구를 실행하거나 개인 비서 프레임워크를 대체하려는 제품이
  아닙니다. 범위는 회의와 회의 사이의 연속성입니다.

## Preview 설치

현재 후보: **0.2.4 (8) Private Developer Preview**

| 항목 | 값 |
| --- | --- |
| macOS | 14.0 이상 |
| 패키지 | `HAE.NA-0.2.4-8-unsigned.app.zip` |
| 아키텍처 | universal — Apple silicon + Intel |
| SHA-256 | `64d85ffc9186f47fffb3d92c450d88297836c0e69235b29a7982ea0522eb1726` |
| 서명 | ad-hoc; Developer ID 서명·공증 없음 |

패키지는 지정된 Preview 사용자에게 개별 전달합니다. 공개 GitHub Release에는 첨부하지 않았습니다.
빌드별 사실과 검증 상태는 [0.2.4 릴리스 노트](docs/private-preview-0.2.4.md)를 확인하세요.

실행 전에 패키지를 검증하세요.

```bash
shasum -a 256 HAE.NA-0.2.4-8-unsigned.app.zip
```

그다음:

1. 압축을 풀고 `HAE.NA.app`을 `/Applications`로 옮깁니다.
2. Finder에서 앱을 Control-클릭하고 **열기**를 선택합니다.
3. macOS 경고 창에서 **열기**를 확인합니다.
4. 계속 차단되면 **시스템 설정 → 개인정보 보호 및 보안**에서 이 앱을 허용합니다.

HAE.NA 하나를 실행하기 위해 Gatekeeper를 전역으로 끄거나 격리 속성을 재귀적으로 제거하지 마세요.

### 첫 실행

HAE.NA는 사용자의 OpenAI API 키를 사용합니다. **AI 설정**에서 키를 저장하고 필요하면 연결 확인을
실행하세요. 연결 확인은 인증을 위해 모델 목록만 조회하며 모델을 실행하지 않습니다.

키는 macOS Keychain의 `com.haena.HAENA` / `openai-api-key`에 저장되고, 저장 후 다시 표시되지
않습니다.

현재 모델 구성은 전사 `gpt-4o-transcribe-diarize`, 업무 상태 추출 `gpt-5.6`입니다.

## 소스에서 빌드

요구 사항은 macOS 14+, Swift 6 툴체인이 포함된 Xcode,
[XcodeGen](https://github.com/yonaskolb/XcodeGen)입니다.

```bash
brew install xcodegen
xcodegen generate
open HAENA.xcodeproj
```

Xcode에서 `HAENA` 스킴을 선택합니다. 명령줄 빌드는 다음과 같습니다.

```bash
xcodebuild -project HAENA.xcodeproj -scheme HAENA -configuration Debug build
```

`HAENA.xcodeproj`는 `project.yml`에서 생성됩니다. 생성된 프로젝트 설정을 직접 고치지 말고
`project.yml`을 수정한 뒤 다시 생성하세요.

격리된 unsigned 패키지를 만들려면:

```bash
./scripts/package-unsigned.sh
```

스크립트는 기존 패키지를 조용히 덮어쓰지 않고 `dist/` 아래에 버전이 붙은 ZIP과 `.sha256` 파일을
만듭니다.

## Meeting Continuity 작동 방식

1. **근거 저장** — AI 추출 전에 회의를 먼저 저장하므로 요청이 실패해도 회의가 사라지지 않습니다.
2. **구조화된 상태 제안** — 모델이 근거·확신도와 함께 결정, 업무, 미해결 질문, 다음 아젠다를
   타입이 있는 형태로 제안합니다.
3. **명시적 검토** — 사용자가 승인·제외하거나 지원되는 필드를 수정합니다. 승인 전 제안은 프로젝트
   상태가 아닙니다.
4. **다음 회의로 전달** — Continuity Brief는 승인된 상태와 새로운 전이 후보를 분리해 보여줍니다.
5. **새 판정 적용** — 완료·변경·지연·차단·해결 후보도 사용자가 검토할 때까지 pending 상태입니다.

이 승인 경계가 제품 계약입니다. 프롬프트, 모델, 내부 도구 또는 향후 MCP 인터페이스가 달라져도 이를
우회해서는 안 됩니다.

## 개인정보와 비용

Local-first가 완전한 오프라인을 의미하지는 않습니다. 사용자가 전사·추출·재시도 또는 연결 확인을
명시적으로 실행할 때만 네트워크 요청이 발생합니다.

| 이 Mac에 남는 정보 | 요청 시 OpenAI로 보내는 정보 |
| --- | --- |
| 프로젝트·회의·참석자 식별자 | 전사용 회의 오디오 |
| 로컬 사용자 프로필 | 추출용 회의 제목과 전사 내용 |
| 기존 근거 인용문 | 연속성 판단에 필요한 최소 승인 상태 문구 |
| Agent 기록과 Preview 측정 | 연결 확인용 인증 메타데이터 |

- 앱에는 개발자 공용 키가 없습니다. 사용자가 입력한 키의 계정에 API 비용이 발생하며 ChatGPT 구독과
  API 비용은 별개입니다.
- 요청은 `store: false`를 사용합니다.
- 추출에 프로젝트·회의·참석자 UUID와 로컬 프로필을 보내지 않습니다.
- 추출은 재시도 가능한 429 또는 5xx 응답 뒤 최대 3번의 HTTP 요청을 만들 수 있습니다. 타임아웃과
  네트워크 실패는 자동 재시도하지 않습니다.
- Preview 측정은 로컬에서 집계하며 회의 제목, 전사 원문, 참석자 이름을 담지 않습니다.

민감한 데이터를 사용하기 전에 [PRIVACY.md](PRIVACY.md)와 [SECURITY.md](SECURITY.md)를 읽어주세요.

## 로컬 데이터와 삭제

모든 앱 데이터는 다음 폴더 아래에 있습니다.

```text
~/Library/Application Support/com.haena.HAENA/
```

| 데이터 | 파일 또는 위치 |
| --- | --- |
| 프로젝트·회의·전사·업무 상태 | `projects.json` |
| 연속성 제안과 검토 상태 | `continuity-transitions.json` |
| 로컬 프로필 | `profile.json` |
| 알림 작업 | `agent-jobs.json` |
| Agent 사건과 선택적 피드백 | `agent-ledger.json` |
| 로컬 Preview 측정 | `beta-metrics.json` |
| 보관된 오디오 사본 | `Audio/` |
| API 키 | macOS Keychain |

회의나 프로젝트를 삭제하면 저장된 업무 상태와 연속성 기록을 정리한 뒤 보관된 오디오 사본 삭제를
시도합니다. 기록 정리 후 오디오 파일 삭제 전에 프로세스가 중단되면 `Audio/`에 고아 파일이 남을 수
있습니다. 삭제는 일반 파일 삭제이며 secure erase가 아닙니다. 완전히 제거하려면 앱을 종료하고
Application Support 폴더를 확인하거나 삭제한 뒤 Keychain 항목을 별도로 제거하세요.

## 언어 지원 상태

HAE.NA의 제품 모델은 언어에 종속되지 않는 것을 목표로 하지만, 현재 앱은 **글로벌 검증이 끝난
빌드가 아닙니다.**

- UI는 한국어 우선이며 영어로 현지화되지 않았습니다.
- 한국어 회의를 가장 많이 직접 확인했습니다.
- 영어와 다른 언어는 전체 흐름의 품질 평가를 마치지 않았습니다.
- 혼합 언어 감지와 회의 후 번역은 구현되지 않았습니다.

목표는 한국어 전사 성능만으로 경쟁하는 것이 아닙니다. 향후 다국어 기능은 원문과 번역문 사이에서도
같은 근거, 업무 상태 ID, 담당자, 날짜, 승인 경계를 보존해야 합니다.

## 현재 제한사항

- 서명·공증되지 않아 위의 수동 macOS 설치 절차가 필요합니다.
- 공개 릴리스 채널과 자동 업데이트가 없습니다.
- 영어 UI 현지화가 없고 언어별 품질을 폭넓게 검증하지 않았습니다.
- 혼합 언어 감지와 번역이 없습니다.
- WER와 화자 분리 정확도의 정량 보고서가 없습니다.
- 영상에서 오디오를 추출하지 않습니다.
- 팀 계정, 권한, 동기화, 동시 다중 사용자 편집이 없습니다.
- Continuity Brief는 수동으로 열며 Calendar trigger가 없습니다.
- 앱을 여러 개 실행하면 같은 로컬 파일을 두고 경합할 수 있습니다.
- 삭제가 중단되면 위에서 설명한 고아 오디오 파일이 남을 수 있습니다.

## 검증 상태

0.2.4 삭제 lifecycle은 **focused test 149/149**를 통과했습니다. 패키지 버전, universal 아키텍처,
ad-hoc 서명, SHA-256과 패키지의 개인정보 포함 여부를 확인했습니다. 남은 Private Preview 관문은
패키징된 앱에서 다음 실제 흐름을 짧게 사용해보는 것입니다.

```text
저장 → 추출 → 검토·승인 → 다음 Brief → 종료·재실행
```

프로젝트에는 추출과 Audio/STT 품질을 위한 개발 전용 benchmark 계약도 있습니다. 이는 완성된 제품
품질을 주장하는 근거가 아니며 sealed 평가 데이터는 공개 corpus가 아닙니다.
[Benchmark harness](docs/benchmark-harness.md)와
[Audio/STT benchmark](docs/audio-stt-benchmark.md)를 참고하세요.

## 방향이며 약속은 아닙니다

- 플랫폼을 넓히기 전에 실제 회의가 반복되는 전체 흐름을 검증합니다.
- 영어 UI 현지화와 다국어 전체 흐름 평가를 추가합니다.
- 원문 근거를 추적할 수 있고 승인 의미가 바뀌지 않는 번역만 검토합니다.
- 마지막 검토 이후 변화 요약, 근거 연결 오디오 이동, 공유용 Brief를 검토합니다.
- Calendar는 자동 녹음·자동 상태 적용이 아니라 검증된 Brief를 적시에 보여주는 데 사용합니다.
- 설치 장벽이 테스트를 막을 때 Developer ID 서명·공증을 검토합니다.

MCP나 toolized orchestration은 내부적으로 유용할 수 있지만, 품질·latency·비용·복구 가능성을 비교해
결정할 아키텍처 선택입니다. 기능 개수를 늘리기 위한 목표가 아닙니다.

## 기여와 보안

- 버그와 제안은 GitHub Issues로 올려주세요.
- 이슈에 회의 오디오, 전사 원문, API 키, `projects.json`, Agent 기록 또는 Preview 측정을 첨부하지
  마세요.
- 코드를 제출하기 전에 [CONTRIBUTING.md](CONTRIBUTING.md), 취약점을 신고하기 전에
  [SECURITY.md](SECURITY.md)를 확인하세요.

## 라이선스

HAE.NA는 [Apache License 2.0](LICENSE)을 따릅니다. 명시적인 특허 라이선스 부여와 특허 보복 방지
조항은 의도된 선택입니다. OpenAI API와 모델은 이 라이선스 대상이 아닙니다.
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)를 확인하세요.
