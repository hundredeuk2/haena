import XCTest
@testable import HAENA

/// What a finished capture reports and where it sends the user.
///
/// The three capture paths differ only in how the meeting gets made; from the moment it is stored
/// they are the same flow, so these tests drive all three through the real capture services and
/// then assert one set of rules about the result.
final class CaptureOutcomeTests: XCTestCase {
    private typealias Fixtures = MeetingResultFixtures

    private var repository: InMemoryProjectRepository!

    override func setUp() {
        super.setUp()
        repository = InMemoryProjectRepository()
    }

    override func tearDown() {
        repository = nil
        super.tearDown()
    }

    // MARK: - Destinations from each capture path

    func testPastedTextCaptureReportsItsOwnProjectAndMeeting() async throws {
        let service = TextMeetingCaptureService(repository: repository)
        let project = try await service.createProject(name: "HAE.NA")

        let meeting = try await service.saveTextMeeting(
            projectID: project.id,
            title: "킥오프",
            transcript: "2월 출시로 가기로 했습니다."
        )

        let outcome = await CaptureOutcome.make(for: meeting, notice: nil, repository: repository)

        XCTAssertEqual(outcome.destination, CaptureDestination(projectID: project.id, meetingID: meeting.id))
        XCTAssertEqual(outcome.meetingTitle, "킥오프")

        // The destination really is in storage — a capture must never hand over ids that only
        // exist in memory.
        let stored = try await repository.project(id: project.id)
        XCTAssertEqual(stored?.meetings.map(\.id), [meeting.id])
    }

    func testImportedAudioCaptureReportsItsOwnProjectAndMeeting() async throws {
        let context = try AudioCaptureContext(self)
        let project = try await context.service.createProject(name: "HAE.NA")

        let meeting = try await context.service.importAudioMeeting(
            projectID: project.id,
            title: "가져온 회의",
            fileURL: try context.audioFile(),
            sourceType: .audioFile
        )

        let outcome = await CaptureOutcome.make(for: meeting, notice: nil, repository: context.repository)

        XCTAssertEqual(outcome.destination, CaptureDestination(projectID: project.id, meetingID: meeting.id))
        XCTAssertEqual(meeting.sourceType, .audioFile)
    }

    /// The microphone path hands its recording to the same capture service the file path uses; the
    /// only thing it changes is `sourceType`. Its destination must be built the same way.
    func testMicrophoneCaptureReportsItsOwnProjectAndMeeting() async throws {
        let context = try AudioCaptureContext(self)
        let project = try await context.service.createProject(name: "HAE.NA")

        let meeting = try await context.service.importAudioMeeting(
            projectID: project.id,
            title: "녹음 회의",
            fileURL: try context.audioFile(named: "recording.m4a"),
            sourceType: .microphone
        )

        let outcome = await CaptureOutcome.make(for: meeting, notice: nil, repository: context.repository)

        XCTAssertEqual(outcome.destination, CaptureDestination(projectID: project.id, meetingID: meeting.id))
        XCTAssertEqual(meeting.sourceType, .microphone)
    }

    // MARK: - Counts

    func testCountsMatchTheMeetingsOwnResults() async throws {
        let project = Fixtures.project(
            decisions: [
                Fixtures.decision(id: Fixtures.uuid(1)),
                Fixtures.decision(id: Fixtures.uuid(2), status: .confirmed)
            ],
            actionItems: [Fixtures.actionItem(id: Fixtures.uuid(3))],
            openQuestions: [
                Fixtures.openQuestion(id: Fixtures.uuid(4)),
                Fixtures.openQuestion(id: Fixtures.uuid(5)),
                Fixtures.openQuestion(id: Fixtures.uuid(6))
            ],
            nextAgenda: []
        )
        try await repository.save(project)

        let outcome = await CaptureOutcome.make(
            for: try meeting(Fixtures.meetingA, in: project),
            notice: nil,
            repository: repository
        )

        let counts = try XCTUnwrap(outcome.counts)
        XCTAssertEqual(counts.decisions, 2)
        XCTAssertEqual(counts.actionItems, 1)
        XCTAssertEqual(counts.openQuestions, 3)
        XCTAssertEqual(counts.agendaItems, 0)
        XCTAssertEqual(counts.total, 6)
    }

