import XCTest
@testable import HAENA

/// The summary must never invent state, never promote an unreviewed proposal into the confirmed
/// sections, and never disagree with the review screen about what is pending — those three are
/// what these tests are guarding.
final class ProjectStatusSummaryTests: XCTestCase {
    private let reference = TestFixtures.fixedDate

    private func summary(_ project: Project) -> ProjectStatusSummary {
        ProjectStatusSummary(project: project, referenceDate: reference)
    }

    // MARK: - Unreviewed proposals stay out of confirmed state

    func testUnreviewedProposalsCountAsNeedsReviewAndNowhereElse() {
        // ReviewFixtures.project() is exactly one unreviewed proposal of each of the four kinds.
        let result = summary(ReviewFixtures.project())

        XCTAssertEqual(result.pendingProposalCount, 4)
        XCTAssertTrue(result.recentDecisions.isEmpty, "a proposed decision is not a confirmed one")
        XCTAssertTrue(result.activeActionItems.isEmpty)
        XCTAssertTrue(result.unresolvedQuestions.isEmpty)
        XCTAssertTrue(result.upcomingAgendaItems.isEmpty)
    }

    func testPendingCountMatchesTheReviewInbox() {
        let project = ReviewFixtures.project()

        XCTAssertEqual(
            summary(project).pendingProposalCount,
            WorkStateInbox.pendingProposals(in: project).count,
            "the summary and the review screen must never disagree about what is pending"
        )
    }

