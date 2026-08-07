import AppKit
import Foundation
import SwiftUI

@main
struct HAENAApp: App {
    private let repository: any ProjectRepository
    private let extractor: any WorkStateExtractor
    private let transcriptionProvider: any TranscriptionProvider
    private let audioAssetStore: AudioAssetStore

    // Hoisted out of `ContentView` (rather than left as its local @State) so the Quit command
    // below can close an open sheet before terminating: see `terminate()`.
    @State private var showingPasteTranscript = false
    @State private var showingProjectBrowser = false
    @State private var showingImportAudio = false

    init() {
        // UI tests must never read or write the real Application Support data, nor reach the
        // network, so the app's single assembly point swaps in isolated implementations when
        // launched under test. No other code branches on this — everything downstream just sees
        // `any ProjectRepository` and `any WorkStateExtractor`.
        //
        // Note this is the *only* place either implementation is chosen: the deterministic
        // extractor is never substituted for OpenAI when a request fails, because showing a user
        // invented decisions and tasks in place of an error would be worse than showing nothing.
        if ProcessInfo.processInfo.environment["HAENA_UI_TESTING"] == "1" {
            repository = InMemoryProjectRepository()
            extractor = DeterministicWorkStateExtractor()
            transcriptionProvider = DeterministicTranscriptionProvider()
            // A throwaway directory per launch, so a UI test that imports audio cannot write
            // into — or delete out of — the real Application Support store.
            audioAssetStore = AudioAssetStore(
                directoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("HAENAUITests-\(UUID().uuidString)", isDirectory: true)
            )
        } else {
            repository = JSONProjectRepository(fileURL: JSONProjectRepository.defaultFileURL())
            extractor = OpenAIWorkStateExtractor()
            transcriptionProvider = OpenAITranscriptionProvider()
            audioAssetStore = AudioAssetStore(directoryURL: AudioAssetStore.defaultDirectoryURL())
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                repository: repository,
                extractor: extractor,
                transcriptionProvider: transcriptionProvider,
                audioAssetStore: audioAssetStore,
                showingPasteTranscript: $showingPasteTranscript,
                showingProjectBrowser: $showingProjectBrowser,
                showingImportAudio: $showingImportAudio
            )
        }
        .commands {
            // AppKit's own handling of `NSApp.terminate(_:)` silently declines whenever a SwiftUI
            // `.sheet` is still attached to the window (SwiftUI owns the sheet's presentation
            // state, so nothing outside these bindings can clear that attachment). Every sheet
            // also has its own escape route (Cancel/닫기), so the expected path is that a sheet is
            // already closed by the time Quit is invoked — this only matters when it isn't:
            // dismiss it through the same SwiftUI state that presented it, then let the dismissal
            // finish before asking AppKit to terminate on the next run loop turn.
            CommandGroup(replacing: .appTermination) {
                Button("Quit \(AppInfo.name)") {
                    terminate()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }

    private func terminate() {
        guard showingPasteTranscript || showingProjectBrowser || showingImportAudio else {
            NSApp.terminate(nil)
            return
        }
        showingPasteTranscript = false
        showingProjectBrowser = false
        showingImportAudio = false
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