    /// The same attribution the results screen uses: another meeting's work — and another
    /// project's — is not this capture's output.
    func testCountsExcludeOtherMeetingsAndOtherProjects() async throws {
        let project = Fixtures.project(
            decisions: [
                Fixtures.decision(id: Fixtures.uuid(1)),
                Fixtures.decision(id: Fixtures.uuid(2), fromMeeting: Fixtures.meetingB),
                Fixtures.decision(id: Fixtures.uuid(3), inProject: Fixtures.projectB)
            ],
            actionItems: [Fixtures.actionItem(id: Fixtures.uuid(4), fromMeeting: Fixtures.meetingB)],
            nextAgenda: [
                // Belongs to no meeting at all, so it belongs to no capture either.
                Fixtures.agendaItem(id: Fixtures.uuid(5), fromMeeting: nil, evidence: nil)
            ]
        )
        try await repository.save(project)

        let outcome = await CaptureOutcome.make(
            for: try meeting(Fixtures.meetingA, in: project),
            notice: nil,
            repository: repository
        )

        let counts = try XCTUnwrap(outcome.counts)
        XCTAssertEqual(counts.decisions, 1)
        XCTAssertEqual(counts.actionItems, 0)
        XCTAssertEqual(counts.agendaItems, 0)
        XCTAssertEqual(counts.total, 1)
    }

    /// Zero of everything is a real answer and has to be reported as four zeros, not as a missing
    /// count — the user needs to see that all four were looked for.
    func testCountsAreAllZeroWhenTheMeetingProducedNothing() async throws {
        let project = Fixtures.project()
        try await repository.save(project)

        let outcome = await CaptureOutcome.make(
            for: try meeting(Fixtures.meetingA, in: project),
            notice: nil,
            repository: repository
        )

        let counts = try XCTUnwrap(outcome.counts)
        XCTAssertEqual(counts.decisions, 0)
        XCTAssertEqual(counts.actionItems, 0)
        XCTAssertEqual(counts.openQuestions, 0)
        XCTAssertEqual(counts.agendaItems, 0)
        XCTAssertEqual(counts.total, 0)
    }

    /// Counts come from storage, not from what the caller believed it had just written.
    func testCountsAreReadBackFromStorageRatherThanFromTheCaller() async throws {
        let stale = Fixtures.project(decisions: [Fixtures.decision(id: Fixtures.uuid(1))])
        var updated = stale
        updated.decisions.append(Fixtures.decision(id: Fixtures.uuid(2)))
        try await repository.save(updated)

        // Built from the *pre-update* value, which knows about only one decision.
        let outcome = await CaptureOutcome.make(
            for: try meeting(Fixtures.meetingA, in: stale),
            notice: nil,
            repository: repository
        )

        XCTAssertEqual(try XCTUnwrap(outcome.counts).decisions, 2)
    }

    func testCountsAreUnavailableRatherThanZeroWhenTheProjectCannotBeRead() async throws {
        let project = Fixtures.project(decisions: [Fixtures.decision(id: Fixtures.uuid(1))])
        // Never saved: the project is not in the repository at all.
        let outcome = await CaptureOutcome.make(
            for: try meeting(Fixtures.meetingA, in: project),
            notice: nil,
            repository: repository
        )

        XCTAssertNil(outcome.counts, "An unreadable project must not be reported as zero results")
        XCTAssertEqual(outcome.destination.meetingID, Fixtures.meetingA)
    }

    // MARK: - Partial failure

    /// Extraction failing after the meeting is stored is a notice beside a real meeting, never a
    /// reason to hide it: the transcript and any audio are already saved.
    func testExtractionFailureStillProducesAReachableDestination() async throws {
        let service = TextMeetingCaptureService(repository: repository)
        let project = try await service.createProject(name: "HAE.NA")
        let meeting = try await service.saveTextMeeting(
            projectID: project.id,
            title: "킥오프",
            transcript: "2월 출시로 가기로 했습니다."
        )

        let notice = CaptureFailureCopy.extraction(WorkStateExtractionError.rateLimited)
        let outcome = await CaptureOutcome.make(for: meeting, notice: notice, repository: repository)

        XCTAssertEqual(outcome.destination, CaptureDestination(projectID: project.id, meetingID: meeting.id))
        XCTAssertEqual(try XCTUnwrap(outcome.counts).total, 0)
        XCTAssertEqual(outcome.notice, notice)

        // The meeting and its transcript survived the failure.
        let stored = try await repository.project(id: project.id)
        let storedMeeting = try XCTUnwrap(stored?.meetings.first { $0.id == meeting.id })
        XCTAssertFalse(storedMeeting.transcriptSegments.isEmpty)
    }

