# HAE.NA 0.2.6 (11) — Experimental Developer Preview

[Download macOS ZIP](https://github.com/hundredeuk2/haena/releases/download/v0.2.6-preview.2/HAE.NA-0.2.6-11-unsigned.app.zip) ·
[SHA-256 file](https://github.com/hundredeuk2/haena/releases/download/v0.2.6-preview.2/HAE.NA-0.2.6-11-unsigned.app.zip.sha256) ·
[Release page](https://github.com/hundredeuk2/haena/releases/tag/v0.2.6-preview.2)

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
| Version | `0.2.6 (11)` |
| Release tag | `v0.2.6-preview.2` |
| File | `HAE.NA-0.2.6-11-unsigned.app.zip` |
| Size | 4,244,296 bytes |
| SHA-256 | `153cb4a590817fd6580e623d296c1a456e3dd448ede232e28d072a4b4a18bc67` |
| Architecture | universal: `x86_64 arm64` |
| Signing | ad-hoc; **no Developer ID signature and no notarization** |
| Minimum macOS | 14.0 |
| Build environment | macOS 26.6.2 (`25G83`); Xcode 27.0 (`27A266a`) |
| Package source | private core repository — **not published**; this repository's source is the 0.2.5 baseline at `a7866d8` |

Verify before opening:

```bash
shasum -a 256 HAE.NA-0.2.6-11-unsigned.app.zip
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
- The extracted app reports version `0.2.6 (11)`, contains both `x86_64` and `arm64`, and passes
  strict on-disk ad-hoc signature verification.
- The packaging guard found no API-key pattern, meeting audio, persisted user-data file, benchmark
  artifact, UI-test marker, or user-specific absolute path in the app bundle.
- Fixes 2, 3, 4, and 5 above were **directly confirmed on the packaged app** (build 10), with two
  later corrections. Dragging the playback slider with the mouse was not exercised then, because that
  verification environment could not deliver drag events; the owner has since confirmed on the
  packaged build that the slider drags. And within fix 2, evidence *listening* (the "listen" control)
  did land on the exact stored segment time, but **opening an evidence quote did not** — it left the
  recording at 00:00, so pressing play started from the beginning of the file. See
  [Corrected in build 11](#corrected-in-build-11).

## Corrected in build 11

The owner, using the packaged build 10, reported this:

> When I open the evidence and play it — say 1:26 is captured — pressing it should play from 1:26,
> but instead it just takes the audio file and plays from the beginning.

That was real. Opening a result's evidence quote routed to the right transcript segment and
highlighted it, but never moved the playhead, so the recording stayed at 00:00 and the next press of
play started at the top of the file. A quote labelled 01:26 played from zero. Every "open evidence"
control was affected, and on the approved work-state screens — which offer "open evidence" and no
"listen" — the stored second could not reach the player by any route at all.

Build 11 fixes it. Opening a quote now moves the playhead to that quote's own stored second and stops
there; play continues from it. Reading a quote still does not start audio on its own, and a quote
whose position cannot be resolved still cues nothing and says so rather than silently landing on zero.

Confirmed on this packaged binary against an isolated synthetic 120-second recording: the review
queue's evidence quote and an approved item's "open evidence" both land on `01:26 / 02:00` with the
scrubber at 86 seconds, and play continues from there. A decoy segment carrying identical text at
00:06 is not chosen, so the position comes from the stored segment id rather than from matching the
quote's words.

## What was not confirmed on the packaged binary

**The in-flight background-transcription lifecycle is still not fully confirmed.** The owner has
since confirmed on the packaged build that transcription starts, shows progress, and retries — which
the original verification environment could not exercise at all. What remains unobserved is the rest
of that lifecycle: duplicate-submission blocking, the absence of an audio re-copy on retry, and the
provider failure copy. The owner's report did not cover those, and nothing here infers them from the
fact that transcription starts.

The paragraphs below describe the original build 10 limitation and are kept for the record.

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

**정직성 고지.** 합성 UI 검증과 패키지 검사는 통과했고 2~5번은 패키징된 빌드 10에서 직접
확인했습니다. 그 뒤 두 가지가 정정됐습니다.

첫째, 오너가 패키징된 빌드에서 **백그라운드 전사의 시작·진행·재시도가 동작하고 재생 슬라이더를
드래그할 수 있음**을 직접 확인했습니다. 다만 실행 중 전사 생애주기의 나머지 — 중복 제출 차단, 재시도 시
오디오 재복사 없음, provider 실패 문구 — 는 **여전히 관찰되지 않았습니다.** 오너의 보고가 그 부분을
다루지 않았고, 전사가 시작된다는 사실에서 그것을 유추하지 않습니다.

둘째, 2번 안에서 **근거 인용을 여는 경로에 실제 결함이 있었습니다.** 인용을 열면 전사의 올바른 구간으로
가고 강조까지 됐지만 재생 위치는 00:00에 그대로 남아, 다음에 재생을 누르면 파일 처음부터 재생됐습니다 —
01:26으로 표시된 인용이 0초부터 재생된 것입니다. '근거 보기'만 있고 '듣기'가 없는 승인된 업무 상태
화면에서는 저장된 시각이 어떤 경로로도 플레이어에 도달할 수 없었습니다. **빌드 11이 이를 고쳤고**,
이 패키지된 바이너리에서 120초 합성 녹음으로 확인했습니다 — 검토 큐의 인용과 승인된 항목의 '근거 보기'
모두 `01:26 / 02:00`, 스크러버 86초에 도달해 그 지점부터 재생되며, 00:06에 있는 글자가 똑같은 미끼
구간은 선택되지 않습니다.

서명·공증이 없어 첫 실행에 Control-클릭 → **열기**가 필요합니다. 실제 사용자 검증, Windows 검증,
회의 품질 주장은 없습니다. 0.2.5 노트에서 "0.2.6 계획"이라고 적었던 **A.X / RunPod provider 연동은
0.2.6에 포함되지 않으며 0.2.6 이후로 연기**되었습니다. 기록이 오해를 남기지 않도록 여기서
정정합니다.

**이 저장소의 공개 소스는 0.2.5입니다.** 0.2.6 이후 제품 소스는 비공개 core 저장소에서 개발하며
공개하지 않습니다. 이 저장소는 0.2.6에 대해서는 배포 창구(바이너리·릴리스 노트·체크섬·배포 테스트·
이슈 접수)와 보존된 0.2.5 소스 baseline(Apache-2.0)입니다. `HAENATests/`·`HAENAUITests/`는 0.2.5
baseline의 테스트이며, 위 다운로드를 검증하는 테스트는 누구나 실행할 수 있는
[`dist-tests/`](../dist-tests/README.md)에 있습니다.
