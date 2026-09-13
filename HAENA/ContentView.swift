import SwiftUI

struct ContentView: View {
    let repository: any ProjectRepository
    let transitionRepository: any WorkStateTransitionRepository
    let manualBriefService: ManualContinuityBriefService
    let transitionReviewService: WorkStateTransitionReviewService
    let extractor: any WorkStateExtractor
    let transcriptionProvider: any TranscriptionProvider
    let audioAssetStore: AudioAssetStore
    let audioRecorder: any MeetingAudioRecorder
    let recordingScratchStore: RecordingScratchStore
    /// A factory, not an instance: playback state belongs to one meeting at a time, so the pane
    /// showing a meeting gets its own player.
    let makeAudioPlayer: () -> any MeetingAudioPlayer
    let profileRepository: any LocalUserProfileRepository
    let reminderRepository: any ActionItemReminderRepository
    let ledgerRepository: any AgentLedgerRepository
    let metricsRepository: any BetaMetricsRepository
    let notificationScheduler: any LocalNotificationScheduler
    let credentialResolver: OpenAICredentialResolver
    /// Assembled by `HAENAApp` and passed down whole, like the credential resolver: re-analysis
    /// has to be able to tell "already running" from "not started", which a per-render value could
    /// not do.
    let reanalysisService: MeetingReanalysisService

    // Owned by `HAENAApp`, not locally, so that quitting while one of these sheets is open can
    // dismiss it first: see `HAENAApp`'s Quit command.
    @Binding var showingPasteTranscript: Bool
    @Binding var showingProjectBrowser: Bool
    @Binding var showingImportAudio: Bool
    @Binding var showingRecordAudio: Bool

    @State private var navigation = AppShellNavigation()
    @FocusState private var focusedDestination: AppShellDestination?
    /// Where to go once the capture sheet currently on screen has finished closing.
    ///
    /// Capture owns its dismissal; only afterwards does the persistent shell take up the link.
    @State private var destinationAfterCapture: BrowserDestination?
    /// Sheet completion, workspace verdicts and returning Home invalidate the read snapshot.
    /// The home reloads on this token rather than polling.
    @State private var homeReloadToken = UUID()
    @State private var showingProfile = false
    @State private var showingAISettings = false
    @State private var showingAgentLedger = false
    @State private var showingBetaMetrics = false

    private var ledgerService: AgentLedgerService {
        AgentLedgerService(repository: ledgerRepository)
    }

    /// One recorder shared by every flow that can produce a measurement, so the same run cannot be
    /// counted under two different measurement periods. The ledger is handed over so the report can
    /// tally feedback the user already gave — this path only ever reads it.
    private var metricsService: BetaMetricsService {
        BetaMetricsService(repository: metricsRepository, ledgerRepository: ledgerRepository)
    }

    private var reminderService: ActionItemReminderService {
        ActionItemReminderService(
            reminderRepository: reminderRepository,
            projectRepository: repository,
            profileRepository: profileRepository,
            notifications: notificationScheduler,
            ledger: ledgerService
        )
    }

    /// The continuity repository is assembled once with the project repository. Extraction owns
    /// the ordering: project content is committed first, then transition proposals are attempted
    /// as a non-rolling-back sidecar write.
    private var extractionService: WorkStateExtractionService {
        WorkStateExtractionService(
            repository: repository,
            extractor: extractor,
            continuity: WorkStateContinuityService(
                projects: repository,
                transitions: transitionRepository
            )
        )
    }

