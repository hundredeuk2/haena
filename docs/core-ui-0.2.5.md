# 0.2.5 UI integration baseline evidence

## 2.1 — approved action hierarchy and integration baseline

2026-09-13. Start: `7355f34`, `codex/0.2.5-ui-plan`, clean, no upstream.
Product input: English UI `e06ec37`. Common base with local `origin/main`: `5b524c5`.
The only independent main commit is `a9c7e8f`; its delta contains exactly `README.md` and
`docs/private-preview-0.2.4.md` (57 insertions / 27 deletions). Neither file had an independent
change on this branch. Applied those two documentation deltas verbatim, without a merge, checkout
switch, product-source replacement, network fetch, or rebuilding the frozen 0.2.4 artifact.

The current Notion Task and both input gates are confirmed; the UI contract and baseline gate
are already user-approved. HQ → current Release → current Task → two named inputs only were read.
Task Master: 2 tasks, 13 subtasks, 17 valid dependencies. This checkpoint completes only 2.1;
parent Task 2 remains in-progress and 2.2 is not started.

### Frozen interaction boundary

- 2a specifies continuity information architecture, not a pixel-perfect layout to reproduce.
- Capture and individual Approve are primary actions. Exclude/Edit/Reject are secondary;
  destructive deletion is separate, with its existing confirmation boundary.
- No automatic or bulk approval. Persisted pending candidates are not approved work state.
- Opening a Brief does not write or call a model. A deliberate verdict may change durable state
  through the existing review/apply services; calling the entire Brief "read-only" is incorrect.
- The deferred menu bar is a **no-approval status/recording control** surface, not read-only:
  start/stop changes recording state. Do not implement Task 2.9 or the 2.10 package gate here.
- Reuse the existing 447-key ko/en localization layer. Do not modify schema, status IDs, evidence,
  participants, due dates, extraction prompt, approval policy, Calendar or team features.

### Verification and open gates

Both integrated files exactly match the blobs at origin/main a9c7e8f:

- README.md: `a75e5e572865c8223e915c5d71d62397fea9d83c`
- docs/private-preview-0.2.4.md: `86b453c97b9eb48ea39b1edb84e14f03996ce692`

The product source, localization, tests and Xcode project have zero diff against e06ec37.
`git diff --check` and offline dependency validation pass. No unit/UI test execution is claimed.
A Debug build is not required or used as acceptance evidence for this document-only checkpoint.

The four old UI symptoms remain open: ambiguity New did not disappear; freeform completion was
not reached; no-project validation was not reached; structured second-turn/save was not reached.
Previous runs included explicit desktop-window interruption. Do not infer four product defects,
four environment exemptions, or an approved rebaseline. Each needs its own current evidence.

Execution stops after the 2.1 local checkpoint. No 2.2 implementation, product UI changes, user
store access, model calls, frozen package changes, push, PR, merge or release are included.

## 2.2 — persistent shell, direct acceptance verified

Start: `482d44fd968a21f9fe192c5282ae7364913a1075`, clean, no upstream.
Initially only 2.2 was moved to in-progress. The final, narrowed acceptance decision is below.

### Navigation implementation

- `AppShellDestination` defines Home, Review, Briefs, Transcripts and Projects as typed cases.
- `AppShellNavigation` keeps project/meeting selection across rail navigation. An explicit
  `BrowserDestination` replaces IDs and preserves its pane/action-item meaning. `.workState`
  routes to Review, `.status` to Projects, `.meetings` to the meeting surface. Capture links
  open meeting results; explicitly selecting Transcripts opens the transcript tab.
- `ContentView` keeps a persistent rail and window owner. Home's existing content is unchanged.
  Capture/settings remain sheets. Capture's queued destination is consumed after dismissal.
  The existing app-owned browser binding now tracks workspace ownership, including dismissal
  of nested review sheets on Quit. Startup recovery and capture reconciliation are untouched.
- `AppShellWorkspaceView` composes existing ProjectDetailView, WorkStateReviewView,
  MeetingDetailView and ManualContinuityBriefView with their existing services. The project
  selector and single content area replace the permanent three-column browser layout.
  Empty selection has destination-specific guidance; no empty transcript column is reserved.
- Navigation/Brief loading queries only. Explicit changes use existing verdict/deletion
  services and then reconcile reminders. No duplicate approval or persistence implementation.
- Three ko/en labels (Home/Review/Briefs) extend the existing localization resources.
  The test-only window placement helper adds a 720x520 content-size option (the former browser
  minimum width), without a storage override. Keyboard rail focus uses typed destinations.

### Typed-prefill checkpoint and acceptance boundary

Start: clean `60ea14a6ffae1ee0d26f065ddfeafdc0f583d967`, branch
`codex/0.2.5-ui-plan`, no upstream. This order explicitly scopes 2.2 to shell destinations,
deep links, meeting selection, sheet dismissal, keyboard focus and minimum width.
Character-entry fidelity is not claimed by navigation tests.

### Production-safe typed seam

- `PastedTranscriptInitialState` is ordinary form state: optional selected project ID, title,
  transcript. Its initializer/default is nil + empty strings; it does not save or extract.
- PasteTranscriptView initializes its three State values once from this dependency.
  ContentView forwards it; production HAENAApp supplies the unchanged empty default.
- Only compile-time DEBUG + HAENA_UI_TESTING=1 + HAENA_UI_TEST_CAPTURE_PREFILL=1 selects
  `CaptureNavigationUITestSeed` in the existing in-memory assembly. No raw environment content.
  The fixed project ID is C9000000-0000-4000-8000-000000000001, initially without any meeting or
  approved output. No provider, model, Keychain or user Application Support dependency is added.
- Capture UI verifies exact selected project name, title and transcript **before Save**, then
  existing Save → completion → Open Results → sheet dismissal → exact meeting result.
  No character typing, clipboard, coordinates, retry, accepted typo or weakened assertion.
- Six focused seed tests cover defaults, dual opt-in, strict boolean values, ignored raw content,
  fixed identity/empty output inventory, explicit-save-only in-memory capture and isolation.

### Confirmed shell fixes

Earlier label hit-area fixes remain (a9282e1): Review rail and project-row contentShape expanded
the clickable region, and unchanged scenarios passed. The stale observation-helper lookup was
a separate repaired test-contract defect.

