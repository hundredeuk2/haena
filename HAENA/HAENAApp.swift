import AppKit
import Foundation
import SwiftUI

/// The one condition that decides whether the app assembles its real components or the
/// deterministic doubles.
///
/// Extracted from `HAENAApp.init` so it can be asserted directly: choosing a double in a shipped
/// build would mean a user pressing record and getting silence, or being shown invented meeting
/// content, and that must not rest on an untested inline comparison.
enum AppComponentSelection {
    static func isUITesting(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["HAENA_UI_TESTING"] == "1"
    }
}

@main
struct HAENAApp: App {
    private let repository: any ProjectRepository
    private let extractor: any WorkStateExtractor
    private let transcriptionProvider: any TranscriptionProvider
    private let audioAssetStore: AudioAssetStore
    private let audioRecorder: any MeetingAudioRecorder
    private let recordingScratchStore: RecordingScratchStore
    private let profileRepository: any LocalUserProfileRepository
    private let reminderRepository: any ActionItemReminderRepository
    private let notificationScheduler: any LocalNotificationScheduler
    /// One resolver, shared by transcription and extraction, so the app cannot use two keys.
    private let credentialResolver: OpenAICredentialResolver
    /// A factory, because playback state belongs to a single meeting at a time.
    private let makeAudioPlayer: () -> any MeetingAudioPlayer

    // Hoisted out of `ContentView` (rather than left as its local @State) so the Quit command
    // below can close an open sheet before terminating: see `terminate()`.
    @State private var showingPasteTranscript = false
    @State private var showingProjectBrowser = false
    @State private var showingImportAudio = false
    @State private var showingRecordAudio = false

    init() {
        // UI tests must never read or write the real Application Support data, nor reach the
        // network, so the app's single assembly point swaps in isolated implementations when
        // launched under test. No other code branches on this — everything downstream just sees
        // `any ProjectRepository` and `any WorkStateExtractor`.
        //
        // Note this is the *only* place either implementation is chosen: the deterministic
        // extractor is never substituted for OpenAI when a request fails, because showing a user
        // invented decisions and tasks in place of an error would be worse than showing nothing.
        if AppComponentSelection.isUITesting() {
            repository = InMemoryProjectRepository()
            extractor = DeterministicWorkStateExtractor()
            transcriptionProvider = DeterministicTranscriptionProvider()
            // Never the real Keychain: an automated run must not read or overwrite the user's key.
            credentialResolver = OpenAICredentialResolver(store: InMemoryAPICredentialStore())
            // A throwaway directory per launch, so a UI test that imports audio cannot write
            // into — or delete out of — the real Application Support store.
            audioAssetStore = AudioAssetStore(
                directoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("HAENAUITests-\(UUID().uuidString)", isDirectory: true)
            )
            // Never opens the microphone and never shows a permission prompt, so a UI-test launch
            // cannot block on a system dialog no automated run can answer.
            audioRecorder = DeterministicMeetingAudioRecorder()
            recordingScratchStore = RecordingScratchStore(
                directoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("HAENAUITestRecordings-\(UUID().uuidString)", isDirectory: true)
            )
            // Never opens an audio device either, so an automated run cannot start playing sound
            // out of whatever machine it happens to be on.
            makeAudioPlayer = { DeterministicMeetingAudioPlayer() }
            profileRepository = InMemoryLocalUserProfileRepository()
            reminderRepository = InMemoryActionItemReminderRepository()
            notificationScheduler = InMemoryLocalNotificationScheduler()
        } else {
            repository = JSONProjectRepository(fileURL: JSONProjectRepository.defaultFileURL())
            let resolver = OpenAICredentialResolver.shared
            credentialResolver = resolver
            extractor = OpenAIWorkStateExtractor(apiKeyProvider: resolver.apiKeyProvider())
            transcriptionProvider = OpenAITranscriptionProvider(apiKeyProvider: resolver.apiKeyProvider())
            audioAssetStore = AudioAssetStore(directoryURL: AudioAssetStore.defaultDirectoryURL())
            audioRecorder = AVFoundationMeetingAudioRecorder()
            recordingScratchStore = RecordingScratchStore(
                directoryURL: RecordingScratchStore.defaultDirectoryURL()
            )
            makeAudioPlayer = { AVFoundationMeetingAudioPlayer() }
            profileRepository = JSONLocalUserProfileRepository(
                fileURL: JSONLocalUserProfileRepository.defaultFileURL()
            )
            reminderRepository = JSONActionItemReminderRepository(
                fileURL: JSONActionItemReminderRepository.defaultFileURL()
            )
            notificationScheduler = UserNotificationScheduler()
        }

        // Anything a previous session left behind — a recording abandoned by a crash — goes now.
        // Recordings are scratch by definition: nothing outside a live recording screen refers to
        // one, so clearing them at launch can never remove something a meeting depends on.
        recordingScratchStore.removeAll()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                repository: repository,
                extractor: extractor,
                transcriptionProvider: transcriptionProvider,
                audioAssetStore: audioAssetStore,
                audioRecorder: audioRecorder,
                recordingScratchStore: recordingScratchStore,
                makeAudioPlayer: makeAudioPlayer,
                profileRepository: profileRepository,
                reminderRepository: reminderRepository,
                notificationScheduler: notificationScheduler,
                credentialResolver: credentialResolver,
                showingPasteTranscript: $showingPasteTranscript,
                showingProjectBrowser: $showingProjectBrowser,
                showingImportAudio: $showingImportAudio,
                showingRecordAudio: $showingRecordAudio
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
        // Closing the recording sheet is what stops the recorder and clears its temporary file:
        // `RecordAudioView.onDisappear` owns that teardown, and quitting must not skip it.
        guard showingPasteTranscript || showingProjectBrowser || showingImportAudio || showingRecordAudio else {
            NSApp.terminate(nil)
            return
        }
        showingPasteTranscript = false
        showingProjectBrowser = false
        showingImportAudio = false
        showingRecordAudio = false
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
