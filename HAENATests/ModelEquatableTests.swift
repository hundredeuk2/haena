import XCTest
@testable import HAENA

final class ModelEquatableTests: XCTestCase {
    func testParticipantEquatable() {
        let a = Participant(id: TestFixtures.participantID, displayName: "김철수", linkedUserID: nil, speakerLabel: "Speaker 1")
        let b = a
        var c = a
        c.displayName = "이영희"

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testDecisionEquatable() {
        let a = Decision(
            id: UUID(),
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            statement: "동일 문구",
            rationale: nil,
            status: .proposed,
            evidence: nil,
            confidence: Confidence(0.5),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
        let b = a
        var c = a
        c.status = .confirmed

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testMeetingEquatable() {
        let a = Meeting(
            id: TestFixtures.meetingID,
            projectID: TestFixtures.projectID,
            title: "Kickoff",
            occurredAt: TestFixtures.fixedDate,
            sourceType: .microphone,
            participants: [],
            transcriptSegments: [],
            createdAt: TestFixtures.fixedDate
        )
        let b = a
        var c = a
        c.title = "Kickoff (renamed)"

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