This checkpoint exposed a distinct keyboard activation defect under valid guards:
after ↓ + Space, target AX showed Review **Keyboard Focused**, but Home still **Selected**.
Directional focus moved; activation did not. A focus-scoped onKeyPress(.space) now invokes the
existing navigation.select(destination). No domain/review/storage/input behavior changed.
The same keyboard scenario passed after this minimum fix; no assertion was removed.

### Known input automation limitation — explicitly transferred to 2.10

Historical A/B evidence showed both an independent plain SwiftUI TextField and the actual
PasteTranscript field received y keyDown yet remained S after S → y. A y-free fixture also lost
x before save. This is the recorded common AppKit/IME/XCUITest automation limitation, not evidence
of storage corruption, and not solved by typed prefill. No more fixture-character avoidance.

The following original character-input scenarios are **not executed** in this checkpoint and
are transferred to 2.10's physical-keyboard / packaged-tryout gate, not counted as pass or skip:

- ProjectBrowserUITests.testCreatingMeetingThenBrowsingShowsProjectAndMeetingDetail
- PasteTranscriptUITests.testCreatingProjectAndSavingMeetingShowsSavedConfirmation
- PasteTranscriptUITests.testStructuredPasteLinksOneSpeakerKeepsAnotherUnlinkedAndReachesCompletion

The 2.10 testStrategy already includes the complete packaged input-to-Brief loop. This evidence
document records the explicit input-fidelity carry-forward; no future task was started.
The removed A/B surface, key probe, env flags and intentionally failing diagnostic remain absent.
The legitimate typed-prefill seed is retained behind its compile-time/test-only boundary.

### Current execution record

Every UI invocation is serial in the existing synthetic assembly, Korean locale, primary-display
placement, bundle com.haena.CoreUI025, no saved-window restoration. Selected non-input legacy
tests now share the same foreground/overlap stop guard. No user app is closed or manipulated.
No guard invalidated any run in this checkpoint. Counts come from actual logs:

| UI run / suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Standalone typed Capture | 1 | 0 | 0 |
| Keyboard before fix | 1 | 1 | 0 |
| Keyboard after fix | 1 | 0 | 0 |
| Final AppShellUITests (all five) | 5 | 0 | 0 |
| HAENAUITests (all two) | 2 | 0 | 0 |
| ProjectBrowser non-input empty state | 1 | 0 | 0 |
| PasteTranscript non-input entry + validation | 2 | 0 | 0 |
| **All checkpoint UI attempts** | **13** | **1** | **0** |
| **Final acceptance suites only** | **10** | **0** | **0** |

The final row is a subset, not additional execution. The repaired keyboard failure remains
disclosed. Three legacy character-input scenarios are unexecuted, not skips (listed above).

| Final unit suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| BrowserDestinationTests | 13 | 0 | 0 |
| AppShellNavigationTests | 12 | 0 | 0 |
| CaptureNavigationUITestSeedTests | 6 | 0 | 0 |
| **Total** | **31** | **0** | **0** |

Debug build and build-for-testing passed. Offline validation after the status update:
**2 tasks / 13 subtasks / 17 dependencies valid**. Diff check passed. XcodeGen regeneration
is idempotent: project.pbxproj SHA-256 remained
`6f1ea8e48a6cc50725024d798b56f76ff480c6a482e70bbf71997f7879b9f8cb`;
project.yml is unchanged. The pbxproj change only registers the seed and its unit-test file.
Models, persistence, services, extraction, prompt/schema, and original window placement are
unchanged. No temporary A/B/probe/intentional-failure test or marker remains in final source
or rebuilt Debug app; Release was not built in this task.

### 2.2 final decision

| Direct acceptance | Current evidence |
| --- | --- |
| Five destinations / minimum width / no orphan pane | Final minimum-width AppShell test passed |
| Home deep link + retained project/meeting selection | Final Home-to-Review/Brief/Transcripts round-trip passed |
| Project selection + existing meeting/results views | Final project/meeting/results round-trip passed |
| Capture sheet dismissal + exact saved result | Final typed-prefill Capture passed with exact pre-save values |
| Directional keyboard focus + activation | Final keyboard test passed after Space handler fix |
| Unchanged production empty input and validation | No-prefill entry and no-project validation passed |

Offline Task Master **2.2 is done**, parent **2 in-progress**, **2.3 pending**, re-read after update.
No blocker remains for the explicitly scoped 2.2 acceptance. Character-input fidelity remains
unverified and explicitly carried to 2.10; this is not evidence of a completed packaged tryout.

Historical totals remain auditable in prior commits and local evidence: initial shell 5/3/1;
pre-A/B follow-ups 10/8/0; A/B 1/0/0 (observation only, not correct input); y-free Capture 1/1/0.
These repeated diagnostic attempts are not this checkpoint's final acceptance suite.

### Evidence and non-goals

Local `haena-025-shell-prefill-*` logs/xcresults contain current evidence. The keyboard failure
target-only attachments are `haena-025-shell-prefill-after-home.txt` and
`haena-025-shell-prefill-keyboard-failure.txt`; no whole-desktop recording was opened.
Prior A/B evidence remains in `haena-025-shell-ab*`, with target receipt in target-specific
stdout only. No raw runtime artifact is staged.

Final unit evidence: `haena-025-shell-prefill-final-unit.xcresult` / log;
build evidence: `haena-025-shell-prefill-keyboard-build.log` (test build) and
`haena-025-shell-prefill-final-debug.log`. Final UI prefixes are `prefill-suite`, `prefill-home`,
`prefill-project-empty` and `prefill-paste`, each under `haena-025-shell-`.
No Notion, Windows work, push, PR, merge, package/release or frozen 0.2.4 replacement.

## 2.3 — first-run / stored-state resume Home

2026-09-13. Start: `1f9b0ea2dccf19bbf0992eabee43df1de952e46a`,
`codex/0.2.5-ui-plan`, no upstream. The only existing dirty file was Task Master's authorized
2.3 pending → in-progress change plus timestamps; preserved, not reset or replaced.

### Implementation and authority boundary

- Empty Home now has one purpose sentence and exactly three visible capture entries: Record,
  Import Audio, Paste Transcript. No onboarding/profile gate. Existing project browsing remains
  a compact header control. Profile/AI settings/Agent History/Beta Metrics are in Home Tools;
  the Debug-only reminder sample no longer precedes the main action.
