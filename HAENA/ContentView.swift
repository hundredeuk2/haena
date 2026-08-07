import SwiftUI

struct ContentView: View {
    let repository: any ProjectRepository
    let extractor: any WorkStateExtractor
    let transcriptionProvider: any TranscriptionProvider
    let audioAssetStore: AudioAssetStore

    // Owned by `HAENAApp`, not locally, so that quitting while one of these sheets is open can
    // dismiss it first: see `HAENAApp`'s Quit command.
    @Binding var showingPasteTranscript: Bool
    @Binding var showingProjectBrowser: Bool
    @Binding var showingImportAudio: Bool

    var body: some View {
        VStack(spacing: 24) {
            Text(AppInfo.name)
                .font(.largeTitle)
                .bold()
                .accessibilityIdentifier("product-name")

            VStack(spacing: 12) {
                Button("녹음 시작") {}
                    .accessibilityIdentifier("record-button")

                Button("파일 불러오기") {
                    showingImportAudio = true
                }
                .accessibilityIdentifier("import-button")

                Button("텍스트 회의록 붙여넣기") {
                    showingPasteTranscript = true
                }
                .accessibilityIdentifier("paste-transcript-button")

                Button("프로젝트 보기") {
                    showingProjectBrowser = true
                }
                .accessibilityIdentifier("browse-projects-button")
            }
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 280)
        .sheet(isPresented: $showingPasteTranscript) {
            PasteTranscriptView(
                service: TextMeetingCaptureService(repository: repository),
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
                audioAssetStore: audioAssetStore
            )
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
        showingPasteTranscript: .constant(false),
        showingProjectBrowser: .constant(false),
        showingImportAudio: .constant(false)
    )
}
