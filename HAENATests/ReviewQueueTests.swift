#if DEBUG
import XCTest
@testable import HAENA

@MainActor
final class ReviewQueueTests: XCTestCase {
    private typealias F = ReviewQueueUITestSeed
    private var project: Project { F.project() }
    private func entries(_ p: Project) -> [ReviewQueue.Entry] { ReviewQueue(project: p).groups.flatMap(\.entries) }

    func testFiniteOptInAndNoEnvironmentPayload() {
        for env in [[:], ["HAENA_UI_TEST_REVIEW_QUEUE": "queue"],
                    ["HAENA_UI_TESTING": "1", "HAENA_UI_TEST_REVIEW_QUEUE": "unknown"]] {
            XCTAssertNil(F.select(environment: env))
        }
        XCTAssertEqual(F.select(environment: ["HAENA_UI_TESTING": "1", "HAENA_UI_TEST_REVIEW_QUEUE": "queue", "path": "ignored"]), project)
    }
    func testAllKindsGroupByExactOwningMeeting() {
        let queue = ReviewQueue(project: project)
        XCTAssertEqual(queue.pendingCount, 5)
        XCTAssertEqual(queue.groups.map(\.id), [F.id(2), F.id(3)])
        XCTAssertEqual(queue.groups.map(\.pendingCount), [4, 1])
        XCTAssertEqual(queue.groups[0].entries.map { $0.proposal.kind }, WorkStateProposal.Kind.allCases)
    }
    func testStableOrderingDoesNotDependOnArrayOrderOrTitles() {
        var shuffled = project
        shuffled.meetings.reverse(); shuffled.decisions.reverse(); shuffled.actionItems.reverse()
        shuffled.openQuestions.reverse(); shuffled.nextAgenda.reverse()
        XCTAssertEqual(ReviewQueue(project: project), ReviewQueue(project: shuffled))
        XCTAssertEqual(entries(project).filter { $0.proposal.kind == .actionItem }.map { $0.proposal.headline },
                       ["Synthetic pending action", "Synthetic pending action"])
        XCTAssertEqual(Set(entries(project).map(\.id)).count, 5)
    }
    func testEveryFilterKeepsTotalAndGroupCounts() {
        let queue = ReviewQueue(project: project)
        XCTAssertEqual(ReviewQueueFilter.allCases.map(queue.count), [5, 1, 2, 1, 1])
        for filter in ReviewQueueFilter.allCases {
            XCTAssertEqual(queue.pendingCount, 5)
            XCTAssertEqual(queue.groups.map(\.pendingCount), [4, 1])
            XCTAssertTrue(queue.groups.flatMap { $0.visible(filter) }.allSatisfy { filter.kind == nil || $0.proposal.kind == filter.kind })
        }
    }
    func testApprovedExcludedAndNonProposalsNeverEnterQueue() {
        var p = project
        p.decisions[1].status = .rejected
        p.actionItems[1].status = .completed
        p.actionItems[2].evidence = nil
        p.openQuestions[1].status = .dismissed
        p.nextAgenda[1].reviewedAt = p.createdAt
        XCTAssertEqual(ReviewQueue(project: p).pendingCount, 0)
        XCTAssertEqual(ReviewQueue(project: F.project(.empty)).pendingCount, 0)
    }
    func testMissingSegmentsPreserveExactQuoteButNeverTimestamp() {
        let queue = ReviewQueue(project: F.project(.missingSource))
        XCTAssertEqual(queue.pendingCount, 5)
        for entry in queue.groups[0].entries {
            XCTAssertEqual(entry.sourceIssue, .missingSegment)
            XCTAssertNil(entry.timestamp)
            XCTAssertEqual(entry.proposal.evidence?.quote, "Synthetic exact source quote.")
            XCTAssertEqual(entry.proposal.evidence?.transcriptSegmentID, F.id(4))
        }
    }
    func testDanglingMeetingKeepsItsOwnGroupAndDoesNotRetarget() {
        var p = project; p.meetings.removeFirst()
        let group = ReviewQueue(project: p).groups.first { $0.id == F.id(2) }
        XCTAssertNil(group?.meeting)
        XCTAssertEqual(group?.entries.count, 4)
        XCTAssertTrue(group!.entries.allSatisfy { $0.sourceIssue == .missingMeeting && $0.timestamp == nil })
    }
    func testNoOwningMeetingStaysSeparateFromEvidenceMeeting() {
        var p = project; p.nextAgenda[1].sourceMeetingID = nil
        let group = ReviewQueue(project: p).groups.first { $0.id == nil }
        XCTAssertEqual(group?.entries.first?.sourceIssue, .noOwningMeeting)
        XCTAssertEqual(group?.entries.first?.proposal.id, F.id(103))
    }
    func testCrossMeetingEvidenceDoesNotBorrowTimestamp() {
        var p = project
        p.actionItems[1].evidence = p.actionItems[2].evidence
        let entry = entries(p).first { $0.proposal.id == F.id(101) }
        XCTAssertEqual(entry?.sourceIssue, .differentMeeting)
        XCTAssertNil(entry?.timestamp)
        XCTAssertEqual(entry?.proposal.meetingID, F.id(2))
    }
    func testExactTimestampAndUntimedSourceRemainDistinct() {
        let all = entries(project)
        XCTAssertEqual(all.first { $0.proposal.id == F.id(100) }?.timestamp, "01:05")
        let untimed = all.first { $0.proposal.id == F.id(104) }
        XCTAssertNil(untimed?.timestamp); XCTAssertNil(untimed?.sourceIssue)
    }
    func testEditAvailableOnlyForActions() {
        for entry in entries(project) { XCTAssertEqual(entry.canEdit, entry.proposal.kind == .actionItem) }
    }
    func testAllFourApprovedSelectionsUseExactTypedOwner() {
        let selections: [ProjectWorkStateSelection] = [.decision(F.id(200)), .actionItem(F.id(201)), .openQuestion(F.id(202)), .agendaItem(F.id(203))]
        for selection in selections {
            let route = BrowserDestination(projectID: project.id, target: .approvedWorkState(selection))
            var nav = AppShellNavigation(); nav.open(route)
            XCTAssertEqual(nav.destination, .projects); XCTAssertEqual(nav.workStateSelection, selection)
            XCTAssertNotNil(selection.proposal(in: project))
        }
    }
    func testOwnerIsNotInferredFromOptionalID() {
        var nav = AppShellNavigation()
        nav.open(.init(projectID: project.id, target: .approvedWorkState(nil)))
        XCTAssertEqual(nav.destination, .projects)
        nav.open(.init(projectID: project.id, target: .pendingReview))
        XCTAssertEqual(nav.destination, .review); XCTAssertNil(nav.workStateSelection)
        nav.select(.projects); XCTAssertEqual(nav.projectPane, .status)
    }
    func testWrongKindMissingOrPendingApprovedSelectionDoesNotResolve() {
        XCTAssertNil(ProjectWorkStateSelection.decision(F.id(201)).proposal(in: project))
        XCTAssertNil(ProjectWorkStateSelection.actionItem(F.id(101)).proposal(in: project))
        XCTAssertNil(ProjectWorkStateSelection.agendaItem(F.id(999)).proposal(in: project))
    }
    func testPresentationPreservesSerializedCanonicalData() throws {
        let p = project; let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(p)
        for filter in ReviewQueueFilter.allCases { _ = ReviewQueue(project: p).count(filter) }
        XCTAssertEqual(try encoder.encode(p), before)
    }
    func testApproveOnlyExactDecisionAndReloadCounts() async throws {
        let p = project; let repo = InMemoryProjectRepository(projects: [p])
        try await WorkStateReviewService(repository: repo).approveDecision(id: F.id(100), in: p.id)
        let loaded = try await repo.project(id: p.id); let after = try XCTUnwrap(loaded)
        XCTAssertEqual(after.decisions[1].status, .confirmed)
        XCTAssertEqual(after.actionItems, p.actionItems); XCTAssertEqual(after.openQuestions, p.openQuestions)
        XCTAssertEqual(after.nextAgenda, p.nextAgenda); XCTAssertEqual(after.meetings, p.meetings)
        XCTAssertEqual(ReviewQueue(project: after).pendingCount, 4)
        XCTAssertNotNil(ProjectWorkStateSelection.decision(F.id(100)).proposal(in: after))
    }
    func testExcludeOnlyExactQuestionAndNeverPromoteIt() async throws {
        let p = project; let repo = InMemoryProjectRepository(projects: [p])
        try await WorkStateReviewService(repository: repo).dismissOpenQuestion(id: F.id(102), in: p.id)
        let loaded = try await repo.project(id: p.id); let after = try XCTUnwrap(loaded)
        XCTAssertEqual(after.openQuestions[1].status, .dismissed)
        XCTAssertEqual(after.decisions, p.decisions); XCTAssertEqual(after.actionItems, p.actionItems)
        XCTAssertEqual(after.nextAgenda, p.nextAgenda); XCTAssertEqual(after.meetings, p.meetings)
        XCTAssertEqual(ReviewQueue(project: after).pendingCount, 4)
        XCTAssertNil(ProjectWorkStateSelection.openQuestion(F.id(102)).proposal(in: after))
    }
    func testExplicitOwnerDueEditDoesNotApproveOrTouchSameTitleSibling() async throws {
        let p = project; let repo = InMemoryProjectRepository(projects: [p])
        try await WorkStateReviewService(repository: repo).updateActionItem(id: F.id(101), in: p.id, assigneeID: nil, dueDate: nil)
        let loaded = try await repo.project(id: p.id); let after = try XCTUnwrap(loaded)
        XCTAssertEqual(after.actionItems[1].status, .proposed)
        XCTAssertNil(after.actionItems[1].assigneeID); XCTAssertNil(after.actionItems[1].dueDate)
        XCTAssertEqual(after.actionItems[1].evidence, p.actionItems[1].evidence)
        XCTAssertEqual(after.actionItems[2], p.actionItems[2]); XCTAssertEqual(after.meetings, p.meetings)
        XCTAssertEqual(ReviewQueue(project: after).pendingCount, 5)
    }
    func testAllKindsLeavePendingOnlyAfterExplicitApproval() async throws {
        let p = project; let repo = InMemoryProjectRepository(projects: [p]); let service = WorkStateReviewService(repository: repo)
        try await service.approveDecision(id: F.id(100), in: p.id)
        try await service.approveActionItem(id: F.id(101), in: p.id)
        try await service.approveOpenQuestion(id: F.id(102), in: p.id)
        try await service.approveAgendaItem(id: F.id(103), in: p.id)
        let loaded = try await repo.project(id: p.id); let after = try XCTUnwrap(loaded)
        XCTAssertEqual(entries(after).map { $0.proposal.id }, [F.id(104)])
        XCTAssertEqual(after.meetings, p.meetings)
        XCTAssertEqual(after.actionItems.map(\.id), p.actionItems.map(\.id))
        XCTAssertEqual(after.decisions.map(\.id), p.decisions.map(\.id))
    }
    func testNewLabelsHaveKoreanAndEnglishResources() {
        for (filter, korean) in zip(ReviewQueueFilter.allCases, ["전체", "결정", "업무", "질문", "아젠다"]) {
            XCTAssertEqual(L10n.text(filter.localizationKey, language: .ko), korean)
            XCTAssertNotEqual(L10n.text(filter.localizationKey, language: .en), filter.localizationKey)
        }
        let keys = ["제안 종류", "미승인 후보", "마감일 미지정", "소유 회의를 찾을 수 없습니다."]
        for key in keys {
            XCTAssertEqual(L10n.text(key, language: .ko), key)
            XCTAssertNotEqual(L10n.text(key, language: .en), key)
        }
    }
}
#endif
