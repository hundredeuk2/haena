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
