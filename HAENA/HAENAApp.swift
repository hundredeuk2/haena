import AppKit
#if DEBUG
import Darwin
#endif
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

#if DEBUG
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
        case invalidDeletionCrashPoint
        case invalidDeletionRequest
    }

    /// Which deletion the seeded launch should perform. Absent means none — the relaunch processes
    /// in a smoke run pass no request and only let launch recovery do its work.
    enum DeletionRequest: String, Equatable {
        case meeting
        case project
    }

    static let projectID = UUID(uuidString: "D0000000-0000-0000-0000-000000000100")!
    static let meetingID = UUID(uuidString: "D0000000-0000-0000-0000-000000000101")!
    static let segmentID = UUID(uuidString: "D0000000-0000-0000-0000-000000000102")!
    static let decisionID = UUID(uuidString: "D0000000-0000-0000-0000-000000000002")!

    // The deletion smoke's own synthetic graph. Separate ids from the apply-path seed above so a
    // run of one can never be mistaken for a run of the other, and obviously synthetic in shape.
    static let deletionProjectID = UUID(uuidString: "D0000000-0000-0000-0000-000000000200")!
    static let deletionMeetingID = UUID(uuidString: "D0000000-0000-0000-0000-000000000201")!
    static let deletionSegmentID = UUID(uuidString: "D0000000-0000-0000-0000-000000000202")!
    static let deletionDecisionID = UUID(uuidString: "D0000000-0000-0000-0000-000000000203")!
    /// A second meeting in the same project that no deletion targets.
    static let deletionKeptMeetingID = UUID(uuidString: "D0000000-0000-0000-0000-000000000204")!
    static let deletionKeptDecisionID = UUID(uuidString: "D0000000-0000-0000-0000-000000000205")!
    /// A second project that no deletion targets.
    static let deletionOtherProjectID = UUID(uuidString: "D0000000-0000-0000-0000-000000000300")!
    static let deletionOtherMeetingID = UUID(uuidString: "D0000000-0000-0000-0000-000000000301")!

    let rootURL: URL
    let shouldSeed: Bool
    let shouldApprove: Bool
    let crashCheckpoint: WorkStateTransitionApplyCheckpoint?
    let shouldSeedDeletion: Bool
    let deletionRequest: DeletionRequest?
    let deletionCrashCheckpoint: MeetingDeletionCheckpoint?
    /// Ends the process after launch recovery has run, so a relaunch in a smoke run terminates on
    /// its own instead of the driver having to guess when it is finished.
    let shouldExitAfterRecovery: Bool

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
        let deletionCrashCheckpoint: MeetingDeletionCheckpoint?
        if let raw = environment["HAENA_RECOVERY_PROCESS_TEST_DELETION_CRASH_POINT"], !raw.isEmpty {
            guard let parsed = MeetingDeletionCheckpoint(rawValue: raw) else {
                throw ConfigurationError.invalidDeletionCrashPoint
            }
            deletionCrashCheckpoint = parsed
        } else {
            deletionCrashCheckpoint = nil
        }

        let deletionRequest: DeletionRequest?
        if let raw = environment["HAENA_RECOVERY_PROCESS_TEST_DELETE"], !raw.isEmpty {
            guard let parsed = DeletionRequest(rawValue: raw) else {
                throw ConfigurationError.invalidDeletionRequest
            }
            deletionRequest = parsed
        } else {
            deletionRequest = nil
        }

        return Self(
            rootURL: root,
            shouldSeed: environment["HAENA_RECOVERY_PROCESS_TEST_SEED"] == "1",
            shouldApprove: environment["HAENA_RECOVERY_PROCESS_TEST_AUTO_APPROVE"] == "1",
            crashCheckpoint: crashCheckpoint,
            shouldSeedDeletion: environment["HAENA_RECOVERY_PROCESS_TEST_DELETION_SEED"] == "1",
            deletionRequest: deletionRequest,
            deletionCrashCheckpoint: deletionCrashCheckpoint,
            shouldExitAfterRecovery:
                environment["HAENA_RECOVERY_PROCESS_TEST_EXIT_AFTER_RECOVERY"] == "1"
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

    /// The deletion smoke's synthetic graph: one project holding a doomed meeting and a kept one,
    /// plus a second project that nothing targets. Every row carries the ids the deletion closure
    /// resolves by, so a leak across either boundary shows up as a surviving or missing row rather
    /// than as a judgement call.
    func seedDeletionIfRequested(fileManager: FileManager = .default) throws {
        guard shouldSeedDeletion else { return }
        guard !fileManager.fileExists(atPath: projectsURL.path),
              !fileManager.fileExists(atPath: transitionsURL.path)
        else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)

        let createdAt = Date(timeIntervalSince1970: 1_788_000_000)
        let quote = "Synthetic deletion evidence"

        func meeting(id: UUID, projectID: UUID, segmentID: UUID, audio: AudioAsset?) -> Meeting {
            Meeting(
                id: id,
                projectID: projectID,
                title: "Synthetic deletion meeting",
                occurredAt: createdAt,
                sourceType: .pastedText,
                participants: [],
                transcriptSegments: [TranscriptSegment(
                    id: segmentID,
                    meetingID: id,
                    speakerID: nil,
                    sourceSpeakerLabel: "synthetic",
                    text: quote,
                    startTime: nil,
                    endTime: nil
                )],
                createdAt: createdAt,
                audioAsset: audio
            )
        }
        func decision(id: UUID, projectID: UUID, meetingID: UUID, segmentID: UUID) -> Decision {
            Decision(
                id: id,
                projectID: projectID,
                meetingID: meetingID,
                statement: "Synthetic decision",
                rationale: nil,
                status: .confirmed,
                evidence: EvidenceReference(
                    meetingID: meetingID, transcriptSegmentID: segmentID, quote: quote
                ),
                confidence: .maximum,
                createdAt: createdAt,
                updatedAt: createdAt
            )
        }
        func proposal(
            projectID: UUID, sourceMeetingID: UUID, currentObjectID: UUID, suffix: String
        ) -> WorkStateTransitionProposal {
            let key = "haena.synthetic-deletion.\(suffix)"
            return WorkStateTransitionProposal(
                id: WorkStateTransitionProposal.deterministicID(forDedupKey: key),
                projectID: projectID,
                workStateKind: .decision,
                transitionKind: .new,
                previousStateID: nil,
                currentObjectID: currentObjectID,
                sourceMeetingID: sourceMeetingID,
                evidence: TransitionEvidencePointer(
                    meetingID: sourceMeetingID, transcriptSegmentID: Self.deletionSegmentID
                ),
                basis: .noPriorCandidate,
                requiresConfirmation: true,
                dedupKey: key,
                createdAt: createdAt
            )
        }

        let audio = AudioAsset(
            id: UUID(uuidString: "D0000000-0000-0000-0000-000000000210")!,
            storedFileName: "synthetic-deletion.m4a",
            originalFileName: "synthetic-deletion.m4a",
            byteSize: 4,
            importedAt: createdAt
        )
        try Data([0, 1, 2, 3]).write(
            to: audioDirectoryURL.appendingPathComponent(audio.storedFileName), options: .atomic
        )

        let target = Project(
            id: Self.deletionProjectID,
            name: "Synthetic Deletion Target",
            summary: "",
            createdAt: createdAt,
            updatedAt: createdAt,
            meetings: [
                meeting(
                    id: Self.deletionMeetingID, projectID: Self.deletionProjectID,
                    segmentID: Self.deletionSegmentID, audio: audio
                ),
                meeting(
                    id: Self.deletionKeptMeetingID, projectID: Self.deletionProjectID,
                    segmentID: UUID(uuidString: "D0000000-0000-0000-0000-000000000206")!, audio: nil
                )
            ],
            decisions: [
                decision(
                    id: Self.deletionDecisionID, projectID: Self.deletionProjectID,
                    meetingID: Self.deletionMeetingID, segmentID: Self.deletionSegmentID
                ),
                decision(
                    id: Self.deletionKeptDecisionID, projectID: Self.deletionProjectID,
                    meetingID: Self.deletionKeptMeetingID,
                    segmentID: UUID(uuidString: "D0000000-0000-0000-0000-000000000206")!
                )
            ],
            actionItems: [], openQuestions: [], nextAgenda: []
        )
        let other = Project(
            id: Self.deletionOtherProjectID,
            name: "Synthetic Deletion Bystander",
            summary: "",
            createdAt: createdAt,
            updatedAt: createdAt,
            meetings: [
                meeting(
                    id: Self.deletionOtherMeetingID, projectID: Self.deletionOtherProjectID,
                    segmentID: UUID(uuidString: "D0000000-0000-0000-0000-000000000302")!, audio: nil
                )
            ],
            decisions: [], actionItems: [], openQuestions: [], nextAgenda: []
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ProjectStoreFile(projects: [target, other]))
            .write(to: projectsURL, options: .atomic)
        try encoder.encode(WorkStateTransitionStoreFile(proposals: [
            // From the doomed meeting.
            proposal(
                projectID: Self.deletionProjectID, sourceMeetingID: Self.deletionMeetingID,
                currentObjectID: Self.deletionDecisionID, suffix: "doomed"
            ),
            // From the kept meeting but about the doomed meeting's object: the cross-meeting edge.
            proposal(
                projectID: Self.deletionProjectID, sourceMeetingID: Self.deletionKeptMeetingID,
                currentObjectID: Self.deletionDecisionID, suffix: "dependent"
            ),
            // Names nothing being removed.
            proposal(
                projectID: Self.deletionProjectID, sourceMeetingID: Self.deletionKeptMeetingID,
                currentObjectID: Self.deletionKeptDecisionID, suffix: "kept"
            ),
            // Another project, same object id: survives on the project guard alone.
            proposal(
                projectID: Self.deletionOtherProjectID, sourceMeetingID: Self.deletionOtherMeetingID,
                currentObjectID: Self.deletionDecisionID, suffix: "bystander"
            )
        ])).write(to: transitionsURL, options: .atomic)
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

    var deletionCheckpointObserver: @Sendable (MeetingDeletionCheckpoint) -> Void {
        let requested = deletionCrashCheckpoint
        return { reached in
            guard reached == requested else { return }
            _exit(86)
        }
    }

    var audioDirectoryURL: URL { rootURL.appendingPathComponent("audio", isDirectory: true) }
}
#endif