- Returning Home highlights one existing NextAction recommendation, or its honest empty state.
  Unchanged priority: pending review before explicitly linked own work; no substitute assignee.
  The four existing summaries are retained under a collapsed Project Summary disclosure.
- `HomeMeetingResume` is a read-only presentation value, not a schema/status or extraction state.
  It selects the latest stored meeting by occurredAt, createdAt, project ID and meeting ID.
  `MeetingWorkStateSummary` supplies the pending/total counts with its existing scope/policies.
  The row says review needed, no proposals awaiting review, or meeting saved/no results.
  It never claims that extraction ran, succeeded, or is currently running.
- Latest-meeting title, stored stage and **that meeting's** pending count appear in one row.
  No meeting-chain or pipeline is added. Its exact IDs route through BrowserDestination.results;
  the primary review/work CTA retains BrowserDestination.nextAction and existing owner screens.
- Nine ko/en entries extend the existing resources. User titles, names and evidence stay raw
  display values, not localization keys. At minimum width, work title/project/assignee wrap rather
  than silently truncating. No root reset, new storage field, due-date change or approval action.
- The only assembly addition is whole-file `#if DEBUG` HomeUITestSeed and failing test repository,
  selected by both HAENA_UI_TESTING=1 and a finite HAENA_UI_TEST_HOME scenario. No raw environment
  payload or storage path. Normal UI-test defaults and production repository/provider defaults
  are unchanged. Tests use fixed synthetic values and in-memory repositories only.

### Direct acceptance

All six scenarios run in **both ko and en** (12 tests). Minimum content size is 720x520;
the measured window is 720x552 including chrome. Tests require the first Home action/row to be
hittable and contained in the window without scrolling, and preserve the 2.2 foreground/overlap
guard. No environment guard was invalidated in either invocation.

| State | Verified result |
| --- | --- |
| Empty | Purpose + exactly three visible capture entries; each opens its existing owner and returns without saving |
| Pending review | One Review CTA, exact meeting/stage/count label, existing Review then exact meeting-results destination |
| Assigned work | Explicit linked participant, full title/assignee at minimum size, exact action and results owner |
| No profile | Honest no-recommendation state; no other person's work substituted; meeting results still reachable |
| Load failure | Existing error + reachable Retry; never represented as successful empty data |
| Restart-resume | Terminate and launch a new process with the same fixed canonical seed; same row/count and exact results owner |

Restart UI evidence is **in-memory seed reconstruction**, not a claim about a user store surviving
process termination. The separate unit round-trip serializes/decodes the canonical Project values
and rebuilds the repository/read model; sorted JSON bytes, IDs, transcript/evidence, assignee,
due date and approval state remain identical. No new persistence seam was introduced.

### Execution, including failed attempts

The first combined UI invocation ran 22 tests: 14 passed, 8 failed, 0 skipped. Six failures were
the new test querying child StaticTexts of a SwiftUI navigation button: target-only AX evidence
showed the full title/stage/count in the button's combined label. Two failures tested a larger
capture sheet's Cancel against the smaller parent Home frame after all three Home actions had
already passed visibility checks. Both were test-boundary errors, not failed saves or navigation.
The repaired tests assert the **entire** combined label and retain Home bounds checks, while
sheet interaction uses its existing hittable control. No timeout increase, blind click or retry.
The target hierarchy also exposed truncated work title/assignee at minimum size; those Text views
now wrap and the final tests assert their full values. No domain data was edited.

| Final unit suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| HomeMeetingResumeTests | 12 | 0 | 0 |
| HomeSummaryTests | 21 | 0 | 0 |
| NextActionTests | 20 | 0 | 0 |
| BrowserDestinationTests | 13 | 0 | 0 |
| AppShellNavigationTests | 12 | 0 | 0 |
| CaptureNavigationUITestSeedTests | 6 | 0 | 0 |
| AppLanguageTests | 15 | 0 | 0 |
| **Total** | **99** | **0** | **0** |

| Final serial UI suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| HomeResumeUITests | 12 | 0 | 0 |
| AppShellUITests (all 2.2 tests unchanged) | 5 | 0 | 0 |
| HAENAUITests | 2 | 0 | 0 |
| ProjectBrowser non-input empty state | 1 | 0 | 0 |
| PasteTranscript non-input entry + validation | 2 | 0 | 0 |
| **Total** | **22** | **0** | **0** |

Both xcresult summaries confirm these actual counts. Across both UI invocations: 44 executed,
8 failed, 0 skipped; the final 22 are a subset, not extra executions. Unit ran 99/0/0 initially
and 99/0/0 finally. A separate zero-test runner startup failed because ordinary Debug build
removed HAENATests.xctest from the host PlugIns directory. Restoring build-for-testing fixed the
assembly; that startup is **not a passing or skipped test run** and required no product change.

Final Debug build and build-for-testing passed. Offline dependencies: 2 tasks, 13 subtasks,
17 valid dependencies. `git diff --check` passed. XcodeGen regeneration is idempotent at
project.pbxproj SHA-256 `7e78c4f5d6bd889048bc71d69692480c7e198d9ddcc3aa635e63689633f92851`;
project.yml is unchanged, and the project-file delta only registers four new Swift files.

Evidence (local only, not staged): `haena-025-home-ui` initial and `haena-025-home-final-ui`
logs/xcresults; `haena-025-home-unit` initial and `haena-025-home-verified-unit` final;
`haena-025-home-final-unit` is the disclosed zero-test assembly failure. Build logs:
`haena-025-home-debug`, `haena-025-home-corrected-testbuild`,
`haena-025-home-verification-testbuild`. Target-only AX evidence is
`haena-025-home-assigned-hierarchy.txt`; no desktop recording was opened.

### Scoped completion / deferred work

Task Master **2.3 done**, parent **2 in-progress**, **2.4 pending**. All direct 2.3 acceptance
passes; no blocker remains in this slice. The three original character-input scenarios listed
under 2.2 remain **unexecuted**, neither passed nor skipped, assigned to the 2.10 packaged/input
gate. No real-user persistence, physical typing, Release/package or full-app regression claim.
Models, repositories, services, extraction/provider/prompt, approval and reminder policies,
HomeSummary/NextAction, ContentView/shell/deep-link contracts and production defaults are
unchanged. No user Application Support or real data access, external API/model call, menu-bar,
2.4 work, Notion change, push, PR, merge, package, release or frozen 0.2.4 replacement.

## 2.4 — truthful capture lifecycle and review counts

