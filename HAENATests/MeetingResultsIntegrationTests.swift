import XCTest
@testable import HAENA

/// The wiring behind the meeting results screen: a verdict goes through `WorkStateReviewService`,
/// the project is re-read from the repository, and the meeting's four areas are rebuilt from what
/// was actually stored.
///
/// The screen itself is a renderer with no rules of its own, so what is exercised here is the loop
/// it participates in — including the two things that must *not* move when it is used.
final class MeetingResultsIntegrationTests: XCTestCase {
    private typealias Fixtures = MeetingResultFixtures

    private var repository: InMemoryProjectRepository!
    private var service: WorkStateReviewService!

    override func setUp() {
        super.setUp()
        repository = InMemoryProjectRepository()
        service = WorkStateReviewService(repository: repository, now: { TestFixtures.laterDate })
    }

    override func tearDown() {
        repository = nil
        service = nil
        super.tearDown()
    }

    /// One proposal of each kind on meeting A, and one of each on meeting B.
    private func seededProject() -> Project {
        Fixtures.project(
            decisions: [
                Fixtures.decision(id: Fixtures.uuid(1)),
                Fixtures.decision(id: Fixtures.uuid(11), fromMeeting: Fixtures.meetingB)
            ],
            actionItems: [
                Fixtures.actionItem(id: Fixtures.uuid(2)),
                Fixtures.actionItem(id: Fixtures.uuid(12), fromMeeting: Fixtures.meetingB)
            ],
            openQuestions: [
                Fixtures.openQuestion(id: Fixtures.uuid(3)),
                Fixtures.openQuestion(id: Fixtures.uuid(13), fromMeeting: Fixtures.meetingB)
            ],
            nextAgenda: [
                Fixtures.agendaItem(id: Fixtures.uuid(4)),
                Fixtures.agendaItem(id: Fixtures.uuid(14), fromMeeting: Fixtures.meetingB)
            ]
        )
    }

    private func reloadedProject() async throws -> Project {
        // Hoisted out of `XCTUnwrap`: its argument is an autoclosure, which cannot carry an await.
        let loaded = try await repository.project(id: Fixtures.projectA)
        return try XCTUnwrap(loaded)
    }

    private func reloadedSummary(meetingID: UUID = Fixtures.meetingA) async throws -> MeetingWorkStateSummary {
        MeetingWorkStateSummary(project: try await reloadedProject(), meetingID: meetingID)
    }

    // MARK: - Approve

    func testApprovingEachKindIsVisibleAfterReloading() async throws {
        try await repository.save(seededProject())

        try await service.approveDecision(id: Fixtures.uuid(1), in: Fixtures.projectA)
        try await service.approveActionItem(id: Fixtures.uuid(2), in: Fixtures.projectA)
        try await service.approveOpenQuestion(id: Fixtures.uuid(3), in: Fixtures.projectA)
        try await service.approveAgendaItem(id: Fixtures.uuid(4), in: Fixtures.projectA)

        let summary = try await reloadedSummary()

        XCTAssertTrue(summary.decisions.needsReview.isEmpty)
        XCTAssertTrue(summary.actionItems.needsReview.isEmpty)
        XCTAssertTrue(summary.openQuestions.needsReview.isEmpty)
        XCTAssertTrue(summary.agendaItems.needsReview.isEmpty)

        XCTAssertEqual(summary.decisions.reviewed.map(\.id), [Fixtures.uuid(1)])
        XCTAssertEqual(summary.actionItems.reviewed.map(\.id), [Fixtures.uuid(2)])
        XCTAssertEqual(summary.openQuestions.reviewed.map(\.id), [Fixtures.uuid(3)])
        XCTAssertEqual(summary.agendaItems.reviewed.map(\.id), [Fixtures.uuid(4)])
    }

    // MARK: - Exclude

    func testExcludingEachKindMovesItToProcessed() async throws {
        try await repository.save(seededProject())

        try await service.rejectDecision(id: Fixtures.uuid(1), in: Fixtures.projectA)
        try await service.excludeActionItem(id: Fixtures.uuid(2), in: Fixtures.projectA)
        try await service.dismissOpenQuestion(id: Fixtures.uuid(3), in: Fixtures.projectA)
        try await service.dismissAgendaItem(id: Fixtures.uuid(4), in: Fixtures.projectA)

        let summary = try await reloadedSummary()

        XCTAssertEqual(summary.decisions.processed.map(\.id), [Fixtures.uuid(1)])
        XCTAssertEqual(summary.actionItems.processed.map(\.id), [Fixtures.uuid(2)])
        XCTAssertEqual(summary.openQuestions.processed.map(\.id), [Fixtures.uuid(3)])
        XCTAssertEqual(summary.agendaItems.processed.map(\.id), [Fixtures.uuid(4)])
        XCTAssertTrue(summary.isEmpty)
    }

    // MARK: - Correct an action item

