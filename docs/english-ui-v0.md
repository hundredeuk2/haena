# English UI v0 — local review checkpoint

## Scope and policy

Product base: `origin/main` at `5b524c50f2e7a78fac21e85c9832ee57ee3d05ed`.
Implementation branch: `codex/english-ui-v0`, separate temporary worktree.
The human-gold checkout, its commits/data, and preserved untracked document are not imported or changed.
The user requested local commits only. No push, PR, merge, version bump, package or distribution change.

Settings / General / App Language is available through the app menu and Command-comma.
Stored values are `system`, `ko`, `en`; absent/invalid values resolve to `system`.
System mode chooses the first supported preferred language, including regional variants, or English.
The stored selection remains `system` even when its effective language is Korean or English.
Explicit selection wins. The choice persists locally in UserDefaults, not in domain data or Keychain.
Language and region/timezone are separate. Date formatting does not change stored Date values.

## Translation inventory

Native Apple `ko.lproj` / `en.lproj` resources contain 447 matching entries.
`scripts/check-localization.py` checks the resource inventory, static call-site coverage,
nonempty English, placeholder agreement, and the preference dependency boundary.

| Surface | v0 coverage |
| --- | --- |
| App-owned Settings/Quit menu, General | Both languages, autonym choices |
| Home, projects, profile, empty states | Buttons, onboarding guidance, state/count labels |
| AI settings | BYOK guidance, missing key, credential errors, long explanatory copy |
| Paste / structured speaker input | Validation, roster/link controls, preview, save completion |
| Import / recording | App-owned instructions, permission explanations, progress and failures |
| Results / edit / approve / exclude | Typed status labels, evidence chrome, errors and retry |
| Meeting / Manual Brief / project state | Confirmed vs pending, ambiguity, source/evidence, dates |
| Deletion / reminders | Confirmation and error copy; scheduling policy unchanged |

User titles, transcript/evidence text, names, speaker labels and proposal text stay verbatim.
UIWorkStateDisplay adapts shared display values without changing export/prompt/model contracts.
Count resources use complete count-neutral English phrases instead of concatenated grammar.

## Deliberate limits

- macOS-owned permission prompts, file dialog chrome and generated File/Edit/View/Window/Help menus follow OS behavior; app language does not override the system.
- Peripheral Beta Metrics detail and Agent Ledger event/feedback descriptions still include legacy Korean presentation copy. Their entry points/common controls are translated; they are not claimed as fully bilingual core paths.
- Already-emitted interpolated transient errors may retain their emission language; newly displayed copy and static validation messages use the selected language.
- English meeting extraction quality, external authentication/model calls, real recording, full regression, packaging and distribution are not validated by this UI task.

## Validation environment

All functional UI journeys use `HAENA_UI_TESTING=1`, the existing in-memory synthetic assembly.
Language persistence tests use unique `com.haena.ui-language-test.*` preference suites.
No new production repository path override or entitlement was added.
UI runs use a temporary command-line bundle identifier to avoid identifying the installed app.
`UITestWindowPlacement` is fully `#if DEBUG`, additionally guarded by `HAENA_UI_TESTING`,
and only positions test windows on the primary display. It has no storage/service dependencies.

Initial UI runs encountered negative display coordinates; a direct test-runner AX placement
attempt failed for lack of Accessibility permission and was removed. These attempts are not
reported as product passes. A native read-only app lookup also resolved to the existing app
because its bundle ID was shared; no action was performed on that returned screen. Subsequent
validation uses the distinct bundle ID. Whole-display screenshot artifacts that showed unrelated
desktop content were discarded as evidence and are not committed. No transcript or user data is
included in this document or commits.

## Executed evidence and remaining gate