2026-09-13. Start: `ea67ee3c231c033a9c321c4bc720ba41f04ad6f9`,
`codex/0.2.5-ui-plan`, clean, no upstream. This checkpoint implements only Task 2.4;
the interrupted changes were preserved and their full diff reviewed before completion.

### Implementation and authority boundary

- Record, Import Audio and Paste use the same finite presentation phases: ready, preparing,
  recording, validating, copying audio, transcribing, saving, analysing and retrying. These
  are transient display observations, not persisted workflow statuses. Existing capture services
  add only optional, nonthrowing MainActor progress callbacks; validation/copy/transcription/save
  ordering and the canonical repository contract are unchanged.
- Saving is not saved. Completion is created only after repository.save returns successfully.
  Pre-save failure retains the entered title/project/transcript or selected audio file and offers
  retry without a results destination. Paste synchronously blocks a second Save while capture is
  in flight; this also prevents editing/cancelling that draft during its active save/analysis.
- Audio transcription failure is **before Meeting save**, after the managed audio copy. Its copy
  says only that audio is preserved and Meeting/transcript are not saved. Validation/copy failure
  does not claim an audio copy. After canonical save, preservation is derived from the actual
  Meeting's audioAsset and transcriptSegments, never from sourceType alone.
- Analysis failure does not roll back the saved Meeting. Retry uses the existing reanalysis
  service and exact project/meeting IDs; results remain accessible through the unchanged 2.2
  typed destination and sheet-dismissal route. A second analysis attempt after results exist is
  refused by the existing policy. No auto-approval or duplicate Meeting is introduced.
- CaptureOutcome retains historical total counts for metrics/reanalysis, separately deriving
  pending counts from MeetingWorkStateSummary. Completion labels those as unapproved AI proposals
  requiring individual review. Approved/processed outputs do not enter the displayed pending
  counts. Read failure or a missing Meeting produces unknown counts, not invented zero results.
  The old analysis-error prefix claiming "0 results" was replaced with the actual failed step.
- Thirty ko/en resource entries cover shared phases, preservation, pending counts and failure
  copy. Transcription credential guidance points to existing AI Settings; no provider behavior,
  response content, user title, transcript or evidence is translated or interpolated as a key.
- Whole-file `#if DEBUG` CaptureLifecycleUITestSeed requires both HAENA_UI_TESTING=1 and a known
  finite scenario. Synthetic projects/repositories/credentials/providers are in-memory; WAVs and
  managed audio copies use unique temporary directories. No environment-provided payload or path.
  The new typed audio draft defaults to empty in production. Test-only three-second provider
  latency makes active phases observable; production has no new delay, provider or retry.

### Direct acceptance

| Boundary | Verified result |
| --- | --- |
| All three paths, English success | Ready/progress before completion, busy Save disabled, correct saved artifacts, unapproved notice, Open Results and no remaining sheet |
| All three paths, canonical save failure | No Meeting/results, exact title/project/transcript or file selection retained, explicit retry creates one Meeting |
| Both audio paths, transcription failure | Managed copy exists, no Meeting/transcript saved; retained selection can retry successfully |
| All three paths, analysis failure/retry | Saved artifacts and exact Meeting preserved; one output per kind remains pending; repeat reanalysis refuses without duplication |
| Count-read failure | Unknown, not zero; existing results destination retained; UI covers combined analysis/read failure and retry; unit separately covers read failure after successful analysis |
| Cancellation | Paste/import dismiss without saving; deterministic recording cancels without a Meeting or approval |
| Counts/approval | Four pending proposals after successful extraction/retry; approved/completed/resolved/dismissed entries excluded from pending counts |
| 2.2/2.3 regression | All existing accepted shell, Home ko/en, typed capture, non-input entry and validation scenarios still pass |

UI uses fixed typed prefills, the isolated bundle `com.haena.CoreUI025`, serial execution and
the existing foreground/WindowServer overlap stop guard. No environment guard invalidated a run.
Record exercises deterministic start/stop through the existing Import owner, not a real microphone.
Open Results checks the exact saved title, sheet count zero, one meeting row and four pending
proposals. Unit checks exact Meeting equality, IDs, nil assignee/due and unchanged proposed status.

### Execution, including initial failures

The initial build-for-testing failed on one newly added fixture call:
`CaptureLifecycleUITestSeed.swift:36:69: extraneous argument label 'fileURL:' in call`.
Correcting the call to the existing validator's unlabeled API fixed compilation. That build
executed **zero tests** and is not counted as a passing or skipped test run. There were no test
assertion failures in the subsequent unit or UI invocations. No timeout increase or assertion
removal was used. Resuming this checkpoint confirmed the completed xcresults without rerunning UI.

| Unit suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| AppLanguageTests | 15 | 0 | 0 |
| AppShellNavigationTests | 12 | 0 | 0 |
| AudioMeetingCaptureServiceTests | 15 | 0 | 0 |
| BrowserDestinationTests | 13 | 0 | 0 |
| CaptureNavigationUITestSeedTests | 6 | 0 | 0 |
| CaptureOutcomeTests | 11 | 0 | 0 |
| CapturePresentationTests (new) | 15 | 0 | 0 |
| HomeMeetingResumeTests | 12 | 0 | 0 |
| HomeSummaryTests | 21 | 0 | 0 |
| MeetingAudioRecorderTests | 21 | 0 | 0 |
| MeetingReanalysisServiceTests | 11 | 0 | 0 |
| MicrophoneRecordingIntegrationTests | 9 | 0 | 0 |
| NextActionTests | 20 | 0 | 0 |
| TextMeetingCaptureServiceTests | 19 | 0 | 0 |
| **Total** | **200** | **0** | **0** |

| Serial UI suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| CaptureLifecycleUITests (new) | 17 | 0 | 0 |
| HomeResumeUITests | 12 | 0 | 0 |
| AppShellUITests | 5 | 0 | 0 |
| HAENAUITests | 2 | 0 | 0 |
| ProjectBrowser non-input empty state | 1 | 0 | 0 |
| PasteTranscript non-input entry + validation | 2 | 0 | 0 |
| **Total across two serial invocations** | **39** | **0** | **0** |

