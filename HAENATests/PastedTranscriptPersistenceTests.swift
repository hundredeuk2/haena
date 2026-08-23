import XCTest
@testable import HAENA

final class PastedTranscriptPersistenceTests: XCTestCase {
    func testLegacyTranscriptSegmentJSONWithoutSourceLabelDecodesAsNil() throws {
        let json = #"""
        {
          "id":"00000000-0000-0000-0000-000000000004",
          "meetingID":"00000000-0000-0000-0000-000000000002",
          "speakerID":null,
          "text":"legacy transcript",
          "startTime":null,
          "endTime":null
        }
        """#.data(using: .utf8)!

        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)

        XCTAssertNil(segment.sourceSpeakerLabel)
        XCTAssertEqual(segment.text, "legacy transcript")
    }

    func testNewSourceLabelAndParticipantLinkRoundTripThroughCodable() throws {
        let segment = TranscriptSegment(
            id: TestFixtures.segmentID,
            meetingID: TestFixtures.meetingID,
            speakerID: TestFixtures.participantID,
            sourceSpeakerLabel: "Speaker A",
            text: "제가 담당하겠습니다.",
            startTime: nil,
            endTime: nil
        )

        let restored = try JSONDecoder().decode(
            TranscriptSegment.self,
            from: JSONEncoder().encode(segment)
        )

        XCTAssertEqual(restored, segment)
        XCTAssertEqual(restored.sourceSpeakerLabel, "Speaker A")
        XCTAssertEqual(restored.speakerID, TestFixtures.participantID)
    }

    func testRepositoryRestartPreservesMeetingRosterLabelsAndUUIDLinks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-PastedTranscript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("projects.json")
        let writer = JSONProjectRepository(fileURL: fileURL)
        let project = Project(
            id: TestFixtures.projectID,
            name: "Persistence",
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: [],
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )
        try await writer.save(project)

        let ids = AudioTestSupport.IDSequence()
        let participantDraftID = UUID()
        let storedMeeting = try await TextMeetingCaptureService(
            repository: writer,
            now: { TestFixtures.laterDate },
            makeID: { ids.next() }
        ).saveTextMeeting(
            projectID: project.id,
            title: "재실행 회의",
            draft: PastedTranscriptDraft(
                participants: [
                    PastedParticipantDraft(
                        id: participantDraftID,
                        displayName: "참석자 A",
                        provenance: .userEntered
                    )
                ],
                turns: [
                    PastedTranscriptTurnDraft(
                        id: UUID(),
                        text: "제가 이 업무를 맡겠습니다.",
                        sourceSpeakerLabel: "A",
                        selectedParticipantDraftID: participantDraftID
                    ),
                    PastedTranscriptTurnDraft(
                        id: UUID(),
                        text: "연결하지 않은 발언입니다.",
                        sourceSpeakerLabel: "C",
                        selectedParticipantDraftID: nil
                    )
                ]
            )
        )

        let relaunched = JSONProjectRepository(fileURL: fileURL)
        let reloaded = try await relaunched.project(id: project.id)
        let restoredProject = try XCTUnwrap(reloaded)
        let restoredMeeting = try XCTUnwrap(restoredProject.meetings.first)

        XCTAssertEqual(restoredMeeting.id, storedMeeting.id)
        XCTAssertEqual(restoredMeeting.participants, storedMeeting.participants)
        XCTAssertEqual(restoredMeeting.transcriptSegments, storedMeeting.transcriptSegments)
        XCTAssertEqual(restoredMeeting.transcriptSegments[0].speakerID, restoredMeeting.participants[0].id)
        XCTAssertEqual(restoredMeeting.transcriptSegments[0].sourceSpeakerLabel, "A")
        XCTAssertNil(restoredMeeting.transcriptSegments[1].speakerID)
        XCTAssertEqual(restoredMeeting.transcriptSegments[1].sourceSpeakerLabel, "C")
    }
}