private struct AppComponentAssembly {
    let repository: any WorkStateTransitionProjectRepository
    let transitionRepository: any WorkStateTransitionRepository
    let extractor: any WorkStateExtractor
    let transcriptionProvider: any TranscriptionProvider
    let credentialResolver: OpenAICredentialResolver
    let audioAssetStore: AudioAssetStore
    let audioRecorder: any MeetingAudioRecorder
    let recordingScratchStore: RecordingScratchStore
    let makeAudioPlayer: () -> any MeetingAudioPlayer
    let profileRepository: any LocalUserProfileRepository
    let reminderRepository: any ActionItemReminderRepository
    let ledgerRepository: any AgentLedgerRepository
    let metricsRepository: any BetaMetricsRepository
    let notificationScheduler: any LocalNotificationScheduler
    let didReachCheckpoint: @Sendable (WorkStateTransitionApplyCheckpoint) -> Void
}

@main
struct HAENAApp: App {
    @Environment(\.openSettings) private var openSettings
    private var pastedTranscriptInitialState: PastedTranscriptInitialState = .empty
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
    /// One re-analysis service for the whole app. It is the only component here that has to keep
    /// state between screens — which meetings currently have a run in flight — so it is built once
    /// rather than per view, the same reason the credential resolver is.
    private let reanalysisService: MeetingReanalysisService
    /// A factory, because playback state belongs to a single meeting at a time.
    private let makeAudioPlayer: () -> any MeetingAudioPlayer