The three xcresult summaries confirm **200/0/0**, **17/0/0** and **22/0/0** respectively.
These are distinct test executions, not repeated passes added to inflate acceptance counts.
Final Debug build and build-for-testing passed. Offline dependency validation confirms
**2 tasks / 13 subtasks / 17 valid dependencies**. `git diff --check` passes. XcodeGen is
idempotent: project.pbxproj SHA-256 before/after regeneration is
`1ccbde8c3e010abe738e898b036747e971e2016eb4c999d5fdda6506bc0fac99`;
project.yml remains `19a1118a9e9a12d1cba35011c78251e963300c7de5624ab264d28e47525b430e`.
The project delta only registers five new Swift files (20 added lines).

Local evidence, not staged: `haena-025-capture-unit`, `haena-025-capture-ui` and
`haena-025-capture-regression-ui` logs/xcresults. Build logs: `haena-025-capture-initial-build`
(disclosed compiler failure), `haena-025-capture-unit-build`,
`haena-025-capture-regression-build` (test builds) and `haena-025-capture-final-debug`.

### Scoped completion / unverified boundaries

Task Master **2.4 done**, parent **2 in-progress**, **2.5 pending**, re-read after the update.
All direct 2.4 acceptance passes. No blocking issue remains for this slice.

- The original three character-input scenarios under 2.2 remain **unexecuted**, neither passed
  nor skipped, assigned to 2.10. Typed-prefill capture is not evidence of physical input fidelity.
- Native file-picker invalid-selection behavior, OS permission dialogs, real hardware/audio,
  credential interaction, real providers, Release/package and full-app regression are unverified.
- Pre-save audio retry retains the existing selected-file service path and can leave the prior
  unattached managed copy. This checkpoint verifies no duplicate **Meeting**, not audio-asset
  deduplication, orphan cleanup or recovery from a missing original file. Those policies were
  not changed or represented as solved.
- Models, persistence, extraction, recording/transcription implementations, HomeSummary,
  NextAction and BrowserDestination have zero diff. Domain IDs/schema, prompt/provider contract,
  evidence/assignee/due, approval, reminders and production storage defaults are unchanged.
- No real-user Application Support or meeting data access, external model/API call, Notion,
  push, PR, merge, package, release, frozen 0.2.4 replacement or Task 2.5 work in this checkpoint.

## 2.5 — Pending Review queue and approved Work State ownership

### Baseline and approved ownership rebaseline

2026-09-13. Start: `2e17aaa06a6de36b42725c7b29453bf30b917214`,
`codex/0.2.5-ui-plan`, no upstream. The checkout already contained the authorized Task Master
`2.5 in-progress` change and a partial implementation in product and test files. Those changes were
preserved and reviewed in place; no checkout, reset, stash or clean operation was used.

The product-owner-approved screen contract is now explicit and typed:

- Review owns only pending Decision, Action Item, Open Question and Agenda proposals.
- Projects / Work State owns only approved objects and their existing edit, reminder and lifecycle
  controls.
- Home pending rows and review recommendations route to Review. Home work, question and agenda rows,
  plus the debug reminder sample, route to Projects with an exact typed object selection.
- `BrowserDestination.nextAction(.review)` is `.pendingReview`; `.work` is
  `.approvedWorkState(.actionItem(exactID))`. Screen ownership is never inferred from whether an
  optional action-item ID happens to exist.

This changes two old expectations by approved product contract, not by weakening a regression:
`AppShellNavigationTests` now expects the legacy approved-work link to open Projects, and
`HomeResumeUITests` expects pending state in Review but approved state in Projects. Exact object-ID
assertions remain in place.

### Implementation and preserved boundaries

`ReviewQueue` derives a deterministic pending-only queue grouped by exact owning Meeting, with
All / Decisions / Actions / Questions / Agenda filters and stable ordering. Cards show kind,
confidence, headline, Action Item assignee and due date, and the exact stored evidence quote with a
timestamp only when the owning Meeting and transcript segment prove it. Missing, dangling,
cross-meeting and unassigned evidence are shown as unavailable rather than retargeted or invented.

Approve is the single primary action. Exclude and Action-Item-only Edit are secondary actions.
Each verdict calls the existing service with the exact proposal ID, reloads storage before changing
the displayed queue and Home count, and never batches or auto-approves. Approved Work State keeps
the existing exact IDs, editing, reminder reconciliation and lifecycle services. No domain model,
repository or persisted schema changed. Task 2.6 transcript-context highlighting was not started.

### Direct acceptance

Focused unit acceptance and the 2.2–2.4 unit regression set passed on the final test build:

| Unit selection | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Navigation, destination, Home, capture and presentation regressions | 212 | 0 | 0 |
| ReviewQueue and exact verdict/typed-owner tests | 20 | 0 | 0 |
| **Total** | **232** | **0** | **0** |

The 20 Review tests cover all four kinds, meeting grouping, stable order, all filters and counts,
non-pending exclusion, exact typed routes, wrong-kind/missing selections, exact verdict isolation,
Action-Item-only editing, and honest missing/dangling/cross-meeting evidence. Result:
`haena-025-review-focused-unit-final.xcresult`.

All ten distinct serial synthetic Review UI scenarios have a final pass: presentation, verdict/edit/
Home-count reload and approved ownership in Korean and English; empty state in both languages;
missing-source honesty; and focused keyboard Space approval. VoiceOver-facing identifiers, labels,
sort order and the exact evidence value are asserted by the same presentation/ownership scenarios.

| Review UI acceptance | Distinct scenarios with final pass | Failed final | Skipped final |
| --- | ---: | ---: | ---: |
| Korean / English and accessibility / keyboard | **10** | **0** | **0** |

Attempt history is kept separate from the final distinct-case result. An initial unsigned runner
setup exited before executing a test. The first combined signed run passed two empty-state cases,
then the foreground guard detected Codex and skipped eight cases. Independent reruns passed those
eight; one missing-source attempt observed a synthesized click that left Home unchanged and failed
its exact navigation assertion, and its immediate clean rerun passed without changing the
assertion. Across all direct UI attempts this is 19 framework test invocations: 10 pass, 1 fail and
8 environment skips. Temporary event/screen probes and the click-triage attachment were removed.

### Preserved 2.2–2.4 UI regression

| Serial UI suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| CaptureLifecycleUITests | 17 | 0 | 0 |
| HomeResumeUITests | 12 | 0 | 0 |
| AppShellUITests | 5 | 0 | 0 |
| HAENAUITests | 2 | 0 | 0 |
| ProjectBrowser non-input empty state | 1 | 0 | 0 |
| PasteTranscript non-input entry + validation | 2 | 0 | 0 |
| **Final distinct regression cases** | **39** | **0** | **0** |