    /// The notice is fixed copy: nothing from a provider response reaches the screen through it.
    func testFailureNoticeSaysZeroResultsAndNeverRepeatsTheSaveMessage() {
        for error in [
            WorkStateExtractionError.missingCredential,
            .unauthorized,
            .rateLimited,
            .timedOut,
            .networkUnavailable,
            .refused,
            .serverError(statusCode: 500),
            .requestRejected(statusCode: 400),
            .emptyResponse,
            .malformedResponse,
            .invalidConfiguration
        ] {
            let notice = CaptureFailureCopy.extraction(error)
            XCTAssertTrue(notice.hasPrefix("결과 0건 · "), "\(error): \(notice)")
            XCTAssertFalse(notice.contains("저장되었습니다"), "\(error): the completion screen already says this")
        }
    }

    // MARK: - Closing

    /// 닫기 reports nothing back and touches no storage; the meeting stays exactly as saved.
    func testClosingWithoutOpeningResultsLeavesTheSavedMeetingIntact() async throws {
        let service = TextMeetingCaptureService(repository: repository)
        let project = try await service.createProject(name: "HAE.NA")
        let meeting = try await service.saveTextMeeting(
            projectID: project.id,
            title: "킥오프",
            transcript: "2월 출시로 가기로 했습니다."
        )
        let before = try await repository.project(id: project.id)

        // Building and discarding the outcome is everything 닫기 does — it is a value, and nothing
        // about it writes.
        _ = await CaptureOutcome.make(for: meeting, notice: nil, repository: repository)

        let after = try await repository.project(id: project.id)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after?.meetings.map(\.id), [meeting.id])
    }

    // MARK: - Helpers

    private func meeting(_ id: UUID, in project: Project) throws -> Meeting {
        try XCTUnwrap(project.meetings.first { $0.id == id })
    }
}

/// A real audio capture service writing to throwaway directories, with a stub provider so no
/// network is involved.
private struct AudioCaptureContext {
    let repository = InMemoryProjectRepository()
    let service: AudioMeetingCaptureService
    private let sourceDirectory: URL

    init(_ testCase: XCTestCase) throws {
        sourceDirectory = try AudioTestSupport.makeTemporaryDirectory(testCase)
        let storeDirectory = try AudioTestSupport.makeTemporaryDirectory(testCase)
        service = AudioMeetingCaptureService(
            repository: repository,
            provider: StubTranscriptionProvider(
                .success([AudioTestSupport.segment("2월 출시로 가기로 했습니다.", start: 0, end: 4, speaker: "speaker_1")])
            ),
            assetStore: AudioAssetStore(directoryURL: storeDirectory.appendingPathComponent("Audio", isDirectory: true))
        )
    }

    func audioFile(named name: String = "meeting.m4a") throws -> URL {
        try AudioTestSupport.writeFile(named: name, byteCount: 256, in: sourceDirectory)
    }

    // MARK: - Credential boundary copy

    /// A user whose key is already saved must not be told to register one. The copy has to send
    /// them to the one screen where a Keychain prompt is part of what they asked for.
    func testInteractionRequiredCopyPointsAtSettingsRatherThanRegistration() {
        let text = CaptureFailureCopy.extraction(WorkStateExtractionError.credentialInteractionRequired)

        XCTAssertTrue(text.contains("AI 설정"))
        XCTAssertFalse(text.contains("등록"), "the key already exists; do not ask for a new one")
        // "연결 확인" only checks a key typed into the field next to it — it never reads the stored
        // item, so it cannot clear this state and must not be what the user is sent to do.
        XCTAssertFalse(text.contains("연결 확인"))
    }

    func testUnreadableCredentialCopyIsDistinctFromMissingCredentialCopy() {
        let unavailable = CaptureFailureCopy.extraction(WorkStateExtractionError.credentialUnavailable)
        let missing = CaptureFailureCopy.extraction(WorkStateExtractionError.missingCredential)

        XCTAssertNotEqual(unavailable, missing)
        XCTAssertTrue(unavailable.contains("AI 설정"))
    }
}
