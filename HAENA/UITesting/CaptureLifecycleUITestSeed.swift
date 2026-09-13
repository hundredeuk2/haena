#if DEBUG
import Foundation

/// Fixed finite assembly: no provider, user data, arbitrary environment content or path.
struct CaptureLifecycleUITestSeed {
    enum Scenario: String, CaseIterable { case success, preSaveFailure, analysisFailure, transcriptionFailure, countReadFailure }
    let scenario: Scenario
    static let projectID = UUID(uuidString: "CB000000-0000-4000-8000-000000000001")!
    static let title = "Synthetic Capture Lifecycle"
    static let transcript = "Synthetic capture evidence."

    static func select(environment: [String: String]) -> Self? {
        guard environment["HAENA_UI_TESTING"] == "1",
              let raw = environment["HAENA_UI_TEST_CAPTURE_LIFECYCLE"],
              let scenario = Scenario(rawValue: raw) else { return nil }
        return Self(scenario: scenario)
    }

    var project: Project {
        let date = Date(timeIntervalSince1970: 1_786_358_400)
        return Project(id: Self.projectID, name: "Synthetic Capture Project", summary: "",
                       createdAt: date, updatedAt: date, meetings: [], decisions: [],
                       actionItems: [], openQuestions: [], nextAgenda: [])
    }

    var pastedState: PastedTranscriptInitialState {
        .init(selectedProjectID: Self.projectID, meetingTitle: Self.title, transcript: Self.transcript)
    }

    func audioState() throws -> AudioCaptureInitialState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HAENA-Capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("SyntheticCapture.wav")
        try DeterministicMeetingAudioRecorder.silentWAVData(seconds: 1, sampleRate: 8_000).write(to: file)
        return .init(selectedProjectID: Self.projectID, meetingTitle: Self.title,
                     selectedFile: try AudioFileValidator().validate(file))
    }
}

actor CaptureLifecycleUITestRepository: WorkStateTransitionProjectRepository {
    enum Failure: Error { case syntheticSave, syntheticRead }
    private let base: InMemoryProjectRepository
    private var failSave: Bool
    private var failRead = false
    private(set) var meetingWrites = 0

    init(seed: CaptureLifecycleUITestSeed) {
        base = InMemoryProjectRepository(projects: [seed.project])
        failSave = seed.scenario == .preSaveFailure
    }

    func failNextRead() { failRead = true }
    func project(id: UUID) async throws -> Project? {
        if failRead { failRead = false; throw Failure.syntheticRead }
        return try await base.project(id: id)
    }
    func allProjects() async throws -> [Project] { try await base.allProjects() }
    func delete(id: UUID) async throws { try await base.delete(id: id) }
    func save(_ project: Project) async throws {
        if !project.meetings.isEmpty, failSave { failSave = false; throw Failure.syntheticSave }
        if !project.meetings.isEmpty { meetingWrites += 1 }
        try await base.save(project)
    }
    func save(_ project: Project, recording marker: WorkStateTransitionApplyMarker) async throws {
        try await base.save(project, recording: marker)
    }
    func transitionApplyMarker(projectID: UUID, operationID: UUID,
                               operationKind: WorkStateTransitionApplyOperationKind) async throws -> WorkStateTransitionApplyMarker? {
        await base.transitionApplyMarker(projectID: projectID, operationID: operationID, operationKind: operationKind)
    }
}

actor CaptureLifecycleUITestExtractor: WorkStateExtractor {
    private let scenario: CaptureLifecycleUITestSeed.Scenario
    private let repository: CaptureLifecycleUITestRepository
    private let latency: Duration
    private var calls = 0

    init(scenario: CaptureLifecycleUITestSeed.Scenario, repository: CaptureLifecycleUITestRepository,
         latency: Duration = .zero) {
        self.scenario = scenario; self.repository = repository; self.latency = latency
    }
    func extract(from input: WorkStateExtractionInput) async throws -> WorkStateExtractionResult {
        calls += 1
        if latency > .zero { try await Task.sleep(for: latency) }
        if calls == 1 && (scenario == .analysisFailure || scenario == .countReadFailure) {
            if scenario == .countReadFailure { await repository.failNextRead() }
            throw WorkStateExtractionError.timedOut
        }
        return try await DeterministicWorkStateExtractor().extract(from: input)
    }
}

actor CaptureLifecycleUITestTranscriber: TranscriptionProvider {
    nonisolated var capabilities: TranscriptionCapabilities { DeterministicTranscriptionProvider().capabilities }
    private let failFirst: Bool
    private let latency: Duration
    private var calls = 0
    init(failFirst: Bool, latency: Duration = .zero) { self.failFirst = failFirst; self.latency = latency }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        calls += 1
        if latency > .zero { try await Task.sleep(for: latency) }
        if failFirst && calls == 1 { throw TranscriptionError.timedOut }
        return try await DeterministicTranscriptionProvider().transcribe(request)
    }
}
#endif
