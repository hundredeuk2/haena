import AppKit
import Darwin
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

/// Debug-only assembly contract for process-level recovery smoke tests.
///
/// The root is required to be a strict descendant of the system temporary directory. An invalid
/// opt-in is an error rather than a reason to fall back to the user's Application Support store.
struct TransitionApplyRecoveryProcessTestConfiguration: Equatable {
    enum ConfigurationError: Error, Equatable {
        case missingRoot
        case rootMustBeAbsolute
        case rootOutsideSystemTemporaryDirectory
        case invalidCrashPoint
    }

    static let projectID = UUID(uuidString: "D0000000-0000-0000-0000-000000000100")!
    static let meetingID = UUID(uuidString: "D0000000-0000-0000-0000-000000000101")!
    static let segmentID = UUID(uuidString: "D0000000-0000-0000-0000-000000000102")!
    static let decisionID = UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!

    let rootURL: URL
    let shouldSeed: Bool
    let shouldApprove: Bool
    let crashCheckpoint: WorkStateTransitionApplyCheckpoint?

    var projectsURL: URL { rootURL.appendingPathComponent("projects.json") }
    var transitionsURL: URL { rootURL.appendingPathComponent("continuity-transitions.json") }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> Self? {
        guard environment["HAENA_RECOVERY_PROCESS_TESTING"] == "1" else { return nil }
        guard let rawRoot = environment["HAENA_RECOVERY_PROCESS_TEST_ROOT"], !rawRoot.isEmpty else {
            throw ConfigurationError.missingRoot
        }
        guard rawRoot.hasPrefix("/") else { throw ConfigurationError.rootMustBeAbsolute }

        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let systemTemporary = fileManager.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(systemTemporary.path + "/") else {
            throw ConfigurationError.rootOutsideSystemTemporaryDirectory
        }

        let crashCheckpoint: WorkStateTransitionApplyCheckpoint?
        if let raw = environment["HAENA_RECOVERY_PROCESS_TEST_CRASH_POINT"], !raw.isEmpty {
            guard let parsed = WorkStateTransitionApplyCheckpoint(rawValue: raw) else {
                throw ConfigurationError.invalidCrashPoint
            }
            crashCheckpoint = parsed
        } else {
            crashCheckpoint = nil
        }
        return Self(
            rootURL: root,
            shouldSeed: environment["HAENA_RECOVERY_PROCESS_TEST_SEED"] == "1",
            shouldApprove: environment["HAENA_RECOVERY_PROCESS_TEST_AUTO_APPROVE"] == "1",
            crashCheckpoint: crashCheckpoint
        )
    }

    var proposalID: UUID {
        WorkStateTransitionProposal.deterministicID(forDedupKey: proposalDedupKey)
    }

    var proposalDedupKey: String {
        WorkStateTransitionProposal.dedupKey(
            projectID: Self.projectID,
            workStateKind: .decision,
            transitionKind: .new,
            previousStateID: nil,
            currentObjectID: Self.decisionID
        )
    }

