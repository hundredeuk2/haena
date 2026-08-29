import XCTest
@testable import HAENA

final class PastedSpeakerExtractionContractTests: XCTestCase {
    func testExtractorReceivesExactSourceLabelRatherThanParticipantNameOrStoredSpeakerLabel() {
        let participant = Participant(
            id: TestFixtures.participantID,
            displayName: "현재 회의 참석자",
            linkedUserID: nil,
            speakerLabel: "legacy-participant-label"
        )
        let meeting = Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "Paste",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: [participant],
            transcriptSegments: [
                TranscriptSegment(
                    id: TestFixtures.segmentID,
                    meetingID: TestFixtures.meetingID,
                    speakerID: participant.id,
                    sourceSpeakerLabel: "SOURCE_A",
                    text: "제가 맡겠습니다.",
                    startTime: nil,
                    endTime: nil
                )
            ],
            createdAt: TestFixtures.fixedDate
        )

        let input = WorkStateExtractionInput(meeting: meeting)

        XCTAssertEqual(input.excerpts.map(\.speakerLabel), ["SOURCE_A"])
        XCTAssertFalse(Mirror(reflecting: input.excerpts[0]).children.contains { child in
            child.label == "speakerID" || child.value as? UUID == participant.id
        })
    }

    func testUnlinkedSourceLabelStillReachesExtractorWithoutParticipantIdentity() {
        let meeting = Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "Paste",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: [],
            transcriptSegments: [
                TranscriptSegment(
                    id: TestFixtures.segmentID,
                    meetingID: TestFixtures.meetingID,
                    speakerID: nil,
                    sourceSpeakerLabel: "C",
                    text: "담당자는 아직 없습니다.",
                    startTime: nil,
                    endTime: nil
                )
            ],
            createdAt: TestFixtures.fixedDate
        )

        XCTAssertEqual(WorkStateExtractionInput(meeting: meeting).excerpts[0].speakerLabel, "C")
    }
}
