# English UI: four-failure comparison checkpoint

## Baselines and scope

- Feature input: `codex/english-ui-v0` / `0a3a80f2210f8a964ae3b9ca3c2f1a2492eb4114`, clean.
- Product comparison input: `5b524c50f2e7a78fac21e85c9832ee57ee3d05ed`.
- No saved checkout switches, private candidate changes, push, merge or package creation.
- No Beta Metrics or Agent translation expansion. Existing assertions and timeouts remain intact.

## Existing evidence, before rerunning

Source run: `haena-en-ui-single-final.log` and
`Test-HAENA-2026.09.12_22-01-32-+0900.xcresult`.
Original log SHA-256: `84e118a6a6d100c888af29b88e523ed591b4c1b3a566910fa9e506bacefdf88b`.
All four tests launched `com.haena.EnglishUIPrimary`.
Line numbers below refer to the source as built in that run, not the current edited test file.

| Case | First failed assertion | Immediately preceding recorded UI activity | What is not established |
| --- | --- | --- | --- |
| Brief ambiguity `new` | ManualContinuityBriefUITests:115, `waitUntilGone(newChoice)` | Target `manual-brief-ambiguity-0841E425-DEDD-5B34-9066-7A0BAAD7B3A0-new` clicked at t=41.96; existence checks t=43.43–52.41 did not become false | Whether the action was delivered, its review result, or underlying verdict |
| Freeform save | PasteTranscriptUITests:78, saved-message wait | Text-entry events followed by save click at t=15.13. At t=15.21 an interrupting `com.google.antigravity-ide` window was reported; interruption unhandled and click fell back to point `{882.5,824}` | Whether save ran or storage succeeded; no readback evidence |
| No-project validation | PasteTranscriptUITests:28, home paste-button wait | App launched (pid 68516); home `paste-transcript-button` absent through t=6.62 | Validation was never reached; not a validation-logic or save-failure observation |
| Structured paste | PasteTranscriptUITests:126, second speaker-field scroll/access | First turn entered; add-turn click t=21.27, show-turns click t=21.75; `pasted-speaker-label-field-1` not found through t=49.44 | Save was never reached; not a stored meeting or completion failure |

The old result bundle's failure-only attachment export returned no matching attachments.
The ambiguity text attachment contains a query chain for the target identifier, not a full
rendered state or a storage snapshot. Whole-desktop recordings are not used as evidence because
they may include unrelated user content. These gaps are preserved, not filled by inference.

## Controlled comparison assembly

Code-only snapshots were materialized with `git archive` (HAENA, HAENATests, HAENAUITests,
HAENABenchmarkCLI and project.yml only), outside the saved checkout. No corpus/data/dist paths.
The current 0a3a80f versions of the two scenario test files were applied to both snapshots.
The existing test-only primary-display placement helper was applied identically; only the
baseline main scene needed the equivalent DEBUG background attachment.

Existing scenario changes relative to 5b524c5 are kept separate from product changes: launch
readiness, saved-window restore suppression, bounded target-directed scrolling, explicit
structured-input button/text-field actions, and Korean pinning. The same changes are on both sides.

Additional shared comparison-only instrumentation:

- Same bundle ID `com.haena.UIComparison`, Debug/arm64, serial execution, separate DerivedData.
- Existing `HAENA_UI_TESTING=1` in-memory deterministic assembly; same fixture.
- macOS launch arguments `-AppleLanguages (ko) -AppleLocale ko_KR`, plus an assertion that the
  actual home paste button says `텍스트 회의록 붙여넣기` on both sides.
- `HAENA_UI_TEST_LANGUAGE` is explicitly removed from both launch environments. Baseline Korean
  is not claimed based on an unsupported variable.
- Same primary placement and scale; initial display metadata: primary `{0,0,2560,1440}` at 1x,
  secondary `{-2560,-1440,2560,2880}` at 1x. Runtime screen/window geometry is logged on launch.
- Before/after each click, assert the foreground bundle ID. UI interruption marks
  `ENVIRONMENT_INVALID_UI_INTERRUPTION`; such a run cannot be used for a product verdict.
- No assertion removal, timeout increases, automatic retries or concurrent UI runs.

Identical SHA-256 values on both snapshots:

| Shared input | SHA-256 |
| --- | --- |
| ComparisonEnvironment.swift | bcadf2ed8e8e06120b0c8320a083e7c0a0def582dfb1beac2533194058bb62fa |
| ManualContinuityBriefUITests.swift | 2bead23ba87edd64737d60390170a254fedaa9e483d0c768eadc5a413759da15 |
| PasteTranscriptUITests.swift | 26b62ca4a9636dc04b7d5623f4c796776839a264acadec4b23ae679938ff8b40 |
| UITestWindowPlacement.swift | 400314897f94b136035c768422ecf6afa35ffc9783fd2d3b69e7cf616d4f906f |
| ManualContinuityBriefUITestSeed.swift | 3e6bb74295896b13b45e8342e511b4d8e1bb5726101b3e01890a0aa3d184d668 |

## Comparison result

The baseline build succeeded. Its controlled launch logged actual Korean, primary window
`(80,110,1000,800)` and the same two 1x displays recorded above.
Stopped comparison log SHA-256: `e39136b030a4e517ea06d54ba54a6684b5756dff2eeb6b3f440c07955d751939`.

| Baseline scenario | Observed result | Product-comparison eligibility |
| --- | --- | --- |
| Ambiguity `new` | Failed the original disappearance assertion. Before click: frame `(389,846,365,24)`, enabled and hittable, foreground check passed. | Isolated observation only; paired current run not executed, so no regression classification or exemption |
| Freeform save | Guard failed at t=17.81: `ENVIRONMENT_INVALID_UI_INTERRUPTION`. Save frame `(859,812,47,24)`, enabled=true, hittable=false. Interrupter: `com.google.antigravity-ide`, window `(0,30,1280,1320)`. | Invalid environment; excluded from product pass/fail judgment. Save execution/result unknown |
| No-project validation | Passed; runner had advanced before the guard failure was observed externally. | Recorded, not used to finish an invalid/partial paired comparison |
| Structured paste | Began, then the runner was interrupted. | No completion result; not counted as pass or product failure |

On observing the interference guard, only the owned baseline xcodebuild process was sent SIGINT.
The current snapshot was prepared but not run. There was no automatic retry. The interfering app
was neither queried for content nor closed/modified. No current-product or scenario-test files
were edited; the experimental overlay is confined to the two temporary comparison snapshots.

Required environmental action (one): close Antigravity IDE for the dedicated UI verification
session. Resume the four-case paired comparison only after that condition is confirmed.
Do not infer that all four symptoms have this cause. Actual save/review/Brief usability remains
an open gate irrespective of whether its cause predates localization.

The combined 9+6 UI run and any code-related unit rerun are deferred by the explicit environment
stop condition. This checkpoint changes evidence documentation only; no product fix, timeout
increase, weakened assertion, push, merge, or frozen-candidate change is claimed.