    // Hoisted out of `ContentView` (rather than left as its local @State) so the Quit command
    // below can close an open sheet before terminating: see `terminate()`.
    @State private var showingPasteTranscript = false
    @State private var showingProjectBrowser = false
    @State private var showingImportAudio = false
    @State private var showingRecordAudio = false

    init() {
        let recoveryProcessAssembly: AppComponentAssembly?
        #if DEBUG
        do {
            let configuration = try TransitionApplyRecoveryProcessTestConfiguration.load()
            try configuration?.seedIfRequested()
            try configuration?.seedDeletionIfRequested()
            recoveryProcessAssembly = configuration.map { configuration in
                AppComponentAssembly(
                    repository: JSONProjectRepository(fileURL: configuration.projectsURL),
                    transitionRepository: JSONWorkStateTransitionRepository(
                        fileURL: configuration.transitionsURL
                    ),
                    extractor: DeterministicWorkStateExtractor(),
                    transcriptionProvider: DeterministicTranscriptionProvider(),
                    credentialResolver: OpenAICredentialResolver(store: InMemoryAPICredentialStore()),
                    audioAssetStore: AudioAssetStore(
                        directoryURL: configuration.rootURL.appendingPathComponent("audio", isDirectory: true)
                    ),
                    audioRecorder: DeterministicMeetingAudioRecorder(),
                    recordingScratchStore: RecordingScratchStore(
                        directoryURL: configuration.rootURL
                            .appendingPathComponent("recordings", isDirectory: true)
                    ),
                    makeAudioPlayer: { DeterministicMeetingAudioPlayer() },
                    profileRepository: InMemoryLocalUserProfileRepository(),
                    reminderRepository: InMemoryActionItemReminderRepository(),
                    ledgerRepository: InMemoryAgentLedgerRepository(),
                    metricsRepository: InMemoryBetaMetricsRepository(),
                    notificationScheduler: InMemoryLocalNotificationScheduler(),
                    didReachCheckpoint: configuration.checkpointObserver
                )
            }
        } catch {
            fatalError("Invalid isolated transition recovery process-test configuration: \(error)")
        }
        #else
        recoveryProcessAssembly = nil
        #endif

        // UI tests must never read or write the real Application Support data, nor reach the
        // network, so the app's single assembly point swaps in isolated implementations when
        // launched under test. No other code branches on this — everything downstream just sees
        // `any ProjectRepository` and `any WorkStateExtractor`.
        //
        // Note this is the *only* place either implementation is chosen: the deterministic
        // extractor is never substituted for OpenAI when a request fails, because showing a user
        // invented decisions and tasks in place of an error would be worse than showing nothing.
        if let recoveryProcessAssembly {
            repository = recoveryProcessAssembly.repository
            transitionRepository = recoveryProcessAssembly.transitionRepository
            extractor = recoveryProcessAssembly.extractor
            transcriptionProvider = recoveryProcessAssembly.transcriptionProvider
            credentialResolver = recoveryProcessAssembly.credentialResolver
            audioAssetStore = recoveryProcessAssembly.audioAssetStore
            audioRecorder = recoveryProcessAssembly.audioRecorder
            recordingScratchStore = recoveryProcessAssembly.recordingScratchStore
            makeAudioPlayer = recoveryProcessAssembly.makeAudioPlayer
            profileRepository = recoveryProcessAssembly.profileRepository
            reminderRepository = recoveryProcessAssembly.reminderRepository
            ledgerRepository = recoveryProcessAssembly.ledgerRepository
            metricsRepository = recoveryProcessAssembly.metricsRepository
            notificationScheduler = recoveryProcessAssembly.notificationScheduler
        } else if _isDebugAssertConfiguration() && AppComponentSelection.isUITesting() {
            let manualBriefSeed = ProcessInfo.processInfo.environment["HAENA_UI_TESTING_MANUAL_BRIEF"] == "1"
                ? ManualContinuityBriefUITestSeed.make()
                : nil
            var uiTestProjects = manualBriefSeed.map { [$0.project] } ?? []
            var uiTestProfile = manualBriefSeed?.profile
            #if DEBUG
            let homeSeed = HomeUITestSeed.select(environment: ProcessInfo.processInfo.environment)
            if let homeSeed {
                uiTestProjects = homeSeed.projects
                uiTestProfile = homeSeed.profile
            }
            if let captureSeed = CaptureNavigationUITestSeed.select(environment: ProcessInfo.processInfo.environment) {
                uiTestProjects.append(captureSeed.project)
                pastedTranscriptInitialState = captureSeed.initialState
            }
            if homeSeed?.scenario == .loadFailure {
                repository = HomeLoadFailureUITestRepository()
            } else {
                repository = InMemoryProjectRepository(projects: uiTestProjects)
            }
            #else
            repository = InMemoryProjectRepository(projects: uiTestProjects)
            #endif
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
            profileRepository = InMemoryLocalUserProfileRepository(profile: uiTestProfile)
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
            // Extraction gets the non-interactive resolver: it runs off saving a meeting, so it
            // must never be the thing that puts a Keychain prompt on screen.
            var extractionTransport: (any HTTPTransport)?
            #if DEBUG
            // Off unless a run asks for it. Reproducing a pre-network failure means proving no
            // request left the machine, and the only airtight way to prove that is to make one
            // impossible. Absent in Release, where this branch does not compile.
            if _isDebugAssertConfiguration(), FailClosedHTTPTransport.isRequested() {
                extractionTransport = FailClosedHTTPTransport()
            }
            #endif
            extractor = OpenAIWorkStateExtractor(
                credentialProvider: { await resolver.resolveWithoutInteraction() },
                transport: extractionTransport
            )
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
        if let recoveryProcessAssembly {
            transitionReviewService = WorkStateTransitionReviewService(
                projectRepository: repository,
                transitionRepository: transitionRepository,
                didReachCheckpoint: recoveryProcessAssembly.didReachCheckpoint
            )
        } else {
            transitionReviewService = WorkStateTransitionReviewService(
                projectRepository: repository,
                transitionRepository: transitionRepository
            )
        }

        reanalysisService = MeetingReanalysisService(
            repository: repository,
            extraction: WorkStateExtractionService(
                repository: repository,
                extractor: extractor,
                continuity: WorkStateContinuityService(
                    projects: repository,
                    transitions: transitionRepository
                )
            ),
            transitions: transitionRepository
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
                reanalysisService: reanalysisService,
                pastedTranscriptInitialState: pastedTranscriptInitialState,
                showingPasteTranscript: $showingPasteTranscript,
                showingProjectBrowser: $showingProjectBrowser,
                showingImportAudio: $showingImportAudio,
                showingRecordAudio: $showingRecordAudio
            )
            .environment(\.locale, AppLanguageSettings.shared.locale)
            #if DEBUG
            .background(UITestWindowPlacement(resizeMainWindow: true).frame(width: 0, height: 0))
            #endif
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("설정…")) { openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            // AppKit's own handling of `NSApp.terminate(_:)` silently declines whenever a SwiftUI
            // `.sheet` is still attached to the window (SwiftUI owns the sheet's presentation
            // state, so nothing outside these bindings can clear that attachment). Every sheet
            // also has its own escape route (Cancel/닫기), so the expected path is that a sheet is
            // already closed by the time Quit is invoked — this only matters when it isn't:
            // dismiss it through the same SwiftUI state that presented it, then let the dismissal
            // finish before asking AppKit to terminate on the next run loop turn.
            CommandGroup(replacing: .appTermination) {
                Button(L10n.text("종료")) {
                    terminate()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        Settings {
            GeneralSettingsView()
                .environment(\.locale, AppLanguageSettings.shared.locale)
                #if DEBUG
                .background(UITestWindowPlacement().frame(width: 0, height: 0))
                #endif
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