    func seedIfRequested(fileManager: FileManager = .default) throws {
        guard shouldSeed else { return }
        guard !fileManager.fileExists(atPath: projectsURL.path),
              !fileManager.fileExists(atPath: transitionsURL.path)
        else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let createdAt = Date(timeIntervalSince1970: 1_788_000_000)
        let quote = "Synthetic recovery evidence"
        let evidence = EvidenceReference(
            meetingID: Self.meetingID,
            transcriptSegmentID: Self.segmentID,
            quote: quote
        )
        let project = Project(
            id: Self.projectID,
            name: "Synthetic Transition Recovery",
            summary: "",
            createdAt: createdAt,
            updatedAt: createdAt,
            meetings: [Meeting(
                id: Self.meetingID,
                projectID: Self.projectID,
                title: "Synthetic recovery meeting",
                occurredAt: createdAt,
                sourceType: .pastedText,
                participants: [],
                transcriptSegments: [TranscriptSegment(
                    id: Self.segmentID,
                    meetingID: Self.meetingID,
                    speakerID: nil,
                    sourceSpeakerLabel: "synthetic",
                    text: quote,
                    startTime: nil,
                    endTime: nil
                )],
                createdAt: createdAt
            )],
            decisions: [Decision(
                id: Self.decisionID,
                projectID: Self.projectID,
                meetingID: Self.meetingID,
                statement: "Synthetic decision awaiting review",
                rationale: nil,
                status: .proposed,
                evidence: evidence,
                confidence: .maximum,
                createdAt: createdAt,
                updatedAt: createdAt
            )],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
        let proposal = WorkStateTransitionProposal(
            id: proposalID,
            projectID: Self.projectID,
            workStateKind: .decision,
            transitionKind: .new,
            previousStateID: nil,
            currentObjectID: Self.decisionID,
            sourceMeetingID: Self.meetingID,
            evidence: TransitionEvidencePointer(
                meetingID: Self.meetingID,
                transcriptSegmentID: Self.segmentID
            ),
            basis: .noPriorCandidate,
            requiresConfirmation: true,
            dedupKey: proposalDedupKey,
            createdAt: createdAt
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ProjectStoreFile(projects: [project]))
            .write(to: projectsURL, options: .atomic)
        try encoder.encode(WorkStateTransitionStoreFile(proposals: [proposal]))
            .write(to: transitionsURL, options: .atomic)
        _ = try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: projectsURL.path)
        _ = try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transitionsURL.path)
    }

    var checkpointObserver: @Sendable (WorkStateTransitionApplyCheckpoint) -> Void {
        let requested = crashCheckpoint
        return { reached in
            guard reached == requested else { return }
            _exit(86)
        }
    }
}

@main
struct HAENAApp: App {
    private let repository: any WorkStateTransitionProjectRepository
    private let transitionRepository: any WorkStateTransitionRepository
    private let manualBriefService: ManualContinuityBriefService
    private let transitionReviewService: WorkStateTransitionReviewService
    private let extractor: any WorkStateExtractor
    private let transcriptionProvider: any TranscriptionProvider
    private let audioAssetStore: AudioAssetStore
    private let audioRecorder: any MeetingAudioRecorder
    private let recordingScratchStore: RecordingScratchStore
    private let profileRepository: any LocalUserProfileRepository
    private let reminderRepository: any ActionItemReminderRepository
    private let ledgerRepository: any AgentLedgerRepository
    private let metricsRepository: any BetaMetricsRepository
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
        let recoveryProcessConfiguration: TransitionApplyRecoveryProcessTestConfiguration?
        #if DEBUG
        do {
            recoveryProcessConfiguration = try TransitionApplyRecoveryProcessTestConfiguration.load()
            try recoveryProcessConfiguration?.seedIfRequested()
        } catch {
            fatalError("Invalid isolated transition recovery process-test configuration: \(error)")
        }
        #else
        recoveryProcessConfiguration = nil
        #endif