| Suite | Executed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| AppLanguageTests | 15 | 0 | 0 |
| CaptureOutcomeTests | 11 | 0 | 0 |
| MeetingReanalysisServiceTests | 11 | 0 | 0 |
| TextMeetingCaptureServiceTests | 19 | 0 | 0 |
| WorkStateDisplayTests | 7 | 0 | 0 |
| Unit total | 63 | 0 | 0 |
| AppLanguageUITests | 6 | 0 | 0 |
| ManualContinuityBriefUITests, latest full run | 5 | 1 | 0 |
| PasteTranscriptUITests, latest full run | 4 | 3 | 0 |

UI language cases verify Korean/English home and AI guidance, unsaved text/validation across
a switch, a new process with the saved preference, returning to system mode, ongoing deterministic
recording, and the same Brief/selection across a switch. Native window inspection additionally
checked a roughly 528-point home window and long AI guidance. No actual recording or provider ran.

The latest full existing-UI run is not green: ambiguity `new` disappearance, freeform save
completion, empty-project validation navigation, and structured-paste completion remain failed.
Earlier runs had proven negative-coordinate, foreground/Accessibility interruption and screenshot
selection problems; these do not prove every remaining failure is environmental. No baseline
failure is asserted without a baseline execution. No domain/review/apply logic was altered to
make tests pass. A separate follow-up with saved-window restoration disabled executed 2 tests
(ambiguity `new`, freeform save): 2 failed, 0 skipped. These are repeats, not two extra unique cases.
The task remains at partial verification; a clean interactive UI session is needed to distinguish
remaining click/foreground interference from a reproducible product failure before completion.

Debug test build and Release universal build pass. Release architectures: arm64 and x86_64.
Both built apps include ko/en Localizable.strings. Release remains version 0.2.4, build 8.
The release binary has zero matches for UITestWindowPlacement, HAENA_UI_TEST_LANGUAGE and
com.haena.ui-language-test; the Debug dylib positive control has 6 matching lines.
The final catalog audit finds 447 keys, 404 static references, zero missing keys or format mismatch.
XcodeGen re-generation is idempotent (project.pbxproj SHA-256
`66df885a52490afbffabcbb64cb3c981c29159d81cd7a28d65070196ec6ee8e0`).

Diff from the product baseline is zero in Models, Extraction, Services, Presentation, Continuity,
Benchmark and Agent. The preference object has no repository/provider/recorder dependency and
does not recreate the root view. Synthetic domain serialization, IDs, source text, review status
and deadlines are unchanged across language selection. Source inspection proves no language
selection call to domain save, extraction or API; it is not presented as a production network trace.

The frozen 0.2.4 candidate and archives were not build destinations and were not replaced.
No actual corpus, gold or sealed files, translation/model API, or user Application Support files
were opened or modified by the implementation tools. The incidental existing-app UI lookup
described above prevents claiming strict zero exposure to user UI content.

Local checkpoints: `bf092d8` (foundation), `33596ad` (core surfaces), followed by the regression
evidence checkpoint. Task Master A/B implementation is done; final verification and the parent
remain in-progress while the existing UI regression gate is open. This is not a completion approval.

## Safe review launch

Build the Debug scheme with a temporary bundle ID and a separate DerivedData directory,
then launch its executable with `HAENA_UI_TESTING=1 HAENA_UI_TEST_LANGUAGE=en`.
This uses synthetic in-memory projects and deterministic services, not the user's store or keys.
Do not replace the frozen 0.2.4 app or ZIP. Open Settings with Command-comma to switch languages.

For the existing isolated build (no production data; no actual API keys should be entered):

```sh
HAENA_UI_TESTING=1 \
HAENA_UI_TEST_LANGUAGE_SUITE=com.haena.ui-language-test.manual-review \
/private/tmp/haena-en-ui-primary/Build/Products/Debug/HAENA.app/Contents/MacOS/HAENA
```

The fixed test preference suite lets a manual relaunch retain language selection. Project data
remains in memory. Temporary build directories may be cleaned by macOS; rebuild if unavailable.