The 17 Capture tests passed in one serial invocation. The next invocation passed its selected 19
tests; three initially mistyped method selectors executed zero tests and were not counted. With the
correct selectors, Chrome took foreground and the guard skipped those three. Independent guarded
reruns then passed ProjectBrowser and both PasteTranscript cases. Environment skips are disclosed,
not counted as passes. Results are in the `haena-025-review-capture-regression-rerun`,
`haena-025-review-shell-regression`, `haena-025-review-project-empty-rerun`,
`haena-025-review-paste-open-final` and `haena-025-review-paste-validation-final` xcresults.

### Broader baseline and completion checks

A broad HAENATests probe executed 1,117 tests: 1,108 passed, six failed and three skipped. The six
failures are outside this diff: five stale `StructuredAssigneeProviderContractTests` expectations
against the current provider schema and one `MicrophoneConfigurationTests` assertion because the
scheme supplied `HAENA_UI_TESTING=1`. They are disclosed as baseline issues, not repaired or counted
as Task 2.5 acceptance. The final scoped 232/232 run above is green.

Final Debug build and build-for-testing passed. Offline Task Master validation confirms **2 parent
tasks / 13 subtasks / 17 valid, unique, non-self, acyclic dependencies**. XcodeGen is idempotent:
project.pbxproj SHA-256 before/after is
`bdf6d67120f840051ff8c5a4d89246f634f6752b0864e5ccecec10952d4cfd98`; `project.yml` remains
`19a1118a9e9a12d1cba35011c78251e963300c7de5624ab264d28e47525b430e`.
`git diff --check` passes.

The three physical character-input scenarios transferred from 2.2 remain **unexecuted** and assigned
to 2.10; they are neither pass nor skip. No real user data, real provider/API, real microphone,
package, Release, Windows, Notion, push, PR or merge operation was performed.

Task Master is **parent 2 in-progress / 2.5 done / 2.6 pending**. All direct 2.5 acceptance has a
passing final result and no blocker remains for this slice.

## 2.6 — source quote to exact transcript context

### Baseline and route

2026-09-14. Start: `bcb673d75a59c9f5697b4f708760ab12c94599df`, `codex/0.2.5-ui-plan`, upstream
`origin/codex/0.2.5-ui-plan` 0/0, clean. Read-only gate confirmed parent 2 in-progress / 2.5 done /
2.6 pending and 2 parents / 13 subtasks / 17 valid unique acyclic dependencies before 2.6 was set
in-progress. No worktree, checkout, reset, stash or clean operation was used.

The route is typed end to end. `TranscriptEvidenceSelection(meetingID, segmentID)` is built only
from the stored `EvidenceReference`; it carries no text and no time. `BrowserTarget
.transcriptEvidence(selection)` lands on `.transcripts` with `meetingPane = .transcript`, and the
route's meeting is taken from the selection itself, so a caller cannot name one meeting and
highlight a segment of another. `AppShellNavigation.transcriptSelection` is a one-shot request
like `workStateSelection`: replaced by any explicit `open`, cleared by rail navigation, project
change, a meeting that fails validation, and never applied to a meeting other than the one on
screen (`highlightedSegmentID(in:)`).

`ReviewQueue.Entry.transcriptSelection` is non-nil only when the owning meeting really stores the
referenced segment — the same proof 2.5 requires for a timestamp, but independent of it: a pasted
transcript has no timing and still has an exactly addressable segment. Missing, dangling,
cross-meeting and unassigned references get nil. On the card a proven quote becomes a plain-style
button (the transcripts symbol beside it, Approve still the only prominent control), focusable and
Space-activated like the verdicts, with the exact quote text as its accessibility label and a hint
saying it opens the transcript. An unproven quote stays the 2.5 static text beside the 2.5
source-issue line. The transcript pane scrolls to the stored ID, tints that one row with a
"근거 발화 / Evidence segment" marker, and states in words whether the segment was highlighted or
could not be found. A same-text segment elsewhere in the transcript is never marked. The Review /
Projects ownership, verdict services, editing, reminders, lifecycle, schema and stable IDs are
unchanged; `MeetingResultsView` still shows the quote as text. Opening the screen performs reads
only: no model call, no reconciliation write.

### Direct acceptance

| Unit selection | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| ReviewEvidenceNavigationTests (new) | 20 | 0 | 0 |
| ReviewQueueTests (2.5 direct) | 20 | 0 | 0 |
| Navigation, destination, Home, capture, presentation, language regressions | 181 | 0 | 0 |
| **Total** | **221** | **0** | **0** |

The 20 new tests cover exact stored meeting/segment IDs for every pending kind, three proposals of
one meeting on the same segment plus one on its own segment, an identical-text duplicate segment
that is never selected, a pasted transcript without timing or audio, a recorded meeting whose audio
asset is absent, missing segment, dangling meeting, cross-meeting and unassigned references,
an emptied transcript, the typed route and shell state, selection change, one-shot clearing,
manual meeting switch, validation, preserved proposal identity / pending state / stored bytes, the
selection's two-field shape, and ko/en resources. The first unit run failed one assertion that
compared kind-ordered inbox IDs with meeting-grouped queue IDs as arrays; the test was corrected to
a set comparison and the whole selection rerun green (`haena-026-unit-final.xcresult`).

Synthetic `evidence` seed UI, guarded launch, minimum window:

| Review evidence UI | Distinct scenarios with final pass | Failed final | Skipped final |
| --- | ---: | ---: | ---: |
| ko / en navigation, keyboard Space activation, missing-source honesty | **4** | **0** | **0** |

Each navigation scenario clicks decision 100 → "Synthetic Review Meeting" transcript with only
segment 4 marked (same-text segment 8 and segment 7 unmarked), no audio player; returns to Review
with the count still 5, the same card, headline and hittable unselected Approve/Exclude; clicks
agenda 103 → segment 7 marked and 4 unmarked; clicks action 104 → "Synthetic Earlier Meeting"
(텍스트 입력 / Pasted Text), segment 5 marked, no timestamp, no player; then rail navigation shows
the meeting without a highlight and Review still at 5. The keyboard case tabs to the quote button,
confirms its own "Keyboard Focused" attribute, and presses Space. Attempt history: the first run
passed keyboard and missing-source and failed both navigation cases at the same step — action
104's quote existed below the fold of the minimum-height list and was not hittable. The test now
scrolls the quote into the list viewport first, exactly as the 2.5 ownership case does, and both
cases passed on rerun (`haena-026-evidence-ui.xcresult`, `haena-026-evidence-ui-rerun.xcresult`).
Across direct 2.6 UI attempts: 6 invocations, 4 pass, 2 fail, 0 environment skips.