        // UI tests must never read or write the real Application Support data, nor reach the
        // network, so the app's single assembly point swaps in isolated implementations when
        // launched under test. No other code branches on this — everything downstream just sees
        // `any ProjectRepository` and `any WorkStateExtractor`.
        //
        // Note this is the *only* place either implementation is chosen: the deterministic
        // extractor is never substituted for OpenAI when a request fails, because showing a user
        // invented decisions and tasks in place of an error would be worse than showing nothing.
        if let recoveryProcessConfiguration {
            repository = JSONProjectRepository(fileURL: recoveryProcessConfiguration.projectsURL)
            transitionRepository = JSONWorkStateTransitionRepository(
                fileURL: recoveryProcessConfiguration.transitionsURL
            )
            extractor = DeterministicWorkStateExtractor()
            transcriptionProvider = DeterministicTranscriptionProvider()
            credentialResolver = OpenAICredentialResolver(store: InMemoryAPICredentialStore())
            audioAssetStore = AudioAssetStore(
                directoryURL: recoveryProcessConfiguration.rootURL
                    .appendingPathComponent("audio", isDirectory: true)
            )
            audioRecorder = DeterministicMeetingAudioRecorder()
            recordingScratchStore = RecordingScratchStore(
                directoryURL: recoveryProcessConfiguration.rootURL
                    .appendingPathComponent("recordings", isDirectory: true)
            )
            makeAudioPlayer = { DeterministicMeetingAudioPlayer() }
            profileRepository = InMemoryLocalUserProfileRepository()
            reminderRepository = InMemoryActionItemReminderRepository()
            ledgerRepository = InMemoryAgentLedgerRepository()
            metricsRepository = InMemoryBetaMetricsRepository()
            notificationScheduler = InMemoryLocalNotificationScheduler()
        } else if _isDebugAssertConfiguration() && AppComponentSelection.isUITesting() {
            let manualBriefSeed = ProcessInfo.processInfo.environment["HAENA_UI_TESTING_MANUAL_BRIEF"] == "1"
                ? ManualContinuityBriefUITestSeed.make()
                : nil
            repository = InMemoryProjectRepository(
                projects: manualBriefSeed.map { [$0.project] } ?? []
            )
            transitionRepository = InMemoryWorkStateTransitionRepository(
                proposals: manualBriefSeed?.proposals ?? [],
                ambiguousMatchGroups: manualBriefSeed?.ambiguityGroups ?? []
            )
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
            profileRepository = InMemoryLocalUserProfileRepository(profile: manualBriefSeed?.profile)
            reminderRepository = InMemoryActionItemReminderRepository()
            ledgerRepository = InMemoryAgentLedgerRepository(
                events: Self.uiTestLedgerSeed(environment: ProcessInfo.processInfo.environment)
            )
            notificationScheduler = InMemoryLocalNotificationScheduler()
            metricsRepository = InMemoryBetaMetricsRepository(
                measurementStartedAt: Self.uiTestMetricsStart,
                events: Self.uiTestMetricsSeed(environment: ProcessInfo.processInfo.environment)
            )
        } else {
            repository = JSONProjectRepository(fileURL: JSONProjectRepository.defaultFileURL())
            transitionRepository = JSONWorkStateTransitionRepository(
                fileURL: JSONWorkStateTransitionRepository.defaultFileURL()
            )
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
            let assembledReminderRepository = JSONActionItemReminderRepository(
                fileURL: JSONActionItemReminderRepository.defaultFileURL()
            )
            let assembledLedgerRepository = JSONAgentLedgerRepository(
                fileURL: JSONAgentLedgerRepository.defaultFileURL()
            )
            reminderRepository = assembledReminderRepository
            ledgerRepository = assembledLedgerRepository
            let notificationLedgerBridge = AgentNotificationLedgerBridge(
                reminderRepository: assembledReminderRepository,
                ledger: AgentLedgerService(repository: assembledLedgerRepository)
            )
            metricsRepository = JSONBetaMetricsRepository(
                fileURL: JSONBetaMetricsRepository.defaultFileURL()
            )
            notificationScheduler = UserNotificationScheduler(
                foregroundDelegate: ForegroundNotificationDelegate { callback in
                    Task { await notificationLedgerBridge.record(callback) }
                }
            )
        }

        manualBriefService = ManualContinuityBriefService(
            projects: repository,
            transitions: transitionRepository,
            profiles: profileRepository
        )
        let checkpointObserver: @Sendable (WorkStateTransitionApplyCheckpoint) -> Void
        if let recoveryProcessConfiguration {
            checkpointObserver = recoveryProcessConfiguration.checkpointObserver
        } else {
            checkpointObserver = { _ in }
        }
        transitionReviewService = WorkStateTransitionReviewService(
            projectRepository: repository,
            transitionRepository: transitionRepository,
            didReachCheckpoint: checkpointObserver
        )

        // Anything a previous session left behind — a recording abandoned by a crash — goes now.
        // Recordings are scratch by definition: nothing outside a live recording screen refers to
        // one, so clearing them at launch can never remove something a meeting depends on.
        recordingScratchStore.removeAll()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                repository: repository,
                transitionRepository: transitionRepository,
                manualBriefService: manualBriefService,
                transitionReviewService: transitionReviewService,
                extractor: extractor,
                transcriptionProvider: transcriptionProvider,
                audioAssetStore: audioAssetStore,
                audioRecorder: audioRecorder,
                recordingScratchStore: recordingScratchStore,
                makeAudioPlayer: makeAudioPlayer,
                profileRepository: profileRepository,
                reminderRepository: reminderRepository,
                ledgerRepository: ledgerRepository,
                metricsRepository: metricsRepository,
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

