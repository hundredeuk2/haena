import XCTest
@testable import HAENA

final class WorkStateReviewServiceTests: XCTestCase {
    private var repository: InMemoryProjectRepository!
    private var service: WorkStateReviewService!

    override func setUp() async throws {
        repository = InMemoryProjectRepository()
        try await repository.save(ReviewFixtures.project())
        service = WorkStateReviewService(repository: repository, now: { TestFixtures.laterDate })
    }

    private func storedProject() async throws -> Project {
        let project = try await repository.project(id: TestFixtures.projectID)
        return try XCTUnwrap(project)
    }

    // MARK: - Decisions

    func testApprovingADecisionConfirmsIt() async throws {
        try await service.approveDecision(id: ReviewFixtures.decisionID, in: TestFixtures.projectID)

        let project = try await storedProject()
        XCTAssertEqual(project.decisions[0].status, .confirmed)
        XCTAssertEqual(project.decisions[0].updatedAt, TestFixtures.laterDate)
        XCTAssertEqual(project.updatedAt, TestFixtures.laterDate)
    }

    func testRejectingADecisionKeepsTheRecordRatherThanDeletingIt() async throws {
        try await service.rejectDecision(id: ReviewFixtures.decisionID, in: TestFixtures.projectID)

        let project = try await storedProject()
        XCTAssertEqual(project.decisions.count, 1, "a rejected suggestion stays visible as considered-and-declined")
        XCTAssertEqual(project.decisions[0].status, .rejected)
    }

    func testApprovingPreservesTheEvidenceAndConfidence() async throws {
        try await service.approveDecision(id: ReviewFixtures.decisionID, in: TestFixtures.projectID)

        let project = try await storedProject()
        XCTAssertEqual(project.decisions[0].evidence, ReviewFixtures.evidence)
        XCTAssertEqual(project.decisions[0].confidence, Confidence(0.8))
    }

    // MARK: - Action items

    func testApprovingAndExcludingActionItems() async throws {
        try await service.approveActionItem(id: ReviewFixtures.actionItemID, in: TestFixtures.projectID)
        var project = try await storedProject()
        XCTAssertEqual(project.actionItems[0].status, .confirmed)

        try await service.excludeActionItem(id: ReviewFixtures.actionItemID, in: TestFixtures.projectID)
        project = try await storedProject()
        XCTAssertEqual(project.actionItems[0].status, .cancelled)
    }

    func testUpdatingAssigneeAndDueDate() async throws {
        let due = Date(timeIntervalSince1970: 1_800_000_000)

        try await service.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: ReviewFixtures.assignee.id,
            dueDate: due
        )

