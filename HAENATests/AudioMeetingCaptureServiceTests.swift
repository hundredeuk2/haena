import XCTest
@testable import HAENA

/// Covers the ordering guarantees the import flow is built around: the local copy is made before
/// the network call, and the project is written only after a real transcript comes back.
final class AudioMeetingCaptureServiceTests: XCTestCase {
    private var sourceDirectory: URL!
    private var storeDirectory: URL!
    private var assetStore: AudioAssetStore!
    private var repository: InMemoryProjectRepository!
    private var ids: AudioTestSupport.IDSequence!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sourceDirectory = try AudioTestSupport.makeTemporaryDirectory(self)
        storeDirectory = try AudioTestSupport.makeTemporaryDirectory(self)
        assetStore = AudioAssetStore(directoryURL: storeDirectory.appendingPathComponent("Audio", isDirectory: true))
        repository = InMemoryProjectRepository()
        ids = AudioTestSupport.IDSequence()
    }

    private func makeService(_ provider: StubTranscriptionProvider) -> AudioMeetingCaptureService {
        let ids = self.ids!
        return AudioMeetingCaptureService(
            repository: repository,
            provider: provider,
            assetStore: assetStore,
            now: { TestFixtures.fixedDate },
            makeID: { ids.next() }
        )
    }

    private func audioFile(named name: String = "meeting.m4a", byteCount: Int = 256) throws -> URL {
        try AudioTestSupport.writeFile(named: name, byteCount: byteCount, in: sourceDirectory)
    }

    private func storedProject() async throws -> Project? {
        try await repository.project(id: TestFixtures.projectID)
    }

    private static let twoSpeakerTranscript = [
        AudioTestSupport.segment("우리는 2월 출시로 가기로 했습니다.", start: 0, end: 4, speaker: "speaker_1"),
        AudioTestSupport.segment("지표 정의는 아직 정하지 못했습니다.", start: 4, end: 8, speaker: "speaker_2"),
        AudioTestSupport.segment("그럼 다음 주에 확정하죠.", start: 8, end: 11, speaker: "speaker_1")
    ]

    // MARK: - Input validation

    func testRejectsMissingProjectSelection() async throws {
        let service = makeService(StubTranscriptionProvider(.success(Self.twoSpeakerTranscript)))
        await assertThrows(.noProjectSelected) {
            try await service.importAudioMeeting(projectID: nil, title: "회의", fileURL: try self.audioFile())
        }
    }

    func testRejectsBlankTitle() async throws {
        try await repository.save(AudioTestSupport.project())
        let service = makeService(StubTranscriptionProvider(.success(Self.twoSpeakerTranscript)))
        await assertThrows(.meetingTitleMissing) {
            try await service.importAudioMeeting(
                projectID: TestFixtures.projectID,
                title: "   ",
                fileURL: try self.audioFile()
            )
        }
    }

    func testRejectsUnsupportedFileBeforeTouchingTheProvider() async throws {
        try await repository.save(AudioTestSupport.project())
        let provider = StubTranscriptionProvider(.success(Self.twoSpeakerTranscript))
        let service = makeService(provider)

        await assertThrows(.invalidFile(.unsupportedFormat(fileExtension: "aiff"))) {
            try await service.importAudioMeeting(
                projectID: TestFixtures.projectID,
                title: "회의",
                fileURL: try self.audioFile(named: "meeting.aiff")
            )
        }
        let requests = await provider.receivedRequests
        XCTAssertTrue(requests.isEmpty)
    }

    /// Discovering the project is gone only after a long upload would waste the request.
    func testMissingProjectFailsBeforeTheUpload() async throws {
        let provider = StubTranscriptionProvider(.success(Self.twoSpeakerTranscript))
        let service = makeService(provider)

        await assertThrows(.projectNotFound) {
            try await service.importAudioMeeting(
                projectID: TestFixtures.projectID,
                title: "회의",
                fileURL: try self.audioFile()
            )
        }
        let requests = await provider.receivedRequests
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - Success path

    func testSuccessPersistsMeetingSegmentsAndAudioReference() async throws {
        try await repository.save(AudioTestSupport.project())
        let service = makeService(StubTranscriptionProvider(.success(Self.twoSpeakerTranscript)))

        let meeting = try await service.importAudioMeeting(
            projectID: TestFixtures.projectID,
            title: "  주간 회의  ",
            fileURL: try audioFile()
        )

        XCTAssertEqual(meeting.title, "주간 회의", "Title should be trimmed.")
        XCTAssertEqual(meeting.sourceType, .audioFile)
        XCTAssertEqual(meeting.transcriptSegments.count, 3)

        let loadedProject = try await storedProject()
        let stored = try XCTUnwrap(loadedProject)
        let storedMeeting = try XCTUnwrap(stored.meetings.first)
        XCTAssertEqual(stored.meetings.count, 1)
        XCTAssertEqual(storedMeeting, meeting, "What was returned must be what was persisted.")
        XCTAssertEqual(stored.updatedAt, TestFixtures.fixedDate)

        let asset = try XCTUnwrap(storedMeeting.audioAsset)
        XCTAssertEqual(asset.originalFileName, "meeting.m4a")
        XCTAssertEqual(asset.byteSize, 256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetStore.url(for: asset).path))
    }

    func testSegmentTimingsAndTextAreMappedOntoTranscriptSegments() async throws {
        try await repository.save(AudioTestSupport.project())
        let service = makeService(StubTranscriptionProvider(.success(Self.twoSpeakerTranscript)))

        let meeting = try await service.importAudioMeeting(
            projectID: TestFixtures.projectID,
            title: "회의",
            fileURL: try audioFile()
        )

        XCTAssertEqual(meeting.transcriptSegments[0].text, "우리는 2월 출시로 가기로 했습니다.")
        XCTAssertEqual(meeting.transcriptSegments[0].startTime, 0)
        XCTAssertEqual(meeting.transcriptSegments[0].endTime, 4)
        XCTAssertEqual(meeting.transcriptSegments[2].startTime, 8)
        XCTAssertTrue(meeting.transcriptSegments.allSatisfy { $0.meetingID == meeting.id })
    }

    /// The same provider label must resolve to one identity across the whole meeting, or the
    /// transcript would show three speakers where there were two.
    func testRepeatedSpeakerLabelMapsToOneStableParticipant() async throws {
        try await repository.save(AudioTestSupport.project())
        let service = makeService(StubTranscriptionProvider(.success(Self.twoSpeakerTranscript)))

        let meeting = try await service.importAudioMeeting(
            projectID: TestFixtures.projectID,
            title: "회의",
            fileURL: try audioFile()
        )

        XCTAssertEqual(meeting.participants.count, 2)
        XCTAssertEqual(
            meeting.transcriptSegments[0].speakerID,
            meeting.transcriptSegments[2].speakerID,
            "Both 'speaker_1' segments must point at the same participant."
        )
        XCTAssertNotEqual(meeting.transcriptSegments[0].speakerID, meeting.transcriptSegments[1].speakerID)
        XCTAssertTrue(
            meeting.participants.allSatisfy { participant in
                meeting.transcriptSegments.contains { $0.speakerID == participant.id }
            },
            "No participant may be created that no segment refers to."
        )
    }

    /// No provider knows who is in the room, so display names stay anonymous and positional.
    func testParticipantsGetAnonymousPositionalNames() async throws {
        try await repository.save(AudioTestSupport.project())
        let service = makeService(StubTranscriptionProvider(.success(Self.twoSpeakerTranscript)))

        let meeting = try await service.importAudioMeeting(
            projectID: TestFixtures.projectID,
            title: "회의",
            fileURL: try audioFile()
        )

        XCTAssertEqual(meeting.participants.map(\.displayName), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(meeting.participants.map(\.speakerLabel), ["speaker_1", "speaker_2"])
        XCTAssertTrue(meeting.participants.allSatisfy { $0.linkedUserID == nil })
    }

    func testTranscriptWithoutSpeakersStoresNilSpeakerIDs() async throws {
        try await repository.save(AudioTestSupport.project())
        let provider = StubTranscriptionProvider(.success([
            AudioTestSupport.segment("안녕하세요", start: 0, end: 2),
            AudioTestSupport.segment("반갑습니다", start: 2, end: 4)
        ]))
        let service = makeService(provider)

        let meeting = try await service.importAudioMeeting(
            projectID: TestFixtures.projectID,
            title: "회의",
            fileURL: try audioFile()
        )

        XCTAssertTrue(meeting.participants.isEmpty)
        XCTAssertTrue(meeting.transcriptSegments.allSatisfy { $0.speakerID == nil })
    }

    /// The provider is handed the app's copy, not the user's original — a retry must not depend
    /// on a file the user may have moved since.
    func testProviderReceivesTheStoredCopyNotTheOriginal() async throws {
        try await repository.save(AudioTestSupport.project())
        let provider = StubTranscriptionProvider(.success(Self.twoSpeakerTranscript))
        let service = makeService(provider)
        let original = try audioFile()

        _ = try await service.importAudioMeeting(
            projectID: TestFixtures.projectID,
            title: "회의",
            fileURL: original
        )

        let requests = await provider.receivedRequests
        let received = try XCTUnwrap(requests.first)
        XCTAssertNotEqual(received.fileURL, original)
        XCTAssertTrue(received.fileURL.path.contains("Audio"))
        XCTAssertEqual(received.byteSize, 256)
        XCTAssertTrue(received.fileName.hasSuffix(".m4a"), "The extension must survive so the provider can read the container.")
    }

    // MARK: - Failure atomicity

    func testProviderFailureSavesNoMeeting() async throws {
        try await repository.save(AudioTestSupport.project())
        let service = makeService(StubTranscriptionProvider(.failure(.rateLimited)))

        await assertThrows(.transcriptionFailed(.rateLimited)) {
            try await service.importAudioMeeting(
                projectID: TestFixtures.projectID,
                title: "회의",
                fileURL: try self.audioFile()
            )
        }

        let loadedProject = try await storedProject()
        let stored = try XCTUnwrap(loadedProject)
        XCTAssertTrue(stored.meetings.isEmpty, "A failed transcription must leave no partial meeting.")
        XCTAssertEqual(stored.updatedAt, TestFixtures.fixedDate, "The project must not be rewritten at all.")
    }

    /// The stored copy is what makes a retry possible without re-choosing the file.
    func testProviderFailureKeepsTheStoredAudioCopy() async throws {
        try await repository.save(AudioTestSupport.project())
        let service = makeService(StubTranscriptionProvider(.failure(.networkUnavailable)))

        await assertThrows(.transcriptionFailed(.networkUnavailable)) {
            try await service.importAudioMeeting(
                projectID: TestFixtures.projectID,
                title: "회의",
                fileURL: try self.audioFile()
            )
        }

        let storedFiles = try FileManager.default.contentsOfDirectory(
            atPath: storeDirectory.appendingPathComponent("Audio").path
        )
        XCTAssertEqual(storedFiles.count, 1, "The local copy must survive a provider failure.")
    }

    func testEmptyTranscriptIsAFailureThatSavesNothing() async throws {
        try await repository.save(AudioTestSupport.project())
        let service = makeService(StubTranscriptionProvider(.failure(.emptyTranscript)))

        await assertThrows(.transcriptionFailed(.emptyTranscript)) {
            try await service.importAudioMeeting(
                projectID: TestFixtures.projectID,
                title: "회의",
                fileURL: try self.audioFile()
            )
        }
        let loadedProject = try await storedProject()
        let stored = try XCTUnwrap(loadedProject)
        XCTAssertTrue(stored.meetings.isEmpty)
    }

    func testFailedImportLeavesPreexistingProjectDataUntouched() async throws {
        let existing = ExtractionFixtures.meeting()
        try await repository.save(AudioTestSupport.project(meetings: [existing]))
        let service = makeService(StubTranscriptionProvider(.failure(.unauthorized)))

        await assertThrows(.transcriptionFailed(.unauthorized)) {
            try await service.importAudioMeeting(
                projectID: TestFixtures.projectID,
                title: "회의",
                fileURL: try self.audioFile()
            )
        }

        let loadedProject = try await storedProject()
        let stored = try XCTUnwrap(loadedProject)
        XCTAssertEqual(stored.meetings, [existing])
    }

    // MARK: - Project creation

    func testCreateProjectPersistsAndRejectsBlankNames() async throws {
        let service = makeService(StubTranscriptionProvider(.success(Self.twoSpeakerTranscript)))

        let project = try await service.createProject(name: "  새 프로젝트  ")
        XCTAssertEqual(project.name, "새 프로젝트")
        let reloaded = try await repository.project(id: project.id)
        XCTAssertEqual(reloaded?.name, "새 프로젝트")

        await assertThrows(.projectNameMissing) {
            _ = try await service.createProject(name: "   ")
        }
    }

    // MARK: - Helper

    private func assertThrows(
        _ expected: AudioMeetingCaptureError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch let error as AudioMeetingCaptureError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected) but got \(error).", file: file, line: line)
        }
    }
}