### Preserved 2.5 and 2.2–2.4 UI regression

| Serial UI suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| ReviewQueueUITests (2.5 direct) | 10 | 0 | 0 |
| AppShellUITests | 5 | 0 | 0 |
| HomeResumeUITests | 12 | 0 | 0 |
| CaptureLifecycleUITests | 17 | 0 | 0 |
| **Total** | **44** | **0** | **0** |

One serial invocation, `haena-026-ui-regression.xcresult`. The 2.5 presentation cases now assert
the exact evidence text as the label of the quote *button* for the four proven cards; the 2.5
missing-source case additionally asserts that no such button exists. No other 2.5 assertion
changed. PasteTranscript and ProjectBrowser non-input cases were not rerun for 2.6: nothing in
this diff touches those screens.

### Completion checks and boundaries

Final Debug build and build-for-testing passed. XcodeGen is idempotent: project.pbxproj SHA-256
before/after regeneration is `e08955b633c7071dbe582dda08acacedc2473cb8788f520c75d7bcc6ed151cf9`
(two new test files); `project.yml` remains `19a1118a9e9a12d1cba35011c78251e963300c7de5624ab264d28e47525b430e`.
`git diff --check` passes. Dependency validation confirms **2 parents / 13 subtasks / 17 valid,
unique, non-self, acyclic dependencies**; it ran as an equivalent offline script because the only
installed Task Master executable lives under the unrelated human-gold checkout, which this session
must not read, and `.taskmaster/tasks/tasks.json` was updated in the CLI's own field format.

Out of scope, disclosed not repaired: `scripts/check-localization.py` already fails at the start
HEAD on a pre-existing duplicate key `저장된 회의가 없습니다.`; the same audit with that one
duplicate tolerated reports 511 keys, 415 static references, 0 missing, 0 placeholder mismatches.
The quote button gives up text selection on the Review card; the transcript row keeps it. VoiceOver
hint text is set in code and visible in the attached hierarchies but is not asserted by XCUITest.
The physical character-input scenarios remain assigned to 2.10. No real user data, provider, model,
microphone, audio, Notion, package, Release, Windows, push, PR or merge operation was performed.
Task 2.7 was not started.

Task Master is **parent 2 in-progress / 2.5 done / 2.6 done / 2.7 pending**.

## 2.7 — Continuity Brief verdict flow

### Baseline and audited contract

2026-09-14. Start: `9568b37c8d239180262fdf2b0cf9f71853291bd3`, `codex/0.2.5-ui-plan`, upstream 1/0,
clean. The read-only gate confirmed parent 2 in-progress / 2.5 done / 2.6 done / 2.7 pending, 17
valid unique non-self acyclic dependencies, and the 2.6 evidence with its disclosed boundaries
before 2.7 was set in-progress. No worktree, checkout, reset, stash or clean operation was used.

Audit of the existing surface: `ManualContinuityBriefService` is a pure read (three repositories,
no extractor, no provider); `WorkStateTransitionReviewService.review(action:)` accepts exactly
`.approve` / `.reject` per proposal ID, `resolveAmbiguity(selection:)` accepts `.priorCandidate(id)`
/ `.new` per group, and `WorkStateReviewService` approves or dismisses one Agenda Item. The six
`WorkStateTransitionKind` cases map onto those verdicts as the service really applies them:
`completed` → prior item becomes `.completed`; `delayed` (blocked / deferred / overdue) → prior
status, due date and assignee stay exactly as stored and only this meeting's duplicate is cleared;
`changed` → prior takes this meeting's content; `resolved` → question resolved and linked item
approved; `new` → adopted; `same` → duplicate cleared. No verdict outside this set exists, so none
was invented: `ManualContinuityBriefVerdictKind` is a total, typed function of the transition kind,
and its labels name the real effect ("차단 확인 · 상태 유지", "완료로 반영", …). No schema, service
or engine change was needed; no contract gap was found.

### Implementation

`ManualContinuityBriefVerdictQueue` splits the loaded Brief once into A (approved carried state,
read-only), B (candidates awaiting a verdict: completion, blocked/delayed/overdue, other changes,
link groups, agenda candidates — each with its own exact ID) and C (approved next agenda,
read-only), with `ManualContinuityBriefCandidateState` naming why B is empty: `.unavailable`
(transition store unreadable — not zero), `.firstBrief` (fewer than two meetings), `.none` (two or
more meetings, nothing pending). The header states the count and the boundary in words: opening or
browsing saves nothing; only a candidate's verdict button changes stored state. Each candidate card
shows the affected exact object, its current stored status, the proposed transition, its evidence
control, and an "on approval" line describing the effect before the user presses. Approve is the
single prominent control; reject is bordered. All verdict controls are focusable, Space- and
Return-activated, and carry a VoiceOver hint that says whether they change stored state. A refused
or failed apply keeps the candidate, re-enables its buttons and says so in the feedback line. The
seed gained `firstBrief`, `zeroCandidates` and `applyFailure` scenarios; `applyFailure` makes the
in-memory transition store throw before any Project write. Task 2.5 Review / Projects ownership and
the 2.6 evidence route are untouched.

### Direct unit acceptance

| Unit selection | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| ManualContinuityBriefVerdictFlowTests (new) | 14 | 0 | 0 |
| ManualContinuityBriefTests · WorkStateTransitionReviewServiceTests · WorkStateTransitionRepositoryTests | 71 | 0 | 0 |
| 2.6 ReviewEvidenceNavigationTests · 2.5 ReviewQueueTests | 40 | 0 | 0 |
| Navigation, destination, Home, capture, presentation, language regressions | 181 | 0 | 0 |
| **Total** | **306** | **0** | **0** |

