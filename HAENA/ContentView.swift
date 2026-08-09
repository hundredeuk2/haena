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
    /// Changed whenever a sheet closes, which is the only way stored data changes while the home is
    /// on screen. The home reloads on it rather than polling.
    @State private var homeReloadToken = UUID()
    @State private var showingProfile = false
    @State private var showingAISettings = false

    private struct BrowserDestination: Equatable {
        let projectID: UUID
        let pane: ProjectDetailPane
    }

    var body: some View {
        HomeView(
            repository: repository,
            profileRepository: profileRepository,
            reloadToken: homeReloadToken,
            onOpenProfile: { showingProfile = true },
            onOpenAISettings: { showingAISettings = true },
            onRecord: { showingRecordAudio = true },
            onImportAudio: { showingImportAudio = true },
            onPasteTranscript: { showingPasteTranscript = true },
            onBrowseProjects: {
                browserDestination = nil
                showingProjectBrowser = true
            },
            // The home never presents review UI of its own; it opens the screen that already owns
            // the action, on the area the user asked for.
            onOpenProject: { projectID, pane in
                browserDestination = BrowserDestination(projectID: projectID, pane: pane)
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
                extractionService: WorkStateExtractionService(repository: repository, extractor: extractor)
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
                extractionService: WorkStateExtractionService(repository: repository, extractor: extractor)
            )
        }
        .sheet(isPresented: $showingImportAudio) {
            ImportAudioView(
                service: AudioMeetingCaptureService(
                    repository: repository,
                    provider: transcriptionProvider,
                    assetStore: audioAssetStore
                ),
                extractionService: WorkStateExtractionService(repository: repository, extractor: extractor)
            )
        }
        .sheet(isPresented: $showingProjectBrowser) {
            ProjectBrowserView(
                repository: repository,
                extractor: extractor,
                audioAssetStore: audioAssetStore,
                makeAudioPlayer: makeAudioPlayer,
                initialProjectID: browserDestination?.projectID,
                initialPane: browserDestination?.pane ?? .status
            )
        }
    }

    /// Reloads once a sheet has actually closed. A capture sheet can add a meeting and a whole set
    /// of proposals, and the browser can approve or delete them, so what the home showed before is
    /// stale by the time the user is looking at it again.
    private func reloadHomeAfterDismissal(_ isShowing: Bool) {
        guard !isShowing else {
            return
        }
        homeReloadToken = UUID()
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
        credentialResolver: OpenAICredentialResolver(store: InMemoryAPICredentialStore()),
        showingPasteTranscript: .constant(false),
        showingProjectBrowser: .constant(false),
        showingImportAudio: .constant(false),
        showingRecordAudio: .constant(false)
    )
}
