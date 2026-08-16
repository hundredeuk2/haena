import SwiftUI

struct ContentView: View {
    let repository: any ProjectRepository
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

    // Owned by `HAENAApp`, not locally, so that quitting while one of these sheets is open can
    // dismiss it first: see `HAENAApp`'s Quit command.
    @Binding var showingPasteTranscript: Bool
    @Binding var showingProjectBrowser: Bool
    @Binding var showingImportAudio: Bool
    @Binding var showingRecordAudio: Bool

    /// Where the browser should land when it opens. Set by a home row, cleared by the 프로젝트 보기
    /// button. Kept here rather than in `HAENAApp` because, unlike the sheet flags, quitting has no
    /// interest in it.
    @State private var browserDestination: BrowserDestination?
    /// Where to go once the capture sheet currently on screen has finished closing.
    ///
    /// One sheet cannot be swapped for another in a single step: asking for the browser while the
    /// capture sheet is still attached to the window leaves SwiftUI holding two presentations for
    /// one window, and it drops one of them. So the destination waits here, and the capture
    /// sheet's own dismissal is what opens the browser.
    @State private var destinationAfterCapture: BrowserDestination?
    /// Changed whenever a sheet closes, which is the only way stored data changes while the home is
    /// on screen. The home reloads on it rather than polling.
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

    var body: some View {
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
                browserDestination = nil
                showingProjectBrowser = true
            },
            // The home never presents review UI of its own; it opens the screen that already owns
            // the action, at the place the user asked for.
            onOpen: { destination in
                browserDestination = destination
                showingProjectBrowser = true
            }
        )
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
            reloadHomeAfterDismissal(isShowing)
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
                extractionService: WorkStateExtractionService(repository: repository, extractor: extractor),
                onOpenResults: requestResults,
                metrics: metricsService
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
                extractionService: WorkStateExtractionService(repository: repository, extractor: extractor),
                onOpenResults: requestResults,
                metrics: metricsService
            )
        }
        .sheet(isPresented: $showingImportAudio) {
            ImportAudioView(
                service: AudioMeetingCaptureService(
                    repository: repository,
                    provider: transcriptionProvider,
                    assetStore: audioAssetStore
                ),
                extractionService: WorkStateExtractionService(repository: repository, extractor: extractor),
                onOpenResults: requestResults,
                metrics: metricsService
            )
        }
        .sheet(isPresented: $showingProjectBrowser) {
            ProjectBrowserView(
                repository: repository,
                extractor: extractor,
                audioAssetStore: audioAssetStore,
                makeAudioPlayer: makeAudioPlayer,
                profileRepository: profileRepository,
                reminderRepository: reminderRepository,
                reminderService: reminderService,
                // Without this the review screen builds an uninstrumented service and no verdict is
                // ever counted: this view is the only place `WorkStateReviewService` is constructed.
                metrics: metricsService,
                initialProjectID: browserDestination?.projectID,
                initialMeetingID: browserDestination?.meetingID,
                initialActionItemID: browserDestination?.actionItemID,
                initialPane: browserDestination?.pane ?? .status
            )
        }
        .task {
            await reminderService.reconcile()
        }
    }

    /// Records where a finished capture wants to go. The capture sheet closes itself right after
    /// calling this; opening the browser is left to `openPendingDestination`, once that dismissal
    /// has actually happened.
    ///
    /// Landing on 회의 means the meeting list is the useful middle pane — the meeting the user just
    /// made is selected in it — while the detail pane opens on 회의 결과 by itself.
    private func requestResults(_ destination: CaptureDestination) {
        destinationAfterCapture = .results(of: destination)
    }

    /// Reloads once a sheet has actually closed, and opens the browser if the capture that just
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

    /// Opens the browser on the next run loop turn rather than immediately: the sheet whose
    /// dismissal brought us here is still being torn down, and presenting into the same window
    /// before it has finished is what makes one of the two sheets never appear.
    private func openPendingDestination() {
        guard let destination = destinationAfterCapture else {
            return
        }
        destinationAfterCapture = nil
        DispatchQueue.main.async {
            browserDestination = destination
            showingProjectBrowser = true
        }
    }
}

#Preview {
    ContentView(
        repository: InMemoryProjectRepository(),
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
        showingPasteTranscript: .constant(false),
        showingProjectBrowser: .constant(false),
        showingImportAudio: .constant(false),
        showingRecordAudio: .constant(false)
    )
}
