# HAE.NA 0.2.7 (12) — Experimental Developer Preview

[Download macOS ZIP](https://github.com/hundredeuk2/haena/releases/download/v0.2.7-preview.1/HAE.NA-0.2.7-12-unsigned.app.zip) ·
[SHA-256 file](https://github.com/hundredeuk2/haena/releases/download/v0.2.7-preview.1/HAE.NA-0.2.7-12-unsigned.app.zip.sha256) ·
[Release page](https://github.com/hundredeuk2/haena/releases/tag/v0.2.7-preview.1)

> This is an unsigned, unnotarized experimental build for a small self-tryout. Public download
> availability does not mean that real-meeting quality, reliability, privacy suitability, or
> production readiness has been validated.

> **No human has used this build.** 0.2.7 is a UI/UX release whose screens were rebuilt, and the
> owner's tryout of the packaged app has **not** happened. Read
> [What was not confirmed](#what-was-not-confirmed) before treating any screen claim below as
> observed behaviour.

> **The source in this repository is 0.2.5, not 0.2.7.** This repository is the distribution
> surface for the 0.2.7 download plus the preserved 0.2.5 source baseline. See
> [Source and repository boundary](#source-and-repository-boundary) before reading the code here as
> the code of the build above.

## Package identity

| Item | Value |
| --- | --- |
| Version | `0.2.7 (12)` |
| Release tag | `v0.2.7-preview.1` |
| File | `HAE.NA-0.2.7-12-unsigned.app.zip` |
| Size | 4,868,299 bytes |
| SHA-256 | `dedbda669313f9e69b5a997a6fe7a8af83c7ecd6013eae3422c4ce81fc077a62` |
| Architecture | universal: `x86_64 arm64` |
| Signing | ad-hoc; **no Developer ID signature and no notarization** |
| Bundle identifier | `com.haena.HAENA` |
| Minimum macOS | 14.0 |
| Build environment | macOS 26.6.2 (`25G83`); Xcode 27.0 (`27A266a`) |
| Package source | private core repository — **not published**; built from core commit `d81cba2`, carrying the *core* tag `v0.2.7-preview.1` (a different repository from this one's release tag of the same name), on a clean tree. This repository's source is the 0.2.5 baseline at `a7866d8` |

Verify before opening:

```bash
shasum -a 256 HAE.NA-0.2.7-12-unsigned.app.zip
```

The result must exactly match the SHA-256 above. Every earlier release — `v0.2.6-preview.2`,
`v0.2.6-preview.1` and `v0.2.5-preview.1` — and all of their assets stay published and unchanged;
this release does not replace or mutate them.

You can verify all of that yourself, without any access to the source, with the
[public distribution tests](../dist-tests/README.md):

```bash
cd dist-tests && ./run-all.sh
```

## What changed

0.2.7 adds **no new AI capability** and changes no model, provider, or price. It is a UI/UX release:
the screens were rebuilt around *when something happened* and *what you are being asked to decide*.

1. **Home is a time axis.** Three zones of unequal weight replace a flat list. The single primary
   next action stays on the first screen without scrolling. That was measured directly on the
   running app for this build in **the smallest window the app allows** — 520×552, two different
   card shapes, with no scrolling helper called — rather than assumed. At **1180, 800 and 520 point
   widths** it is asserted by a separate test that executed and passed earlier in this work at 800
   height; that test was **not re-run against the state this build was made from**, so treat it as
   an assertion rather than as a measurement of this binary.
2. **Projects live in a sidebar, and reading is split from judging.** One flat, one-level column of
   projects carries a *waiting* badge where something needs a person. The project screen is a time
   band plus two tabs — read, and judge. The badge is copied from the count Home already holds
   rather than recounted, and is read from the complete summary rather than Home's truncated one, so
   the sixth project is still badged. The column distinguishes "not read yet", "read and empty" and
   "could not be read" instead of giving all three one sentence.
3. **The Brief can be looked through.** A *what to look for* section sits at the top with three
   groups, folded by default: confirmed decisions, my remaining work, and unanswered questions to
   prepare. Each shows a count, a scope sentence, and one or two previews. No count is recomputed —
   they are the lengths of arrays the carried queue already holds. Three honesty rules hold inside
   it: an item whose assignee was never confirmed as you stays out of *my remaining work* and the
   scope sentence says so; a question is listed as answered only when a continuity record approved
   the resolution, and that record is named; a question closed by hand appears in no list rather
   than quietly reducing a count.
4. **Proposals are judged one at a time.** The judging tab shows one card — `3 / 7`, the number
   remaining counted off the same filtered list, the source meeting, and the quoted evidence behind
   a fold. *See later* skips a candidate in view state only and calls no service. "Everything
   deferred" is a different sentence from "nothing of this kind exists". Warnings — missing
   evidence, an owning-meeting mismatch, no segment, why something cannot be listened to — stay
   **outside** the fold, because they are what the approval decision needs and a fold would let
   someone approve without ever seeing them.
5. **Empty and failed screens get exactly one next step.** The first-user, no-candidate and
   analysis-failed screens each offer a single action, enforced by the type that holds it rather
   than by convention. The failure screen reports what actually survived rather than asserting that
   anything did, and drops the preservation sentence entirely in the cases where nothing was
   confirmed.
6. **The three approval states are said in words.** Confirmed, unapproved candidate, and read-only
   now carry spoken labels rather than relying on colour and position alone, and one state can no
   longer be labelled two ways on two screens. The printed words are unchanged. Repeated fold,
   collapse and by-meeting controls now carry their own section's name instead of three identical
   labels.
7. **Three Brief transition sentences were wrong and are now audited** against what the review
   service actually writes: completion also clears this meeting's duplicate candidate when there is
   one, progress writes nothing at all in the cases that reach it, and change moves the existing
   item's own assignee and deadline. Each verdict's impact sentence was copied from the fields the
   service writes. "Other items' deadlines do not change" stands under both buttons. Undo, chained
   deadlines and next-meeting dates appear nowhere on screen.
8. **A missing transition row is no longer read as proof that a value is unchanged.** An item whose
   edit path is not recorded is reported as *unproven as of*, not as *as recorded*.

## What was verified

**The unit suite passes in full.** `1336 tests executed, 3 skipped, 0 failures`, run on the source
this package was built from.

- 28 of those are new tests for the time projection behind the Home band and the project band.
  Their binding force was checked rather than assumed: the projection was deliberately broken six
  different ways and the expected tests failed each time, and the projection was restored after
  each.
- Seven unit tests were **already failing before this work** and were fixed rather than left: six
  contract tests that had drifted behind the continuity schema, and one assertion that could never
  pass under the project's own test scheme. The strictness of the contract tests was not reduced;
  two new assertions were added.

**The package boundary passes.** The release script's own checks, run against this bundle, found no
user data, no credential-shaped string, no benchmark or UI-test fixture material, no development
UI/test marker in the binary, and no user-specific absolute path. The built app was verified
independently after packaging: `0.2.7` / `12`, `com.haena.HAENA`, minimum macOS `14.0`, universal
`x86_64 arm64`, ad-hoc signature with no Team ID. The repository tree was clean at the build commit,
so the source SHA in the table above describes the bytes exactly.

## What was not confirmed

This section is the reason to read the rest sceptically.

**No human has used this build.** There is no owner tryout of the packaged 0.2.7 app. Whether the
rebuilt screens are actually readable, whether the three approval states are distinguishable with
colour off, and whether VoiceOver reads the new spoken labels are **intentions, not results** — they
were reviewed in source and asserted in tests, and nobody has looked at them.

**The UI suite is not green on this build, and 0.2.7 does not claim it is.** A representative
18-case UI run gave **15 pass, 1 skip, 2 fail**:

- The **skip** is a Full Keyboard Access setting that is off on the build machine. It is recorded as
  a skip and **not counted as a pass**.
- The **two failures** are the project-deletion confirmations. They fail inside XCTest's own
  Notification Center banner interruption monitor, which the tests cannot remove. They are reported
  as **failing** — not as passing, not as skipped. No Focus mode, Do Not Disturb, notification
  setting or any other system setting was changed, and no process was killed, to make them pass.
- Some routes were **not run at all** for this build: the stale-cue route, the Space key, and the
  all-width meeting routes.

**Carried over from 0.2.6, still unobserved.** Duplicate-submission blocking, no audio re-copy on
retry, and the provider failure copy were listed as unobserved in the 0.2.6 notes. 0.2.7 did not
revisit them and they remain unobserved.

## Not yet validated

- No real-user validation and no real-meeting quality claim.
- No Windows validation and no Windows binary.
- No quantitative WER or speaker-diarization accuracy report.
- A.X / RunPod provider integration is still deferred; 0.2.7 changed no model or provider.

## Source and repository boundary

- The **published source in this repository is 0.2.5**, preserved at `a7866d8` under Apache-2.0. It
  is a real, buildable baseline, and it is not the source of the 0.2.7 download.
- **0.2.6 and later product source is developed in a private core repository and is not published.**
- What this repository is, for 0.2.7: the **distribution surface** — the binary, these release
  notes, the checksum, the public distribution tests, and issue intake.
- Therefore, do not read the Swift code here as the code of the build linked above, and do not
  report a 0.2.7 behavior as a bug "in" this source tree. Report the behavior; the maintainer maps
  it to the private source.
- The test suites under `HAENATests/` and `HAENAUITests/` are the **0.2.5 baseline's** tests. The
  0.2.7 product's own tests live with the private source and are not published. The tests that do
  cover the 0.2.7 download are in [`dist-tests/`](../dist-tests/README.md), and anyone can run them.

## Known limitations

- **Unsigned and un-notarized.** Gatekeeper will warn on first launch. Use Control-click → **Open**
  the first time, and allow the app in **System Settings → Privacy & Security** if macOS still
  blocks it. Do not disable Gatekeeper globally or strip quarantine attributes recursively.
- **No automatic updates.** A new build must be downloaded and replaced by hand.
- This build uses the **same bundle identifier as every other HAE.NA build**, so it reads and writes
  the same local store. It is not an isolated harness. Use a throwaway project for anything
  destructive, such as testing deletion.
- Honest progress means the transcription sheet may sit on one step for a while without a moving
  percentage. That is the intended behavior, not a hang.
- Evidence with no stored segment time has its "listen" control disabled. That is the intended
  behavior, not a broken button.
- Everything still listed under [Current limitations](../README.md#current-limitations) in the
  README continues to apply.

## First tryout

Use non-sensitive data first, and prefer a throwaway project.

1. Open AI Settings and save your own OpenAI API key.
2. Open Home. **Does the time axis tell you what is recent and what is waiting, without scrolling?**
   Resize the window down to its smallest and check that the primary action is still on the first
   screen. That one was measured by a test on this build — but whether the axis *reads* has never
   been judged by a person.
3. Open the project sidebar. Confirm that the *waiting* badge appears where something needs you, and
   that "not read yet", "read and empty" and "could not be read" are three different screens.
4. Open a project's read tab, then its judge tab. **Is it obvious which one only shows you things
   and which one asks you to decide?**
5. In the judge tab, step through candidates one at a time. Confirm that *see later* changes nothing
   but the card on screen, and that warnings are visible before you approve, not hidden behind the
   evidence fold.
6. Open the Brief and read the *what to look for* section without expanding anything. **Do the three
   counts tell you what to prepare?** Then expand one and confirm nothing was approved by expanding
   it.
7. Turn colour off, or use VoiceOver, and check that confirmed / unapproved candidate / read-only
   are still distinguishable. This is the claim with the least evidence behind it.
8. Approve only what is correct, then quit and relaunch, and confirm the approved state and item
   identity survived.

Record only the blocked step, the expected result, and the actual result. Do not attach meeting
audio, transcripts, API keys, or application data files to a public issue.

---

## 한국어 요약

0.2.7은 **새 AI 기능을 추가하지 않고** 모델·provider·가격도 바꾸지 않는 **UI/UX 릴리스**입니다.
"언제 일어난 일인가"와 "지금 무엇을 판단해 달라는 것인가"를 기준으로 화면을 다시 세웠습니다.

1. **Home이 시간 축이 됩니다.** 평평한 목록 대신 비중이 다른 세 구역입니다. 주 행동 하나는 스크롤
   없이 첫 화면에 남습니다. **이 앱이 허용하는 가장 작은 창**에서는 이 빌드를 대상으로 돌고 있는
   앱에서 직접 쟀습니다 — 520×552, 서로 다른 카드 두 종류, 스크롤 헬퍼를 부르지 않음. **1180 ·
   800 · 520 세 폭**은 이 작업의 앞선 시점에 800 높이에서 실행해 통과한 별도 테스트가 단언하는
   것이고, 그 테스트를 **이 빌드가 만들어진 상태에서 다시 돌리지는 않았습니다.** 이 바이너리에
   대한 측정이 아니라 단언으로 읽어 주세요.
2. **프로젝트는 사이드바로, 읽기와 판정은 분리됩니다.** 한 단계짜리 평평한 목록에 사람 손이 필요한
   곳만 **대기** 배지가 붙고, 프로젝트 화면은 시간 밴드 + 두 탭(읽기 · 판정)입니다. 배지는 Home이
   이미 들고 있는 수를 그대로 가져오며 다시 세지 않고, 잘린 요약이 아니라 완전한 요약에서 가져오므로
   여섯 번째 프로젝트에도 붙습니다. 목록은 "아직 읽지 않음" · "읽었고 비어 있음" · "읽지 못함"을
   한 문장으로 뭉뚱그리지 않고 구분합니다.
3. **Brief를 훑어볼 수 있습니다.** 맨 위 **찾아볼 것** 구역에 확정된 결정 · 내 남은 할 일 · 준비할
   미답 질문 세 묶음이 기본 접힘으로 있고, 각각 건수 · 범위 문장 · 미리보기를 보여 줍니다. 어떤
   건수도 새로 계산하지 않습니다 — 이월 큐가 이미 들고 있는 배열의 길이입니다. 세 가지 정직성 규칙이
   함께 갑니다: 담당자가 본인으로 확정된 적 없는 항목은 *내 남은 할 일*에 들어가지 않고 범위 문장이
   그 사실을 말합니다. 질문은 연속성 기록이 해소를 승인한 경우에만 "답변됨"으로 적고 그 기록을
   이름으로 밝힙니다. 손으로 닫은 질문은 건수를 조용히 줄이는 대신 어느 목록에도 나타나지 않습니다.
4. **후보는 한 번에 하나씩 판정합니다.** 판정 탭이 카드 하나를 보여 줍니다 — `3 / 7`, 분자와 같은
   필터 목록에서 센 남은 건수, 출처 회의, 그리고 접힘 뒤의 인용 근거. **나중에 보기**는 화면 상태에서만
   건너뛰며 어떤 서비스도 호출하지 않습니다. "전부 미뤘다"와 "이런 종류가 없다"는 다른 문장입니다.
   경고 — 근거 없음, 소유 회의 불일치, 구간 없음, 들을 수 없는 이유 — 는 접힘 **바깥**에 남습니다.
   승인 판단에 필요한 것이고, 접어 두면 그것을 한 번도 보지 않은 채 승인할 수 있기 때문입니다.
5. **비어 있는 화면과 실패한 화면에 다음 한 걸음이 정확히 하나씩 생깁니다.** 첫 사용자 · 후보 없음 ·
   분석 실패 화면이 각각 행동 하나만 제시하며, 관례가 아니라 그것을 담는 타입으로 강제됩니다. 실패
   화면은 무엇이 보존됐다고 단정하는 대신 실제로 살아남은 것을 읽고, 확인된 것이 없는 경우에는 보존
   문장을 아예 빼 줍니다.
6. **세 가지 승인 상태를 말로 읽어 줍니다.** 확정 · 미승인 후보 · 읽기 전용에 음성 레이블이 붙어 색과
   위치만으로 구분하지 않아도 되고, 한 상태가 두 화면에서 다르게 불릴 수 없게 됐습니다. 화면에 찍히는
   단어 자체는 바뀌지 않았습니다. 세 곳에서 같은 이름이던 접기·펼치기·회의별 보기 컨트롤은 이제 각자
   구역의 이름을 답니다.
7. **Brief의 전이 문장 세 개가 틀려 있었고, 서비스가 실제로 쓰는 것에 맞춰 바로잡았습니다.** 완료는
   이번 회의의 중복 후보가 있으면 그것도 함께 정리하고, 진행은 도달하는 경우에 아무것도 쓰지 않으며,
   변경은 기존 항목 자신의 담당자와 기한을 옮깁니다. **다른 항목의 기한은 바뀌지 않습니다**가 두 버튼
   아래에 함께 섭니다. 되돌리기, 연쇄 기한, 다음 회의 날짜는 화면 어디에도 없습니다.
8. **전이 기록이 없다는 것을 "값이 그대로라는 증거"로 읽지 않습니다.** 편집 경로가 기록되지 않는
   항목은 *기록된 그대로*가 아니라 *…시점 기준 미확인*으로 보고합니다.

**확인한 것.** 전체 단위 스위트는 **1336종 실행 · 3 skip · 0 실패**입니다. 그중 28종은 Home 밴드와
프로젝트 밴드 뒤의 시간 투영을 위한 새 테스트이고, 투영을 여섯 가지로 일부러 망가뜨려 매번 예상한
테스트가 실패하는 것을 확인한 뒤 원래대로 되돌렸습니다. 이 작업 이전부터 실패하고 있던 7건은 남겨
두지 않고 고쳤으며, 계약 테스트의 엄격함은 줄이지 않고 오히려 두 가지를 더 단언합니다. 패키지는
릴리스 스크립트의 경계 검사를 통과했고(사용자 데이터·자격 증명·벤치마크/UI 테스트 자료·개발 marker·
사용자별 절대 경로 없음), 패키징 뒤 따로 풀어 `0.2.7` / `12`, `com.haena.HAENA`, 최소 macOS `14.0`,
universal `x86_64 arm64`, Team ID 없는 ad-hoc 서명을 확인했습니다. 빌드 시점 트리는 깨끗했으므로 위
표의 source commit이 이 바이트를 정확히 가리킵니다.

**확인하지 못한 것 — 여기가 중요합니다.**

**사람이 이 빌드를 써 본 적이 없습니다.** 패키징된 0.2.7 앱에 대한 오너 tryout이 없습니다. 다시 세운
화면이 실제로 읽히는지, 색을 끈 상태에서 세 승인 상태가 구분되는지, VoiceOver가 새 음성 레이블을
실제로 읽는지는 **의도이지 결과가 아닙니다.** 소스에서 검토하고 테스트로 단언했을 뿐, 아무도 보지
않았습니다.

**이 빌드에서 UI 스위트는 전부 통과가 아니며, 0.2.7은 그렇다고 주장하지 않습니다.** 대표 18종 기준
**15 통과 · 1 skip · 2 실패**입니다. skip은 빌드 기계의 Full Keyboard Access가 꺼져 있어서이고
**통과로 세지 않았습니다.** 실패 2종은 프로젝트 삭제 확인으로, 테스트가 제거할 수 없는 XCTest 자신의
알림 배너 인터럽션 모니터 안에서 실패합니다. **통과로도 skip으로도 세지 않고 실패로 보고합니다.**
통과시키려고 집중 모드·방해 금지·알림 설정 등 어떤 시스템 설정도 바꾸지 않았고 어떤 프로세스도
종료하지 않았습니다. 지난 신호(stale cue) 경로, Space 키, 모든 폭의 회의 경로는 이 빌드에서 **아예
돌리지 않았습니다.**

**0.2.6에서 넘어온 미관찰 항목.** 중복 제출 차단, 재시도 시 오디오 재복사 없음, provider 실패 문구는
0.2.6 노트에서 미관찰로 적었고, 0.2.7은 그 부분을 다시 보지 않았으므로 **여전히 미관찰**입니다.

**아직 검증하지 않은 것.** 실제 사용자 검증과 실제 회의 품질 주장이 없습니다. Windows 검증도 Windows
바이너리도 없습니다. WER·화자 분리 정확도의 정량 보고서가 없습니다. A.X / RunPod provider 연동은
계속 연기 상태이며 0.2.7은 모델과 provider를 바꾸지 않았습니다.

서명·공증이 없어 첫 실행에 Control-클릭 → **열기**가 필요합니다. 이 빌드는 다른 모든 HAE.NA 빌드와
**같은 번들 식별자**를 쓰므로 평소와 같은 로컬 저장소를 읽고 씁니다 — 격리된 하니스가 아니니 삭제처럼
되돌릴 수 없는 것을 시험할 때는 버려도 되는 프로젝트를 쓰세요.

**이 저장소의 공개 소스는 0.2.5입니다.** 0.2.6 이후 제품 소스는 비공개 core 저장소에서 개발하며
공개하지 않습니다. 이 저장소는 0.2.7에 대해서는 배포 창구(바이너리·릴리스 노트·체크섬·배포 테스트·
이슈 접수)와 보존된 0.2.5 소스 baseline(Apache-2.0)입니다. `HAENATests/`·`HAENAUITests/`는 0.2.5
baseline의 테스트이며, 위 다운로드를 검증하는 테스트는 누구나 실행할 수 있는
[`dist-tests/`](../dist-tests/README.md)에 있습니다. 이전 릴리스
(`v0.2.6-preview.2` · `v0.2.6-preview.1` · `v0.2.5-preview.1`)와 그 파일은 전부 변경 없이 그대로
공개되어 있습니다.
