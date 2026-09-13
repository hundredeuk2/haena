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

## 2.2 — persistent shell, UI verification blocked

Start: `482d44fd968a21f9fe192c5282ae7364913a1075`, clean, no upstream.
Only 2.2 was moved to in-progress. Parent 2 remains in-progress; 2.3 and later remain pending.

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

### Verification status — input A/B checkpoint

Start: clean `8ab73eba39499b65a4a490a725d71ecb103b7c8f` on
`codex/0.2.5-ui-plan`, no upstream. Parent 2 / 2.2 remain **in-progress**; 2.3 pending.
No Notion or Task Master status change. No product-source change remains in this checkpoint.

### A/B result (one process, one S then one y per field)

Both surfaces used Korean locale, the same primary-display placement and the same
foreground/overlap guard. The minimum surface contained only a plain SwiftUI TextField and
a current-value label, with no repository/service/storage/model access. It was followed by
the actual PasteTranscript meeting-title field in the same HAE.NA process.

| Surface | After S | After y | Target keyDown receipt |
| --- | --- | --- | --- |
| Independent minimal TextField | S | S; value label also value=S | minimal=true, keyCode=16, isY=true, textInput=true |
| Actual meeting-title-field | S | S | minimal=false, keyCode=16, isY=true, textInput=true |

The target probe was armed and observed keyCode=1 / isY=false for S as a positive control
on each surface. XCTest recorded Synthesize event for both requests. Thus the y loss is
**common AppKit/IME/XCUITest input-environment boundary**, not specific to PasteTranscript.
Its exact downstream mechanism remains unproven. Do not repeat the already-settled target
arrival diagnostic or claim a storage defect.

The A/B test's pass means both observations completed under valid guards, **not** that y input
worked. Only keyCode/isY/textInput and the static minimal/actual classification were logged by
the local monitor; it returned events unchanged. No clipboard or input-source settings read,
no foreign window contents, and no user data/model/provider access.

### Fixture adjustment and remaining failure

As explicitly authorized for the common-environment outcome, AppShell navigation fixture alone
changed to `Shell Fixture Project`, `Shell Fixture Meeting`, and
`Navigation fixture transcript.`. The expected result title changed consistently.
All exact pre-save assertions remain, with no timing/retry/coordinate/clipboard workaround.

One Capture rerun failed at the first pre-save assertion: actual project-name input was
`Shell Fiture Project`, omitting **x**. No project or meeting was saved by that attempt.
The x event was not independently probed; do not infer its exact mechanism from the y probe.
The y-free fixture therefore did not establish reliable input. No successive character avoidance,
fixture search or retry followed. Capture remains incomplete; keyboard and remaining suites
were not started because the input prerequisite is still unsatisfied.

### Product and test boundaries

- Review rail hit-area defect and project-row hit-area defect remain fixed by a9282e1;
  each unchanged scenario passed after contentShape expanded the respective full label area.
- Original Capture not-hittable symptom did not recur in later attempts; an earlier attempt
  reached saved results with an already-wrong input title. That is not full Capture acceptance.
- The stale observation-helper element query was fixed separately; no assertion was removed.
- Final changes are only the AppShell fixture/comment update and this compressed evidence.
  Models, IDs, evidence, approval, storage, extraction and navigation product code are unchanged.

**Temporary cleanup:** the minimum A/B surface, local keyDown monitor, A/B environment flag and
dedicated diagnostic test were removed. UITestWindowPlacement.swift matches baseline exactly.
The rebuilt Debug app has no INPUT_AB_PROBE, HAENA_UI_TEST_INPUT_AB, ab-input-field or prior
TARGET_KEY_PROBE/environment marker. The five ordinary AppShell test methods remain.

### Execution accounting

Executed / failed / skipped counts below are actual runs, not distinct scenario counts.
Environment-invalid execution must never be interpreted as a functional pass or failure.

| Run / suite | Executed | Failed | Skipped | Interpretation |
| --- | ---: | ---: | ---: | --- |
| Initial AppShell at 69e2bc3 | 5 | 3 | 1 | Historical; keyboard invalid environment |
| Hit-area / Capture triage | 7 | 5 | 0 | Historical; two fixed-hit-area passes |
| Single-character controls at a9282e1 | 2 | 2 | 0 | Historical input diagnostics |
| Event-boundary at 8ab73eb | 1 | 1 | 0 | Historical; y target receipt proved |
| This turn temporary A/B | 1 | 0 | 0 | Diagnostic observations completed, not input correctness |
| This turn AppShell Capture | 1 | 1 | 0 | x omitted; exact pre-save assertion blocked save |
| This turn keyboard | 0 | 0 | 0 | Not executed |
| This turn full AppShell suite | 0 | 0 | 0 | Not executed |
| This turn HAENAUITests | 0 | 0 | 0 | Not executed |
| This turn ProjectBrowserUITests | 0 | 0 | 0 | Not executed |
| This turn PasteTranscriptUITests | 0 | 0 | 0 | Not executed |
| All follow-ups, excluding initial run | 12 | 9 | 0 | Three passes, including diagnostic A/B |

No guard invalidated this turn's two runs. All were serial in the existing isolated synthetic
assembly, bundle `com.haena.CoreUI025`, with saved-window restoration disabled. No other app
was closed or manipulated.

| Final probe-free verification | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| BrowserDestinationTests | 13 | 0 | 0 |
| AppShellNavigationTests | 12 | 0 | 0 |
| Total unit | 25 | 0 | 0 |

Debug build and build-for-testing passed. Offline validation: 2 tasks / 13 subtasks /
17 dependencies valid. Diff check passed; product source and Task Master graph have zero diff
from 8ab73eb. These results do not resolve the failed input prerequisite or unexecuted UI gates.

### Evidence and next gate

Local evidence remains outside Git:

- `haena-025-shell-ab.xcresult` / log: minimal values at log lines 71/81/83,
  actual values at 195/205.
- `haena-025-shell-ab-diagnostics`: target-specific
  `StandardOutputAndStandardError-com.haena.CoreUI025.txt`, probe lines 13/19/21/23/24.
  Export also contains a system log archive; its contents were not read.
- `haena-025-shell-ab-capture.xcresult` / log: exact-input x omission.
- `haena-025-shell-ab-clean-build.log`, `haena-025-shell-ab-final-unit.xcresult` / log,
  `haena-025-shell-ab-final-debug.log`: probe-free final verification.
- Historical evidence prefixes: `haena-025-shell-ui`, `haena-025-shell-triage-*`,
  `haena-025-shell-input-diagnostic`, `haena-025-shell-input-key`,
  `haena-025-shell-event-boundary`.

**Blocker:** input remains unreliable beyond y. A justified input-environment remedy is needed
before Capture, keyboard, full AppShell, Home, ProjectBrowser and PasteTranscript tests can
establish acceptance. Do not mark 2.2 done from unit/build success or the completed A/B observation.
No 2.3 work, Notion, push, PR, merge, package, release or frozen 0.2.4 modification.