        let project = try await storedProject()
        XCTAssertEqual(project.actionItems[0].assigneeID, ReviewFixtures.assignee.id)
        XCTAssertEqual(project.actionItems[0].dueDate, due)
        XCTAssertEqual(project.actionItems[0].updatedAt, TestFixtures.laterDate)
    }

    func testClearingAssigneeAndDueDate() async throws {
        try await service.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: ReviewFixtures.assignee.id,
            dueDate: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try await service.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: nil,
            dueDate: nil
        )

        let project = try await storedProject()
        XCTAssertNil(project.actionItems[0].assigneeID)
        XCTAssertNil(project.actionItems[0].dueDate)
    }

    func testAssigningSomeoneWhoWasNotInTheMeetingIsRejectedAndChangesNothing() async throws {
        let outsider = UUID()

        do {
            try await service.updateActionItem(
                id: ReviewFixtures.actionItemID,
                in: TestFixtures.projectID,
                assigneeID: outsider,
                dueDate: nil
            )
            XCTFail("expected unknownAssignee")
        } catch {
            XCTAssertEqual(error as? WorkStateReviewError, .unknownAssignee)
        }

        let project = try await storedProject()
        XCTAssertNil(project.actionItems[0].assigneeID)
        XCTAssertEqual(project.updatedAt, TestFixtures.fixedDate, "a rejected edit must not touch the project")
    }

    // MARK: - Open questions

    func testApprovingAnOpenQuestionMarksItReviewedWithoutChangingItsStatus() async throws {
        try await service.approveOpenQuestion(id: ReviewFixtures.openQuestionID, in: TestFixtures.projectID)

        let project = try await storedProject()
        XCTAssertEqual(project.openQuestions[0].status, .open)
        XCTAssertEqual(project.openQuestions[0].reviewedAt, TestFixtures.laterDate)
    }

    func testDismissingAnOpenQuestion() async throws {
        try await service.dismissOpenQuestion(id: ReviewFixtures.openQuestionID, in: TestFixtures.projectID)

        let project = try await storedProject()
        XCTAssertEqual(project.openQuestions[0].status, .dismissed)
        XCTAssertEqual(project.openQuestions[0].reviewedAt, TestFixtures.laterDate)
    }

    func testResolvingAnOpenQuestionRecordsWhenItWasResolved() async throws {
        try await service.resolveOpenQuestion(id: ReviewFixtures.openQuestionID, in: TestFixtures.projectID)

        let project = try await storedProject()
        XCTAssertEqual(project.openQuestions[0].status, .resolved)
        XCTAssertEqual(project.openQuestions[0].resolvedAt, TestFixtures.laterDate)
        XCTAssertEqual(project.openQuestions[0].reviewedAt, TestFixtures.laterDate)
    }

    // MARK: - Agenda items

    func testApprovingAnAgendaItemMarksItReviewedWithoutChangingItsStatus() async throws {
        try await service.approveAgendaItem(id: ReviewFixtures.agendaItemID, in: TestFixtures.projectID)

        let project = try await storedProject()
        XCTAssertEqual(project.nextAgenda[0].status, .pending)
        XCTAssertEqual(project.nextAgenda[0].reviewedAt, TestFixtures.laterDate)
    }

    func testDismissingAnAgendaItemIsDistinctFromResolvingIt() async throws {
        try await service.dismissAgendaItem(id: ReviewFixtures.agendaItemID, in: TestFixtures.projectID)

        let project = try await storedProject()
        XCTAssertEqual(project.nextAgenda[0].status, .dismissed)
        XCTAssertNotEqual(project.nextAgenda[0].status, .resolved)
    }

    /// The Manual Brief now records agenda verdicts here rather than against a transition row, so
    /// a failed save has to leave the item exactly as the AI 제안 inbox last saw it. Reporting
    /// success on an unsaved verdict would put the two screens back out of step, which is the
    /// disagreement this path exists to remove.
    func testAgendaVerdictThatFailsToSaveLeavesTheItemUnreviewed() async throws {
        let failing = FailingSaveProjectRepository(project: ReviewFixtures.project())
        let failingService = WorkStateReviewService(repository: failing, now: { TestFixtures.laterDate })

        do {
            try await failingService.dismissAgendaItem(
                id: ReviewFixtures.agendaItemID,
                in: TestFixtures.projectID
            )
            XCTFail("expected the save failure to surface")
        } catch {
            // Expected: the caller must not treat this as a recorded verdict.
        }

        let loaded = try await failing.project(id: TestFixtures.projectID)
        let stored = try XCTUnwrap(loaded)
        let item = try XCTUnwrap(stored.nextAgenda.first { $0.id == ReviewFixtures.agendaItemID })
        XCTAssertEqual(item.status, .pending)
        XCTAssertNil(item.reviewedAt)
        XCTAssertEqual(
            WorkStateInbox.pendingProposals(in: stored).compactMap {
                if case .agendaItem(let value) = $0 { return value.id } else { return nil }
            },
            [ReviewFixtures.agendaItemID],
            "an unsaved verdict leaves the item on the inbox exactly as before"
        )
    }

    // MARK: - Errors

    func testUnknownItemIsReportedAndLeavesTheProjectUntouched() async throws {
        do {
            try await service.approveDecision(id: UUID(), in: TestFixtures.projectID)
            XCTFail("expected itemNotFound")
        } catch {
            XCTAssertEqual(error as? WorkStateReviewError, .itemNotFound)
        }

        let project = try await storedProject()
        XCTAssertEqual(project.decisions[0].status, .proposed)
        XCTAssertEqual(project.updatedAt, TestFixtures.fixedDate)
    }

    func testUnknownProjectIsReported() async throws {
        do {
            try await service.approveDecision(id: ReviewFixtures.decisionID, in: UUID())
            XCTFail("expected projectNotFound")
        } catch {
            XCTAssertEqual(error as? WorkStateReviewError, .projectNotFound)
        }
    }

    // MARK: - Review outcome feeds back into the inbox

    func testApprovedItemsLeaveThePendingInbox() async throws {
        var project = try await storedProject()
        XCTAssertEqual(WorkStateInbox.pendingProposals(in: project).count, 4)

        try await service.approveDecision(id: ReviewFixtures.decisionID, in: TestFixtures.projectID)
        try await service.approveActionItem(id: ReviewFixtures.actionItemID, in: TestFixtures.projectID)
        try await service.approveOpenQuestion(id: ReviewFixtures.openQuestionID, in: TestFixtures.projectID)
        try await service.approveAgendaItem(id: ReviewFixtures.agendaItemID, in: TestFixtures.projectID)

        project = try await storedProject()
        XCTAssertTrue(WorkStateInbox.pendingProposals(in: project).isEmpty)
        XCTAssertEqual(WorkStateInbox.confirmedDecisions(in: project).count, 1)
        XCTAssertEqual(WorkStateInbox.activeActionItems(in: project).count, 1)
        XCTAssertEqual(WorkStateInbox.reviewedOpenQuestions(in: project).count, 1)
        XCTAssertEqual(WorkStateInbox.reviewedAgendaItems(in: project).count, 1)
    }

    // MARK: - Persistence

    func testReviewDecisionsSurviveAJSONReload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HAENATests-Review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("projects.json")
        let writer = JSONProjectRepository(fileURL: fileURL)
        try await writer.save(ReviewFixtures.project())

        let fileBackedService = WorkStateReviewService(repository: writer, now: { TestFixtures.laterDate })
        try await fileBackedService.approveDecision(id: ReviewFixtures.decisionID, in: TestFixtures.projectID)
        try await fileBackedService.approveOpenQuestion(id: ReviewFixtures.openQuestionID, in: TestFixtures.projectID)
        try await fileBackedService.updateActionItem(
            id: ReviewFixtures.actionItemID,
            in: TestFixtures.projectID,
            assigneeID: ReviewFixtures.assignee.id,
            dueDate: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let reloadedProject = try await JSONProjectRepository(fileURL: fileURL).project(id: TestFixtures.projectID)
        let reloaded = try XCTUnwrap(reloadedProject)

        XCTAssertEqual(reloaded.decisions[0].status, .confirmed)
        XCTAssertEqual(reloaded.openQuestions[0].reviewedAt, TestFixtures.laterDate)
        XCTAssertEqual(reloaded.actionItems[0].assigneeID, ReviewFixtures.assignee.id)
        XCTAssertEqual(reloaded.actionItems[0].dueDate, Date(timeIntervalSince1970: 1_800_000_000))
    }
}

/// Serves the stored project but refuses every write, so a test can prove a verdict is only real
/// once it is saved.
private actor FailingSaveProjectRepository: ProjectRepository {
    private let stored: Project
    private enum Failure: Error { case save }

    init(project: Project) { stored = project }

    func save(_ project: Project) throws { throw Failure.save }
    func project(id: UUID) throws -> Project? { stored.id == id ? stored : nil }
    func allProjects() throws -> [Project] { [stored] }
    func delete(id: UUID) throws { throw Failure.save }
}
