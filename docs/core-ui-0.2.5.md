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
