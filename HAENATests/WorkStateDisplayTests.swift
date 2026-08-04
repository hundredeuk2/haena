import XCTest
@testable import HAENA

final class WorkStateDisplayTests: XCTestCase {
    private let formatter = MeetingDateFormatter(
        locale: Locale(identifier: "ko_KR"),
        timeZone: TimeZone(identifier: "Asia/Seoul")!
    )

    func testEveryStatusHasNonEmptyKoreanCopy() {
        let decisionLabels = [DecisionStatus.proposed, .confirmed, .superseded, .rejected]
            .map(WorkStateDisplay.label(for:))
        let actionLabels = [ActionItemStatus.proposed, .confirmed, .inProgress, .completed, .cancelled]
            .map(WorkStateDisplay.label(for:))
        let questionLabels = [OpenQuestionStatus.open, .resolved, .dismissed]
            .map(WorkStateDisplay.label(for:))
        let agendaLabels = [AgendaItemStatus.pending, .resolved, .dismissed]
            .map(WorkStateDisplay.label(for:))

        for label in decisionLabels + actionLabels + questionLabels + agendaLabels {
            XCTAssertFalse(label.isEmpty)
        }
        XCTAssertEqual(Set(questionLabels).count, 3, "each question status must read differently")
        XCTAssertEqual(Set(agendaLabels).count, 3, "dismissed must not read the same as resolved")
    }

    func testProposalKindLabels() {
        XCTAssertEqual(WorkStateDisplay.label(for: WorkStateProposal.Kind.decision), "결정")
        XCTAssertEqual(WorkStateDisplay.label(for: WorkStateProposal.Kind.actionItem), "업무")
        XCTAssertEqual(WorkStateDisplay.label(for: WorkStateProposal.Kind.openQuestion), "미해결 질문")
        XCTAssertEqual(WorkStateDisplay.label(for: WorkStateProposal.Kind.agendaItem), "다음 아젠다")
    }

    func testConfidenceIsShownAsAWholePercentage() {
        XCTAssertEqual(WorkStateDisplay.confidenceLabel(Confidence(0.92)), "확신도 92%")
        XCTAssertEqual(WorkStateDisplay.confidenceLabel(Confidence(1.0)), "확신도 100%")
        XCTAssertEqual(WorkStateDisplay.confidenceLabel(Confidence(0.0)), "확신도 0%")
    }

    func testMissingConfidenceShowsNothingRatherThanZero() {
        XCTAssertNil(
            WorkStateDisplay.confidenceLabel(nil),
            "a hand-entered item has no model confidence; 0% would read as certainty that it is wrong"
        )
    }

    func testDueDateLabelOmitsTheTimeComponent() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)

        let label = try? XCTUnwrap(WorkStateDisplay.dueDateLabel(due, formatter: formatter))

        XCTAssertNotNil(label)
        XCTAssertTrue(label?.hasPrefix("마감 ") == true)
        XCTAssertFalse(label?.contains(":") == true, "a stated day must not gain an implied clock time")
    }

    func testMissingDueDateHasNoLabel() {
        XCTAssertNil(WorkStateDisplay.dueDateLabel(nil, formatter: formatter))
    }

    func testAssigneeLabelResolvesAParticipantAndFallsBackWhenUnset() {
        let participants = [ReviewFixtures.assignee, ReviewFixtures.otherParticipant]

        XCTAssertEqual(
            WorkStateDisplay.assigneeLabel(ReviewFixtures.assignee.id, participants: participants),
            "담당 서연"
        )
        XCTAssertEqual(WorkStateDisplay.assigneeLabel(nil, participants: participants), "담당자 미지정")
        XCTAssertEqual(
            WorkStateDisplay.assigneeLabel(UUID(), participants: participants),
            "담당자 미지정",
            "an id that matches nobody must not render as a blank name"
        )
    }
}
