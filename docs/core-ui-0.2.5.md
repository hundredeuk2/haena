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

### Verification evidence

Commands used this worktree, isolated DerivedData and bundle ID `com.haena.CoreUI025`.
UI launches used `HAENA_UI_TESTING=1`, Korean, the existing in-memory/synthetic assembly,
primary-display placement, disabled saved-window restoration and serial execution.
Preflight: Accessibility trusted; primary 2560x1440 at 1x, secondary 2560x2880 at 1x;
no concurrent HAE.NA or UI runner was found. No real user store or provider was used.

| Suite | Executed | Failed | Skipped | Scope |
| --- | ---: | ---: | ---: | --- |
| BrowserDestinationTests | 13 | 0 | 0 | Existing capture/deep-link/selection regression |
| AppShellNavigationTests | 12 | 0 | 0 | Typed routing, selection, fallback, exact IDs, unchanged synthetic domain bytes |
| AppShellUITests | 5 | 3 | 1 | One serial attempt; 1 passed, 3 assertions failed, 1 environment skip |
| Existing related UI (Home, ProjectBrowser, paste entry) | 0 | 0 | 0 | Built but not executed after environment guard; not counted as passed/skipped |

Debug app/test build passed. `git diff --check` passed. Offline dependency validation remains
2 tasks / 13 subtasks / 17 dependencies valid. No unit/UI totals from earlier tasks are reused.
Initial development builds caught and corrected a main-actor annotation and an unavailable
XCTest property before test execution; those compile failures are not test failures.

### UI observations and unresolved gates

| Scenario | Observed result | Remaining uncertainty |
| --- | --- | --- |
| Home pending Review link and selection across rail navigation | Passed (21.128 s): exact project Review, Brief, selected meeting transcript, Home/Review/Projects/Transcripts round-trip | Not a verdict, persistence or self-tryout test |
| Capture completion handoff | Failed (12.927 s): paste button exists but is not hittable, before input or save | Save and completion were not reached; do not call this a storage failure |
| Five destinations / minimum-width empty state | Failed (9.756 s): after Review click, shell-empty-review not found | Target-app hierarchy still showed Home; click delivery vs product routing unresolved |
| Project selection then meeting results | Failed (10.447 s): project row click did not produce project-detail-screen | Exact meeting/result assertions were not reached |
| Keyboard focus at minimum width | Skipped (3.038 s): ENVIRONMENT_INVALID, Chrome foreground instead of target app | Keyboard behavior unverified |

The xcresult confirms 5 total = 1 pass + 3 failure + 1 skip. The first three failures are not
automatically attributed to Chrome and are not closed as product defects either. A target-only
accessibility attachment confirms the minimum window was 720x552 including title bar, but does
not prove successful navigation. Whole-desktop recordings were not opened. No UI retry followed
the environment guard. A final guard improvement also checks the foreground executable; it was
compiled, not rerun. The four older English UI regression symptoms remain open independently.

Local evidence (outside Git): `haena-025-shell-ui.xcresult`, `haena-025-shell-ui.log`,
`haena-025-shell-final-build.log`, `haena-025-shell-unit-final.xcresult` and
`haena-025-shell-unit-final.log` under the temporary directory. No screenshots, runtime transcript
fixtures, user data or raw logs are included in the commit.

**Blocker:** a dedicated, unobstructed UI session is needed before diagnosing/rerunning the three
unresolved assertions and keyboard test, then running the directly related existing UI tests.
No claim of 2.2 completion, no 2.3 work, no Notion completion, push, PR, merge or package follows.
