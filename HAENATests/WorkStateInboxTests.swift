import XCTest
@testable import HAENA

final class WorkStateInboxTests: XCTestCase {
    func testPendingInboxHoldsOneProposalOfEachKind() {
        let proposals = WorkStateInbox.pendingProposals(in: ReviewFixtures.project())

        XCTAssertEqual(proposals.map(\.kind), [.decision, .actionItem, .openQuestion, .agendaItem])
    }

    func testProposalsExposeHeadlineConfidenceAndEvidence() {
        let proposals = WorkStateInbox.pendingProposals(in: ReviewFixtures.project())

        let decision = try? XCTUnwrap(proposals.first)
        XCTAssertEqual(decision?.headline, "2월 출시로 진행한다")
        XCTAssertEqual(decision?.confidence, Confidence(0.8))
        XCTAssertEqual(decision?.evidence, ReviewFixtures.evidence)
    }

    func testReviewedItemsDropOutOfThePendingInbox() {
        let project = ReviewFixtures.project(
            decisions: [ReviewFixtures.decision(status: .confirmed)],
            actionItems: [ReviewFixtures.actionItem(status: .confirmed)],
            openQuestions: [ReviewFixtures.openQuestion(reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [ReviewFixtures.agendaItem(reviewedAt: TestFixtures.laterDate)]
        )

        XCTAssertTrue(WorkStateInbox.pendingProposals(in: project).isEmpty)
    }

    func testExcludedItemsDoNotReturnToThePendingInbox() {
        let project = ReviewFixtures.project(
            decisions: [ReviewFixtures.decision(status: .rejected)],
            actionItems: [ReviewFixtures.actionItem(status: .cancelled)],
            openQuestions: [ReviewFixtures.openQuestion(status: .dismissed, reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [ReviewFixtures.agendaItem(status: .dismissed, reviewedAt: TestFixtures.laterDate)]
        )

        XCTAssertTrue(WorkStateInbox.pendingProposals(in: project).isEmpty)
    }

    func testEvidencelessItemsOfAnyKindAreNotTreatedAsAIProposals() {
        // No evidence means no model produced it, so there is nothing for a user to review —
        // across all four types, not just AgendaItem.
        var decision = ReviewFixtures.decision(status: .proposed)
        decision.evidence = nil
        var actionItem = ReviewFixtures.actionItem(status: .proposed)
        actionItem.evidence = nil
        var question = ReviewFixtures.openQuestion()
        question.evidence = nil

        let project = ReviewFixtures.project(
            decisions: [decision],
            actionItems: [actionItem],
            openQuestions: [question],
            nextAgenda: [ReviewFixtures.agendaItem(evidence: nil)]
        )

        XCTAssertTrue(WorkStateInbox.pendingProposals(in: project).isEmpty)
    }

    func testPendingOrderIsTotalAndStable() {
        let project = ReviewFixtures.project()

        let first = WorkStateInbox.pendingProposals(in: project)
        let second = WorkStateInbox.pendingProposals(in: project)

        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    // MARK: - Reviewed sections

    func testConfirmedDecisionsFormTheDecisionLog() {
        let project = ReviewFixtures.project(
            decisions: [ReviewFixtures.decision(status: .confirmed)]
        )

        XCTAssertEqual(WorkStateInbox.confirmedDecisions(in: project).count, 1)
    }

    func testRejectedDecisionsAreNotInTheDecisionLog() {
        let project = ReviewFixtures.project(
            decisions: [ReviewFixtures.decision(status: .rejected)]
        )

        XCTAssertTrue(WorkStateInbox.confirmedDecisions(in: project).isEmpty)
    }

    func testActiveWorkCoversConfirmedAndInProgressButNotCancelledOrCompleted() {
        func project(_ status: ActionItemStatus) -> Project {
            ReviewFixtures.project(actionItems: [ReviewFixtures.actionItem(status: status)])
        }

        XCTAssertEqual(WorkStateInbox.activeActionItems(in: project(.confirmed)).count, 1)
        XCTAssertEqual(WorkStateInbox.activeActionItems(in: project(.inProgress)).count, 1)
        XCTAssertTrue(WorkStateInbox.activeActionItems(in: project(.cancelled)).isEmpty)
        XCTAssertTrue(WorkStateInbox.activeActionItems(in: project(.completed)).isEmpty)
        XCTAssertTrue(WorkStateInbox.activeActionItems(in: project(.proposed)).isEmpty)
    }

    func testReviewedOpenQuestionsExcludeUnreviewedAndResolvedOnes() {
        let unreviewed = ReviewFixtures.project(openQuestions: [ReviewFixtures.openQuestion()])
        XCTAssertTrue(WorkStateInbox.reviewedOpenQuestions(in: unreviewed).isEmpty)

        let reviewed = ReviewFixtures.project(
            openQuestions: [ReviewFixtures.openQuestion(reviewedAt: TestFixtures.laterDate)]
        )
        XCTAssertEqual(WorkStateInbox.reviewedOpenQuestions(in: reviewed).count, 1)

        let resolved = ReviewFixtures.project(
            openQuestions: [ReviewFixtures.openQuestion(status: .resolved, reviewedAt: TestFixtures.laterDate)]
        )
        XCTAssertTrue(WorkStateInbox.reviewedOpenQuestions(in: resolved).isEmpty)
    }

    func testReviewedAgendaItemsExcludeUnreviewedAndDismissedOnes() {
        let unreviewed = ReviewFixtures.project(nextAgenda: [ReviewFixtures.agendaItem()])
        XCTAssertTrue(WorkStateInbox.reviewedAgendaItems(in: unreviewed).isEmpty)

        let reviewed = ReviewFixtures.project(
            nextAgenda: [ReviewFixtures.agendaItem(reviewedAt: TestFixtures.laterDate)]
        )
        XCTAssertEqual(WorkStateInbox.reviewedAgendaItems(in: reviewed).count, 1)

        let dismissed = ReviewFixtures.project(
            nextAgenda: [ReviewFixtures.agendaItem(status: .dismissed, reviewedAt: TestFixtures.laterDate)]
        )
        XCTAssertTrue(WorkStateInbox.reviewedAgendaItems(in: dismissed).isEmpty)
    }
}
