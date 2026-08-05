import XCTest
@testable import HAENA

/// Direct tests of the one function both the review inbox and re-extraction now share. Anything
/// wrong here would be wrong in both places at once — which is the point of centralizing it.
final class PendingAIProposalPolicyTests: XCTestCase {
    // MARK: - Decision

    func testDecisionIsPendingWhenProposedWithEvidence() {
        XCTAssertTrue(PendingAIProposalPolicy.isPending(ReviewFixtures.decision(status: .proposed)))
    }

    func testProposedDecisionWithoutEvidenceIsNotPending() {
        var decision = ReviewFixtures.decision(status: .proposed)
        decision.evidence = nil
        XCTAssertFalse(PendingAIProposalPolicy.isPending(decision))
    }

    func testConfirmedOrRejectedDecisionIsNotPending() {
        XCTAssertFalse(PendingAIProposalPolicy.isPending(ReviewFixtures.decision(status: .confirmed)))
        XCTAssertFalse(PendingAIProposalPolicy.isPending(ReviewFixtures.decision(status: .rejected)))
    }

    // MARK: - ActionItem

    func testActionItemIsPendingWhenProposedWithEvidence() {
        XCTAssertTrue(PendingAIProposalPolicy.isPending(ReviewFixtures.actionItem(status: .proposed)))
    }

    func testProposedActionItemWithoutEvidenceIsNotPending() {
        var item = ReviewFixtures.actionItem(status: .proposed)
        item.evidence = nil
        XCTAssertFalse(PendingAIProposalPolicy.isPending(item))
    }

    func testConfirmedOrCancelledActionItemIsNotPending() {
        XCTAssertFalse(PendingAIProposalPolicy.isPending(ReviewFixtures.actionItem(status: .confirmed)))
        XCTAssertFalse(PendingAIProposalPolicy.isPending(ReviewFixtures.actionItem(status: .cancelled)))
    }

    // MARK: - OpenQuestion

    func testOpenQuestionIsPendingWhenOpenUnreviewedWithEvidence() {
        XCTAssertTrue(PendingAIProposalPolicy.isPending(ReviewFixtures.openQuestion()))
    }

    func testOpenQuestionWithoutEvidenceIsNotPending() {
        var question = ReviewFixtures.openQuestion()
        question.evidence = nil
        XCTAssertFalse(PendingAIProposalPolicy.isPending(question))
    }

    func testApprovedOpenQuestionIsNotPending() {
        XCTAssertFalse(PendingAIProposalPolicy.isPending(ReviewFixtures.openQuestion(reviewedAt: TestFixtures.laterDate)))
    }

    func testDismissedOrResolvedOpenQuestionIsNotPending() {
        XCTAssertFalse(
            PendingAIProposalPolicy.isPending(
                ReviewFixtures.openQuestion(status: .dismissed, reviewedAt: TestFixtures.laterDate)
            )
        )
        XCTAssertFalse(
            PendingAIProposalPolicy.isPending(
                ReviewFixtures.openQuestion(status: .resolved, reviewedAt: TestFixtures.laterDate)
            )
        )
    }

    // MARK: - AgendaItem

    func testAgendaItemIsPendingWhenPendingUnreviewedWithEvidence() {
        XCTAssertTrue(PendingAIProposalPolicy.isPending(ReviewFixtures.agendaItem()))
    }

    func testAgendaItemWithoutEvidenceIsNotPending() {
        XCTAssertFalse(PendingAIProposalPolicy.isPending(ReviewFixtures.agendaItem(evidence: nil)))
    }

    func testApprovedAgendaItemIsNotPending() {
        XCTAssertFalse(PendingAIProposalPolicy.isPending(ReviewFixtures.agendaItem(reviewedAt: TestFixtures.laterDate)))
    }

    func testDismissedOrResolvedAgendaItemIsNotPending() {
        XCTAssertFalse(
            PendingAIProposalPolicy.isPending(
                ReviewFixtures.agendaItem(status: .dismissed, reviewedAt: TestFixtures.laterDate)
            )
        )
        XCTAssertFalse(
            PendingAIProposalPolicy.isPending(
                ReviewFixtures.agendaItem(status: .resolved, reviewedAt: TestFixtures.laterDate)
            )
        )
    }
}