    func testApprovedItemsAppearInConfirmedSectionsAndLeaveTheReviewCount() {
        let project = ReviewFixtures.project(
            decisions: [ReviewFixtures.decision(status: .confirmed)],
            actionItems: [ReviewFixtures.actionItem(status: .confirmed)],
            openQuestions: [ReviewFixtures.openQuestion(reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [ReviewFixtures.agendaItem(reviewedAt: TestFixtures.laterDate)]
        )

        let result = summary(project)

        XCTAssertEqual(result.pendingProposalCount, 0)
        XCTAssertEqual(result.recentDecisions.totalCount, 1)
        XCTAssertEqual(result.activeActionItems.totalCount, 1)
        XCTAssertEqual(result.unresolvedQuestions.totalCount, 1)
        XCTAssertEqual(result.upcomingAgendaItems.totalCount, 1)
    }

    func testRejectedExcludedResolvedAndCompletedItemsAreExcludedEverywhere() {
        let project = ReviewFixtures.project(
            decisions: [ReviewFixtures.decision(status: .rejected)],
            actionItems: [ReviewFixtures.actionItem(status: .completed)],
            openQuestions: [ReviewFixtures.openQuestion(status: .resolved, reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [ReviewFixtures.agendaItem(status: .dismissed, reviewedAt: TestFixtures.laterDate)]
        )

        let result = summary(project)

        XCTAssertEqual(result.pendingProposalCount, 0)
        XCTAssertTrue(result.recentDecisions.isEmpty)
        XCTAssertTrue(result.activeActionItems.isEmpty)
        XCTAssertTrue(result.unresolvedQuestions.isEmpty)
        XCTAssertTrue(result.upcomingAgendaItems.isEmpty)
    }

    func testCancelledWorkIsExcludedButInProgressWorkIsKept() {
        func work(_ status: ActionItemStatus) -> ProjectStatusSummary {
            summary(ReviewFixtures.project(actionItems: [ReviewFixtures.actionItem(status: status)]))
        }

        XCTAssertEqual(work(.inProgress).activeActionItems.totalCount, 1)
        XCTAssertTrue(work(.cancelled).activeActionItems.isEmpty)
    }

    // MARK: - Recent decisions

    func testRecentDecisionsAreNewestFirstAndCappedAtThree() {
        let decisions = (0..<5).map { index in
            decision(
                suffix: String(format: "%02d", index),
                status: .confirmed,
                statement: "결정 \(index)",
                updatedAt: TestFixtures.fixedDate.addingTimeInterval(Double(index) * 60)
            )
        }

        let result = summary(ReviewFixtures.project(decisions: decisions))

        XCTAssertEqual(result.recentDecisions.totalCount, 5, "the count reports everything, not just what is shown")
        XCTAssertEqual(result.recentDecisions.items.map(\.statement), ["결정 4", "결정 3", "결정 2"])
        XCTAssertEqual(result.recentDecisions.hiddenCount, 2)
    }

    // MARK: - Work ordering

    func testWorkIsOrderedBySoonestDueDateWithUndatedWorkLast() {
        let project = ReviewFixtures.project(actionItems: [
            actionItem(suffix: "01", due: nil),
            actionItem(suffix: "02", due: TestFixtures.fixedDate.addingTimeInterval(7_200)),
            actionItem(suffix: "03", due: TestFixtures.fixedDate.addingTimeInterval(3_600)),
        ])

        let result = ProjectStatusSummary(project: project, referenceDate: reference, limit: 10)

        XCTAssertEqual(
            result.activeActionItems.items.map(\.title),
            ["업무 03", "업무 02", "업무 01"],
            "undated work sorts last rather than being dropped or treated as urgent"
        )
    }

    func testUndatedWorkIsNeverOverdueAndNoDateIsInvented() {
        var undated = ReviewFixtures.actionItem(status: .confirmed)
        undated.dueDate = nil

        let result = summary(ReviewFixtures.project(actionItems: [undated]))
        let stored = try? XCTUnwrap(result.activeActionItems.items.first)

        XCTAssertNil(stored?.dueDate, "a missing deadline stays missing")
        XCTAssertFalse(result.isOverdue(undated))
    }

    func testOverdueIsMeasuredAgainstTheReferenceDate() {
        var past = ReviewFixtures.actionItem(status: .confirmed)
        past.dueDate = reference.addingTimeInterval(-60)
        var future = ReviewFixtures.actionItem(status: .confirmed)
        future.dueDate = reference.addingTimeInterval(60)

        let result = summary(ReviewFixtures.project())

        XCTAssertTrue(result.isOverdue(past))
        XCTAssertFalse(result.isOverdue(future))
    }

    // MARK: - Empty and fully-populated projects

    func testEmptyProjectReportsEveryAreaEmptyRatherThanFailing() {
        let project = ReviewFixtures.project(
            decisions: [],
            actionItems: [],
            openQuestions: [],
            nextAgenda: []
        )

        let result = summary(project)

        XCTAssertEqual(result.pendingProposalCount, 0)
        XCTAssertTrue(result.recentDecisions.isEmpty)
        XCTAssertTrue(result.activeActionItems.isEmpty)
        XCTAssertTrue(result.unresolvedQuestions.isEmpty)
        XCTAssertTrue(result.upcomingAgendaItems.isEmpty)
        XCTAssertEqual(result.recentDecisions.hiddenCount, 0)
    }

    func testProjectWithAllFourAreasPopulatedAlongsidePendingProposals() {
        let project = Project(
            id: TestFixtures.projectID,
            name: "HAE.NA",
            summary: "",
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate,
            meetings: [ReviewFixtures.meeting()],
            decisions: [
                ReviewFixtures.decision(status: .confirmed),
                decision(suffix: "F1", status: .proposed),
            ],
            actionItems: [ReviewFixtures.actionItem(status: .confirmed)],
            openQuestions: [ReviewFixtures.openQuestion(reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [ReviewFixtures.agendaItem(reviewedAt: TestFixtures.laterDate)]
        )

        let result = summary(project)

        XCTAssertEqual(result.pendingProposalCount, 1, "only the still-unreviewed decision")
        XCTAssertEqual(result.recentDecisions.totalCount, 1)
        XCTAssertEqual(result.activeActionItems.totalCount, 1)
        XCTAssertEqual(result.unresolvedQuestions.totalCount, 1)
        XCTAssertEqual(result.upcomingAgendaItems.totalCount, 1)
    }

    // MARK: - Builders
    //
    // `id` is a `let` on the domain models, so these build whole values rather than copying a
    // fixture and reassigning — which is the point: an identity is decided at creation.

    private func decision(
        suffix: String,
        status: DecisionStatus,
        statement: String = "2월 출시로 진행한다",
        updatedAt: Date = TestFixtures.fixedDate
    ) -> Decision {
        Decision(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")!,
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            statement: statement,
            rationale: nil,
            status: status,
            evidence: ReviewFixtures.evidence,
            confidence: Confidence(0.8),
            createdAt: TestFixtures.fixedDate,
            updatedAt: updatedAt
        )
    }

    private func actionItem(suffix: String, due: Date?) -> ActionItem {
        ActionItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000CC\(suffix)")!,
            projectID: TestFixtures.projectID,
            meetingID: TestFixtures.meetingID,
            title: "업무 \(suffix)",
            details: nil,
            assigneeID: nil,
            dueDate: due,
            status: .confirmed,
            evidence: ReviewFixtures.evidence,
            confidence: Confidence(0.7),
            createdAt: TestFixtures.fixedDate,
            updatedAt: TestFixtures.fixedDate
        )
    }

    // MARK: - Persistence

    func testSummaryIsIdenticalAfterAJSONReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-Status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var dated = ReviewFixtures.actionItem(status: .confirmed)
        dated.dueDate = TestFixtures.fixedDate.addingTimeInterval(3_600)

        let project = ReviewFixtures.project(
            decisions: [ReviewFixtures.decision(status: .confirmed)],
            actionItems: [dated],
            openQuestions: [ReviewFixtures.openQuestion(reviewedAt: TestFixtures.laterDate)],
            nextAgenda: [ReviewFixtures.agendaItem(reviewedAt: TestFixtures.laterDate)]
        )

        let fileURL = directory.appendingPathComponent("projects.json")
        try await JSONProjectRepository(fileURL: fileURL).save(project)

        // A second repository over the same file is what relaunching the app actually does.
        let reloaded = try await JSONProjectRepository(fileURL: fileURL).project(id: TestFixtures.projectID)
        let reloadedProject = try XCTUnwrap(reloaded)

        XCTAssertEqual(summary(project), summary(reloadedProject))
    }
}
