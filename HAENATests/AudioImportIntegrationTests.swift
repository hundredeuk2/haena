import XCTest
@testable import HAENA

/// End-to-end over the real JSON repository: import → persist → extract → delete, with the
/// network boundary stubbed. This is the flow the "파일 불러오기" button drives.
final class AudioImportIntegrationTests: XCTestCase {
    private var sourceDirectory: URL!
    private var supportDirectory: URL!
    private var assetStore: AudioAssetStore!
    private var repository: JSONProjectRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sourceDirectory = try AudioTestSupport.makeTemporaryDirectory(self)
        supportDirectory = try AudioTestSupport.makeTemporaryDirectory(self)
        assetStore = AudioAssetStore(directoryURL: supportDirectory.appendingPathComponent("Audio", isDirectory: true))
        repository = JSONProjectRepository(fileURL: supportDirectory.appendingPathComponent("projects.json"))
    }

    private static let transcript = [
        AudioTestSupport.segment("우리는 2월 출시로 가기로 했습니다.", start: 0, end: 4, speaker: "speaker_1"),
        AudioTestSupport.segment("지표 정의는 아직 정하지 못했습니다.", start: 4, end: 8, speaker: "speaker_2")
    ]

    private func makeCaptureService(
        _ outcome: StubTranscriptionProvider.Outcome = .success(AudioImportIntegrationTests.transcript)
    ) -> AudioMeetingCaptureService {
        AudioMeetingCaptureService(
            repository: repository,
            provider: StubTranscriptionProvider(outcome),
            assetStore: assetStore
        )
    }

    private func importMeeting(
        into projectID: UUID,
        service: AudioMeetingCaptureService,
        fileName: String = "meeting.m4a"
    ) async throws -> Meeting {
        let url = try AudioTestSupport.writeFile(named: fileName, byteCount: 512, in: sourceDirectory)
        return try await service.importAudioMeeting(projectID: projectID, title: "주간 회의", fileURL: url)
    }

    // MARK: - Persistence

    /// A reload through a *new* repository instance proves the meeting reached disk rather than
    /// living in an in-memory cache.
    func testImportedMeetingAndAudioSurviveAReload() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "HAE.NA")
        let meeting = try await importMeeting(into: project.id, service: service)

        let reopened = JSONProjectRepository(fileURL: supportDirectory.appendingPathComponent("projects.json"))
        let loaded = try await reopened.project(id: project.id)
        let reloaded = try XCTUnwrap(loaded)
        let reloadedMeeting = try XCTUnwrap(reloaded.meetings.first)

        XCTAssertEqual(reloadedMeeting, meeting)
        XCTAssertEqual(reloadedMeeting.sourceType, .audioFile)
        XCTAssertEqual(reloadedMeeting.transcriptSegments.count, 2)
        XCTAssertEqual(reloadedMeeting.participants.count, 2)

        let asset = try XCTUnwrap(reloadedMeeting.audioAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetStore.url(for: asset).path))
    }

    /// Meetings written before audio import existed must keep decoding — the schema version is
    /// still 1, so a missing `audioAsset` key has to be tolerated.
    func testMeetingWithoutAudioAssetStillDecodes() throws {
        let json = """
        {"id":"\(TestFixtures.meetingID.uuidString)","projectID":"\(TestFixtures.projectID.uuidString)",
         "title":"이전 회의","occurredAt":0,"sourceType":"pastedText","participants":[],
         "transcriptSegments":[],"createdAt":0}
        """
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))
        XCTAssertNil(meeting.audioAsset)
        XCTAssertEqual(meeting.title, "이전 회의")
    }

    // MARK: - Extraction hand-off

    func testExtractionRunsOverTheImportedTranscriptAndStoresProposals() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "HAE.NA")
        let meeting = try await importMeeting(into: project.id, service: service)

        let extractionService = WorkStateExtractionService(
            repository: repository,
            extractor: DeterministicWorkStateExtractor()
        )
        let report = try await extractionService.extractAndApply(
            meetingID: meeting.id,
            projectID: project.id
        )

        XCTAssertGreaterThan(report.storedCount, 0)

        // Evidence must resolve against the segments the *transcription* produced, which is the
        // real integration point between the two features.
        let loaded = try await repository.project(id: project.id)
        let stored = try XCTUnwrap(loaded)
        let segmentIDs = Set(meeting.transcriptSegments.map(\.id))
        XCTAssertFalse(stored.decisions.isEmpty)
        for decision in stored.decisions {
            let evidence = try XCTUnwrap(decision.evidence)
            XCTAssertTrue(segmentIDs.contains(evidence.transcriptSegmentID))
            XCTAssertEqual(evidence.meetingID, meeting.id)
        }
    }

    // MARK: - Deletion policy

    func testDeletingTheMeetingDeletesItsStoredAudio() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "HAE.NA")
        let meeting = try await importMeeting(into: project.id, service: service)
        let asset = try XCTUnwrap(meeting.audioAsset)

        let deletion = ProjectDeletionService(repository: repository, assetStore: assetStore)
        try await deletion.deleteMeeting(meetingID: meeting.id, fromProjectID: project.id)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: assetStore.url(for: asset).path),
            "An unreachable recording must not be left in Application Support."
        )
        let loadedProject = try await repository.project(id: project.id)
        let stored = try XCTUnwrap(loadedProject)
        XCTAssertTrue(stored.meetings.isEmpty)
    }

    func testDeletingTheProjectDeletesEveryMeetingsStoredAudio() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "HAE.NA")
        let first = try await importMeeting(into: project.id, service: service, fileName: "one.m4a")
        let second = try await importMeeting(into: project.id, service: service, fileName: "two.wav")
        let assets = [try XCTUnwrap(first.audioAsset), try XCTUnwrap(second.audioAsset)]

        let deletion = ProjectDeletionService(repository: repository, assetStore: assetStore)
        try await deletion.deleteProject(id: project.id)

        for asset in assets {
            XCTAssertFalse(FileManager.default.fileExists(atPath: assetStore.url(for: asset).path))
        }
        let stored = try await repository.project(id: project.id)
        XCTAssertNil(stored)
    }

    /// Deleting one meeting must not take another meeting's recording with it.
    func testDeletingOneMeetingLeavesTheOtherMeetingsAudioIntact() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "HAE.NA")
        let kept = try await importMeeting(into: project.id, service: service, fileName: "kept.m4a")
        let removed = try await importMeeting(into: project.id, service: service, fileName: "removed.m4a")

        let deletion = ProjectDeletionService(repository: repository, assetStore: assetStore)
        try await deletion.deleteMeeting(meetingID: removed.id, fromProjectID: project.id)

        let keptAsset = try XCTUnwrap(kept.audioAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: assetStore.url(for: keptAsset).path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: assetStore.url(for: try XCTUnwrap(removed.audioAsset)).path)
        )
    }

    /// Deleting a pasted-text meeting has no audio to remove and must not be disturbed by the
    /// audio policy at all.
    func testDeletingATextMeetingIsUnaffectedByTheAudioPolicy() async throws {
        let textService = TextMeetingCaptureService(repository: repository)
        let project = try await textService.createProject(name: "HAE.NA")
        let meeting = try await textService.saveTextMeeting(
            projectID: project.id,
            title: "붙여넣은 회의",
            transcript: "내용"
        )

        let deletion = ProjectDeletionService(repository: repository, assetStore: assetStore)
        try await deletion.deleteMeeting(meetingID: meeting.id, fromProjectID: project.id)

        let loadedProject = try await repository.project(id: project.id)
        let stored = try XCTUnwrap(loadedProject)
        XCTAssertTrue(stored.meetings.isEmpty)
    }

    // MARK: - Mixed sources

    /// Audio import must not disturb the pasted-text flow that already shipped.
    func testAudioAndTextMeetingsCoexistInOneProject() async throws {
        let service = makeCaptureService()
        let project = try await service.createProject(name: "HAE.NA")

        let textService = TextMeetingCaptureService(repository: repository)
        _ = try await textService.saveTextMeeting(
            projectID: project.id,
            title: "붙여넣은 회의",
            transcript: "우리는 2월 출시로 가기로 했습니다."
        )
        _ = try await importMeeting(into: project.id, service: service)

        let loadedProject = try await repository.project(id: project.id)
        let stored = try XCTUnwrap(loadedProject)
        XCTAssertEqual(stored.meetings.count, 2)
        XCTAssertEqual(Set(stored.meetings.map(\.sourceType)), [.pastedText, .audioFile])
        XCTAssertEqual(stored.meetings.filter { $0.audioAsset != nil }.count, 1)
    }
}
