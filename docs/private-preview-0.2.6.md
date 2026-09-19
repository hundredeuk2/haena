# HAE.NA 0.2.6 (10) — Experimental Developer Preview

[Download macOS ZIP](https://github.com/hundredeuk2/haena/releases/download/v0.2.6-preview.1/HAE.NA-0.2.6-10-unsigned.app.zip) ·
[SHA-256 file](https://github.com/hundredeuk2/haena/releases/download/v0.2.6-preview.1/HAE.NA-0.2.6-10-unsigned.app.zip.sha256) ·
[Release page](https://github.com/hundredeuk2/haena/releases/tag/v0.2.6-preview.1)

> This is an unsigned, unnotarized experimental build for a small self-tryout. Public download
> availability does not mean that real-meeting quality, reliability, privacy suitability, or
> production readiness has been validated.

> **The source in this repository is 0.2.5, not 0.2.6.** This repository is the distribution
> surface for the 0.2.6 download plus the preserved 0.2.5 source baseline. See
> [Source and repository boundary](#source-and-repository-boundary) before reading the code here as
> the code of the build above.

## Package identity

| Item | Value |
| --- | --- |
| Version | `0.2.6 (10)` |
| Release tag | `v0.2.6-preview.1` |
| File | `HAE.NA-0.2.6-10-unsigned.app.zip` |
| Size | 4,242,057 bytes |
| SHA-256 | `621dc1e2252f9ff8d0673808364368b007cdcddfd5a7c2dfd563da70e620d287` |
| Architecture | universal: `x86_64 arm64` |
| Signing | ad-hoc; **no Developer ID signature and no notarization** |
| Minimum macOS | 14.0 |
| Build environment | macOS 26.6.2 (`25G83`); Xcode 27.0 (`27A266a`) |
| Package source | private core repository — **not published**; this repository's source is the 0.2.5 baseline at `a7866d8` |

Verify before opening:

```bash
shasum -a 256 HAE.NA-0.2.6-10-unsigned.app.zip
```

The result must exactly match the SHA-256 above. The previous `v0.2.5-preview.1` release and its
assets stay published and unchanged; this release does not replace or mutate them.

You can verify all of that yourself, without any access to the source, with the
[public distribution tests](../dist-tests/README.md):

```bash
cd dist-tests && ./run-all.sh
```

## What changed

0.2.6 adds no new AI capability. It is a **usability release**: five places where the previous build
made the user fight the app, or where a screen implied more certainty than the data supported.

1. **Background transcription.** Closing the progress sheet or navigating away no longer cancels the
   job. The transcription keeps running, and on return the current step, success, failure, and retry
   are visible. Submitting the same meeting twice is prevented. Progress is honest — the app reports
   the step it is actually on rather than inventing a percentage that advances on a timer.
2. **Playback seek and evidence listening.** The playback position is draggable. A decision or action
   item's "listen" control jumps to the exact stored transcript segment time for that evidence. When
   no time is stored for a piece of evidence, the app says so and the control is disabled, instead of
   guessing a timestamp that would send the user to the wrong moment.
3. **Three-scope separation.** The meeting transcript, this meeting's results (candidates and
   approved), and the project's current approved state are now distinct in both screens and wording.
   Candidates are never merged into approved state or displayed as if they already counted.
4. **Readable Brief hierarchy.** The Brief leads with what changed, then remaining work, then what to
   discuss next. Details, evidence, and review actions sit behind progressive disclosure.
   **Expanding a section or navigating never approves anything** — approval stays an explicit act.
5. **Chronological meeting history.** Each meeting shows its decisions, new work, carried work, and
   completed work in time order, with navigation to the exact past evidence behind each item. Work
   item identity and approval state survive quitting and relaunching the app.

## Verification completed

- Synthetic UI checks and packaging checks passed.
- The ZIP passed archive integrity verification and an independent SHA-256 calculation.
- The extracted app reports version `0.2.6 (10)`, contains both `x86_64` and `arm64`, and passes
  strict on-disk ad-hoc signature verification.
- The packaging guard found no API-key pattern, meeting audio, persisted user-data file, benchmark
  artifact, UI-test marker, or user-specific absolute path in the app bundle.
- Fixes 2, 3, 4, and 5 above were **directly confirmed on the packaged app**, with one exception
  inside fix 2: dragging the playback slider with the mouse was **not** exercised, because the
  verification environment could not deliver drag events to any application. The same slider's
  commit path was confirmed by other means, and evidence listening was confirmed to land on the
  exact stored segment time and to stay disabled when no time is stored.

## What was not confirmed on the packaged binary

**Fix 1, background transcription, was not directly confirmed on the packaged binary.** This is
stated plainly because the fix is the headline of the release and a reader should not assume it was
exercised end to end.

What *was* confirmed on the packaged app is the behavioral contract the fix depends on: closing the
window keeps the same process and the same job alive, and quitting the app leaves no transcription
state behind. What could **not** be exercised is the in-flight lifecycle — starting a real
transcription, closing the sheet while it runs, and returning to a finished or failed job — because
the verification environment could not deliver synthetic input to start a transcription.

This is a **limitation of verification on a developer Mac, not a known defect**. No failure of the
background-transcription behavior was observed. It simply was not driven end to end in the packaged
build, and the release does not claim that it was. If the first real tryout finds that a closed sheet
still cancels a job, that is the gap this paragraph is marking.

## Not yet validated

- No real-user validation. The product owner's real packaged-app tryout with their own meeting and
  OpenAI API key remains outstanding, as it did for 0.2.5.
- The in-flight background-transcription lifecycle described above.
- Real microphone, provider, network-failure, cost, or long-running soak behavior in this package.
- Broad English or multilingual meeting extraction quality.
- No meeting-quality claim of any kind — no WER, diarization accuracy, or extraction-accuracy figure
  is asserted for this build.
- No Windows validation. There is still no Windows binary.
- Developer ID signing, notarization, and automatic updates.

## Corrections to the 0.2.5 notes

The 0.2.5 release notes said the A.X / RunPod provider work "belongs to the future 0.2.6 plan."
**That is no longer accurate.** A.X / RunPod provider integration is **not in 0.2.6** and is
**deferred past 0.2.6**. It is recorded here rather than quietly dropped, so that the 0.2.5 notes are
not left standing as the most recent statement on the matter. When that work is scheduled, it must
still preserve the same evidence and approval boundaries.

## Source and repository boundary

- The **published source in this repository is 0.2.5**, preserved at `a7866d8` under Apache-2.0. It
  is a real, buildable baseline, and it is not the source of the 0.2.6 download.
- **0.2.6 and later product source is developed in a private core repository and is not published.**
- What this repository is, for 0.2.6: the **distribution surface** — the binary, these release notes,
  the checksum, the public distribution tests, and issue intake.
- Therefore, do not read the Swift code here as the code of the build linked above, and do not report
  a 0.2.6 behavior as a bug "in" this source tree. Report the behavior; the maintainer maps it to the
  private source.
- The test suites under `HAENATests/` and `HAENAUITests/` are the **0.2.5 baseline's** tests. The
  0.2.6 product's own tests live with the private source and are not published. The tests that do
  cover the 0.2.6 download are in [`dist-tests/`](../dist-tests/README.md), and anyone can run them.

## Known limitations

- **Unsigned and un-notarized.** Gatekeeper will warn on first launch. Use Control-click → **Open**
  the first time, and allow the app in **System Settings → Privacy & Security** if macOS still
  blocks it. Do not disable Gatekeeper globally or strip quarantine attributes recursively.
- **No automatic updates.** A new build must be downloaded and replaced by hand.
- Honest progress means the transcription sheet may sit on one step for a while without a moving
  percentage. That is the intended behavior, not a hang.
- Evidence with no stored segment time has its "listen" control disabled. That is the intended
  behavior, not a broken button.
- Everything still listed under [Current limitations](../README.md#current-limitations) in the README
  continues to apply.

## First tryout

Use non-sensitive data first:

1. Open AI Settings and save your own OpenAI API key.
2. Record or import a short meeting and start transcription.
3. **Close the progress sheet while it runs, move to another screen, and come back.** The job should
   still be running or finished — not cancelled. This is the step that is not yet confirmed on the
   packaged build, so it is the most useful thing to report on.
4. Open a resulting decision or action item and use its "listen" control. Confirm it lands on the
   right moment, or that it is disabled with a stated reason.
5. Check that this meeting's candidates are visibly separate from the project's approved state.
6. Open the Brief. Expand a section and confirm that nothing was approved by expanding it.
7. Approve only what is correct, then quit and relaunch, and confirm the approved state and item
   identity survived.

Record only the blocked step, the expected result, and the actual result. Do not attach meeting
audio, transcripts, API keys, or application data files to a public issue.

---

## 한국어 요약

0.2.6은 새 AI 기능을 추가하지 않는 **사용성 릴리스**입니다. 다섯 가지를 고쳤습니다.

1. **백그라운드 전사** — 진행 시트를 닫거나 다른 화면으로 이동해도 작업이 취소되지 않습니다. 돌아오면
   현재 단계·성공·실패·재시도가 보이고, 같은 회의의 중복 제출을 막습니다. 진행률은 가짜 퍼센트 없이
   실제 단계를 표시합니다.
2. **재생 탐색과 근거 듣기** — 재생 위치를 드래그할 수 있고, 결정·액션 아이템의 "듣기"는 저장된 정확한
   전사 구간 시각으로 이동합니다. 저장된 시각이 없으면 시각을 지어내지 않고 그 사실을 표시한 뒤 컨트롤을
   비활성화합니다.
3. **세 가지 범위 분리** — 회의 전사 / 이번 회의 결과(후보와 승인) / 프로젝트의 현재 승인 상태를 화면과
   문구에서 구분합니다. 후보는 승인 상태와 절대 섞이지 않습니다.
4. **읽기 쉬운 Brief 위계** — 변경된 것 → 남은 업무 → 다음에 논의할 것 순서로 제시하고, 상세·근거·검토
   동작은 단계적으로 펼칩니다. **펼치거나 이동하는 것으로는 아무것도 승인되지 않습니다.**
5. **시간순 회의 이력** — 회의마다 결정 / 새 업무 / 이월 업무 / 완료 업무를 시간순으로 보여주고 과거
   근거의 정확한 위치로 이동합니다. ID와 승인 상태는 종료·재실행 후에도 유지됩니다.

**정직성 고지.** 합성 UI 검증과 패키지 검사는 통과했고 2~5번은 패키징된 앱에서 직접 확인했습니다.
그러나 **1번(백그라운드 전사)은 패키징된 바이너리에서 직접 확인하지 못했습니다.** 창을 닫아도 같은
프로세스·같은 작업이 유지되고 앱을 종료하면 전사 상태가 남지 않는다는 동작 계약은 패키지에서
확인했지만, 검증 환경이 전사를 시작할 합성 입력을 전달할 수 없어 **실행 중 생애주기**를 끝까지
구동하지 못했습니다. 이는 개발용 Mac의 **검증 한계이지 알려진 결함이 아닙니다.**

서명·공증이 없어 첫 실행에 Control-클릭 → **열기**가 필요합니다. 실제 사용자 검증, Windows 검증,
회의 품질 주장은 없습니다. 0.2.5 노트에서 "0.2.6 계획"이라고 적었던 **A.X / RunPod provider 연동은
0.2.6에 포함되지 않으며 0.2.6 이후로 연기**되었습니다. 기록이 오해를 남기지 않도록 여기서
정정합니다.

**이 저장소의 공개 소스는 0.2.5입니다.** 0.2.6 이후 제품 소스는 비공개 core 저장소에서 개발하며
공개하지 않습니다. 이 저장소는 0.2.6에 대해서는 배포 창구(바이너리·릴리스 노트·체크섬·배포 테스트·
이슈 접수)와 보존된 0.2.5 소스 baseline(Apache-2.0)입니다. `HAENATests/`·`HAENAUITests/`는 0.2.5
baseline의 테스트이며, 위 다운로드를 검증하는 테스트는 누구나 실행할 수 있는
[`dist-tests/`](../dist-tests/README.md)에 있습니다.
