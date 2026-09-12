# HAE.NA Windows text pilot — first executable checkpoint

Status: **core verified on macOS / Windows execution pending**.
This is a separate synthetic-only pilot, not a Windows release or a Mac data migration tool.
The existing Swift application, English UI, human-gold work and frozen 0.2.4 candidate are unchanged.

## Projects

- `Haena.TextPilot.Core`: .NET 10 only, no WPF or third-party runtime dependency.
  Explicit synthetic fixture, meeting/candidate snapshots, individual verdicts and read-only Brief.
- `Haena.TextPilot.Tests`: xUnit tests using unique temporary directories and synthetic data only.
- `Haena.TextPilot.Wpf`: the connected paste / review / Brief screens. Windows UI and app assembly
  stay outside core. Code-built WPF controls avoid requiring a XAML designer on the Mac host.

No AI/provider, secret store, recording, notification, transition apply, Mac import, server,
telemetry service or deployment workflow is implemented. SDK and test packages are build tooling,
not application network integrations.

## Run core verification (macOS or Windows with .NET SDK)

Run from this directory; `global.json` pins SDK **10.0.401**. The SDK is not committed or installed
by this repository. Substitute an explicit isolated SDK path for `dotnet` if needed.

```sh
dotnet restore Haena.TextPilot.Tests/Haena.TextPilot.Tests.csproj --locked-mode --configfile NuGet.Config
dotnet test Haena.TextPilot.Tests/Haena.TextPilot.Tests.csproj --no-restore --logger trx
dotnet restore Haena.TextPilot.Wpf/Haena.TextPilot.Wpf.csproj --locked-mode --configfile NuGet.Config
dotnet build Haena.TextPilot.Wpf/Haena.TextPilot.Wpf.csproj --no-restore -c Debug
```

Test tooling is pinned and transitive hashes are recorded in `packages.lock.json`:
Microsoft.NET.Test.Sdk 17.12.0, xunit 2.9.3, xunit.runner.visualstudio 2.8.2.
The SDK downloads Microsoft.WindowsDesktop.App.Ref 10.0.12 to compile WPF off Windows.
`EnableWindowsTargeting` enables compilation, **not Windows execution**.
The symlink rejection test needs symlink permission (Windows Developer Mode or equivalent).

## Run the three screens on Windows

Use an actual Windows machine with the pinned .NET SDK and Windows Desktop runtime available:

```powershell
dotnet run --project Haena.TextPilot.Wpf/Haena.TextPilot.Wpf.csproj
```

1. **붙여넣기:** explicitly select `text-pilot-synthetic-v1` and click the fixture-load button.
   The default is no selection. Title can be changed; arbitrary or edited transcript is refused.
2. Click **회의와 pending 후보 저장 → 검토**. Four fixed fixture outputs are stored as pending.
   This is fixture loading, not inferred analysis of pasted text. No sample auto-approval occurs.
3. **결과 검토:** open each evidence expander, then approve or exclude that item only.
   Terminal items stay visible with their verdict; there is no approve-all or terminal overwrite.
4. **Brief:** confirmed Decision, Action Item, unresolved Open Question and Next Agenda have
   separate sections. Pending candidates are visibly separate; excluded items are counted and
   remain inspectable in review. Unfinished items are not promoted to Next Agenda.
5. Close the process, launch again, and open Review / Brief. Loading the fixture again explicitly
   starts a *new* capture; it is not the way to reopen a saved meeting.

Storage is resolved using `LocalApplicationData` and the dedicated `HAENA.WindowsTextPilot`
directory (`text-pilot.json` plus a zero-content writer lock). There is no Mac-path fallback,
file import, user-selected data root, credential storage or automatic corrupt-store reset.
The pilot relies on the user directory's inherited OS permissions; this is not encryption.

## Narrow contract

- The separate `haena-windows-text-pilot-v1` schema is **not** Swift `ProjectStoreFile` v2 or
  transition-store v4. It describes one pilot workspace, with meetings and four output kinds.
  It is not a lossless format for arbitrary Mac projects. Unknown schema/fields fail closed.
- Meeting ID equals the app-generated capture ID. Segment/output IDs derive from capture identity
  with a pilot-specific algorithm. No provider chooses domain IDs. Quote and segment references
  are validated; no fuzzy, keyword, name, regex or semantic matching occurs.
- The exact selected fixture is checked **before repository access**. The full original fixture
  transcript is stored unchanged. Only the user-edited title is trimmed.
- Capture persists the meeting before candidate creation. Candidate persistence failure keeps
  the saved meeting; retry with the same capture ID completes candidates without duplicates or
  resetting reviewed items. The UI retains its input/capture identity on failure.
- Only an explicit individual review can move Pending to Approved/Excluded. The same verdict is
  idempotent; a conflicting terminal verdict is refused. UTC review time persists separately.
  Approved Open Question still means unresolved; approved Agenda still means a pending agenda
  for a future meeting. No status-resolution or task-completion editing is in this first slice.
- Action Item assignee and due are unsupported/unspecified in this slice, not guessed. No roster
  or personalisation model is invented. The UI explicitly displays that limitation.
- Each write uses an exclusive writer lease, validates a fresh snapshot, flushes a same-directory
  temporary file, then replaces the destination. No mutable repository cache becomes authoritative.
  A failed pre-replace write preserves old bytes and removes its own temporary file. Concurrent
  writers fail busy rather than retrying or overwriting stale cached state.
- Brief is read-only, with deterministic kind/identity order. Corrupt evidence is refused, not
  rendered as invented support. Transition/ambiguity processing is explicitly unavailable.
- Same-directory replacement and writer exclusion were tested on macOS. **Windows ACL, file
  sharing, abrupt-process termination and power-loss durability are not established by that test.**
  There is no claim of a distributed transaction or full transition recovery.

## Evidence and remaining gate

Initial core checkpoint: **26 executed / 0 failed / 0 skipped**, macOS arm64, SDK 10.0.401.
Final checkpoint including dangling-directory symlink rejection: **27 executed / 0 failed / 0
skipped**. A separate sandboxed attempt could not start VSTest's local IPC listener (permission
denied); it executed no tests and is not counted as passing. The final 27-case run used the same
test-host IPC permission as the successful initial run, with `--no-restore`.
Final TRX SHA-256: `df8ee7a8f33dc199422e420c5fcac6c0ef87d9fe9a086b16d6c6d1f656d6e083`.
The tests cover the complete synthetic capture → pending persistence → individual approve/exclude
→ fresh repository → Brief journey, all four output-kind approvals, refusal-before-access,
idempotent retry, terminal conflict, candidate-stage failure, atomic replacement failure, malformed
and future schemas, invalid evidence/identity/state, exclusive writer and symlink rejection.
Temporary test stores are removed by fixture teardown; real meeting/review stores are not used.

WPF Debug cross-compilation on macOS: **0 warnings / 0 errors**. This verifies the connected C#
screen code against WindowsDesktop reference assemblies; it does not verify rendered controls,
keyboard navigation, Windows startup, actual Windows persistence or an executable distribution.

Next verification is on actual Windows: native build, the five UI steps above, a fresh process,
unchanged IDs/quotes/verdicts, no duplicate outputs, rejection of failed writes, 100%/150% DPI,
Korean text entry and keyboard/evidence/button access. No Windows execution has been performed.
No installer, package replacement, signing, publication or push is part of this checkpoint.
