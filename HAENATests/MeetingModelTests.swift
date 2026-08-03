import XCTest
@testable import HAENA

final class MeetingModelTests: XCTestCase {
    func testMeetingRepresentsPastedTextSource() {
        let meeting = Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "Pasted meeting notes",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .pastedText,
            participants: [],
            transcriptSegments: [],
            createdAt: TestFixtures.fixedDate
        )

        XCTAssertEqual(meeting.sourceType, .pastedText)
    }

    func testTranscriptSegmentWithoutTimestampsForPastedText() {
        let segment = TranscriptSegment(
            id: TestFixtures.segmentID,
            meetingID: TestFixtures.meetingID,
            speakerID: TestFixtures.participantID,
            text: "다음 스프린트에 배포하기로 했습니다.",
            startTime: nil,
            endTime: nil
        )

        XCTAssertNil(segment.startTime)
        XCTAssertNil(segment.endTime)
    }

    func testMeetingSourceTypeCoversAllRequiredCases() {
        let allCases: [MeetingSourceType] = [.microphone, .audioFile, .videoFile, .pastedText]
        XCTAssertEqual(Set(allCases).count, 4)
    }
}