    private var home: some View {
        HomeView(
            repository: repository,
            profileRepository: profileRepository,
            reminderRepository: reminderRepository,
            reloadToken: homeReloadToken,
            onOpenProfile: { showingProfile = true },
            onOpenAISettings: { showingAISettings = true },
            onOpenAgentLedger: { showingAgentLedger = true },
            onOpenBetaMetrics: { showingBetaMetrics = true },
            onRecord: { showingRecordAudio = true },
            onImportAudio: { showingImportAudio = true },
            onPasteTranscript: { showingPasteTranscript = true },
            onBrowseProjects: {
                navigation.select(.projects)
            },
            // The home never presents review UI of its own; it opens the screen that already owns
            // the action, at the place the user asked for.
            onOpen: { destination in
                navigation.open(destination)
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(AppShellDestination.allCases) { destination in
                    Button { navigation.select(destination) } label: {
                        Label(destination.title, systemImage: destination.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                            .background(navigation.destination == destination ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            // A plain button must include label spacing/padding in its hit area,
                            // not only the separate glyphs that happen to be painted.
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable()
                    .focused($focusedDestination, equals: destination)
                    .accessibilityLabel(destination.title)
                    .accessibilityAddTraits(navigation.destination == destination ? .isSelected : [])
                    .accessibilityIdentifier("shell-rail-\(destination.rawValue)")
                    .onMoveCommand { direction in
                        let destinations = AppShellDestination.allCases
                        guard let index = destinations.firstIndex(of: destination) else { return }
                        switch direction {
                        case .down: focusedDestination = destinations[(index + 1) % destinations.count]
                        case .up: focusedDestination = destinations[(index + destinations.count - 1) % destinations.count]
                        default: break
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 160)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("shell-rail")
            Divider()
            // Neither rail navigation nor locale changes rebuilds the root/window owner. Home
            // keeps its local presentation state while the workspace retains exact selections.
            ZStack {
                home
                    .opacity(navigation.destination == .home ? 1 : 0)
                    .allowsHitTesting(navigation.destination == .home)
                    .accessibilityHidden(navigation.destination != .home)
                AppShellWorkspaceView(
                    navigation: $navigation, repository: repository,
                    reviewService: WorkStateReviewService(repository: repository, metrics: metricsService),
                    manualBriefService: manualBriefService, transitionReviewService: transitionReviewService,
                    deletionService: ProjectDeletionService(repository: repository, assetStore: audioAssetStore,
                                                            transitions: transitionRepository),
                    profileRepository: profileRepository, reminderRepository: reminderRepository,
                    reminderService: reminderService, audioAssetStore: audioAssetStore,
                    makeAudioPlayer: makeAudioPlayer, reanalysisService: reanalysisService,
                    reloadToken: homeReloadToken,
                    onPaste: { showingPasteTranscript = true },
                    onChanged: { homeReloadToken = UUID() }
                )
                .opacity(navigation.destination == .home ? 0 : 1)
                .allowsHitTesting(navigation.destination != .home)
                .accessibilityHidden(navigation.destination == .home)
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-shell")
        .onChange(of: navigation.destination) { old, new in
            // The app's Quit command clears this binding before termination. Keep it as the
            // workspace ownership flag so a nested edit/confirmation sheet is dismissed too.
            showingProjectBrowser = new != .home
            if old == .home || new == .home { homeReloadToken = UUID() }
        }
        .onChange(of: showingPasteTranscript) { _, isShowing in
            reloadHomeAfterDismissal(isShowing)
        }
        .onChange(of: showingRecordAudio) { _, isShowing in
            reloadHomeAfterDismissal(isShowing)
        }
        .onChange(of: showingImportAudio) { _, isShowing in
            reloadHomeAfterDismissal(isShowing)
        }
        .onChange(of: showingProjectBrowser) { _, isShowing in
            if isShowing, navigation.destination == .home {
                navigation.select(.projects)
            } else if !isShowing, navigation.destination != .home {
                navigation.select(.home)
            }
        }
        .onChange(of: showingProfile) { _, isShowing in
            reloadHomeAfterDismissal(isShowing)
        }
        .sheet(isPresented: $showingAISettings) {
            AISettingsView(
                resolver: credentialResolver,
                verifier: OpenAICredentialVerifier()
            )
        }
        .sheet(isPresented: $showingAgentLedger) {
            AgentLedgerView(
                projectRepository: repository,
                service: ledgerService,
                onClose: { showingAgentLedger = false }
            )
        }
        .sheet(isPresented: $showingBetaMetrics) {
            BetaMetricsView(
                service: metricsService,
                onClose: { showingBetaMetrics = false }
            )
        }
        .sheet(isPresented: $showingProfile) {
            ProfileSettingsView(
                service: LocalUserProfileService(
                    profileRepository: profileRepository,
                    projectRepository: repository
                )
            )
        }
        .sheet(isPresented: $showingPasteTranscript) {
            PasteTranscriptView(
                service: TextMeetingCaptureService(repository: repository),
                extractionService: extractionService,
                onOpenResults: requestResults,
                metrics: metricsService,
                reanalysisService: reanalysisService
            )
        }
        .sheet(isPresented: $showingRecordAudio) {
            RecordAudioView(
                recorder: audioRecorder,
                scratchStore: recordingScratchStore,
                captureService: AudioMeetingCaptureService(
                    repository: repository,
                    provider: transcriptionProvider,
                    assetStore: audioAssetStore
                ),
                extractionService: extractionService,
                onOpenResults: requestResults,
                metrics: metricsService,
                reanalysisService: reanalysisService
            )
        }
        .sheet(isPresented: $showingImportAudio) {
            ImportAudioView(
                service: AudioMeetingCaptureService(
                    repository: repository,
                    provider: transcriptionProvider,
                    assetStore: audioAssetStore
                ),
                extractionService: extractionService,
                onOpenResults: requestResults,
                metrics: metricsService,
                reanalysisService: reanalysisService
            )
        }
        .task {
            #if DEBUG
            if let configuration = try? TransitionApplyRecoveryProcessTestConfiguration.load(),
               configuration.shouldApprove {
                _ = await transitionReviewService.review(
                    projectID: TransitionApplyRecoveryProcessTestConfiguration.projectID,
                    proposalID: configuration.proposalID,
                    action: .approve
                )
            }
            #endif
            _ = await transitionReviewService.recoverPendingApplies()
            // A meeting deletion spans the Project and the transition sidecar, so an interrupted one
            // has to be finished here rather than waiting for the user to notice orphans.
            await ProjectDeletionService(
                repository: repository,
                assetStore: audioAssetStore,
                transitions: transitionRepository
            ).recoverInterruptedMeetingDeletions()
            // Deleting a whole project spans the same two stores, so an interrupted one needs the
            // same finishing here.
            await ProjectDeletionService(
                repository: repository,
                assetStore: audioAssetStore,
                transitions: transitionRepository
            ).recoverInterruptedProjectDeletions()
            #if DEBUG
            // Runs after launch recovery, so a relaunch in the deletion smoke finishes recovering
            // before it is asked to end. A first process performs the seeded deletion instead and
            // is terminated inside it by the checkpoint observer.
            if let configuration = try? TransitionApplyRecoveryProcessTestConfiguration.load() {
                await performProcessTestDeletion(configuration)
                if configuration.shouldExitAfterRecovery {
                    _exit(0)
                }
            }
            #endif
            await reminderService.reconcile()
        }
    }

    #if DEBUG
    /// Debug-only. Drives one deletion for the process smoke harness, with the crash observer the
    /// configuration supplies. Absent a request this does nothing at all.
    private func performProcessTestDeletion(
        _ configuration: TransitionApplyRecoveryProcessTestConfiguration
    ) async {
        guard let request = configuration.deletionRequest else {
            return
        }
        let service = ProjectDeletionService(
            repository: repository,
            assetStore: audioAssetStore,
            transitions: transitionRepository,
            didReachCheckpoint: configuration.deletionCheckpointObserver
        )
        switch request {
        case .meeting:
            _ = try? await service.deleteMeeting(
                meetingID: TransitionApplyRecoveryProcessTestConfiguration.deletionMeetingID,
                fromProjectID: TransitionApplyRecoveryProcessTestConfiguration.deletionProjectID
            )
        case .project:
            try? await service.deleteProject(
                id: TransitionApplyRecoveryProcessTestConfiguration.deletionProjectID
            )
        }
    }
    #endif

    /// Records where a finished capture wants to go. The capture sheet closes itself right after
    /// calling this; routing the shell is left to `openPendingDestination`, once that dismissal
    /// has actually happened.
    ///
    /// Landing on 회의 means the meeting list is the useful middle pane — the meeting the user just
    /// made is selected in it — while the detail pane opens on 회의 결과 by itself.
    private func requestResults(_ destination: CaptureDestination) {
        destinationAfterCapture = .results(of: destination)
    }

    /// Reloads once a sheet has actually closed, and routes the shell if the capture that just
    /// closed asked for it.
    ///
    /// A capture sheet can add a meeting and a whole set of proposals, and the browser can approve
    /// or delete them, so what the home showed before is stale by the time the user is looking at
    /// it again.
    private func reloadHomeAfterDismissal(_ isShowing: Bool) {
        guard !isShowing else {
            return
        }
        homeReloadToken = UUID()
        Task { await reminderService.reconcile() }
        openPendingDestination()
    }

    /// Consume the capture request after dismissal, without presenting another sheet.
    private func openPendingDestination() {
        guard let destination = destinationAfterCapture else {
            return
        }
        destinationAfterCapture = nil
        DispatchQueue.main.async {
            navigation.open(destination)
        }
    }
}

#Preview {
    ContentView(
        repository: InMemoryProjectRepository(),
        transitionRepository: InMemoryWorkStateTransitionRepository(),
        manualBriefService: ManualContinuityBriefService(
            projects: InMemoryProjectRepository(),
            transitions: InMemoryWorkStateTransitionRepository(),
            profiles: InMemoryLocalUserProfileRepository()
        ),
        transitionReviewService: WorkStateTransitionReviewService(
            projectRepository: InMemoryProjectRepository(),
            transitionRepository: InMemoryWorkStateTransitionRepository()
        ),
        extractor: DeterministicWorkStateExtractor(),
        transcriptionProvider: DeterministicTranscriptionProvider(),
        audioAssetStore: AudioAssetStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("HAENAPreview", isDirectory: true)
        ),
        audioRecorder: DeterministicMeetingAudioRecorder(),
        recordingScratchStore: RecordingScratchStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("HAENAPreviewRecordings", isDirectory: true)
        ),
        makeAudioPlayer: { DeterministicMeetingAudioPlayer() },
        profileRepository: InMemoryLocalUserProfileRepository(),
        reminderRepository: InMemoryActionItemReminderRepository(),
        ledgerRepository: InMemoryAgentLedgerRepository(),
        metricsRepository: InMemoryBetaMetricsRepository(),
        notificationScheduler: InMemoryLocalNotificationScheduler(),
        credentialResolver: OpenAICredentialResolver(store: InMemoryAPICredentialStore()),
        reanalysisService: {
            let repository = InMemoryProjectRepository()
            return MeetingReanalysisService(
                repository: repository,
                extraction: WorkStateExtractionService(
                    repository: repository,
                    extractor: DeterministicWorkStateExtractor()
                )
            )
        }(),
        showingPasteTranscript: .constant(false),
        showingProjectBrowser: .constant(false),
        showingImportAudio: .constant(false),
        showingRecordAudio: .constant(false)
    )
}
