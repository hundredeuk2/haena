# HAE.NA 0.2.5 (9) — Experimental Developer Preview

[Download macOS ZIP](https://github.com/hundredeuk2/haena/releases/download/v0.2.5-preview.1/HAE.NA-0.2.5-9-unsigned.app.zip) ·
[SHA-256 file](https://github.com/hundredeuk2/haena/releases/download/v0.2.5-preview.1/HAE.NA-0.2.5-9-unsigned.app.zip.sha256) ·
[Release page](https://github.com/hundredeuk2/haena/releases/tag/v0.2.5-preview.1)

> This is an unsigned, unnotarized experimental build for a small self-tryout. Public download
> availability does not mean that real-meeting quality, reliability, privacy suitability, or
> production readiness has been validated.

## Package identity

| Item | Value |
| --- | --- |
| Version | `0.2.5 (9)` |
| Package source commit | `4ab2c9f0829e1b8ca948211279c16b1c3a710d9c` |
| Release tag | `v0.2.5-preview.1` |
| File | `HAE.NA-0.2.5-9-unsigned.app.zip` |
| SHA-256 | `7f69eef6f19f018962a0156f44b910e484a50b15e3fa8de76d299e1bc0d67785` |
| Architecture | universal: `x86_64 arm64` |
| Signing | ad-hoc; no Developer ID signature or notarization |
| Minimum macOS | 14.0 |
| Build environment | macOS 26.6.2; Xcode 26.6 (`17F113`) |

Verify before opening:

```bash
shasum -a 256 HAE.NA-0.2.5-9-unsigned.app.zip
```

The result must exactly match the SHA-256 above. Preserve the previous 0.2.4 package for comparison;
this release does not replace or mutate that asset.

## What changed

- Added a persistent Home / Review / Briefs / Transcripts / Projects shell with typed navigation.
- Clarified first-use capture and returning-user next actions on Home.
- Unified capture progress, failure, retry, and saved-result messaging.
- Made Review the owner of pending AI proposals and Projects the owner of approved work state.
- Made a supported evidence quote open the exact stored transcript segment by meeting and segment ID.
- Split Continuity Briefs into confirmed carried state, candidates awaiting a verdict, and approved
  next agenda, with explicit per-candidate verdict effects.
- Included Korean and English display UI with System / 한국어 / English selection. This does not
  translate transcripts or model output.

The detailed implementation record is in [the 0.2.5 UI evidence log](core-ui-0.2.5.md).

## Verification completed

- Final 0.2.5 UI checkpoint: 306 selected unit tests, 6 direct Brief UI cases, and 53 preserved UI
  regression cases passed with no final failures or skips.
- Later light synthetic tryout: one Korean core loop and one English UI smoke passed.
- Release packaging completed from an isolated DerivedData directory.
- The ZIP passed archive integrity verification and an independent SHA-256 calculation.
- The extracted app reports version `0.2.5 (9)`, contains both `x86_64` and `arm64`, and passes strict
  on-disk ad-hoc signature verification.
- The packaging guard found no API-key pattern, meeting audio, persisted user-data file, benchmark
  artifact, UI-test marker, or user-specific absolute path in the app bundle.

## Not yet validated

- The product owner's real packaged-app tryout with their own meeting and OpenAI API key.
- Real microphone, provider, network-failure, cost, or long-running soak behavior in this package.
- Broad English or multilingual meeting extraction quality.
- Three physical character-input automation scenarios carried forward from development testing.
- Developer ID signing, notarization, automatic updates, and actual Windows execution.

The planned A.X / RunPod provider work is **not included** in 0.2.5; it belongs to the future 0.2.6
plan and must preserve the same evidence and approval boundaries.

## First tryout

Use non-sensitive data first:

1. Open AI Settings and save your own OpenAI API key.
2. Paste a short meeting note or record/import a short meeting.
3. Confirm that the meeting is saved before extraction finishes.
4. Review one pending proposal and open its evidence quote.
5. Approve only what is correct, then quit and reopen the app.
6. Open the next Brief and confirm that approved state and pending verdicts are distinct.

Record only the blocked step, expected result, and actual result. Do not attach meeting audio,
transcripts, API keys, or application data files to a public issue.

---

## 한국어 요약

0.2.5는 새 AI 기능을 늘리기보다 **처음 사용하고 다시 이어 쓰는 핵심 흐름을 명확하게 만든 UI
릴리스**입니다. Home에서 다음 행동을 안내하고, 미승인 후보는 Review, 승인된 업무는 Projects로
분리했습니다. 근거 인용문은 저장된 정확한 전사 구간으로 이동하며, 다음 Brief는 확정 이월 상태·판정
대기 후보·승인 아젠다를 구분합니다. 한국어와 영어 표시 UI가 포함되지만 회의 원문이나 분석 결과를
번역하지는 않습니다.

합성 계정 검증과 패키지 무결성 검사는 통과했지만, 실제 회의·API·마이크를 사용한 제품 오너의 패키지
tryout은 아직 남았습니다. 처음에는 민감하지 않은 짧은 자료로 저장 → 추출 → 검토·근거 확인 → 승인 →
종료·재실행 → 다음 Brief 흐름만 확인하세요.
