import XCTest
@testable import HAENA

final class OpenQuestionAgendaTests: XCTestCase {
    func testOpenQuestionStatusTransitionsFromOpenToResolved() {
        var question = OpenQuestion(
            id: UUID(),
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            question: "Voice 모델 제공사를 확정할까요?",
            status: .open,
            evidence: nil,
            confidence: Confidence(0.5),
            createdAt: TestFixtures.fixedDate,
            resolvedAt: nil
        )
        XCTAssertEqual(question.status, .open)
        XCTAssertNil(question.resolvedAt)

        question.status = .resolved
        question.resolvedAt = TestFixtures.fixedDate
        XCTAssertEqual(question.status, .resolved)
        XCTAssertNotNil(question.resolvedAt)
    }

    func testEvidenceReferenceLinksBackToTranscriptSegment() {
        let segment = TranscriptSegment(
            id: TestFixtures.segmentID,
            meetingID: TestFixtures.meetingID,
            speakerID: TestFixtures.participantID,
            text: "이 부분은 한번 검증해주세요.",
            startTime: 120,
            endTime: 128
        )

        let evidence = EvidenceReference(
            meetingID: segment.meetingID,
            transcriptSegmentID: segment.id,
            quote: segment.text
        )

        XCTAssertEqual(evidence.meetingID, segment.meetingID)
        XCTAssertEqual(evidence.transcriptSegmentID, segment.id)
        XCTAssertEqual(evidence.quote, segment.text)
    }

    func testAgendaItemAllowsNoRelatedActionItemOrOpenQuestion() {
        let agendaItem = AgendaItem(
            id: UUID(),
            projectID: TestFixtures.projectID,
            title: "다음 회의에서 예산 재검토",
            reason: "지난 회의에서 결론이 나지 않음",
            sourceMeetingID: nil,
            relatedActionItemID: nil,
            relatedOpenQuestionID: nil,
            status: .pending,
            createdAt: TestFixtures.fixedDate
        )

        XCTAssertNil(agendaItem.sourceMeetingID)
        XCTAssertNil(agendaItem.relatedActionItemID)
        XCTAssertNil(agendaItem.relatedOpenQuestionID)
        XCTAssertEqual(agendaItem.status, .pending)
    }
}
