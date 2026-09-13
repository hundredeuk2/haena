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

### Verification status — event-boundary checkpoint

Current Task 2.2 remains **in-progress**; parent 2 in-progress, 2.3 pending. This checkpoint
started on clean `a9282e12052863db2d6a7b7b67cd570e7bc4ef7b`, no upstream.
The five normal AppShell UI scenarios remain; the deliberately failing character diagnostic
has been removed from the general suite. No Task Master status or Notion page was changed.

All UI evidence uses the isolated in-memory/synthetic assembly, Korean UI, bundle
`com.haena.CoreUI025`, primary-display placement, disabled saved-window restoration and serial
execution. Guards check target foreground and WindowServer owner/layer/bounds only, never
foreign titles/content. The original keyboard run was environment-invalid; the follow-up
runs and event-boundary run did not invalidate a guard. No other app was closed/manipulated.

### Current failure classification

| Symptom | Classification and direct evidence |
| --- | --- |
| Review rail click leaves Home selected | Product hit-area defect, fixed in a9282e1. Label hit area expanded 48x16 to 136x32 by contentShape; unchanged minimum-width/empty-state UI passed. |
| Project row click leaves selection unchanged | Product hit-area defect, fixed in a9282e1. Label hit area expanded 121x33 to 775x33; unchanged project/meeting/results/selection UI passed. |
| Original Capture button not hittable | Not reproduced in follow-ups; do not retroactively blame Chrome. One execution reached saved results but its title already differed before save. Full Capture acceptance remains open. |
| Observation helper re-queries removed Save button | Diagnostic test-contract defect fixed in a9282e1 by capturing identifier before click. |
| Synthetic y omitted | **After target-process arrival: app/AppKit/IME input boundary, root cause unresolved.** Not a proven XCTest transport defect and not a storage defect. |

The normal Capture test retains its original strings and exact pre-save assertions. No alternate
fixture, timing retry, coordinate click, clipboard input, assertion weakening or speculative
product input workaround was applied. Plain SwiftUI TextField bindings contain no y-specific
logic; absence of an app-owned y handler is not proof of which downstream layer is responsible.

### Target-process evidence (one execution, no repeated probe)

An ephemeral NSEvent local keyDown monitor was installed only inside the target process and
only under compile-time DEBUG + HAENA_UI_TESTING=1 + HAENA_UI_TEST_KEY_BOUNDARY_PROBE=1.
It returned every event unchanged. It recorded keyCode, exact isY Boolean and text-input
first-responder Boolean, never full input strings. One synthetic meeting-title field received
one S and one y request. No project/meeting was saved in this diagnostic.

| Stage | Recorded evidence |
| --- | --- |
| Probe installation | armed=true |
| XCTest S request | Synthesize event; target keyCode=1, isY=false, textInput=true; AX value S |
| XCTest y request | Synthesize event; target keyCode=16, isY=true, textInput=true; AX value remains S |
| Result | Target received y but the field did not reflect it; cannot call this target-prearrival transport loss |

The target stdout evidence is at lines 13, 19 and 21 of the target-specific
`StandardOutputAndStandardError-com.haena.CoreUI025.txt` within the local event diagnostic export.
The same target log contains an IMK mach-port warning; that correlation does not establish an
IME root cause. Input-source settings were neither read nor switched. The earlier optional
source-ID read had been safety-rejected; no workaround was attempted.

**Cleanup:** UITestWindowPlacement.swift exactly matches the checkpoint baseline. The probe,
probe environment flag, and testSyntheticUppercaseAndYInputDiagnostic are absent from final
source. Only the aggregate evidence and local xcresult/log retain diagnostic results. Exporting
xcresult diagnostics also produced a system log archive; only the target stdout was read, not
the archive's contents or whole-desktop recordings. No runtime artifacts are staged.

### Execution accounting

Counts are executed / failed / skipped; diagnostic failures are disclosed, not hidden as passes.
Historical rows are separate attempts, not a final all-green suite.

| Run / suite | Executed | Failed | Skipped | Interpretation |
| --- | ---: | ---: | ---: | --- |
| Initial AppShell run at 69e2bc3 | 5 | 3 | 1 | 1 pass; keyboard invalid environment |
| Hit-area / Capture triage | 7 | 5 | 0 | 2 passes, includes helper-defect and exact-input failures |
| Single-character API diagnostics at a9282e1 | 2 | 2 | 0 | typeText and typeKey both omit y; root then unknown |
| This event-boundary diagnostic | 1 | 1 | 0 | Target receipt proved; strict Sy assertion failed |
| Follow-up UI cumulative (excludes initial run) | 10 | 8 | 0 | 2 passes; not ten distinct scenarios |
| This turn normal AppShellUITests | 0 | 0 | 0 | Capture prerequisite unresolved |
| This turn HAENAUITests | 0 | 0 | 0 | Not executed |
| This turn ProjectBrowserUITests | 0 | 0 | 0 | Not executed |
| This turn PasteTranscriptUITests | 0 | 0 | 0 | Not executed |

Keyboard and the full related UI sequence are intentionally not started after the input
prerequisite failed. Zero execution is not a pass or a skip.

Probe-free final verification was executed, not copied from earlier results:

| Suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| BrowserDestinationTests | 13 | 0 | 0 |
| AppShellNavigationTests | 12 | 0 | 0 |
| Total unit | 25 | 0 | 0 |

Debug build and build-for-testing passed. Offline dependency validation: 2 tasks / 13 subtasks /
17 dependencies valid. Diff check passed. Product source and Task Master graph are byte-unchanged
from a9282e1; final diff contains only diagnostic-test removal and this compressed evidence.
The rebuilt Debug app binary contains neither TARGET_KEY_PROBE nor the probe environment marker.

### Local evidence and remaining gate

Evidence is outside Git in the temporary directory:

- Original: `haena-025-shell-ui.xcresult` / log.
- Triage: `haena-025-shell-triage-*` logs/xcresults.
- Previous input controls: `haena-025-shell-input-diagnostic`, `haena-025-shell-input-key`.
- This run: `haena-025-shell-event-boundary.xcresult` / log and
  `haena-025-shell-event-diagnostics` target stdout.
- Probe-free final verification: `haena-025-shell-event-final-test-build.log`,
  `haena-025-shell-event-final-unit.xcresult` / log, `haena-025-shell-event-final-debug.log`.

**Blocking:** identify the app/AppKit/IME post-keyDown loss before a justified fix and same-key
empty-field verification; then Capture, keyboard, full AppShell and related UI in the specified
order. Do not repeat the already-resolved question of whether y reached the target process.
No new product change is justified by this probe alone. Existing two hit-area fixes remain.
No 2.3 work, Notion, push, PR, merge, package, release or user-data access is included.