The 14 new tests cover the A/B/C split of the full seed with no candidate in two groups, the
total mapping of every transition kind to one verdict with distinct localized labels, first-Brief
/ zero-candidate / unavailable as three states, load failure reported rather than shown as empty,
opening twice with zero writes and a three-repository dependency shape, navigation-only reads,
completion completing only its prior and moving it to A, blocked/deferred/overdue leaving status,
due date, assignee and evidence unchanged, reject touching no object, resolution / link / agenda
verdicts routing to their own services, agenda exclusion retiring one candidate, apply failure
leaving Project and candidate untouched with a later retry applying, and the absence of any batch
member. Two first-run assertion failures were my own ordering assumptions (inbox vs. queue order;
`changes` order), corrected to set comparisons; the final selection ran green
(`haena-027-unit-final.xcresult`).

### Direct UI acceptance

Synthetic seed, minimum window, foreground guard on every click:

| Brief verdict UI | Distinct scenarios with final pass | Failed final | Skipped final |
| --- | ---: | ---: | ---: |
| ko / en sections + verdicts, apply failure, first Brief, zero candidates, keyboard Space | **6** | **0** | **0** |

The ko/en scenario asserts the header count "판정 대기 8건 · 확정 아젠다 1건", the boundary line, A
above B above C, zero verdict buttons inside A and C, the approved agenda item only in C and the
candidate only in B, the four distinct primary labels (완료로 반영 / 차단 확인 · 상태 유지 / 지연
확인 · 상태 유지 / 기한 초과 확인 · 기한 유지), the "on approval" effect line, no approve-all
control; then one completion verdict removes exactly that card, moves "Export transition fixture"
from A's active group to A's completed group and drops the count to 7 while the three progress
candidates remain; then one reject removes only the deferred note (count 6). Apply failure keeps
the candidate enabled, the count at 8, nothing moved to A, and shows the retry sentence. First
Brief and zero candidates show their own sentence with no verdict button and no error or
unavailable banner. The keyboard case tabs to the completion button, confirms its own "Keyboard
Focused" attribute and applies it with Space.

Attempt history: two invocations executed zero tests because the UI runner timed out enabling
automation mode behind a macOS authentication window (`coreautha`); a bounded wait resumed once it
closed. The first executed run passed 5 and failed the apply-failure case on my own wrong
assumption (the prior's title is already visible in A as active work); the carried groups gained
stable identifiers (`manual-brief-confirmed-<group>`) and the rerun passed 6/6
(`haena-027-brief-ui-final.xcresult`, `haena-027-brief-ui-rerun.xcresult`). Across direct 2.7 UI
attempts: 12 framework invocations, 11 pass, 1 fail, 0 guard skips, plus 2 runner-initialization
failures with nothing executed.

### Preserved Brief, 2.6, 2.5 and 2.2–2.4 UI regression

| Serial UI suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| ManualContinuityBriefUITests (legacy Brief journey, final) | 5 | 0 | 0 |
| ReviewEvidenceUITests (2.6 direct) | 4 | 0 | 0 |
| ReviewQueueUITests (2.5 direct) | 10 | 0 | 0 |
| AppShellUITests | 5 | 0 | 0 |
| HomeResumeUITests | 12 | 0 | 0 |
| CaptureLifecycleUITests | 17 | 0 | 0 |
| **Final distinct regression cases** | **53** | **0** | **0** |

The first combined invocation (`haena-027-ui-regression.xcresult`) passed 47 and failed 6. One,
`CaptureLifecycleUITests/testRecordCancellation`, asserted `sheets.count == 0` while the
recording sheet was still dismissing; its immediate rerun passed without any change
(`haena-027-brief-legacy-ui.xcresult`). The five legacy `ManualContinuityBriefUITests` cases all
failed at their shared `selectSeedProject` helper, which still looked for a project-name static
text inside `project-list`; the 2.2 shell exposes projects as `project-row-<id>` buttons. This is
pre-existing: the unmodified suite, run against a `git archive` export of the start HEAD
`9568b37c` (no checkout, no worktree), fails all five at the same line
(`haena-027-head-baseline-brief-ui.xcresult`). The helper now clicks the seed row. With that fix
three cases passed and two still missed their click after a scroll; the legacy `scrollTo` reported
an element hittable while only partly inside the list viewport, the same finding the 2.5 ownership
case recorded. The helper now requires two agreeing frame reads and full viewport containment,
and the whole suite passed 5/5 in one invocation (`haena-027-brief-legacy-ui-final.xcresult`). No
assertion of any legacy case was weakened. Across the legacy-suite attempts: 5 + 5 + 2 + 5
invocations, 10 pass, 7 fail (5 stale helper, 2 click geometry), 0 guard skips, plus the 5
HEAD-baseline failures recorded as evidence.

### Completion checks and boundaries

Final Debug build and build-for-testing passed. XcodeGen is idempotent: project.pbxproj SHA-256
before/after regeneration is `52ad6b46e4bad358cc70754fcf2dc2d061705e7af7dc6dc27c80dd142d213143`
(three new files); `project.yml` remains `19a1118a9e9a12d1cba35011c78251e963300c7de5624ab264d28e47525b430e`.
`git diff --check` passes. Dependency validation (equivalent offline script, as in 2.6) confirms
**2 parents / 13 subtasks / 17 valid, unique, non-self, acyclic dependencies**. The localization
audit with the pre-existing `저장된 회의가 없습니다.` duplicate tolerated reports 547 keys, 440
static references, 0 missing, 0 placeholder mismatches; that duplicate, the three physical
character-input scenarios and the VoiceOver hint (set in code, visible in the attached hierarchies,
not asserted by XCUITest) remain 2.10 boundaries, unchanged.

Opening read-only evidence: `testOpeningTheBriefTwiceWritesNothingAndHasNoModelDependency` loads
the Brief twice and after a rail navigation with the Project bytes unchanged, every proposal still
`pendingReview`, no apply intent, and a read service whose only dependencies are the three
repositories; scenario 35 of the existing suite still counts 0 writes per load. The UI journeys
open the Brief through the seeded in-memory stores with `DeterministicWorkStateExtractor` and no
provider, and the header count is unchanged after every open. Not verified: the transition-store
unavailable state in the UI (its typed state and banner are unit-covered; the in-memory store has
no read-failure switch and none was added), and both ambiguity choices being prominent — the
existing "new" choice stays prominent and "link" bordered as before 2.7. No real user data,
provider, model, microphone, audio, Notion, package, Release, Windows, push, PR or merge operation
was performed. Task 2.8 was not started.

Task Master is **parent 2 in-progress / 2.5 done / 2.6 done / 2.7 done / 2.8 pending**.
