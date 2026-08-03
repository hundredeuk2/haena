import XCTest
@testable import HAENA

final class DecisionActionItemTests: XCTestCase {
    func testDecisionProposedVersusConfirmedAreDistinctStatuses() {
        var decision = Decision(
            id: UUID(),
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            statement: "Ship the v1 API by next sprint",
            rationale: nil,
            status: .proposed,
            evidence: nil,
            confidence: Confidence(0.6),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
        XCTAssertEqual(decision.status, .proposed)

        decision.status = .confirmed
        XCTAssertEqual(decision.status, .confirmed)
        XCTAssertNotEqual(DecisionStatus.proposed, DecisionStatus.confirmed)
    }

    func testActionItemWithoutAssigneeOrDueDate() {
        let actionItem = ActionItem(
            id: UUID(),
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            title: "확인해보시죠",
            details: nil,
            assigneeID: nil,
            dueDate: nil,
            status: .proposed,
            evidence: nil,
            confidence: Confidence(0.4),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )

        XCTAssertNil(actionItem.assigneeID)
        XCTAssertNil(actionItem.dueDate)
        XCTAssertEqual(actionItem.status, .proposed)
    }

    func testActionItemStatusCoversAllRequiredCases() {
        let allCases: [ActionItemStatus] = [.proposed, .confirmed, .inProgress, .completed, .cancelled]
        XCTAssertEqual(Set(allCases).count, 5)
    }
}