    private static func uiTestLedgerSeed(environment: [String: String]) -> [AgentLedgerEvent] {
        guard environment["HAENA_UI_TESTING_AGENT_LEDGER"] == "1" else { return [] }
        let occurredAt = Date(timeIntervalSince1970: 1_786_358_400)
        return [
            AgentLedgerEvent(
                id: UUID(uuidString: "A7000000-0000-4000-8000-000000000001")!,
                deduplicationKey: "fireTimeReached:a7000000-ui-test",
                reminderID: UUID(uuidString: "A7000000-0000-4000-8000-000000000002")!,
                projectID: UUID(uuidString: "A7000000-0000-4000-8000-000000000003")!,
                actionItemID: UUID(uuidString: "A7000000-0000-4000-8000-000000000004")!,
                type: .fireTimeReached,
                occurredAt: occurredAt,
                scheduledFor: occurredAt.addingTimeInterval(3_600)
            )
        ]
    }

    /// The measurement period a UI-test launch reports. Fixed rather than `Date()`, so the seeded
    /// events below are always inside the window and the screen never depends on when the run
    /// happened.
    private static let uiTestMetricsStart = Date(timeIntervalSince1970: 1_786_272_000)

    /// A seeded beta-measurement period, so the screen can be exercised with real numbers rather
    /// than only in its empty state.
    ///
    /// Deliberately produces a *computable* approval rate — three approvals and one exclusion —
    /// because the interesting assertion is that a rate renders with its numerator and denominator,
    /// and a zero denominator would render the empty state instead and prove nothing. The two
    /// meetings sit on two different local days so repeat usage is observable too.
    private static func uiTestMetricsSeed(environment: [String: String]) -> [BetaMetricEvent] {
        guard environment["HAENA_UI_TESTING_BETA_METRICS"] == "1" else { return [] }

        let firstDay = uiTestMetricsStart.addingTimeInterval(3_600)
        let secondDay = uiTestMetricsStart.addingTimeInterval(90_000)

        func id(_ index: Int) -> UUID {
            UUID(uuidString: "B7000000-0000-4000-8000-\(String(format: "%012d", index))")!
        }

        var events: [BetaMetricEvent] = [
            BetaMetricEvent(
                id: id(1),
                deduplicationKey: "meetingProcessed:\(id(101).uuidString)",
                type: .meetingProcessed,
                occurredAt: firstDay,
                projectID: id(100),
                meetingID: id(101),
                captureSource: .pastedText,
                resultCount: 4
            ),
            BetaMetricEvent(
                id: id(2),
                deduplicationKey: "meetingProcessed:\(id(102).uuidString)",
                type: .meetingProcessed,
                occurredAt: secondDay,
                projectID: id(100),
                meetingID: id(102),
                captureSource: .importedAudio,
                resultCount: 3
            ),
            BetaMetricEvent(
                id: id(3),
                deduplicationKey: "processingDuration:\(id(103).uuidString)",
                type: .processingDuration,
                occurredAt: firstDay,
                meetingID: id(101),
                captureSource: .pastedText,
                outcome: .succeeded,
                durationMilliseconds: 4_200
            ),
            BetaMetricEvent(
                id: id(4),
                deduplicationKey: "processingDuration:\(id(104).uuidString)",
                type: .processingDuration,
                occurredAt: secondDay,
                meetingID: id(102),
                captureSource: .importedAudio,
                outcome: .succeeded,
                durationMilliseconds: 12_800
            ),
            BetaMetricEvent(
                id: id(5),
                deduplicationKey: "proposalModified:\(id(201).uuidString)",
                type: .proposalModified,
                occurredAt: firstDay,
                projectID: id(100),
                proposalID: id(201),
                proposalKind: .actionItem,
                fieldCategory: .assignee
            )
        ]

        let verdicts: [(Int, BetaMetricProposalKind, BetaMetricVerdict)] = [
            (201, .actionItem, .approved),
            (202, .decision, .approved),
            (203, .openQuestion, .approved),
            (204, .agendaItem, .excluded)
        ]
        for (offset, entry) in verdicts.enumerated() {
            events.append(
                BetaMetricEvent(
                    id: id(300 + offset),
                    deduplicationKey: "proposalReviewed:\(id(entry.0).uuidString)",
                    type: .proposalReviewed,
                    occurredAt: firstDay,
                    projectID: id(100),
                    proposalID: id(entry.0),
                    proposalKind: entry.1,
                    verdict: entry.2
                )
            )
        }
        return events
    }
}