    func testEditingAnActionItemAssigneeAndDueDateIsVisibleAfterReloading() async throws {
        try await repository.save(seededProject())
        let due = TestFixtures.fixedDate.addingTimeInterval(86_400)

        try await service.approveActionItem(id: Fixtures.uuid(2), in: Fixtures.projectA)
        try await service.updateActionItem(
            id: Fixtures.uuid(2),
            in: Fixtures.projectA,
            assigneeID: Fixtures.assignee.id,
            dueDate: due
        )

        let reviewed = try await reloadedSummary().actionItems.reviewed
        let item = try XCTUnwrap(reviewed.first)
        XCTAssertEqual(item.assigneeID, Fixtures.assignee.id)
        XCTAssertEqual(item.dueDate, due)
    }

    /// The screen offers the meeting's own roster, and the service refuses anyone else — an
    /// assignee who was never in the room must not become attachable from this surface either.
    func testAssigningSomeoneOutsideTheMeetingIsRejected() async throws {
        try await repository.save(seededProject())
        let stranger = UUID()

        do {
            try await service.updateActionItem(
                id: Fixtures.uuid(2),
                in: Fixtures.projectA,
                assigneeID: stranger,
                dueDate: nil
            )
            XCTFail("Expected an unknownAssignee failure")
        } catch {
            XCTAssertEqual(error as? WorkStateReviewError, .unknownAssignee)
        }

        let pending = try await reloadedSummary().actionItems.needsReview
        let item = try XCTUnwrap(pending.first)
        XCTAssertEqual(item.id, Fixtures.uuid(2))
    }

    // MARK: - The other meeting must not move

    func testApprovingOnOneMeetingLeavesTheOtherMeetingUntouched() async throws {
        try await repository.save(seededProject())
        let before = try await reloadedSummary(meetingID: Fixtures.meetingB)

        try await service.approveDecision(id: Fixtures.uuid(1), in: Fixtures.projectA)
        try await service.approveActionItem(id: Fixtures.uuid(2), in: Fixtures.projectA)
        try await service.approveOpenQuestion(id: Fixtures.uuid(3), in: Fixtures.projectA)
        try await service.approveAgendaItem(id: Fixtures.uuid(4), in: Fixtures.projectA)

        let after = try await reloadedSummary(meetingID: Fixtures.meetingB)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.decisions.needsReview.map(\.id), [Fixtures.uuid(11)])
        XCTAssertEqual(after.actionItems.needsReview.map(\.id), [Fixtures.uuid(12)])
        XCTAssertEqual(after.openQuestions.needsReview.map(\.id), [Fixtures.uuid(13)])
        XCTAssertEqual(after.agendaItems.needsReview.map(\.id), [Fixtures.uuid(14)])
    }

    // MARK: - No regression in what already existed

    /// The project-wide review screen reads the same stored data through `WorkStateInbox`. A
    /// verdict given on the meeting screen must land there identically — the two are one inbox seen
    /// from two places, not two lists that happen to agree.
    func testProjectWideReviewSeesTheSameVerdict() async throws {
        try await repository.save(seededProject())
        let before = try await reloadedProject()
        XCTAssertEqual(WorkStateInbox.pendingProposals(in: before).count, 8)

        try await service.approveDecision(id: Fixtures.uuid(1), in: Fixtures.projectA)

        let after = try await reloadedProject()
        XCTAssertEqual(WorkStateInbox.pendingProposals(in: after).count, 7)
        XCTAssertEqual(WorkStateInbox.confirmedDecisions(in: after).map(\.id), [Fixtures.uuid(1)])
    }

    /// Reviewing work state changes no words. The transcript export is built from the meeting's
    /// segments alone, and putting the results screen in front of the transcript must not have
    /// quietly coupled the two.
    func testTranscriptExportIsUnaffectedByReviewVerdicts() async throws {
        try await repository.save(seededProject())
        let renderer = MeetingTranscriptMarkdownRenderer()

        let before = try await reloadedProject()
        let beforeMeeting = try XCTUnwrap(before.meetings.first { $0.id == Fixtures.meetingA })
        let beforeMarkdown = renderer.render(meeting: beforeMeeting)

        try await service.approveDecision(id: Fixtures.uuid(1), in: Fixtures.projectA)
        try await service.excludeActionItem(id: Fixtures.uuid(2), in: Fixtures.projectA)

        let after = try await reloadedProject()
        let afterMeeting = try XCTUnwrap(after.meetings.first { $0.id == Fixtures.meetingA })

        XCTAssertEqual(renderer.render(meeting: afterMeeting), beforeMarkdown)
        XCTAssertTrue(MeetingTranscriptMarkdownRenderer.hasExportableContent(afterMeeting))
    }

    /// Stored audio is not part of work state either: approving a proposal must leave the meeting's
    /// recording — the thing the player resolves — exactly where it was.
    func testStoredAudioIsUnaffectedByReviewVerdicts() async throws {
        var project = seededProject()
        let asset = AudioAsset(
            id: Fixtures.uuid(700),
            storedFileName: "\(Fixtures.uuid(700).uuidString).m4a",
            originalFileName: "kickoff.m4a",
            byteSize: 1_024,
            importedAt: TestFixtures.fixedDate
        )
        project.meetings[0].audioAsset = asset
        try await repository.save(project)

        try await service.approveDecision(id: Fixtures.uuid(1), in: Fixtures.projectA)

        let after = try await reloadedProject()
        let meeting = try XCTUnwrap(after.meetings.first { $0.id == Fixtures.meetingA })
        XCTAssertEqual(meeting.audioAsset, asset)
    }
}
